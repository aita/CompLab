# frozen_string_literal: true

require "set"
require_relative "ir"

module Wolv
  # Leaving SSA before allocation.
  #
  # A phi is a copy that happens on an edge, so it becomes copies at the end of
  # each predecessor.  Critical edges are already split, so a predecessor of a
  # block with phis has nowhere else to go and the copies can simply be
  # appended.
  #
  # The copies of one edge happen at once: every argument is read before any
  # destination is written.  Usually that needs no care, because a phi's
  # destination is defined nowhere else and so is nobody's argument — but a
  # block that is its own predecessor can have two phis that swap, and then the
  # copies go through temporaries, which is Sreedhar's answer and which
  # coalescing is expected to remove again.
  module OutOfSSA
    module_function

    # Replace every phi in `func` with copies in its predecessors.
    def destruct(func)
      func.walk.each do |b|
        next if b.phis.empty?

        b.preds.each do |pred|
          source = func.blocks[pred]
          raise "#{pred} -> #{b.label} is a critical edge" unless source.succs.one?

          copy_in_parallel(func, source, b.phis.map { |phi| [phi.dst, phi.args[pred]] })
        end
        b.phis = []
      end
      IR.recompute_preds(func)
    end

    def destruct_module(mod) = mod.funcs.each { |f| destruct(f) }

    def copy_in_parallel(func, block, moves)
      real = moves.reject { |dst, src| dst == src }
      return if real.empty?

      written = Set.new(real.map(&:first))
      copies =
        if real.any? { |_, src| written.include?(src) }
          # Something read is also written, so the two halves cannot be one list.
          through = real.to_h { |dst, _| [dst, func.new_reg] }
          real.map { |dst, src| IR::Move.new(through[dst], src) } +
            real.map { |dst, _| IR::Move.new(dst, through[dst]) }
        else
          real.map { |dst, src| IR::Move.new(dst, src) }
        end
      block.instrs.insert(block.instrs.length - 1, *copies)
    end
  end
end
