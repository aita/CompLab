# frozen_string_literal: true

require_relative "ast"
require_relative "ir"
require_relative "types"

module Wolv
  # Lowering: the typed syntax tree becomes a control flow graph.
  #
  # Two things are worth knowing about this pass.
  #
  # It never builds a phi.  A variable written in two branches is written to the
  # same register twice, and `ssa.rb` is what turns those two writes into one
  # phi.  Lowering only has to make sure a definition reaches every use, which
  # structured control flow does for free.
  #
  # It decides where a variable lives.  A variable the checker did not mark as
  # escaping becomes a register; one that escaped becomes a frame slot, reached
  # through `LoadSlot`/`StoreSlot` in its own function and through a chain of
  # static links from a nested one.
  module Lower
    Options = Struct.new(:checks, keyword_init: true) do
      def initialize(checks: true) = super
    end

    def self.lower(prog, opts = Options.new)
      Lowerer.new(opts).program(prog)
    end

    # Owns what the whole module shares: string literals and the function list.
    class Lowerer
      attr_reader :opts, :mod

      def initialize(opts)
        @opts = opts
        @mod = IR.new_module
        @symbols = {}
      end

      def string(text)
        @symbols[text] ||= begin
          symbol = ".Lstr#{@symbols.length}"
          @mod.strings[symbol] = text
          symbol
        end
      end

      def program(prog)
        FuncLowerer.new(self, "wol_main", "main", 0).top_level(prog)
        @mod
      end

      def function(bind)
        sym = bind.sym
        FuncLowerer.new(self, sym.label, sym.name, sym.depth).function_body(bind, sym)
      end
    end

    class FuncLowerer
      def initialize(up, label, name, depth)
        @up = up
        @opts = up.opts
        @func = IR::Func.new(label, name, depth)
        @cur = @func.add_block("entry")
        @breaks = []
        @counter = 0
        @has_children = false
        @func.static_link_slot = @func.new_slot if depth.positive?
        up.mod.funcs << @func
      end

      # -- block plumbing ---------------------------------------------------

      def fresh(hint)
        @counter += 1
        @func.add_block("#{hint}#{@counter}")
      end

      def emit(instr) = @cur.instrs << instr

      def terminate(term)
        emit(term)
        @cur = fresh("dead")
      end

      def jump(block) = terminate(IR::Jmp.new(block.label))

      def branch(cond, yes, no) = terminate(IR::CBr.new(cond, yes.label, no.label, ""))

      def reg = @func.new_reg

      def const(value)
        r = reg
        emit(IR::Const.new(r, value))
        r
      end

      # -- function bodies --------------------------------------------------

      def top_level(decls)
        declarations(decls)
        terminate(IR::Ret.new(nil))
        finish
      end

      def function_body(bind, sym)
        if @func.depth.positive?
          link = reg
          @func.params << link
          emit(IR::StoreSlot.new(@func.static_link_slot, link))
        end
        # The static link, if there is one, has taken the first register
        # already, so the parameters are numbered from where it left off.
        first = @func.params.length
        sym.params.each_with_index do |psym, i|
          index = first + i
          # The ninth argument and beyond is already in the frame when the
          # callee starts, at a negative slot, so it never takes a register.
          if index >= IR::ARGUMENT_REGISTERS
            psym.escapes = true
            psym.home = Types::InFrame.new(-(index - IR::ARGUMENT_REGISTERS + 1))
            next
          end
          r = reg
          @func.params << r
          if psym.escapes
            slot = @func.new_slot
            psym.home = Types::InFrame.new(slot)
            emit(IR::StoreSlot.new(slot, r))
          else
            psym.home = Types::InRegister.new(r)
          end
        end
        value = exp(bind.body)
        terminate(IR::Ret.new(sym.result == :unit ? nil : value))
        finish
      end

      def finish
        IR.drop_unreachable(@func)
        drop_unused_static_link
      end

      # A function nobody nests inside, and that never looks outward, keeps no
      # static link: the slot goes, and every later slot moves down one.
      def drop_unused_static_link
        slot = @func.static_link_slot
        return if slot.negative? || @has_children

        reads = @func.walk.any? do |b|
          b.instrs.any? { |i| i.is_a?(IR::LoadSlot) && i.slot == slot }
        end
        return if reads

        moved = ->(s) { s > slot ? s - 1 : s }
        @func.walk.each do |b|
          b.instrs = b.instrs.filter_map do |i|
            case i
            when IR::StoreSlot
              next if i.slot == slot

              i.with(slot: moved.(i.slot))
            when IR::LoadSlot then i.with(slot: moved.(i.slot))
            else i
            end
          end
        end
        @func.nslots -= 1
        @func.static_link_slot = -1
      end

      # -- declarations -----------------------------------------------------

      def declarations(decls)
        decls.each do |d|
          case d
          when Ast::TypeDecl then nil
          when Ast::ValDecl then val_decl(d)
          when Ast::FunDecl
            @has_children = true
            d.binds.each { |b| @up.function(b) }
          end
        end
      end

      def val_decl(d)
        value = exp(d.init)
        sym = d.sym
        bind(sym, value) if sym && sym.ty != :unit
      end

      # Give a variable its home, and put the initial value in it.
      def bind(sym, value)
        if sym.escapes
          slot = @func.new_slot
          sym.home = Types::InFrame.new(slot)
          emit(IR::StoreSlot.new(slot, value))
        else
          r = reg
          sym.home = Types::InRegister.new(r)
          emit(IR::Move.new(r, value))
        end
      end

      # -- reaching variables and frames ------------------------------------

      # A register holding the frame pointer of the function at `depth`.
      def frame_at(depth)
        r = reg
        if depth == @func.depth
          emit(IR::FrameAddr.new(r))
          return r
        end
        emit(IR::LoadSlot.new(r, @func.static_link_slot))
        here = @func.depth - 1
        while here > depth
          nxt = reg
          emit(IR::Load.new(nxt, r, IR.slot_offset(0)))
          r = nxt
          here -= 1
        end
        r
      end

      def read_var(sym)
        return sym.reg unless sym.escapes

        if sym.depth == @func.depth
          r = reg
          emit(IR::LoadSlot.new(r, sym.slot))
          return r
        end
        base = frame_at(sym.depth)
        r = reg
        emit(IR::Load.new(r, base, IR.slot_offset(sym.slot)))
        r
      end

      # The three shapes `read_var` has, written the same way round.
      def write_var(sym, value)
        return emit(IR::Move.new(sym.reg, value)) unless sym.escapes
        return emit(IR::StoreSlot.new(sym.slot, value)) if sym.depth == @func.depth

        emit(IR::Store.new(frame_at(sym.depth), IR.slot_offset(sym.slot), value))
      end

      # -- expressions ------------------------------------------------------

      def value(e) = exp(e) or raise "expected a value from #{e.class}"

      def exp(e)
        case e
        in Ast::IntLit(value:) then const(value)
        in Ast::BoolLit(value:) then const(value ? 1 : 0)
        in Ast::NilLit then const(0)
        in Ast::UnitLit then nil
        in Ast::StrLit(value: text)
          r = reg
          emit(IR::StrConst.new(r, @up.string(text)))
          r
        in Ast::Var(sym:) then read_var(sym)
        in Ast::Call then call(e)
        in Ast::RecordLit then record(e)
        in Ast::Index then index(e)
        in Ast::Field then field(e)
        in Ast::Neg(operand:)
          zero = const(0)
          binop("-", zero, value(operand))
        in Ast::Bin then bin(e)
        in Ast::Logic then logic(e)
        in Ast::Assign
          assign(e)
          nil
        in Ast::If then if_exp(e)
        in Ast::While
          while_exp(e)
          nil
        in Ast::For
          for_exp(e)
          nil
        in Ast::Break
          terminate(IR::Jmp.new(@breaks.last))
          nil
        in Ast::Seq(items:)
          items.reduce(nil) { |_, item| exp(item) }
        in Ast::Let(decls:, body:)
          declarations(decls)
          exp(body)
        end
      end

      def binop(op, lhs, rhs)
        r = reg
        emit(IR::Bin.new(r, op, lhs, rhs))
        r
      end

      def compare(op, lhs, rhs)
        r = reg
        emit(IR::Cmp.new(r, op, lhs, rhs))
        r
      end

      def call_runtime(name, args)
        r = reg
        emit(IR::Call.new(r, name, args))
        r
      end

      def bin(e)
        lhs = value(e.lhs)
        rhs = value(e.rhs)
        case e.op
        when "^" then call_runtime("wol_concat", [lhs, rhs])
        when "/", "mod"
          check_nonzero(rhs)
          if e.op == "/"
            binop("/", lhs, rhs)
          else
            # The remainder is spelled out rather than left to the emitter: the
            # quotient it needs in between is a value like any other, and the
            # allocator can find it a register.  The emitter fuses the last two
            # back into one `msub`.
            quotient = binop("/", lhs, rhs)
            product = binop("*", quotient, rhs)
            binop("-", lhs, product)
          end
        when "+", "-", "*" then binop(e.op, lhs, rhs)
        else
          if e.lhs.ty == :string
            order = call_runtime("wol_string_cmp", [lhs, rhs])
            compare(e.op, order, const(0))
          else
            compare(e.op, lhs, rhs)
          end
        end
      end

      # `andalso` and `orelse` are branches, so the result needs a register.
      def logic(e)
        result = reg
        rhs_block = fresh("logic")
        join = fresh("logicjoin")
        lhs = value(e.lhs)
        emit(IR::Move.new(result, lhs))
        if e.op == "andalso"
          branch(lhs, rhs_block, join)
        else
          branch(lhs, join, rhs_block)
        end
        @cur = rhs_block
        emit(IR::Move.new(result, value(e.rhs)))
        jump(join)
        @cur = join
        result
      end

      def call(e)
        sym = e.sym
        case sym.builtin
        when "not" then return binop("xor", value(e.args[0]), const(1))
        when "array"
          n = value(e.args[0])
          init = value(e.args[1])
          return call_runtime("wol_array", [n, init])
        when "length"
          arr = value(e.args[0])
          check_not_nil(arr)
          r = reg
          emit(IR::Load.new(r, arr, 0))
          return r
        end
        args = e.args.map { |a| value(a) }
        args = [frame_at(sym.depth - 1), *args] unless sym.builtin
        if sym.result == :unit
          emit(IR::Call.new(nil, sym.label, args))
          nil
        else
          call_runtime(sym.label, args)
        end
      end

      def record(e)
        size = const(IR::WORD * [e.ty.fields.length, 1].max)
        base = call_runtime("wol_alloc", [size])
        e.fields.each_with_index do |f, i|
          emit(IR::Store.new(base, IR::WORD * i, value(f.value)))
        end
        base
      end

      def index(e)
        addr = element_address(e)
        r = reg
        emit(IR::Load.new(r, addr, IR::WORD))
        r
      end

      # The address of `a[i]`, without the length word the elements follow.
      #
      # The selector turns this into one `add` with a shifted operand, and the
      # word is the load's displacement, so the two instructions that come out
      # are the two the machine has.
      def element_address(e)
        base = value(e.array)
        idx = value(e.index)
        check_not_nil(base)
        check_bounds(base, idx)
        binop("+", base, binop("shl", idx, const(3)))
      end

      def field(e)
        base = value(e.record)
        check_not_nil(base)
        r = reg
        emit(IR::Load.new(r, base, IR::WORD * e.offset))
        r
      end

      def assign(e)
        case e.target
        when Ast::Var then write_var(e.target.sym, value(e.value))
        when Ast::Index
          addr = element_address(e.target)
          emit(IR::Store.new(addr, IR::WORD, value(e.value)))
        when Ast::Field
          base = value(e.target.record)
          check_not_nil(base)
          emit(IR::Store.new(base, IR::WORD * e.target.offset, value(e.value)))
        end
      end

      def if_exp(e)
        result = e.ty == :unit ? nil : reg
        yes = fresh("then")
        no = fresh("else")
        join = fresh("join")
        branch(value(e.cond), yes, no)

        @cur = yes
        got = exp(e.then)
        emit(IR::Move.new(result, got)) if result && got
        jump(join)

        @cur = no
        if e.els
          got = exp(e.els)
          emit(IR::Move.new(result, got)) if result && got
        end
        jump(join)

        @cur = join
        result
      end

      def in_loop(done)
        @breaks.push(done.label)
        yield
        @breaks.pop
      end

      def while_exp(e)
        test = fresh("test")
        body = fresh("body")
        done = fresh("done")
        jump(test)
        @cur = test
        branch(value(e.cond), body, done)
        @cur = body
        in_loop(done) { exp(e.body) }
        jump(test)
        @cur = done
      end

      # `for i = lo to hi` counts up, and stops before overflowing at `hi`.
      def for_exp(e)
        sym = e.sym
        lo = value(e.lo)
        hi_value = value(e.hi)
        hi = reg
        emit(IR::Move.new(hi, hi_value))
        bind(sym, lo)
        body = fresh("forbody")
        step = fresh("forstep")
        done = fresh("fordone")
        branch(compare("<=", lo, hi), body, done)

        @cur = body
        in_loop(done) { exp(e.body) }
        branch(compare("<", read_var(sym), hi), step, done)

        @cur = step
        write_var(sym, binop("+", read_var(sym), const(1)))
        jump(body)

        @cur = done
      end

      # -- run-time checks --------------------------------------------------

      # Each of the three is the same shape: a branch to a block that calls the
      # runtime and never comes back, and a block where the program carries on.
      def guard(hint, test, bad_first, instr)
        bad = fresh(hint)
        ok = fresh("ok")
        if bad_first
          branch(test, bad, ok)
        else
          branch(test, ok, bad)
        end
        @cur = bad
        emit(instr)
        jump(ok)
        @cur = ok
      end

      def check_not_nil(base)
        return unless @opts.checks

        guard("nil", compare("=", base, const(0)), true, IR::Call.new(nil, "wol_nil_error", []))
      end

      def check_bounds(base, idx)
        return unless @opts.checks

        len = reg
        emit(IR::Load.new(len, base, 0))
        guard("oob", compare("u<", idx, len), false,
              IR::Call.new(nil, "wol_bounds_error", [idx, len]))
      end

      def check_nonzero(rhs)
        return unless @opts.checks

        guard("divzero", compare("=", rhs, const(0)), true,
              IR::Call.new(nil, "wol_div_error", []))
      end
    end
  end
end
