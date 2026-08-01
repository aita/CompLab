# frozen_string_literal: true

require "set"
require_relative "ir"
require_relative "ssa"

module Wolv
  # Spilling.
  #
  # A spilled value gets a frame slot, a store after every definition of it and
  # a reload in front of every use.  The reloads are new registers, live from
  # the load to the instruction under it and nowhere else, which is what makes
  # the pressure come down.  Nothing here assumes SSA: a value written twice
  # gets two stores, and a phi argument is reloaded at the end of the
  # predecessor it comes from, so the same rewrite serves the graph before and
  # after it left SSA.
  module Spill
    # Raised when spilling cannot help either.
    class OutOfRegisters < StandardError; end

    module_function

    # How deeply each block is nested in loops, for weighing what a use costs.
    #
    # A back edge is an edge into a block that dominates its source; everything
    # that can reach the source without leaving the dominated region is in that
    # loop.
    def loop_depth(func)
      dom = SSA.dominance(func)
      depth = func.blocks.keys.to_h { |label| [label, 0] }
      func.walk.each do |b|
        b.succs.each do |succ|
          next unless dom.dominates?(succ, b.label)

          body = Set[succ]
          stack = [b.label]
          until stack.empty?
            label = stack.pop
            next if body.include?(label)

            body << label
            stack.concat(func.blocks[label].preds)
          end
          body.each { |label| depth[label] += 1 }
        end
      end
      depth
    end

    # What spilling a value would cost: its reads and writes, weighed by loops.
    def costs(func)
      depth = loop_depth(func)
      weight = Hash.new(0.0)
      func.walk.each do |b|
        scale = (10**[depth[b.label], 4].min).to_f
        b.phis.each do |phi|
          phi.args.each { |pred, arg| weight[arg] += (10**[depth[pred], 4].min).to_f }
          weight[phi.dst] += scale
        end
        b.instrs.each do |i|
          i.uses.each { |r| weight[r] += scale }
          d = i.defs
          weight[d] += scale unless d.nil?
        end
      end
      weight
    end

    # Give `victim` a frame slot, and answer with the reloads that replaced it.
    def spill(func, victim)
      slot = func.new_slot
      func.spill_slots[victim] = slot
      param = func.params.include?(victim)
      reloads = Set.new

      func.walk.each do |b|
        b.instrs.unshift(IR::StoreSlot.new(slot, victim)) if b.phis.any? { |phi| phi.dst == victim }
        b.instrs.unshift(IR::StoreSlot.new(slot, victim)) if param && b.label == func.entry

        b.instrs = b.instrs.flat_map do |instr|
          # The store this pass just put in reads the victim on purpose.
          store = instr.is_a?(IR::StoreSlot) && instr.slot == slot
          reload = !store && instr.uses.include?(victim) && func.new_reg
          reloads << reload if reload
          [ (IR::LoadSlot.new(reload, slot) if reload),
            reload ? instr.map_uses { |r| r == victim ? reload : r } : instr,
            (IR::StoreSlot.new(slot, victim) if instr.defs == victim) ].compact
        end
      end

      func.walk.each do |b|
        b.phis.each do |phi|
          phi.args.to_a.each do |pred, arg|
            next unless arg == victim

            source = func.blocks[pred]
            fresh = func.new_reg
            reloads << fresh
            source.instrs.insert(source.instrs.length - 1, IR::LoadSlot.new(fresh, slot))
            phi.args[pred] = fresh
          end
        end
      end
      reloads
    end
  end
end
