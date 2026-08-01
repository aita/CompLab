/**
 * Leaving SSA before allocation.
 *
 * A phi is a copy that happens on an edge, so it becomes copies at the end of
 * each predecessor.  Critical edges are already split, so a predecessor of a
 * block with phis has nowhere else to go and the copies can simply be appended.
 *
 * The copies of one edge happen at once: every argument is read before any
 * destination is written.  Usually that needs no care, because a phi's
 * destination is defined nowhere else and so is nobody's argument — but a block
 * that is its own predecessor can have two phis that swap, and then the copies go
 * through temporaries, which is Sreedhar's answer and which coalescing is
 * expected to remove again.
 *
 * That the copies are a cost to be paid is the point rather than a complaint:
 * copies are what coalescing eats, and the allocator earns nearly all of them
 * back.
 */

package wolv

import wolv.ir.*

/** Replace every phi in `func` with copies in its predecessors. */
fun destruct(func: Func) {
    for (block in func.walk()) {
        if (block.phis.isEmpty()) continue
        for (pred in block.preds) {
            val source = func.blocks.getValue(pred)
            check(source.succs.size == 1) { "$pred -> ${block.label} is a critical edge" }
            copyInParallel(func, source, block.phis.map { it.dst to it.args.getValue(pred) })
        }
        block.phis = mutableListOf()
    }
    func.recomputePreds()
}

fun destructModule(mod: Module) {
    for (func in mod.funcs) destruct(func)
}

private fun copyInParallel(
    func: Func,
    block: Block,
    moves: List<Pair<Reg, Reg>>,
) {
    val real = moves.filter { (dst, src) -> dst != src }
    if (real.isEmpty()) return
    val written = real.map { it.first }.toSet()
    val read = real.map { it.second }.toSet()
    val copies = mutableListOf<Instr>()
    if (written.intersect(read).isNotEmpty()) {
        val through = real.associate { (dst, _) -> dst to func.newReg() }
        copies += real.map { (dst, src) -> Move(through.getValue(dst), src) }
        copies += real.map { (dst, _) -> Move(dst, through.getValue(dst)) }
    } else {
        copies += real.map { (dst, src) -> Move(dst, src) }
    }
    block.instrs.addAll(block.instrs.size - 1, copies)
}
