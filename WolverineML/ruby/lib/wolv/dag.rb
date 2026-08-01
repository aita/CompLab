# frozen_string_literal: true

require_relative "ir"

module Wolv
  # The data-flow DAG of one basic block.
  #
  # Instruction selection wants to see a block as expressions, not as a list:
  # `a + (i << 3)` is one ARM instruction and `a + b*c` is another, and neither
  # is visible while the operands are separate lines with names in between.  So
  # each block is read into a graph — a node per instruction, an edge per
  # operand — and the selector covers that graph with instructions.
  #
  # It is a graph and not a tree because a value can be read twice.  That is
  # what `users` counts, and it is what decides whether a node may be folded
  # into the instruction that reads it or has to become an instruction of its
  # own: a node read twice would otherwise be computed twice.  A value that
  # leaves the block counts as read as well, and so does one a phi in a
  # successor names.
  #
  # Only pure nodes are ever folded, and only into a reader whose instruction
  # really absorbs them.  Both halves matter.  Folding moves a computation to
  # where it is read, which is fine for arithmetic and not fine for a load,
  # because a store in between would change what it reads; and folding a chain
  # of nodes that nothing absorbs would move a whole expression to its last
  # line, leaving every value it read alive until then.  So the selector plans
  # first — it asks, of each node with one reader, whether that reader has a
  # tile that takes it — and everything else is computed where it was written.
  module Dag
    # `operands` holds a node index for a value this block computed, and nil for
    # one that came from outside it.  `reader` is the only node that reads it,
    # when there is one.
    Node = Struct.new(:index, :instr, :operands, :users, :reader, :escapes) do
      def value = instr.defs

      # Read exactly once, inside the block, and computable where read.
      def alone? = users == 1 && !escapes && instr.is_a?(IR::Bin)
    end

    Graph = Struct.new(:nodes, :by_value) do
      def of(index) = index && nodes[index]

      # A constant, which costs nothing to repeat and is often not an
      # instruction at all once it has become an immediate operand.
      def rematerialisable(index)
        node = of(index)
        return nil unless node && !node.escapes && node.instr.is_a?(IR::Const)

        node
      end

      # The value at `index`, if it is a constant — however many read it.  Even
      # one that has to exist in a register for somebody else can be an
      # immediate here, so this asks less than `rematerialisable` does.
      def constant(index)
        node = of(index)
        node&.instr.is_a?(IR::Const) ? node.instr.value : nil
      end
    end

    module_function

    # Read a block into a graph.  `live_out` includes what the phis will read.
    def build(block, live_out)
      graph = Graph.new([], {})
      block.instrs.each_with_index do |instr, i|
        operands = instr.uses.map { |r| graph.by_value[r] }
        node = Node.new(i, instr, operands, 0, nil, false)
        graph.nodes << node
        defined = instr.defs
        graph.by_value[defined] = i if defined
        operands.each do |operand|
          next unless operand

          read = graph.nodes[operand]
          read.users += 1
          read.reader = read.users == 1 ? i : nil
        end
      end
      # A value that leaves the block is read there as far as this is concerned.
      graph.nodes.each { |node| node.escapes = live_out.include?(node.value) }
      graph
    end

    PLAIN = ->(r) { "%#{r}" }

    def show(graph)
      graph.nodes.map do |node|
        reads = node.operands.map { |o| o&.to_s || "-" }.join(", ")
        marks = (node.escapes ? "*" : "") + (node.instr.effect? ? "!" : "")
        format("  %3d%-2s %-38s reads [%s]  users %d",
               node.index, marks, node.instr.show(PLAIN), reads, node.users)
      end.join("\n")
    end
  end
end
