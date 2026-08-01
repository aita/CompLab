/**
 * The seam the register allocator is reached through, and what it promises.
 *
 * There is one allocator here: leave SSA, build the interference graph, and
 * colour it the way Chaitin's algorithm does, with the iterated coalescing that
 * eats the copies leaving SSA made.  The Python tree beside this one carries a
 * second allocator that colours the SSA itself in dominance order, so that the
 * two can be measured against each other; this tree keeps the graph.
 */

package wolv.allocator

import wolv.ir.*
import wolv.*


/**
 * The colouring of each function, by label.  Spilling rewrites the functions on
 * the way, which is why the module is taken and not given back.
 */
fun allocateModule(mod: Module, machine: Registers = Registers()): Map<String, Allocation> =
    mod.funcs.associate { it.label to allocate(it, machine) }

/**
 * No two values that hold different things at once may share a colour.
 *
 * The check is made where the interference graph joins values — at each
 * definition, and at the top of a block for the phis and the parameters, which
 * define several at once.  Looking at a whole live set instead would be wrong,
 * not merely slower: both ends of a copy are live after it and hold the same
 * value, so they may share a register, and that is the entire point of
 * coalescing.  A verifier that rejected it would reject every program the
 * coalescer had done its job on.
 *
 * Nothing that interferes escapes this, because the later of the two
 * definitions that put the values there happens while the other is live.
 */
fun verifyColouring(alloc: Allocation, func: Func) {
    val live = func.liveness()
    for (block in func.walk()) {
        val alive = live.liveOut.getValue(block.label).toMutableSet()
        for (instr in block.instrs.asReversed()) {
            if (instr is Move) alive.remove(instr.src)
            for (r in instr.uses) alloc.coloured(r)
            instr.def?.let { d ->
                alloc.coloured(d)
                alive.add(d)
                alloc.noClash(alive, d, block.label)
                alive.remove(d)
            }
            alive.addAll(instr.uses)
        }

        val entering = live.liveIn.getValue(block.label).toMutableSet()
        for (phi in block.phis) {
            alloc.coloured(phi.dst)
            entering.add(phi.dst)
            alloc.noClash(entering, phi.dst, block.label)
        }
        if (block.label == func.entry) {
            for (param in func.params) {
                entering.add(param)
                alloc.noClash(entering, param, block.label)
            }
        }
    }
}

private fun Allocation.coloured(r: Reg) = check(r in colours) { "%$r has no colour" }

/** Nothing else live here may hold the colour [written] was just given. */
private fun Allocation.noClash(alive: Set<Reg>, written: Reg, where: String) {
    val colour = colours[written] ?: return
    val other = alive.sorted().firstOrNull { it != written && colours[it] == colour } ?: return
    error("x$colour holds %$written and %$other at once in $where")
}
