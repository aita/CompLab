/**
 * Doing several copies at once, one at a time.
 *
 * Every argument of a call is read before any of them is written, and so is
 * every parameter at the top of a function.  Once the allocator has given both
 * ends real registers that is a permutation, and putting a permutation into a
 * sequence of instructions is this file.
 *
 * Copies whose destination nobody else has still to read can go first.  When only
 * cycles are left, something has to be got out of the way, and there are two ways
 * to do it: a register the function never used can hold a value for one step, and
 * if there is no such register the two ends of the cycle swap.  A swap is three
 * `eor`s and needs nothing to borrow, which is why no register is reserved for
 * this anywhere in the compiler.
 */

package wolv

import wolv.ir.*

sealed interface Step

data class Mov(val dst: Int, val src: Int) : Step

data class Swap(val a: Int, val b: Int) : Step

/** Order `(destination, source)` pairs so that nothing is lost on the way. */
fun sequentialize(moves: List<Pair<Int, Int>>, borrowed: Int?): List<Step> {
    val real = moves.filter { (dst, src) -> dst != src }
    val pending: MutableMap<Int, Int> = LinkedHashMap()
    for ((dst, src) in real) pending[dst] = src
    check(pending.size == real.size) { "a parallel copy writes a register twice" }
    val done = mutableListOf<Step>()
    while (pending.isNotEmpty()) {
        val sources = pending.values.toSet()
        val ready = pending.keys.filter { it !in sources }
        if (ready.isNotEmpty()) {
            for (dst in ready) done.add(Mov(dst, pending.remove(dst)!!))
            continue
        }
        val stuck = pending.keys.first()
        if (borrowed != null) {
            done.add(Mov(borrowed, stuck))
            moved(pending, stuck, borrowed)
            continue
        }
        // Swapping satisfies `stuck` outright and leaves its old value where the
        // other end was, so everything still to read it reads there instead.
        val other = pending.remove(stuck)!!
        done.add(Swap(stuck, other))
        moved(pending, stuck, other)
    }
    return done
}

/** The value that was in `was` is in `now`; whoever wanted it looks there. */
private fun moved(pending: MutableMap<Int, Int>, was: Int, now: Int) {
    for ((dst, src) in pending.entries.toList()) {
        if (src != was) continue
        // The swap already put it where it belongs.
        if (dst == now) pending.remove(dst) else pending[dst] = now
    }
}
