# frozen_string_literal: true

require "set"
require_relative "graph"
require_relative "ir"
require_relative "liveness"
require_relative "registers"

module Wolv
  # The seam the allocator is reached through, and the verifier it answers to.
  #
  # There is one allocator here — leave SSA, build the interference graph,
  # colour it with Chaitin's algorithm and George and Appel's iterated
  # coalescing.  The Python tree has a second one that colours the SSA itself in
  # dominance order, and keeps both so that the two can be measured against each
  # other; this tree keeps the graph.
  module Allocator
    module_function

    def allocate_module(mod, machine = Registers.whole)
      mod.funcs.each { |f| Graph.allocate(f, machine) }
    end

    # No two values that hold different things at once may share a colour.
    #
    # The check is made where the interference graph joins values — at each
    # definition, and at the top of a block for the phis and the parameters,
    # which define several at once.  Looking at a whole live set instead would
    # be wrong, not merely slower: both ends of a copy are live after it and
    # hold the same value, so they may share a register, and that is the entire
    # point of coalescing.  A verifier that rejected it would reject every
    # program the coalescer had done its job on.
    #
    # Every value that interferes with another is caught this way, because the
    # later of the two definitions that put the values there happens while the
    # other is live.
    def verify(func)
      live = Liveness.analyse(func)
      func.walk.each do |b|
        alive = live.live_out[b.label].dup
        b.instrs.reverse_each do |instr|
          alive.delete(instr.src) if instr.is_a?(IR::Move)
          instr.uses.each { |r| raise "%#{r} has no colour" unless func.colours.key?(r) }
          d = instr.defs
          if d
            raise "%#{d} has no colour" unless func.colours.key?(d)

            alive << d
            no_clash(func, alive, d, b.label)
            alive.delete(d)
          end
          alive.merge(instr.uses)
        end

        entering = live.live_in[b.label].dup
        b.phis.each do |phi|
          raise "%#{phi.dst} has no colour" unless func.colours.key?(phi.dst)

          entering << phi.dst
          no_clash(func, entering, phi.dst, b.label)
        end
        next unless b.label == func.entry

        func.params.each do |param|
          entering << param
          no_clash(func, entering, param, b.label)
        end
      end
    end

    # Nothing else live here may hold the colour `written` was just given.
    def no_clash(func, alive, written, where)
      colour = func.colours[written]
      return unless colour

      other = alive.sort.find { |r| r != written && func.colours[r] == colour }
      raise "x#{colour} holds %#{written} and %#{other} at once in #{where}" if other
    end

    def verify_module(mod) = mod.funcs.each { |f| verify(f) }
  end
end
