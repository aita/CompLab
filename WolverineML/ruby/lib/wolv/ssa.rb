# frozen_string_literal: true

require "set"
require_relative "ir"

module Wolv
  # SSA construction, the textbook way.
  #
  # Dominators by the iterative algorithm of Cooper, Harvey and Kennedy,
  # dominance frontiers from those, phis at the frontiers of every definition,
  # and then one walk of the dominator tree renaming as it goes.  This is
  # minimal SSA and nothing cleverer: a phi is placed wherever the frontier
  # says, whether or not the variable is live there, and the dead ones leave in
  # `opt.rb`.
  #
  # Only registers written more than once take part.  Everything lowering
  # produced once — a temporary — is already in SSA and is left with the name it
  # has.
  module SSA
    Dominance = Struct.new(:idom, :children, :frontier, :order) do
      def dominates?(a, b)
        loop do
          return true if a == b

          parent = idom[b]
          return false if parent == b

          b = parent
        end
      end
    end

    module_function

    def dominance(func)
      order = IR.rpo(func)
      rank = order.each_with_index.to_h
      idom = { func.entry => func.entry }

      # The two runners climb until they meet, each time from the deeper one.
      intersect = lambda do |a, b|
        until a == b
          a = idom[a] while rank[a] > rank[b]
          b = idom[b] while rank[b] > rank[a]
        end
        a
      end

      changed = true
      while changed
        changed = false
        order.drop(1).each do |label|
          preds = func.blocks[label].preds.select { |p| idom.key?(p) }
          next if preds.empty?

          new = preds.drop(1).reduce(preds.first) { |acc, p| intersect.(p, acc) }
          next if idom[label] == new

          idom[label] = new
          changed = true
        end
      end

      children = order.to_h { |label| [label, []] }
      order.each do |label|
        parent = idom[label]
        children[parent] << label unless parent == label
      end

      frontier = order.to_h { |label| [label, Set.new] }
      order.each do |label|
        block = func.blocks[label]
        next if block.preds.length < 2

        block.preds.each do |pred|
          runner = pred
          while runner != idom[label] && idom.key?(runner)
            frontier[runner] << label
            runner = idom[runner]
          end
        end
      end
      Dominance.new(idom, children, frontier, order)
    end

    # Where each register is written, and how often.  A register written twice
    # in one block is as much a variable as one written in two blocks, so the
    # count is what decides, and the blocks are what the frontier walk needs.
    Defs = Struct.new(:blocks, :count) do
      def variables = count.select { |_, n| n > 1 }.keys.sort
    end

    def definitions(func)
      blocks = {}
      count = Hash.new(0)
      note = lambda do |r, label|
        (blocks[r] ||= Set.new) << label
        count[r] += 1
      end
      func.walk.each do |b|
        b.instrs.each { |i| note.(i.defs, b.label) if i.defs }
      end
      func.params.each { |p| note.(p, func.entry) }
      Defs.new(blocks, count)
    end

    # A phi for `v` at every dominance frontier of a block defining `v`.  What
    # each block's phis are for is kept beside them: the renamer needs the
    # variable, and the phi itself only remembers what it was renamed to.
    def place_phis(func, dom, defs)
      sites = defs.blocks
      phi_vars = func.blocks.keys.to_h { |label| [label, []] }
      defs.variables.each do |v|
        placed = Set.new
        work = sites[v].sort
        until work.empty?
          block = work.pop
          dom.frontier[block].sort.each do |target|
            next if placed.include?(target)

            placed << target
            phi_vars[target] << v
            func.blocks[target].phis << IR::Phi.new(v, func.blocks[target].preds.to_h { |p| [p, v] })
            work << target unless sites[v].include?(target)
          end
        end
      end
      phi_vars
    end

    # `stacks` is the reaching definition of each variable; `undefined` the
    # register a variable read on a path that never wrote it reads from.
    class Renamer
      attr_reader :variables

      def initialize(func, dom, phi_vars, variables)
        @func = func
        @dom = dom
        @phi_vars = phi_vars
        @variables = variables
        @stacks = {}
        @undefined = {}
      end

      # A register is a number, and zero is a register, so `||` is safe here only
      # because an empty stack answers `nil` and never `false`.
      def top(v) = @stacks[v]&.last || undefined(v)

      # A variable read on a path that never wrote it reads zero.
      def undefined(v) = @undefined[v] ||= @func.new_reg

      def plant_undefined
        entry = @func.blocks[@func.entry]
        @undefined.each_value { |r| entry.instrs.unshift(IR::Const.new(r, 0)) }
      end

      def rename(v)
        fresh = @func.new_reg
        (@stacks[v] ||= []) << fresh
        fresh
      end

      # The dominator tree, walked with an explicit stack so that what a block
      # pushed comes off again when its subtree is done.
      def run
        work = [[@func.entry, false]]
        pushed = {}
        until work.empty?
          label, done = work.pop
          if done
            pushed[label].each { |v| @stacks[v].pop }
            next
          end
          pushed[label] = block(label)
          work << [label, true]
          @dom.children[label].reverse_each { |child| work << [child, false] }
        end
      end

      def block(label)
        b = @func.blocks[label]
        mine = []
        b.phis.zip(@phi_vars[label]).each do |phi, v|
          phi.dst = rename(v)
          mine << v
        end
        b.instrs.map! do |instr|
          renamed = instr.map_uses { |r| @variables.include?(r) ? top(r) : r }
          d = renamed.defs
          if d && @variables.include?(d)
            mine << d
            renamed.with_def(rename(d))
          else
            renamed
          end
        end
        b.succs.each do |succ|
          @func.blocks[succ].phis.zip(@phi_vars[succ]).each do |phi, v|
            phi.args[label] = top(v)
          end
        end
        mine
      end
    end

    # Rewrite one function into SSA, in place.
    def construct(func)
      IR.recompute_preds(func)
      dom = dominance(func)
      defs = definitions(func)
      phi_vars = place_phis(func, dom, defs)
      renamer = Renamer.new(func, dom, phi_vars, Set.new(defs.variables))
      func.params.map! { |p| renamer.variables.include?(p) ? renamer.rename(p) : p }
      renamer.run
      renamer.plant_undefined
    end

    def construct_module(mod) = mod.funcs.each { |f| construct(f) }

    # Give every phi a place to put its copy in.
    #
    # An edge from a block with several successors into a block with several
    # predecessors has nowhere to hold the copies a phi turns into, so it gets a
    # block of its own.  The same goes for any edge into a block that still has
    # a phi, so that the emitter only ever has to put copies before a `jmp`.
    def split_critical_edges(func)
      func.order.dup.each do |label|
        block = func.blocks[label]
        next if block.succs.length < 2

        block.succs.dup.each do |succ|
          target = func.blocks[succ]
          next if target.preds.length < 2 && target.phis.empty?

          split = func.add_block("#{label}.#{succ}")
          split.instrs << IR::Jmp.new(succ)
          block.instrs[-1] = IR.rename_target(block.terminator, succ, split.label)
          target.phis.each do |phi|
            phi.args[split.label] = phi.args.delete(label) if phi.args.key?(label)
          end
        end
      end
      IR.recompute_preds(func)
    end

    # Check what SSA promises: one definition per register, and it dominates.
    def verify(func)
      dom = dominance(func)
      definition = {}
      claim = lambda do |r, where|
        raise "%#{r} is defined twice" if definition.key?(r)

        definition[r] = where
      end
      func.walk.each do |b|
        b.phis.each { |phi| claim.(phi.dst, b.label) }
        b.instrs.each { |i| claim.(i.defs, b.label) if i.defs }
      end
      func.params.each { |p| definition[p] ||= func.entry }

      reaches = lambda do |r, where, what|
        at = definition[r]
        raise "%#{r} is never defined" unless at
        raise "%#{r} does not reach #{what}" unless dom.dominates?(at, where)
      end
      func.walk.each do |b|
        b.phis.each do |phi|
          unless phi.args.keys.sort == b.preds.sort
            raise "the phi in #{b.label} does not name its predecessors"
          end

          phi.args.each { |pred, r| reaches.(r, pred, "#{b.label} through #{pred}") }
        end
        b.instrs.each do |i|
          i.uses.each { |r| reaches.(r, b.label, "its use in #{b.label}") }
        end
      end
    end
  end
end
