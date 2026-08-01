/**
 * Liveness.
 *
 * The only subtlety is the phi.  A phi does not read its arguments where it
 * stands; it reads them on the edges, so an argument is live at the end of the
 * predecessor it is paired with and not anywhere inside the block that holds the
 * phi.  Getting that wrong is what makes phi-related values interfere when they
 * should not.
 */

package wolv

import wolv.ir.*

class Liveness(
    val liveIn: MutableMap<String, Set<Reg>> = mutableMapOf(),
    val liveOut: MutableMap<String, Set<Reg>> = mutableMapOf(),
)

fun Func.liveness(): Liveness {
    // What each block reads before writing, and what it writes at all.
    val upward = mutableMapOf<String, Set<Reg>>()
    val killed = mutableMapOf<String, Set<Reg>>()
    for (block in walk()) {
        val kill = block.phis.mapTo(mutableSetOf()) { it.dst }
        val use = mutableSetOf<Reg>()
        for (instr in block.instrs) {
            instr.uses.filterNotTo(use) { it in kill }
            instr.def?.let(kill::add)
        }
        upward[block.label] = use
        killed[block.label] = kill
    }

    val live = Liveness()
    for (label in blocks.keys) {
        live.liveIn[label] = emptySet()
        live.liveOut[label] = emptySet()
    }

    // Backwards, to a fixed point.
    val order = rpo().asReversed()
    do {
        var changed = false
        for (label in order) {
            val out = this[label].succs.flatMapTo(mutableSetOf()) { succ ->
                live.liveIn.getValue(succ) + this[succ].phis.mapNotNull { it.args[label] }
            }
            val newIn = upward.getValue(label) + (out - killed.getValue(label))
            if (out != live.liveOut[label] || newIn != live.liveIn[label]) {
                live.liveOut[label] = out
                live.liveIn[label] = newIn
                changed = true
            }
        }
    } while (changed)
    return live
}

/** Values live across a call, and so unable to sit in a scratch register. */
fun Func.acrossCalls(live: Liveness): Set<Reg> = buildSet {
    for (block in walk()) {
        // A call's own arguments are not live across it, so the set is read after
        // its result is taken out and before its arguments go back in.
        val after = live.liveOut.getValue(block.label).toMutableSet()
        for (instr in block.instrs.asReversed()) {
            instr.def?.let(after::remove)
            if (instr is Call) addAll(after)
            after.addAll(instr.uses)
        }
    }
}

/** The most values live at any one point — the registers the function wants. */
fun Func.pressure(live: Liveness): Int = walk().maxOf { block ->
    val after = live.liveOut.getValue(block.label).toMutableSet()
    var most = after.size
    for (instr in block.instrs.asReversed()) {
        instr.def?.let(after::remove)
        after.addAll(instr.uses)
        most = maxOf(most, after.size)
    }
    // At entry the phis are all written at once, so they are all live together.
    maxOf(most, (live.liveIn.getValue(block.label) + block.phis.map { it.dst }).size)
}
