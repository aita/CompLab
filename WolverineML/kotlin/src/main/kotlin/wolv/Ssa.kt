/**
 * SSA construction, the textbook way.
 *
 * Dominators by the iterative algorithm of Cooper, Harvey and Kennedy, dominance
 * frontiers from those, phis at the frontiers of every definition, and then one
 * walk of the dominator tree renaming as it goes.  This is minimal SSA and
 * nothing cleverer: a phi is placed wherever the frontier says, whether or not
 * the variable is live there, and the dead ones leave in `deadCode`.
 *
 * Only registers written more than once take part.  Everything lowering produced
 * once — a temporary — is already in SSA and is left with the name it has.
 */

package wolv

import wolv.ir.*

class Dominance(
    val idom: Map<String, String>,
    val children: Map<String, List<String>>,
    val frontier: Map<String, Set<String>>,
    val order: List<String>,
) {
    fun dominates(a: String, b: String): Boolean {
        var at = b
        while (true) {
            if (a == at) return true
            val parent = idom.getValue(at)
            if (parent == at) return false
            at = parent
        }
    }
}

fun dominance(func: Func): Dominance {
    val order = func.rpo()
    val rank = order.withIndex().associate { (i, label) -> label to i }
    val idom = mutableMapOf(func.entry to func.entry)

    fun intersect(first: String, second: String): String {
        var a = first
        var b = second
        while (a != b) {
            while (rank.getValue(a) > rank.getValue(b)) a = idom.getValue(a)
            while (rank.getValue(b) > rank.getValue(a)) b = idom.getValue(b)
        }
        return a
    }

    var changed = true
    while (changed) {
        changed = false
        for (label in order.drop(1)) {
            val preds = func.blocks.getValue(label).preds.filter { it in idom }
            if (preds.isEmpty()) continue
            var new = preds[0]
            for (p in preds.drop(1)) new = intersect(p, new)
            if (idom[label] != new) {
                idom[label] = new
                changed = true
            }
        }
    }

    val children: Map<String, MutableList<String>> = order.associateWith { mutableListOf() }
    for (label in order) {
        val parent = idom.getValue(label)
        if (parent != label) children.getValue(parent).add(label)
    }

    val frontier: Map<String, MutableSet<String>> = order.associateWith { mutableSetOf() }
    for (label in order) {
        val block = func.blocks.getValue(label)
        if (block.preds.size < 2) continue
        for (pred in block.preds) {
            var runner = pred
            while (runner != idom[label] && runner in idom) {
                frontier.getValue(runner).add(label)
                runner = idom.getValue(runner)
            }
        }
    }
    return Dominance(idom, children, frontier, order)
}

/**
 * Where each register is written, and how often.
 *
 * A register written twice in one block is as much a variable as one written
 * in two blocks, so the count is what decides, and the blocks are what the
 * frontier walk needs.
 */
private class Defs {
    val blocks: MutableMap<Reg, MutableSet<String>> = mutableMapOf()
    val count: MutableMap<Reg, Int> = mutableMapOf()

    fun variables(): Set<Reg> = count.filterValues { it > 1 }.keys

    fun record(r: Reg, label: String) {
        blocks.getOrPut(r) { mutableSetOf() }.add(label)
        count[r] = (count[r] ?: 0) + 1
    }
}

private fun definitions(func: Func): Defs {
    val defs = Defs()
    for (block in func.walk()) {
        for (instr in block.instrs) instr.def?.let { defs.record(it, block.label) }
    }
    for (r in func.params) defs.record(r, func.entry)
    return defs
}

/** Put a phi for `v` at every dominance frontier of a block defining `v`. */
private fun placePhis(func: Func, dom: Dominance, defs: Defs): Map<String, MutableList<Reg>> {
    val sites = defs.blocks
    val phiVars: Map<String, MutableList<Reg>> = func.blocks.keys.associateWith { mutableListOf() }
    for (v in defs.variables().sorted()) {
        val placed = mutableSetOf<String>()
        val work = ArrayDeque(sites.getValue(v).sorted())
        while (work.isNotEmpty()) {
            val block = work.removeLast()
            for (target in dom.frontier.getValue(block).sorted()) {
                if (!placed.add(target)) continue
                phiVars.getValue(target).add(v)
                val preds = func.blocks.getValue(target).preds
                func.blocks.getValue(target).phis.add(
                    Phi(v, preds.associateWithTo(LinkedHashMap()) { v }),
                )
                if (target !in sites.getValue(v)) work.addLast(target)
            }
        }
    }
    return phiVars
}

