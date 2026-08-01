# frozen_string_literal: true

module Wolv
  # Doing several copies at once, one at a time.
  #
  # A phi is a copy that happens on an edge, and all the phis of a block happen
  # together: every argument is read before any destination is written.  Once
  # the allocator has given both ends real registers that is a permutation, and
  # putting a permutation into a sequence of instructions is this module.
  #
  # Copies whose destination nobody else has still to read can go first.  When
  # only cycles are left, something has to be got out of the way, and there are
  # two ways to do it: a register the function never used can hold a value for
  # one step, and if there is no such register the two ends of the cycle swap.
  # A swap is three `eor`s and needs nothing to borrow, which is why no register
  # is reserved for this anywhere in the compiler.
  module Copies
    Mov = Data.define(:dst, :src)
    Swap = Data.define(:a, :b)

    module_function

    # Order `[destination, source]` pairs so that nothing is lost on the way.
    # `borrowed` is a register free to clobber, or nil.
    def sequentialize(moves, borrowed)
      real = moves.reject { |dst, src| dst == src }
      pending = real.to_h
      raise "a parallel copy writes a register twice" unless pending.length == real.length

      done = []
      until pending.empty?
        sources = pending.values.to_set
        ready = pending.keys.reject { |dst| sources.include?(dst) }
        if ready.any?
          ready.each { |dst| done << Mov.new(dst, pending.delete(dst)) }
          next
        end
        stuck = pending.keys.first
        if borrowed
          done << Mov.new(borrowed, stuck)
          moved(pending, stuck, borrowed)
          next
        end
        # Swapping satisfies `stuck` outright and leaves its old value where the
        # other end was, so everything still to read it reads there instead.
        other = pending.delete(stuck)
        done << Swap.new(stuck, other)
        moved(pending, stuck, other)
      end
      done
    end

    # The value that was in `was` is in `now`; whoever wanted it looks there.
    def moved(pending, was, now)
      pending.to_a.each do |dst, src|
        next unless src == was

        if dst == now
          pending.delete(dst) # the swap already put it where it belongs
        else
          pending[dst] = now
        end
      end
    end
  end
end
