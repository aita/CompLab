# frozen_string_literal: true

require "set"
require_relative "hints"
require_relative "ir"
require_relative "liveness"
require_relative "registers"
require_relative "spill"

module Wolv
  # Register allocation by graph colouring, with iterated coalescing.
  #
  # The idea is Chaitin's: build a graph whose nodes are values and whose edges
  # join values that are live at the same time, then colour it with as many
  # colours as the machine has registers.  Colouring a graph is hard in general,
  # but Kempe's observation makes it practical: a node with fewer than K
  # neighbours can always be coloured whatever happens to the rest of the graph.
  # So remove such nodes one at a time and push them on a stack; when the graph
  # is empty, pop the stack and give each node a colour its neighbours have not
  # taken.  If every remaining node has K or more neighbours, guess that one of
  # them will not get a colour and carry on — if the guess was wrong the value
  # is rewritten to live in memory and the whole thing runs again (Briggs'
  # optimistic colouring).
  #
  # On top of that sits coalescing, which is why leaving SSA first costs
  # nothing.  Leaving SSA fills the predecessors of every join with copies;
  # coalescing merges the two ends of a copy so that it disappears.  Merging
  # aggressively can make a graph uncolourable, so a merge only happens when
  # Briggs' test proves it cannot: the merged node must have fewer than K
  # neighbours of significant degree.  That test is only exact enough to be
  # useful if degrees are up to date, and simplifying lowers degrees while
  # merging raises them — so the two run interleaved, with freezing (giving up
  # on a copy so its nodes can be simplified) as the way out when neither
  # applies.  Hence "iterated" (George and Appel, 1996).
  #
  # This machine has no fixed registers to colour against, so the calling
  # convention is carried as a set of colours each node may not take: a value
  # live across a call may not take a caller-saved one.  A node with `f`
  # forbidden colours and `d` neighbours needs `d + f < K` to be trivially
  # colourable, so that sum is what stands in for the degree everywhere below.
  module Graph
    module_function

    # Colour `func`, rewriting and starting again for as long as it spills.
    def allocate(func, machine)
      protected_regs = Set.new
      loop do
        IR.recompute_preds(func)
        colouring = Colouring.new(func, machine, protected_regs)
        spilled = colouring.run
        if spilled.empty?
          func.colours = colouring.colour
          func.saved = func.colours.values.uniq.intersection(Registers::CALLEE_SAVED).sort
          return
        end
        spilled.sort.each do |victim|
          if protected_regs.include?(victim)
            raise Spill::OutOfRegisters,
                  "`#{func.name}` needs more registers at once than the machine has"
          end

          protected_regs |= Spill.spill(func, victim)
        end
      end
    end

    # `protected_regs` holds values a previous round produced by reloading
    # something.  Their live ranges are a load and its one use, so spilling one
    # again would only make another of the same, and the rewriting would never
    # end.
    class Colouring
      attr_reader :colour

      def initialize(func, machine, protected_regs)
        @func = func
        @machine = machine
        @protected = protected_regs

        @adjacent = {}
        @degree = {}
        @forbidden = {}
        @preferred = {}

        @moves = []
        @moves_of = Hash.new { |h, r| h[r] = Set.new }
        @worklist_moves = Set.new
        @active_moves = Set.new

        @simplify_worklist = Set.new
        @freeze_worklist = Set.new
        @spill_worklist = Set.new
        @select_stack = []
        @on_stack = Set.new
        @coalesced = Set.new
        @alias = {}
        @colour = {}
      end

      def k = @machine.count

      def run
        build
        make_worklists
        until @simplify_worklist.empty? && @worklist_moves.empty? &&
              @freeze_worklist.empty? && @spill_worklist.empty?
          if @simplify_worklist.any? then simplify
          elsif @worklist_moves.any? then coalesce
          elsif @freeze_worklist.any? then freeze
          else select_spill
          end
        end
        assign_colours
      end

      # -- the graph --------------------------------------------------------

      def node(r)
        return if @adjacent.key?(r)

        @adjacent[r] = Set.new
        @degree[r] = 0
        @forbidden[r] = Set.new
      end

      def add_edge(a, b)
        return if a == b || @adjacent[a].include?(b)

        @adjacent[a] << b
        @adjacent[b] << a
        @degree[a] += 1
        @degree[b] += 1
      end

      # The degree, counting a forbidden colour as a neighbour holding it.
      def weight(r) = @degree[r] + @forbidden[r].size

      def build
        @preferred = Hints.preferences(@func)
        live = Liveness.analyse(@func)
        caller_saved = @machine.caller.to_set
        @func.walk.each do |b|
          b.instrs.each do |i|
            i.uses.each { |r| node(r) }
            node(i.defs) unless i.defs.nil?
          end
        end
        @func.params.each { |r| node(r) }

        @func.walk.each do |b|
          alive = live.live_out[b.label].dup
          b.instrs.reverse_each do |instr|
            if instr.is_a?(IR::Move)
              alive.delete(instr.src)
              index = @moves.length
              @moves << [instr.dst, instr.src]
              [instr.dst, instr.src].each { |end_| @moves_of[end_] << index }
              @worklist_moves << index
            end
            defined = instr.defs
            unless defined.nil?
              alive << defined
              alive.sort.each { |other| add_edge(defined, other) }
            end
            # A value live across a call cannot sit in a caller-saved register.
            if instr.is_a?(IR::Call)
              alive.each { |r| @forbidden[r] |= caller_saved unless r == defined }
            end
            alive.delete(defined) unless defined.nil?
            alive.merge(instr.uses)
          end
          entry_edges(alive) if b.label == @func.entry
        end
      end

      # Parameters arrive together, so they interfere with each other.
      def entry_edges(alive)
        @func.params.each_with_index do |param, i|
          alive.sort.each { |other| add_edge(param, other) }
          @func.params[(i + 1)..].each { |another| add_edge(param, another) }
        end
      end

      # -- the worklists ----------------------------------------------------

      def make_worklists
        @adjacent.keys.sort.each do |r|
          if weight(r) >= k then @spill_worklist << r
          elsif move_related?(r) then @freeze_worklist << r
          else @simplify_worklist << r
          end
        end
      end

      # Every set here is walked in increasing order, because which node is
      # simplified first and which copy is looked at first decide the colouring.
      def node_moves(r)
        @moves_of[r].sort.select { |i| @active_moves.include?(i) || @worklist_moves.include?(i) }
      end

      def move_related?(r) = node_moves(r).any?

      def neighbours(r) = (@adjacent[r] - @on_stack - @coalesced).sort

      def simplify
        r = @simplify_worklist.min
        @simplify_worklist.delete(r)
        @select_stack << r
        @on_stack << r
        neighbours(r).each { |other| decrement_degree(other) }
      end

      def decrement_degree(r)
        was = weight(r)
        @degree[r] -= 1
        return unless was == k

        # It has just become trivially colourable, so the copies around it may
        # have become safe to merge as well.
        enable_moves(neighbours(r) + [r])
        @spill_worklist.delete(r)
        if move_related?(r) then @freeze_worklist << r
        else @simplify_worklist << r
        end
      end

      def enable_moves(nodes)
        nodes.each do |r|
          node_moves(r).each do |index|
            next unless @active_moves.include?(index)

            @active_moves.delete(index)
            @worklist_moves << index
          end
        end
      end

      # -- coalescing -------------------------------------------------------

      def alias_of(r)
        r = @alias[r] while @coalesced.include?(r)
        r
      end

      def coalesce
        index = @worklist_moves.min
        dst, src = @moves[index]
        @worklist_moves.delete(index)
        u = alias_of(dst)
        v = alias_of(src)
        if u == v
          add_to_worklist(u)
        elsif @adjacent[u].include?(v)
          add_to_worklist(u)
          add_to_worklist(v)
        elsif conservative?(u, v)
          combine(u, v)
          add_to_worklist(u)
        else
          @active_moves << index
        end
      end

      def add_to_worklist(r)
        return unless weight(r) < k && !move_related?(r)

        @freeze_worklist.delete(r)
        @simplify_worklist << r
      end

      # Briggs: the merged node must have fewer than K significant neighbours.
      # The colours the two ends may not take add up as well, and a colour the
      # merged node is barred from is one more thing standing in its way.
      def conservative?(u, v)
        together = neighbours(u).to_set | neighbours(v).to_set
        barred = (@forbidden[u] | @forbidden[v]).size
        significant = together.count { |r| weight(r) >= k }
        significant + barred < k
      end

      def combine(u, v)
        @freeze_worklist.delete(v)
        @spill_worklist.delete(v)
        @coalesced << v
        @alias[v] = u
        @moves_of[u] |= @moves_of[v]
        @forbidden[u] |= @forbidden[v]
        @preferred[u] = @preferred[v] if @preferred.key?(v) && !@preferred.key?(u)
        enable_moves([v])
        neighbours(v).each do |other|
          add_edge(other, u)
          decrement_degree(other)
        end
        return unless weight(u) >= k && @freeze_worklist.include?(u)

        @freeze_worklist.delete(u)
        @spill_worklist << u
      end

      # -- freezing and spilling --------------------------------------------

      def freeze
        r = @freeze_worklist.min
        @freeze_worklist.delete(r)
        @simplify_worklist << r
        freeze_moves(r)
      end

      def freeze_moves(r)
        node_moves(r).each do |index|
          dst, src = @moves[index]
          @active_moves.delete(index)
          @worklist_moves.delete(index)
          other = alias_of(alias_of(dst) == alias_of(r) ? src : dst)
          next unless !move_related?(other) && weight(other) < k

          @freeze_worklist.delete(other)
          @simplify_worklist << other
        end
      end

      # Guess that the value with the most neighbours per use will not fit.
      #
      # Never a reload, though: those are cheap by that measure precisely
      # because they were made cheap, and choosing one would undo the last
      # round's work instead of the pressure.
      def select_spill
        weights = Spill.costs(@func)
        among = @spill_worklist.sort.reject { |r| @protected.include?(r) }
        among = @spill_worklist.sort if among.empty?
        score = ->(r) { weight(r) / (weights[r] + 1.0) }
        # Not `max_by`: ties go to the one that came first, and only a fold says
        # so out loud.
        chosen = among.reduce { |best, r| score.(r) > score.(best) ? r : best }
        @spill_worklist.delete(chosen)
        @simplify_worklist << chosen
        freeze_moves(chosen)
      end

      # -- handing out the colours ------------------------------------------

      def assign_colours
        spilled = Set.new
        until @select_stack.empty?
          r = @select_stack.pop
          @on_stack.delete(r)
          taken = @adjacent[r].filter_map { |other| @colour[alias_of(other)] }.to_set
          free = @machine.anywhere.reject { |c| taken.include?(c) || @forbidden[r].include?(c) }
          if free.empty?
            spilled << r
            next
          end
          want = @preferred[r]
          @colour[r] = free.include?(want) ? want : free.first
        end
        @coalesced.sort.each do |r|
          @colour[r] = @colour.fetch(alias_of(r), @machine.anywhere.first)
        end
        spilled
      end
    end
  end
end
