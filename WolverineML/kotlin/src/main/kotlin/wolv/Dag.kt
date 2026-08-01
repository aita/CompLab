/**
 * The data-flow DAG of one basic block.
 *
 * Instruction selection wants to see a block as expressions, not as a list: `a +
 * (i << 3)` is one ARM instruction and `a + b*c` is another, and neither is
 * visible while the operands are separate lines with names in between.  So each
 * block is read into a graph — a node per instruction, an edge per operand — and
 * the selector covers that graph with instructions.
 *
 * It is a graph and not a tree because a value can be read twice.  That is what
 * `users` counts, and it is what decides whether a node may be folded into the
 * instruction that reads it or has to become an instruction of its own: a node
 * read twice would otherwise be computed twice.  A value that leaves the block
 * counts as read as well, and so does one a phi in a successor names.
 *
 * Only pure nodes are ever folded, and only into a reader whose instruction
 * really absorbs them.  Both halves matter.  Folding moves a computation to where
 * it is read, which is fine for arithmetic and not fine for a load, because a
 * store in between would change what it reads; and folding a chain of nodes that
 * nothing absorbs would move a whole expression to its last line, leaving every
 * value it read alive until then.  So the selector plans first — it asks, of each
 * node with one reader, whether that reader has a tile that takes it — and
 * everything else is computed where it was written.
 */

package wolv

import wolv.ir.*

class Dag {
    val nodes: MutableList<Node> = mutableListOf()
    val byValue: MutableMap<Reg, Int> = mutableMapOf()

    class Node(
        val index: Int,
        val instr: Instr,
        /** A node in this block, or null for a value from outside. */
        val operands: List<Int?>,
    ) {
        var users: Int = 0

        /** The only node that reads it, when there is one. */
        var reader: Int? = null

        /** Read after the block ends, or by a phi in a successor. */
        var escapes: Boolean = false

        val value: Reg? get() = instr.def

        /** Read exactly once, inside the block, and computable where read. */
        fun alone(): Boolean = users == 1 && !escapes && instr is Bin
    }

    fun of(index: Int?): Node? = index?.let { nodes[it] }

    /**
     * A constant, which costs nothing to repeat and is often not an instruction
     * at all once it has become an immediate operand.
     */
    fun rematerialisable(index: Int?): Node? {
        val node = of(index)
        if (node == null || node.escapes || node.instr !is Const) return null
        return node
    }

    /**
     * The value at `index`, if it is a constant — however many read it.
     *
     * Even one that has to exist in a register for somebody else can be an
     * immediate here, so this asks less than folding does.
     */
    fun constant(index: Int?): Long? = (of(index)?.instr as? Const)?.value

    companion object {
        /** Read a block into a graph.  `liveOut` includes what the phis will read. */
        fun build(block: Block, liveOut: Set<Reg>): Dag {
            val dag = Dag()
            for ((i, instr) in block.instrs.withIndex()) {
                val operands: List<Int?> = instr.uses.map { dag.byValue[it] }
                val node = Node(i, instr, operands)
                dag.nodes.add(node)
                instr.def?.let { dag.byValue[it] = i }
                for (operand in operands) {
                    if (operand == null) continue
                    val read = dag.nodes[operand]
                    read.users += 1
                    read.reader = if (read.users == 1) i else null
                }
            }
            for (node in dag.nodes) {
                val value = node.value
                if (value != null && value in liveOut) node.escapes = true
            }
            return dag
        }

        fun show(dag: Dag): String = dag.nodes.joinToString("\n") { node ->
            val reads = node.operands.joinToString(", ") { it?.toString() ?: "-" }
            val marks = (if (node.escapes) "*" else "") + (if (node.instr.hasEffect) "!" else "")
            "  ${node.index.toString().padStart(3)}${marks.padEnd(2)} " +
                node.instr.show(::plain).padEnd(38) +
                " reads [$reads]  users ${node.users}"
        }

        private fun plain(r: Reg): String = "%$r"
    }
}
