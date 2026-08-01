/**
 * Which colour a value would like, which is the calling convention asking.
 *
 * The allocator does not have to satisfy these — a preference is dropped the
 * moment it clashes with something the colouring actually requires — but taking
 * one when it is free is what stops the emitter having to move a value into `x2`
 * on the way into a call, or out of `x0` on the way back from one.
 */

package wolv.allocator

import wolv.ir.*
import wolv.*


/** The register each value is about to be wanted in, where there is one. */
fun preferences(func: Func): MutableMap<Reg, Int> {
    val wanted = mutableMapOf<Reg, Int>()
    for ((i, param) in func.params.withIndex()) {
        if (i < Registers.ARGUMENT_REGS.size) wanted[param] = Registers.ARGUMENT_REGS[i]
    }
    for (block in func.walk()) {
        for (instr in block.instrs) {
            when (instr) {
                is Call -> {
                    for ((i, arg) in instr.args.take(Registers.ARGUMENT_REGS.size).withIndex()) {
                        wanted[arg] = Registers.ARGUMENT_REGS[i]
                    }
                    instr.dst?.let { wanted[it] = Registers.ARGUMENT_REGS[0] }
                }
                is Ret -> instr.value?.let { wanted[it] = Registers.ARGUMENT_REGS[0] }
                else -> {}
            }
        }
    }
    return wanted
}
