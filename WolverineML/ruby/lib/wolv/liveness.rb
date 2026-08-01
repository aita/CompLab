# frozen_string_literal: true

require "set"
require_relative "ir"

module Wolv
  # Liveness on SSA.
  #
  # The only subtlety is the phi.  A phi does not read its arguments where it
  # stands; it reads them on the edges, so an argument is live at the end of the
  # predecessor it is paired with and not anywhere inside the block that holds
  # the phi.  Getting that wrong is what makes phi-related values interfere when
  # they should not.
  module Liveness
    Live = Struct.new(:live_in, :live_out)

    module_function

    def analyse(func)
      # What a block reads before writing, and what it writes at all.
      upward = {}
      killed = {}
      func.walk.each do |b|
        use = Set.new
        kill = Set.new
        b.phis.each { |phi| kill << phi.dst }
        b.instrs.each do |i|
          i.uses.each { |r| use << r unless kill.include?(r) }
          d = i.defs
          kill << d unless d.nil?
        end
        upward[b.label] = use
        killed[b.label] = kill
      end

      live = Live.new({}, {})
      func.blocks.each_key do |label|
        live.live_in[label] = Set.new
        live.live_out[label] = Set.new
      end

      order = IR.rpo(func).reverse
      changed = true
      while changed
        changed = false
        order.each do |label|
          block = func.blocks[label]
          out = Set.new
          block.succs.each do |succ|
            out |= live.live_in[succ]
            func.blocks[succ].phis.each do |phi|
              arg = phi.args[label]
              out << arg unless arg.nil?
            end
          end
          entering = upward[label] | (out - killed[label])
          next if out == live.live_out[label] && entering == live.live_in[label]

          live.live_out[label] = out
          live.live_in[label] = entering
          changed = true
        end
      end
      live
    end

    # Values that are live across a call, and so cannot sit in a scratch
    # register.
    def across_calls(func, live)
      func.walk.each_with_object(Set.new) do |b, out|
        backwards(b, live) { |i, after| out.merge(after) if i.is_a?(IR::Call) }
      end
    end

    # The most values live at any one point — the registers the function wants.
    def pressure(func, live)
      func.walk.flat_map { |b| sizes(b, live) }.max || 0
    end

    # How many values are live at each point the block passes through — where it
    # is entered, where it is left, and under every instruction.
    def sizes(b, live)
      entry = live.live_in[b.label] | b.phis.map(&:dst)
      alive = [live.live_out[b.label].size, entry.size]
      backwards(b, live) { |i, after| alive << (after | i.uses).size }
      alive
    end

    # Walk a block from its end, keeping what is live after each instruction.
    # The definition is taken away before the block sees it and the reads are
    # added after, because that is the order a backwards walk meets them.
    def backwards(b, live)
      after = live.live_out[b.label].dup
      b.instrs.reverse_each do |i|
        after.delete(i.defs) if i.defs
        yield(i, after)
        after.merge(i.uses)
      end
      after
    end
  end
end
