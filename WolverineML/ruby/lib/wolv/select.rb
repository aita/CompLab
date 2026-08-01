# frozen_string_literal: true

require "set"
require_relative "dag"
require_relative "ir"
require_relative "liveness"
require_relative "mach"

module Wolv
  # Instruction selection: cover the DAG with ARM instructions.
  #
  # Every node that has to become a register of its own is tiled, largest tile
  # first, pulling its foldable operands into the tile as it goes.  The tiles
  # are the things ARM can do in one instruction that the IR needs several nodes
  # to say:
  #
  #     a + b * c            madd
  #     a - b * c            msub
  #     a + (b << k)         add with a shifted operand
  #     a + 4095             add with an immediate
  #     a * 8                lsl
  #     [a + 24]             a load with the addition as its displacement
  #     a < b, then branch   cmp, and a branch on the flags
  #
  # What comes out is still the same CFG, and still in SSA — a tile defines one
  # new register — so liveness, the allocator and the verifier carry on as
  # before.  What has gone is the guesswork the emitter used to do with its
  # peepholes: an instruction is now chosen where the whole expression is
  # visible, rather than by looking at the line before.
  module Select
    # What `add`, `sub` and `cmp` take as an immediate operand.
    IMMEDIATE = 4095

    LOGICAL = { "and" => "and", "or" => "orr", "xor" => "eor" }.freeze
    SHIFTS = { "shl" => "lsl", "shr" => "asr" }.freeze

    module_function

    def select_module(mod) = mod.funcs.each { |f| select(f) }

    def select(func)
      live = Liveness.analyse(func)
      func.walk.each do |b|
        graph = Dag.build(b, live.live_out[b.label])
        b.instrs = Selector.new(func, graph).run
      end
    end

    # The DAGs a selection would work on, for `wolv emit -s dag`.
    def graphs(func)
      live = Liveness.analyse(func)
      func.walk.to_h { |b| [b.label, Dag.build(b, live.live_out[b.label])] }
    end

    class Selector
      def initialize(func, graph)
        @func = func
        @graph = graph
        @out = []
        @done = Set.new
        @absorbed = Set.new
        @fused = nil
      end

      def run
        plan
        @graph.nodes.each_with_index do |node, i|
          next if @absorbed.include?(i)       # part of the tile that reads it
          next if @graph.rematerialisable(i)  # computed where a register wants it
          next if fuse_comparison(i)

          @done << i
          tile(node)
        end
        @out
      end

      # Decide which nodes a tile is going to swallow, before emitting any.
      #
      # Nothing may be deferred on the chance that its reader takes it.  A node
      # left out of the order and then not absorbed would be computed at its
      # reader instead, and a chain of those — `a + b + c + ...`, where every
      # term has one reader — would move the whole sum to its last line and keep
      # every term alive until then.
      def plan
        @graph.nodes.each do |node|
          next unless node.alone? && node.reader

          @absorbed << node.index if swallows?(@graph.nodes[node.reader], node)
        end
      end

      # Whether the instruction chosen for `reader` has room for `node`.
      def swallows?(reader, node)
        case reader.instr
        when IR::Bin
          %w[+ -].include?(reader.instr.op) && reader.operands[1] == node.index &&
            !(as_shift(node.index) || bin?(node, "*")).nil?
        when IR::Load, IR::Store
          reader.operands[0] == node.index && !displaces(node, reader.instr.offset).nil?
        else false
        end
      end

      # `[pointer + 24]`, when what is added to the pointer is a constant.  The
      # answer may be zero, so it is `nil` and not `false` that means "no".
      def displaces(node, offset)
        return nil unless bin?(node, "+")

        value = constant(node.operands[1])
        return nil unless value

        total = offset + value
        return total if total.between?(0, 32_760) && (total % IR::WORD).zero?
        return total if total.between?(-256, 255)

        nil
      end

      # -- emitting ---------------------------------------------------------

      def machine(form, dst, srcs, imm: 0, symbol: "", effect: false)
        @out << Mach.make(form, dst, srcs, imm: imm, symbol: symbol, effect: effect)
      end

      # The register holding an operand, computing it here if it was deferred.
      #
      # Only two kinds of node were left out of the order: a constant, which is
      # tiled the first time somebody needs it in a register and read from there
      # afterwards, and a node the plan said would be absorbed, which ends up
      # here only if the tile that was to absorb it changed its mind.
      def at(index, reg)
        node = @graph.of(index)
        return reg if node.nil? || @done.include?(node.index)

        deferred = @absorbed.include?(node.index) || !@graph.rematerialisable(node.index).nil?
        return reg unless deferred

        @done << node.index
        tile(node)
      end

      # Compute a deferred operand for a reader that has no tile to take it.
      def force(index)
        node = @graph.of(index)
        at(index, node.value || 0) unless node.nil?
      end

      # -- one node ---------------------------------------------------------

      def tile(node)
        instr = node.instr
        case instr
        when IR::Const
          machine("const", instr.dst, [], imm: instr.value)
          instr.dst
        when IR::StrConst
          machine("adr", instr.dst, [], symbol: instr.symbol)
          instr.dst
        when IR::Bin
          arithmetic(node, instr.dst, instr.op, instr.lhs, instr.rhs)
          instr.dst
        when IR::Cmp
          compare(node, instr.op, instr.lhs, instr.rhs)
          machine("cset", instr.dst, [], symbol: Mach::CONDITION[instr.op])
          instr.dst
        when IR::Load
          pointer, offset = address(node.operands[0], instr.base, instr.offset)
          machine("ldr", instr.dst, [pointer], imm: offset)
          instr.dst
        when IR::Store
          value = at(node.operands[1], instr.src)
          pointer, offset = address(node.operands[0], instr.base, instr.offset)
          machine("str", nil, [pointer, value], imm: offset, effect: true)
          instr.src
        else
          # Moves, calls, slot accesses and the terminator are machine
          # instructions already, and a phi is not in this list at all.  None of
          # them folds anything, so every operand that was left to be folded has
          # to be computed here instead.
          node.operands.each { |index| force(index) }
          @out << (instr.is_a?(IR::CBr) && @fused ? instr.with(code: @fused) : instr)
          instr.defs || 0
        end
      end

      # -- the tiles --------------------------------------------------------

      def arithmetic(node, dst, op, lhs, rhs)
        case op
        when "+", "-" then additive(node, dst, op, lhs, rhs)
        when "*" then multiply(node, dst, lhs, rhs)
        when "/" then machine("sdiv", dst, both(node, lhs, rhs))
        when "shl", "shr" then shift(node, dst, op, lhs, rhs)
        when "and", "or", "xor" then logical(node, dst, op, lhs, rhs)
        else raise "no instruction for `#{op}`"
        end
      end

      # Both operands in registers, which is what the plain forms want.
      def both(node, lhs, rhs)
        left = at(node.operands[0], lhs)
        [left, at(node.operands[1], rhs)]
      end

      # `add` and `sub`, in whichever of their four forms fits.
      def additive(node, dst, op, lhs, rhs)
        # A shifted operand comes first: `a + b * 8` is one instruction that way
        # and two as a multiply-add, because the 8 would need a register.
        return if shift_into(node, dst, op, lhs, rhs)
        return if multiply_into(node, dst, op, lhs, rhs)

        left, right = node.operands
        value = constant(right)
        if value&.between?(0, IMMEDIATE)
          return machine(op == "+" ? "addi" : "subi", dst, [at(left, lhs)], imm: value)
        end

        # Only addition may take its constant from the other side.
        value = op == "+" ? constant(left) : nil
        return machine("addi", dst, [at(right, rhs)], imm: value) if value&.between?(0, IMMEDIATE)

        machine(op == "+" ? "add" : "sub", dst, both(node, lhs, rhs))
      end

      def power_of_two?(value) = value.positive? && (value & (value - 1)).zero?

      def multiply(node, dst, lhs, rhs)
        value = constant(node.operands[1])
        if value && power_of_two?(value)
          return machine("lsli", dst, [at(node.operands[0], lhs)], imm: value.bit_length - 1)
        end

        machine("mul", dst, both(node, lhs, rhs))
      end

      def shift(node, dst, op, lhs, rhs)
        value = constant(node.operands[1])
        if value&.between?(0, 63)
          return machine("#{SHIFTS[op]}i", dst, [at(node.operands[0], lhs)], imm: value)
        end

        machine(SHIFTS[op], dst, both(node, lhs, rhs))
      end

      def logical(node, dst, op, lhs, rhs)
        # Which is how `not` arrives.
        if op == "xor" && constant(node.operands[1]) == 1
          return machine("eori", dst, [at(node.operands[0], lhs)], imm: 1)
        end

        machine(LOGICAL[op], dst, both(node, lhs, rhs))
      end

      # `a + b * c` and `a - b * c` are one instruction each.
      def multiply_into(node, dst, op, lhs, _rhs)
        product = @graph.of(node.operands[1])
        return false unless product&.alone? && bin?(product, "*")

        factors = [at(product.operands[0], product.instr.lhs),
                   at(product.operands[1], product.instr.rhs)]
        machine(op == "+" ? "madd" : "msub", dst, [*factors, at(node.operands[0], lhs)])
        true
      end

      # The second operand of an `add` may be shifted on the way in.
      def shift_into(node, dst, op, lhs, _rhs)
        shifted, amount = as_shift(node.operands[1])
        return false unless shifted

        machine(op == "+" ? "adds" : "subs", dst,
                [at(node.operands[0], lhs), at(shifted.operands[0], shifted.instr.lhs)],
                imm: amount)
        true
      end

      # A `x << k` that can be folded, however it was written: `* 8` says it
      # too.  This decides nothing and emits nothing, so the plan and the tiles
      # can both ask it and get the same answer.
      def as_shift(index)
        node = @graph.of(index)
        return nil unless node&.alone?

        amount = constant(node.operands[1])
        return nil if amount.nil?

        amount =
          case node.instr.op
          when "*" then power_of_two?(amount) ? amount.bit_length - 1 : nil
          when "shl" then amount
          end
        [node, amount] if amount&.between?(0, 63)
      end

      # A pointer and a displacement, taking in an addition if there is one.
      def address(index, base, offset)
        node = @graph.of(index)
        if node && node.alone?
          displaced = displaces(node, offset)
          return [at(node.operands[0], node.instr.lhs), displaced] unless displaced.nil?
        end
        [at(index, base), offset]
      end

      # -- comparisons and the branch that reads them -----------------------

      def compare(node, _op, lhs, rhs)
        left, right = node.operands
        value = constant(right)
        return machine("cmpi", nil, [at(left, lhs)], imm: value) if value&.between?(0, IMMEDIATE)


        machine("cmp", nil, [at(left, lhs), at(right, rhs)])
      end

      # A comparison the branch below it is the only reader of sets the flags.
      def fuse_comparison(index)
        nodes = @graph.nodes
        node = nodes[index]
        return false unless node.instr.is_a?(IR::Cmp) && index + 1 == nodes.length - 1

        terminator = nodes.last.instr
        return false unless terminator.is_a?(IR::CBr) && terminator.cond == node.instr.dst
        return false unless node.users == 1 && !node.escapes

        compare(node, node.instr.op, node.instr.lhs, node.instr.rhs)
        @fused = Mach::CONDITION[node.instr.op]
        true
      end

      # -- reading operands -------------------------------------------------

      def constant(index) = @graph.constant(index)

      def bin?(node, op) = node.instr.is_a?(IR::Bin) && node.instr.op == op
    end
  end
end
