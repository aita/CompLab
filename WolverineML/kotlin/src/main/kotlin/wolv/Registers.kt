/**
 * What the allocator and the emitter both have to agree about: the registers.
 *
 * x16 and x17 are the ABI's intra-procedure-call scratch registers, which a
 * linker veneer may clobber at a `bl`.  Nothing of ours is ever live across a
 * call in a caller-saved register, so x16 is allocatable like any other; x17 is
 * the one register kept back, for an address the emitter has to compute after
 * allocation is over.  x18 is the platform register, x29 the frame pointer, x30
 * the link register.
 */

package wolv

import wolv.ir.*

/** The machine the allocator is colouring for. */
class Registers(
    val caller: List<Int> = CALLER_SAVED,
    val callee: List<Int> = CALLEE_SAVED,
) {
    val anywhere: List<Int> get() = caller + callee

    fun count(): Int = caller.size + callee.size

    companion object {
        val CALLER_SAVED = listOf(9, 10, 11, 12, 13, 14, 15, 16, 0, 1, 2, 3, 4, 5, 6, 7, 8)
        val CALLEE_SAVED = listOf(19, 20, 21, 22, 23, 24, 25, 26, 27, 28)
        val ARGUMENT_REGS = listOf(0, 1, 2, 3, 4, 5, 6, 7)
        val SCRATCH = listOf(17)

        /** A smaller machine, so that the spiller can be tested on small programs. */
        fun limited(maxRegs: Int): Registers {
            val callee = CALLEE_SAVED.take(maxOf(2, maxRegs / 2))
            val caller = CALLER_SAVED.take(maxOf(1, maxRegs - callee.size))
            return Registers(caller, callee)
        }
    }
}
