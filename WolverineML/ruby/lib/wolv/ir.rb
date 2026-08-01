# frozen_string_literal: true

module Wolv
  # The three-address IR, and the control flow graph both IRs are written in.
  #
  # There are two instruction sets in this compiler.  This file has the first:
  # three-address code over virtual registers, which is what lowering produces,
  # what `ssa.rb` puts into SSA and what `opt.rb` rewrites.  The second is in
  # `mach.rb`, and instruction selection replaces the arithmetic of this one
  # with it.
  #
  # What they share is everything else — the registers, the blocks, the graph,
  # the frame — so the passes that only care about the shape of a function
  # (liveness, dominance, the allocator, the verifiers) work on either, and
  # neither has to know what the other's instructions mean.  That is what the
  # methods in `Instr` are for: an instruction says which register it writes and
  # which it reads, and nothing outside it has to ask what it is.
  #
  # An instruction is a `Data`, which is to say a value: rewriting one answers
  # with a new one, and `Data#with` is what writes it.  A block, a function and a
  # phi are not values, because a pass moves them about and everything holding
  # one has to see that.
  module IR
    WORD = 8

    # How many arguments AAPCS64 passes in registers.  The rest go on the stack,
    # and the frame layout below knows where.
    ARGUMENT_REGISTERS = 8

    # Where a frame slot sits, relative to the frame pointer.
    #
    # Slot 0 of every nested function holds its static link, so a frame chain
    # can be walked without knowing whose frame it is.  Negative slots are the
    # arguments the caller had to pass on the stack: they are already in the
    # frame, above the saved frame record, so nothing has to be copied for them
    # and they never take a register at entry.
    def self.slot_offset(slot)
      slot.negative? ? 16 + WORD * (-slot - 1) : -WORD * (slot + 1)
    end

    # -- what every instruction of either set can be asked ------------------

    # A pass that walks a function asks these five questions and no others,
    # which is why one liveness analysis and one register allocator serve both
    # levels.  The defaults are for the instructions that answer nothing.
    module Instr
      def defs = nil
      def uses = []
      def map_uses = self
      def with_def(_reg) = raise "#{self.class} defines nothing"
      def effect? = false
    end

    # -- the three-address instructions -------------------------------------

    Const = Data.define(:dst, :value) do
      include Instr
      def defs = dst
      def with_def(reg) = with(dst: reg)
      def show(name) = "#{name.(dst)} = #{value}"
    end

    StrConst = Data.define(:dst, :symbol) do
      include Instr
      def defs = dst
      def with_def(reg) = with(dst: reg)
      def show(name) = "#{name.(dst)} = &#{symbol}"
    end

    Move = Data.define(:dst, :src) do
      include Instr
      def defs = dst
      def uses = [src]
      def map_uses(&f) = with(src: f.(src))
      def with_def(reg) = with(dst: reg)
      def show(name) = "#{name.(dst)} = #{name.(src)}"
    end

    Bin = Data.define(:dst, :op, :lhs, :rhs) do
      include Instr
      def defs = dst
      def uses = [lhs, rhs]
      def map_uses(&f) = with(lhs: f.(lhs), rhs: f.(rhs))
      def with_def(reg) = with(dst: reg)
      def show(name) = "#{name.(dst)} = #{name.(lhs)} #{op} #{name.(rhs)}"
    end

    Cmp = Data.define(:dst, :op, :lhs, :rhs) do
      include Instr
      def defs = dst
      def uses = [lhs, rhs]
      def map_uses(&f) = with(lhs: f.(lhs), rhs: f.(rhs))
      def with_def(reg) = with(dst: reg)
      def show(name) = "#{name.(dst)} = #{name.(lhs)} #{op} #{name.(rhs)}"
    end

    Load = Data.define(:dst, :base, :offset) do
      include Instr
      def defs = dst
      def uses = [base]
      def map_uses(&f) = with(base: f.(base))
      def with_def(reg) = with(dst: reg)
      def show(name) = "#{name.(dst)} = [#{name.(base)} + #{offset}]"
    end

    Store = Data.define(:base, :offset, :src) do
      include Instr
      def uses = [base, src]
      def map_uses(&f) = with(base: f.(base), src: f.(src))
      def effect? = true
      def show(name) = "[#{name.(base)} + #{offset}] = #{name.(src)}"
    end

    # -- the frame, calls and joins, which both instruction sets keep --------

    # Read a frame slot of this function — an escaping variable, or a spill.
    LoadSlot = Data.define(:dst, :slot) do
      include Instr
      def defs = dst
      def with_def(reg) = with(dst: reg)
      def show(name) = "#{name.(dst)} = slot#{slot}"
    end

    StoreSlot = Data.define(:slot, :src) do
      include Instr
      def uses = [src]
      def map_uses(&f) = with(src: f.(src))
      def effect? = true
      def show(name) = "slot#{slot} = #{name.(src)}"
    end

    # The frame pointer itself, which is what a static link points at.
    FrameAddr = Data.define(:dst) do
      include Instr
      def defs = dst
      def with_def(reg) = with(dst: reg)
      def show(name) = "#{name.(dst)} = frame"
    end

    # `dst` is nil when the call writes nothing.
    Call = Data.define(:dst, :callee, :args) do
      include Instr
      def defs = dst
      def uses = args
      def map_uses(&f) = with(args: args.map(&f))
      def with_def(reg) = with(dst: reg)
      def effect? = true

      def show(name)
        call = "#{callee}(#{args.map { |a| name.(a) }.join(', ')})"
        dst ? "#{name.(dst)} = #{call}" : call
      end
    end

    # -- control flow -------------------------------------------------------

    Jmp = Data.define(:target) do
      include Instr
      def effect? = true
      def show(_name) = "jmp #{target}"
    end

    # `code` empty means the branch tests `cond`.  After selection it may
    # instead read the flags a comparison just set, and then it reads no
    # register at all.
    CBr = Data.define(:cond, :then, :els, :code) do
      include Instr
      def uses = code.empty? ? [cond] : []
      def map_uses(&f) = code.empty? ? with(cond: f.(cond)) : self
      def effect? = true

      def show(name)
        test = code.empty? ? "#{name.(cond)} ?" : "#{code}?"
        "br #{test} #{self.then} : #{els}"
      end
    end

    # `value` is nil for a procedure's return.
    Ret = Data.define(:value) do
      include Instr
      def uses = value ? [value] : []
      def map_uses(&f) = value ? with(value: f.(value)) : self
      def effect? = true
      def show(name) = value ? "ret #{name.(value)}" : "ret"
    end

    TERMINATORS = [Jmp, CBr, Ret].freeze

    # The same terminator, with one of its targets renamed.
    def self.rename_target(instr, old, fresh)
      case instr
      when Jmp then instr.target == old ? Jmp.new(fresh) : instr
      when CBr
        instr.with(then: instr.then == old ? fresh : instr.then,
                   els: instr.els == old ? fresh : instr.els)
      else instr
      end
    end

    # -- phis ---------------------------------------------------------------

    # `args` is a hash from predecessor to register, and a hash rather than a
    # list because Ruby keeps one in the order things were put into it, which is
    # the order a dump has to print them in.
    Phi = Struct.new(:dst, :args) do
      def defs = dst
      def uses = []
      def show(name)
        "#{name.(dst)} = phi [#{args.map { |p, r| "#{p}: #{name.(r)}" }.join(', ')}]"
      end
    end

    # -- the graph ----------------------------------------------------------

    Block = Struct.new(:label, :phis, :instrs, :preds) do
      def terminator
        raise "block #{label} is unterminated" if instrs.empty?

        last = instrs.last
        raise "block #{label} falls through" unless TERMINATORS.any? { |k| last.is_a?(k) }

        last
      end

      def succs
        t = terminator
        case t
        when Jmp then [t.target]
        when CBr then t.then == t.els ? [t.then] : [t.then, t.els]
        else []
        end
      end
    end

    # One function: a frame, a set of parameters, and a graph of blocks.
    #
    # The last three are not part of the program — they are what the allocator
    # decided about it — but they live here because the emitter needs a function
    # and its colouring at once and there is nowhere else the two meet.
    class Func
      attr_reader :label, :name, :depth, :entry, :blocks, :order
      attr_accessor :params, :nregs, :nslots, :static_link_slot, :colours, :spill_slots, :saved

      def initialize(label, name, depth)
        @label = label
        @name = name
        @depth = depth
        @params = []
        @entry = "entry"
        @blocks = {}
        @order = []
        @nregs = 0
        @nslots = 0
        @static_link_slot = -1
        @colours = {}
        @spill_slots = {}
        @saved = []
      end

      def new_reg
        @nregs += 1
        @nregs - 1
      end

      def new_slot
        @nslots += 1
        @nslots - 1
      end

      def add_block(label)
        raise "block #{label} already exists" if @blocks.key?(label)

        b = Block.new(label, [], [], [])
        @blocks[label] = b
        @order << label
        b
      end

      # Every block, in the order they were made.
      def walk = @order.map { |l| @blocks[l] }

      def reg_name(reg)
        colour = @colours[reg]
        colour.nil? ? "%#{reg}" : "%#{reg}:#{colour}"
      end

      def naming = ->(reg) { reg_name(reg) }
    end

    Module = Struct.new(:funcs, :strings)

    def self.new_module = Module.new([], {})

    # -- rewiring -----------------------------------------------------------

    def self.recompute_preds(func)
      func.blocks.each_value { |b| b.preds = [] }
      func.walk.each do |b|
        b.succs.each { |s| func.blocks[s].preds << b.label }
      end
    end

    def self.reachable(func)
      seen = {}
      stack = [func.entry]
      until stack.empty?
        label = stack.pop
        next if seen[label]

        seen[label] = true
        stack.concat(func.blocks[label].succs)
      end
      seen
    end

    def self.drop_unreachable(func)
      live = reachable(func)
      func.blocks.keys.each { |label| func.blocks.delete(label) unless live[label] }
      func.order.select! { |label| live[label] }
      func.walk.each do |b|
        b.phis.each { |phi| phi.args = phi.args.select { |p, _| live[p] } }
      end
      recompute_preds(func)
    end

    # Reverse post-order, which is the order every dataflow pass walks in.
    def self.rpo(func)
      order = []
      seen = {}
      stack = [[func.entry, false]]
      until stack.empty?
        label, done = stack.pop
        if done
          order << label
          next
        end
        next if seen[label]

        seen[label] = true
        stack << [label, true]
        func.blocks[label].succs.reverse_each { |s| stack << [s, false] unless seen[s] }
      end
      order.reverse
    end

    # -- printing -----------------------------------------------------------

    def self.show_func(func)
      out = ["fun #{func.label}(#{func.params.map { |r| func.reg_name(r) }.join(', ')})" \
             "  ; depth #{func.depth}, #{func.nslots} slots"]
      name = func.naming
      func.walk.each do |b|
        preds = b.preds.empty? ? "" : "  ; preds: #{b.preds.join(', ')}"
        out << "#{b.label}:#{preds}"
        b.phis.each { |phi| out << "    #{phi.show(name)}" }
        b.instrs.each { |i| out << "    #{i.show(name)}" }
      end
      out.join("\n")
    end

    # A literal is a string of bytes, and this dump writes each one as the
    # character at that code point — which is what the other ports print,
    # because in them a literal is already a string of those characters.
    def self.show_text(text) = text.each_byte.map { |b| [b].pack("U") }.join

    def self.show_module(mod)
      parts = mod.funcs.map { |f| show_func(f) }
      unless mod.strings.empty?
        parts << mod.strings.map { |sym, text| "#{sym}: \"#{show_text(text)}\"" }.join("\n")
      end
      "#{parts.join("\n\n")}\n"
    end
  end
end
