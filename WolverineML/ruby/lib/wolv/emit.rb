# frozen_string_literal: true

require_relative "copies"
require_relative "ir"
require_relative "mach"
require_relative "registers"

module Wolv
  # ARMv8 assembly, in AAPCS64.
  #
  # The frame is the ordinary one.  `x29` points at the saved frame record, the
  # slots an escaping variable or a spill lives in are below it, the
  # callee-saved registers this function actually used are below those, and
  # outgoing stack arguments sit at the bottom, at `sp`, where the callee
  # expects them.
  #
  #     x29 -> | saved x29, x30 |
  #            | slot 0         |   x29 - 8      also where a static link points
  #            | slot 1         |   x29 - 16
  #            | ...            |
  #            | saved x19...   |
  #     sp  -> | outgoing args  |
  #
  # The allocator this tree keeps leaves SSA before it colours, so a phi never
  # reaches here.  The copies a phi stood for are already instructions, and the
  # only parallel copies left are the ones the ABI makes at a call and in the
  # prologue — which are still parallel, and still go through `sequentialize`:
  # when they form a cycle it borrows a register the function never used, and
  # when there is none it swaps the two ends with three `eor`s, so no register
  # has to be reserved for it.
  module Emit
    UNSCALED = { "ldr" => "ldur", "str" => "stur" }.freeze

    # The one register kept back.  A frame big enough to put a slot out of reach
    # of `ldur` is only discovered after allocation has added its spill slots,
    # so the address has to be computed somewhere the allocator does not know
    # about.
    SPARE = Registers::SCRATCH[0]

    # Nothing of ours is live at the top of the prologue except the incoming
    # arguments, so a caller-saved register that is not one of them is free.
    PROLOGUE_TEMP = 9

    Frame = Struct.new(:slots, :saved, :stack_args, :size) do
      def saved_offset(index) = -IR::WORD * (slots + index + 1)
    end

    module_function

    def frame_of(func)
      outgoing = func.walk.flat_map(&:instrs).grep(IR::Call)
                     .map { |i| i.args.length - Registers::ARGUMENT_REGS.length }
      stack_args = outgoing.push(0).max
      raw = IR::WORD * (func.nslots + func.saved.length + stack_args)
      Frame.new(func.nslots, func.saved, stack_args, (raw + 15) & ~15)
    end

    # Shut off, the copies swap instead — which is the path a test would never
    # reach on its own, because there is nearly always something to borrow.
    @borrow = true

    class << self
      attr_accessor :borrow
    end

    class FuncEmitter
      def initialize(func)
        @func = func
        @frame = Emit.frame_of(func)
        @out = []
        @epilogue = ".Lepi_#{func.label}"
        @read_somewhere = registers_read(func)
        @taken = func.colours.values.to_set
      end

      # -- helpers ----------------------------------------------------------

      def line(text) = @out << "\t#{text}"
      def label(text) = @out << "#{text}:"

      def colour(reg)
        @func.colours.fetch(reg) { raise "%#{reg} was never coloured" }
      end

      def mov(dst, src)
        line("mov x#{dst}, x#{src}") unless dst == src
      end

      # A 64-bit constant, in as many `movz`/`movk` as its non-zero halves need.
      def immediate(dst, value)
        word = value & ((1 << 64) - 1)
        return line("mov x#{dst}, #0") if word.zero?

        first = true
        [0, 16, 32, 48].each_with_index do |shift, i|
          chunk = (word >> shift) & 0xFFFF
          next if chunk.zero?

          suffix = i.zero? ? "" : ", lsl ##{i * 16}"
          line("#{first ? 'movz' : 'movk'} x#{dst}, ##{chunk}#{suffix}")
          first = false
        end
      end

      # `ldr`/`str`, in whichever addressing mode reaches this far.
      def access(op, reg, base, offset)
        where = base == 31 ? "sp" : "x#{base}"
        if offset.between?(0, 32_760) && (offset % IR::WORD).zero?
          line("#{op} x#{reg}, [#{where}, ##{offset}]")
        elsif offset.between?(-256, 255)
          line("#{UNSCALED[op]} x#{reg}, [#{where}, ##{offset}]")
        else
          immediate(SPARE, offset)
          line("#{op} x#{reg}, [#{where}, x#{SPARE}]")
        end
      end

      # -- whole functions --------------------------------------------------

      def emit
        @out << "\t.globl #{@func.label}"
        @out << "\t.type #{@func.label}, %function"
        label(@func.label)
        prologue
        order = @func.order
        order.each_with_index do |name, i|
          label(".L#{@func.label}_#{name}")
          block(@func.blocks[name], order[i + 1])
        end
        label(@epilogue)
        restore
        line("mov sp, x29")
        line("ldp x29, x30, [sp], #16")
        line("ret")
        @out << "\t.size #{@func.label}, .-#{@func.label}"
        @out
      end

      def prologue
        line("stp x29, x30, [sp, #-16]!")
        line("mov x29, sp")
        unless @frame.size.zero?
          if @frame.size <= 4095
            line("sub sp, sp, ##{@frame.size}")
          else
            immediate(PROLOGUE_TEMP, @frame.size)
            line("sub sp, sp, x#{PROLOGUE_TEMP}")
          end
        end
        @frame.saved.each_with_index { |reg, i| access("str", reg, 29, @frame.saved_offset(i)) }
        parallel(@func.params.each_with_index.filter_map do |p, i|
          [colour(p), Registers::ARGUMENT_REGS[i]] if @read_somewhere.include?(p)
        end)
      end

      def restore
        @frame.saved.each_with_index { |reg, i| access("ldr", reg, 29, @frame.saved_offset(i)) }
      end

      def block(b, nxt)
        b.instrs[0...-1].each { |i| instruction(i) }
        terminator(b, nxt)
      end

      def terminator(b, nxt)
        t = b.terminator
        where = ->(name) { ".L#{@func.label}_#{name}" }
        case t
        when IR::Jmp
          edge(b.label, t.target)
          line("b #{where.(t.target)}") unless t.target == nxt
        when IR::CBr
          if t.code.empty?
            branch_on_register(t, nxt, where)
          elsif t.then == nxt
            line("b.#{Mach::OPPOSITE[t.code]} #{where.(t.els)}")
          else
            line("b.#{t.code} #{where.(t.then)}")
            line("b #{where.(t.els)}") unless t.els == nxt
          end
        when IR::Ret
          mov(Registers::ARGUMENT_REGS[0], colour(t.value)) unless t.value.nil?
          # The epilogue follows the last block, so the last `ret` needs no
          # branch.
          line("b #{@epilogue}") unless nxt.nil?
        end
      end

      def branch_on_register(t, nxt, where)
        if t.then == nxt
          line("cbz x#{colour(t.cond)}, #{where.(t.els)}")
        else
          line("cbnz x#{colour(t.cond)}, #{where.(t.then)}")
          line("b #{where.(t.els)}") unless t.els == nxt
        end
      end

      # The copies a phi stands for, made real on this edge.  The allocator this
      # tree keeps left SSA already, so this is only ever asked of a block with
      # no phis.
      def edge(source, target)
        phis = @func.blocks[target].phis
        return if phis.empty?

        parallel(phis.map { |phi| [colour(phi.dst), colour(phi.args[source])] })
      end

      def parallel(moves)
        Copies.sequentialize(moves, borrowed(moves)).each do |step|
          case step
          when Copies::Mov then mov(step.dst, step.src)
          when Copies::Swap
            a = step.a
            b = step.b
            line("eor x#{a}, x#{a}, x#{b}")
            line("eor x#{b}, x#{a}, x#{b}")
            line("eor x#{a}, x#{a}, x#{b}")
          end
        end
      end

      # A register free to clobber here, if the function left one over.
      #
      # A caller-saved register this function never gave to a value holds
      # nothing of ours anywhere, and one that this copy neither reads nor
      # writes holds nothing of the copy's either.  With no such register the
      # copies swap instead, which needs no scratch at all.
      def borrowed(moves)
        return nil unless Emit.borrow

        touched = moves.flatten.to_set
        Registers::CALLER_SAVED.find { |reg| !@taken.include?(reg) && !touched.include?(reg) }
      end

      # -- one instruction --------------------------------------------------

      def instruction(instr)
        case instr
        when Mach::Instr then machine(instr)
        when IR::Move then mov(colour(instr.dst), colour(instr.src))
        when IR::LoadSlot then access("ldr", colour(instr.dst), 29, IR.slot_offset(instr.slot))
        when IR::StoreSlot then access("str", colour(instr.src), 29, IR.slot_offset(instr.slot))
        when IR::FrameAddr then mov(colour(instr.dst), 29)
        when IR::Call then call(instr.dst, instr.callee, instr.args)
        else raise "cannot emit #{instr.class}"
        end
      end

      # Write down one selected instruction, or the sequence it stands for.
      def machine(instr)
        srcs = instr.srcs.map { |s| colour(s) }
        case instr.form
        when "const" then immediate(colour(instr.dst), instr.imm)
        when "adr"
          d = colour(instr.dst)
          line("adrp x#{d}, #{instr.symbol}")
          line("add x#{d}, x#{d}, :lo12:#{instr.symbol}")
        when "ldr" then access("ldr", colour(instr.dst), srcs[0], instr.imm)
        when "str" then access("str", srcs[1], srcs[0], instr.imm)
        else
          names = { "{imm}" => instr.imm.to_s, "{sym}" => instr.symbol }
          srcs.each_with_index { |c, i| names["{s#{i}}"] = "x#{c}" }
          names["{d}"] = "x#{colour(instr.dst)}" unless instr.dst.nil?
          line(Mach::FORMS[instr.form].gsub(/\{\w+\}/) { |m| names.fetch(m, m) })
        end
      end

      def call(dst, callee, args)
        in_registers = args.take(Registers::ARGUMENT_REGS.length).each_with_index.map do |a, i|
          [Registers::ARGUMENT_REGS[i], colour(a)]
        end
        args.drop(Registers::ARGUMENT_REGS.length).each_with_index do |a, i|
          access("str", colour(a), 31, IR::WORD * i)
        end
        parallel(in_registers)
        line("bl #{callee}")
        mov(colour(dst), Registers::ARGUMENT_REGS[0]) unless dst.nil?
      end

      def registers_read(func)
        func.walk.each_with_object(Set.new) do |b, read|
          b.phis.each { |phi| read.merge(phi.args.values) }
          b.instrs.each { |i| read.merge(i.uses) }
        end
      end
    end

    # One character of a literal is one byte; write the ones `.ascii` cannot.
    def escape(text)
      text.each_byte.map do |ch|
        case ch
        when 0x22 then '\\"'
        when 0x5C then "\\\\"
        when 0x20...0x7F then ch.chr
        else format("\\%03o", ch)
        end
      end.join
    end

    def emit_module(mod)
      out = ["\t.text"]
      mod.funcs.each do |func|
        out.concat(FuncEmitter.new(func).emit)
        out << ""
      end
      unless mod.strings.empty?
        out << "\t.section .rodata"
        mod.strings.each do |symbol, text|
          out << "\t.p2align 3"
          out << "#{symbol}:"
          out << "\t.quad #{text.bytesize}"
          out << "\t.ascii \"#{escape(text)}\""
          out << "\t.byte 0"
        end
      end
      out << "\t.section .note.GNU-stack,\"\",%progbits"
      "#{out.join("\n")}\n"
    end
  end
end