private class Renamer(
    val func: Func,
    val dom: Dominance,
    val phiVars: Map<String, MutableList<Reg>>,
    val variables: Set<Reg>,
) {
    val stacks: MutableMap<Reg, MutableList<Reg>> = mutableMapOf()
    val undefined: MutableMap<Reg, Reg> = LinkedHashMap()

    fun top(v: Reg): Reg = stacks[v]?.lastOrNull() ?: undef(v)

    /** A variable read on a path that never wrote it reads zero. */
    fun undef(v: Reg): Reg = undefined.getOrPut(v) { func.newReg() }

    fun plantUndefined() {
        val entry = func.blocks.getValue(func.entry)
        for (r in undefined.values) entry.instrs.add(0, Const(r, 0))
    }

    fun rename(v: Reg): Reg {
        val fresh = func.newReg()
        stacks.getOrPut(v) { mutableListOf() }.add(fresh)
        return fresh
    }

    fun run() {
        val work = ArrayDeque(listOf(func.entry to false))
        val pushed = mutableMapOf<String, List<Reg>>()
        while (work.isNotEmpty()) {
            val (label, popping) = work.removeLast()
            if (popping) {
                for (v in pushed.getValue(label)) {
                    stacks.getValue(v).removeAt(stacks.getValue(v).size - 1)
                }
                continue
            }
            pushed[label] = block(label)
            work.addLast(label to true)
            for (child in dom.children.getValue(label).asReversed()) work.addLast(child to false)
        }
    }

    fun block(label: String): List<Reg> {
        val block = func.blocks.getValue(label)
        val mine = mutableListOf<Reg>()
        for ((phi, v) in block.phis.zip(phiVars.getValue(label))) {
            phi.dst = rename(v)
            mine.add(v)
        }
        for (instr in block.instrs) {
            instr.rewriteUses(::use)
            val d = instr.def
            if (d != null && d in variables) {
                instr.redefine(rename(d))
                mine.add(d)
            }
        }
        for (succ in block.succs) {
            val target = func.blocks.getValue(succ)
            for ((phi, v) in target.phis.zip(phiVars.getValue(succ))) {
                phi.args[label] = top(v)
            }
        }
        return mine
    }

    fun use(r: Reg): Reg = if (r in variables) top(r) else r
}

/** Rewrite one function into SSA, in place. */
fun construct(func: Func) {
    func.recomputePreds()
    val dom = dominance(func)
    val defs = definitions(func)
    val phiVars = placePhis(func, dom, defs)
    val renamer = Renamer(func, dom, phiVars, defs.variables())
    for ((i, p) in func.params.withIndex()) {
        if (p in renamer.variables) func.params[i] = renamer.rename(p)
    }
    renamer.run()
    renamer.plantUndefined()
}

fun constructModule(mod: Module) {
    for (func in mod.funcs) construct(func)
}

/**
 * Give every phi a place to put its copy in.
 *
 * An edge from a block with several successors into a block with several
 * predecessors has nowhere to hold the copies a phi turns into, so it gets a
 * block of its own.  The same goes for any edge into a block that still has a
 * phi, so that the emitter only ever has to put copies before a `jmp`.
 */
fun splitCriticalEdges(func: Func) {
    for (label in func.order.toList()) {
        val block = func.blocks.getValue(label)
        if (block.succs.size < 2) continue
        for (succ in block.succs.toList()) {
            val target = func.blocks.getValue(succ)
            if (target.preds.size < 2 && target.phis.isEmpty()) continue
            val split = func.addBlock("$label.$succ")
            split.instrs.add(Jmp(succ))
            block.terminator.renameTarget(succ, split.label)
            for (phi in target.phis) {
                phi.args.remove(label)?.let { phi.args[split.label] = it }
            }
        }
    }
    func.recomputePreds()
}

/** Check what SSA promises: one definition per register, and it dominates. */
fun verifySsa(func: Func) {
    val dom = dominance(func)
    val definition = mutableMapOf<Reg, String>()
    for (block in func.walk()) {
        for (phi in block.phis) {
            check(phi.dst !in definition) { "%${phi.dst} defined twice" }
            definition[phi.dst] = block.label
        }
        for (instr in block.instrs) {
            val d = instr.def ?: continue
            check(d !in definition) { "%$d defined twice" }
            definition[d] = block.label
        }
    }
    for (p in func.params) definition.putIfAbsent(p, func.entry)
    for (block in func.walk()) {
        for (phi in block.phis) {
            check(phi.args.keys == block.preds.toSet()) {
                "phi in ${block.label} names ${phi.args.keys.sorted()}, " +
                    "preds are ${block.preds.sorted()}"
            }
            for ((pred, r) in phi.args) {
                val where = definition[r]
                checkNotNull(where) { "%$r is never defined" }
                check(dom.dominates(where, pred)) {
                    "%$r does not reach ${block.label} through $pred"
                }
            }
        }
        for (instr in block.instrs) {
            for (r in instr.uses) {
                val where = definition[r]
                checkNotNull(where) { "%$r is never defined" }
                check(dom.dominates(where, block.label)) {
                    "%$r does not dominate its use in ${block.label}"
                }
            }
        }
    }
}
