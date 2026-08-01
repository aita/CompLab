/**
 * Spilling.
 *
 * A spilled value gets a frame slot, a store after every definition of it and a
 * reload in front of every use.  The reloads are new registers, live from the
 * load to the instruction under it and nowhere else, which is what makes the
 * pressure come down.  Nothing here assumes SSA: a value written twice gets two
 * stores, and a phi argument is reloaded at the end of the predecessor it comes
 * from, so the same rewrite would serve a walk of the dominator tree as well as
 * the graph.
 */

package wolv.allocator

import wolv.ir.*
import wolv.*

import kotlin.math.min
import kotlin.math.pow

/** Raised when spilling cannot help either. */
class OutOfRegisters(message: String) : Exception(message)

/**
 * How deeply each block is nested in loops, for weighing what a use costs.
 *
 * A back edge is an edge into a block that dominates its source; everything
 * that can reach the source without leaving the dominated region is in that
 * loop.
 */
fun loopDepth(func: Func): Map<String, Int> {
    val dom = dominance(func)
    val depth = func.blocks.keys.associateWithTo(mutableMapOf()) { 0 }
    for (block in func.walk()) {
        for (succ in block.succs) {
            if (!dom.dominates(succ, block.label)) continue
            val body = mutableSetOf(succ)
            val stack = ArrayDeque(listOf(block.label))
            while (stack.isNotEmpty()) {
                val label = stack.removeLast()
                if (!body.add(label)) continue
                stack.addAll(func.blocks.getValue(label).preds)
            }
            for (label in body) depth[label] = depth.getValue(label) + 1
        }
    }
    return depth
}

/** What spilling a value would cost: its reads and writes, weighed by loops. */
fun costs(func: Func): Map<Reg, Double> {
    val depth = loopDepth(func)
    val weight = mutableMapOf<Reg, Double>()

    fun add(r: Reg, amount: Double) {
        weight[r] = (weight[r] ?: 0.0) + amount
    }

    for (block in func.walk()) {
        val scale = 10.0.pow(min(depth.getValue(block.label), 4))
        for (phi in block.phis) {
            for ((pred, arg) in phi.args) add(arg, 10.0.pow(min(depth.getValue(pred), 4)))
            add(phi.dst, scale)
        }
        for (instr in block.instrs) {
            for (r in instr.uses) add(r, scale)
            instr.def?.let { add(it, scale) }
        }
    }
    return weight
}

/**
 * Give `victim` a frame slot, and answer with the slot and the reloads that
 * replaced it.  Where it went is the caller's to remember, because it is part of
 * the allocation and not of the program.
 */
fun spill(func: Func, victim: Reg): Pair<Int, Set<Reg>> {
    val slot = func.newSlot()
    val isParam = victim in func.params
    val reloads = mutableSetOf<Reg>()

    for (block in func.walk()) {
        if (block.phis.any { it.dst == victim }) {
            block.instrs.add(0, StoreSlot(slot, victim))
        }
        if (isParam && block.label == func.entry) {
            block.instrs.add(0, StoreSlot(slot, victim))
        }

        val rebuilt = mutableListOf<Instr>()
        for (instr in block.instrs) {
            val spillStore = instr is StoreSlot && instr.slot == slot
            var here = instr
            if (victim in instr.uses && !spillStore) {
                val fresh = func.newReg()
                reloads.add(fresh)
                rebuilt.add(LoadSlot(fresh, slot))
                here = instr.mapUses { r -> if (r == victim) fresh else r }
            }
            rebuilt.add(here)
            if (instr.def == victim) rebuilt.add(StoreSlot(slot, victim))
        }
        block.instrs = rebuilt
    }

    for (block in func.walk()) {
        block.phis.replaceAll { phi ->
            phi.copy(
                args = phi.args.mapValues { (pred, arg) ->
                    if (arg != victim) {
                        arg
                    } else {
                        val source = func.blocks.getValue(pred)
                        val fresh = func.newReg()
                        reloads.add(fresh)
                        source.instrs.add(source.instrs.size - 1, LoadSlot(fresh, slot))
                        fresh
                    }
                },
            )
        }
    }
    return slot to reloads
}
