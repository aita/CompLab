# frozen_string_literal: true

require "set"
require_relative "i64"
require_relative "ir"

module Wolv
  # Optimisation on SSA.
  #
  # Five small passes run to a fixed point.  Each is cheap because SSA makes it
  # cheap: a register has one definition, so constant folding and copy
  # propagation are a lookup rather than a dataflow problem, and a phi whose
  # arguments all agree is a copy that was never needed.
  #
  #     fold constants   ->  arithmetic on known values
  #     propagate copies ->  `Move`, and phis that turned into one
  #     simplify phis    ->  a phi with one distinct argument is that argument
  #     fold branches    ->  a branch on a known value, and the blocks it strands
  #     dead code        ->  anything computed and not used
  module Opt
    PASSES = %i[fold_constants propagate_copies simplify_phis fold_branches dead_code].freeze

    IDENTITY_RIGHT_ZERO = %w[+ - or xor shl shr].freeze
    IDENTITY_RIGHT_ONE = %w[* /].freeze

    module_function

    def optimise(mod) = mod.funcs.each { |f| optimise_func(f) }

    def optimise_func(func)
      # Every pass runs every round: they are cheap, and one enables another.
      loop do
        changes = PASSES.map { |pass| send(pass, func) }
        return unless changes.any?
      end
    end

    # -- rewriting ----------------------------------------------------------

    # Replace registers everywhere they are read, phi arguments included.  A
    # chain of copies is followed to its end, and the `seen` guard is what stops
    # a phi that was simplified into itself from spinning.
    def rewrite(func, mapping)
      return if mapping.empty?

      resolve = lambda do |r|
        seen = Set.new
        while mapping.key?(r) && !seen.include?(r)
          seen << r
          r = mapping[r]
        end
        r
      end
      func.walk.each do |b|
        b.phis.each { |phi| phi.args = phi.args.transform_values(&resolve) }
        b.instrs.map! { |i| i.map_uses(&resolve) }
      end
    end

    def constants(func)
      known = {}
      func.walk.each do |b|
        b.instrs.each { |i| known[i.dst] = i.value if i.is_a?(IR::Const) }
      end
      known
    end

    # -- the passes ---------------------------------------------------------

    def fold_constants(func)
      known = constants(func)
      changed = false
      func.walk.each do |b|
        b.instrs.map! do |instr|
          folded = fold(instr, known)
          next instr unless folded

          known[folded.dst] = folded.value if folded.is_a?(IR::Const)
          changed = true
          folded
        end
      end
      changed
    end

    def fold(instr, known)
      case instr
      when IR::Bin
        a = known[instr.lhs]
        b = known[instr.rhs]
        if a && b
          value = arith(instr.op, a, b)
          return value && IR::Const.new(instr.dst, value)
        end
        # The identities are worth having on their own: `x shl 0` and `x * 1`
        # come out of lowering an index, and folding them is what lets the
        # selector see one `add` where there were three instructions.
        return IR::Move.new(instr.dst, instr.lhs) if b == 0 && IDENTITY_RIGHT_ZERO.include?(instr.op)
        return IR::Move.new(instr.dst, instr.lhs) if b == 1 && IDENTITY_RIGHT_ONE.include?(instr.op)
        return IR::Move.new(instr.dst, instr.rhs) if a == 0 && instr.op == "+"

        nil
      when IR::Cmp
        a = known[instr.lhs]
        b = known[instr.rhs]
        return nil unless a && b

        IR::Const.new(instr.dst, order(instr.op, a, b) ? 1 : 0)
      end
    end

    # The arithmetic of the machine, done here rather than in the host's width.
    def arith(op, a, b)
      case op
      when "+" then I64.add(a, b)
      when "-" then I64.sub(a, b)
      when "*" then I64.mul(a, b)
      when "/" then b.zero? ? nil : I64.quotient(a, b)
      when "mod" then b.zero? ? nil : I64.remainder(a, b)
      when "and" then I64.and_(a, b)
      when "or" then I64.or_(a, b)
      when "xor" then I64.xor(a, b)
      when "shl" then I64.shl(a, b)
      when "shr" then I64.shr(a, b)
      end
    end

    def order(op, a, b)
      case op
      when "=" then a == b
      when "<>" then a != b
      when "<" then a < b
      when "<=" then a <= b
      when ">" then a > b
      when ">=" then a >= b
      when "u<" then I64.unsigned(a) < I64.unsigned(b)
      when "u>=" then I64.unsigned(a) >= I64.unsigned(b)
      else raise "unknown comparison #{op}"
      end
    end

    def propagate_copies(func)
      mapping = {}
      func.walk.each do |b|
        b.instrs.each { |i| mapping[i.dst] = i.src if i.is_a?(IR::Move) }
      end
      return false if mapping.empty?

      rewrite(func, mapping)
      func.walk.each { |b| b.instrs.reject! { |i| i.is_a?(IR::Move) } }
      true
    end

    def simplify_phis(func)
      mapping = {}
      changed = false
      func.walk.each do |b|
        b.phis = b.phis.reject do |phi|
          others = phi.args.values.reject { |r| r == phi.dst }.uniq
          next false unless others.one?

          mapping[phi.dst] = others.first
          changed = true
        end
      end
      rewrite(func, mapping) if changed
      changed
    end

    def fold_branches(func)
      known = constants(func)
      changed = false
      func.walk.each do |b|
        t = b.terminator
        next unless t.is_a?(IR::CBr)

        value = known[t.cond]
        next unless value || t.then == t.els

        taken = value&.zero? ? t.els : t.then
        b.instrs[-1] = IR::Jmp.new(taken)
        changed = true
      end
      IR.drop_unreachable(func) if changed
      changed
    end

    # Removing one dead value can make another dead, so this one has a fixed
    # point of its own rather than waiting for the next round.
    def dead_code(func)
      changed = false
      loop do
        used = Set.new
        func.walk.each do |b|
          b.phis.each { |phi| used.merge(phi.args.values) }
          b.instrs.each { |i| used.merge(i.uses) }
        end
        again = false
        func.walk.each do |b|
          phis = b.phis.select { |phi| used.include?(phi.dst) }
          if phis.length != b.phis.length
            b.phis = phis
            again = true
          end
          kept = b.instrs.reject do |i|
            d = i.defs
            !d.nil? && !used.include?(d) && !i.effect?
          end
          if kept.length != b.instrs.length
            b.instrs = kept
            again = true
          end
        end
        return changed unless again

        changed = true
      end
    end
  end
end
