/**
 * ARMv8 assembly, in AAPCS64.
 *
 * The frame is the ordinary one.  `x29` points at the saved frame record, the
 * slots an escaping variable or a spill lives in are below it, the callee-saved
 * registers this function actually used are below those, and outgoing stack
 * arguments sit at the bottom, at `sp`, where the callee expects them.
 *
 *     x29 -> | saved x29, x30 |
 *            | slot 0         |   x29 - 8      also where a static link points
 *            | slot 1         |   x29 - 16
 *            | ...            |
 *            | saved x19...   |
 *     sp  -> | outgoing args  |
 *
 * The phis are gone before this point — the allocator left SSA to colour the
 * interference graph — so what is left to do all at once is the arguments of a
 * call and the parameters at the top of a function: the values are read before
 * any is written, which is what `sequentialize` arranges.  When the copies
 * form a cycle it borrows a register the function never used, and when there is
 * none it swaps the two ends with three `eor`s, so no register has to be reserved
 * for it.
 */

package wolv

import wolv.ir.*

val UNSCALED: Map<String, String> = mapOf("ldr" to "ldur", "str" to "stur")

/**
 * The one register kept back.  A frame big enough to put a slot out of reach
 * of `ldur` is only discovered after allocation has added its spill slots, so
 * the address has to be computed somewhere the allocator does not know about.
 */
val SPARE = Registers.SCRATCH[0]

/**
 * Nothing of ours is live at the top of the prologue except the incoming
 * arguments, so a caller-saved register that is not one of them is free there.
 */
const val PROLOGUE_TEMP = 9

class Frame(val slots: Int, val saved: List<Int>, val stackArgs: Int) {
    val size: Int = ((WORD * (slots + saved.size + stackArgs)) + 15) and 15.inv()

    fun savedOffset(index: Int): Int = -WORD * (slots + index + 1)
}

fun frameOf(func: Func): Frame {
    var stackArgs = 0
    for (block in func.walk()) {
        for (instr in block.instrs) {
            if (instr is Call) {
                stackArgs = maxOf(stackArgs, instr.args.size - Registers.ARGUMENT_REGS.size)
            }
        }
    }
    return Frame(func.nslots, func.saved, maxOf(stackArgs, 0))
}

/** One character of a literal is one byte; write the ones `.ascii` cannot. */
fun escape(text: String): String {
    val out = StringBuilder()
    for (ch in text.map { it.code }) {
        when {
            ch == 0x22 -> out.append("\\\"")
            ch == 0x5C -> out.append("\\\\")
            ch in 0x20..0x7E -> out.append(ch.toChar())
            else -> out.append("\\" + Integer.toOctalString(ch).padStart(3, '0'))
        }
    }
    return out.toString()
}

fun emitModule(mod: Module, newEmitter: (Func) -> FuncEmitter = ::FuncEmitter): String {
    val out = mutableListOf("\t.text")
    for (func in mod.funcs) {
        out.addAll(newEmitter(func).emit())
        out.add("")
    }
    if (mod.strings.isNotEmpty()) {
        out.add("\t.section .rodata")
        for ((symbol, text) in mod.strings) {
            out.add("\t.p2align 3")
            out.add("$symbol:")
            out.add("\t.quad ${text.length}")
            out.add("\t.ascii \"${escape(text)}\"")
            out.add("\t.byte 0")
        }
    }
    out.add("\t.section .note.GNU-stack,\"\",%progbits")
    return out.joinToString("\n") + "\n"
}

private fun registersRead(func: Func): Set<Reg> {
    val read = mutableSetOf<Reg>()
    for (block in func.walk()) {
        for (instr in block.instrs) read.addAll(instr.uses)
    }
    return read
}

open class FuncEmitter(val func: Func) {
    val frame = frameOf(func)
    val out = mutableListOf<String>()
    val epilogue = ".Lepi_${func.label}"
    val readSomewhere = registersRead(func)
    val taken = func.colours.values.toSet()

    // -- helpers ----------------------------------------------------------

    fun line(text: String) {
        out.add("\t$text")
    }

    fun label(text: String) {
        out.add("$text:")
    }

    fun colour(reg: Reg): Int =
        func.colours[reg] ?: throw AssertionError("%$reg was never coloured")

    fun mov(dst: Int, src: Int) {
        if (dst != src) line("mov x$dst, x$src")
    }

    fun immediate(dst: Int, value: Long) {
        if (value == 0L) {
            line("mov x$dst, #0")
            return
        }
        var first = true
        for (i in 0..3) {
            val chunk = (value ushr (i * 16)) and 0xFFFF
            if (chunk == 0L) continue
            val shift = if (i != 0) ", lsl #${i * 16}" else ""
            line("${if (first) "movz" else "movk"} x$dst, #$chunk$shift")
            first = false
        }
    }

    /** `ldr`/`str`, in whichever addressing mode reaches this far. */
    fun access(op: String, reg: Int, base: Int, offset: Long) {
        val where = if (base == 31) "sp" else "x$base"
        if (offset in 0L..32760L && offset % WORD == 0L) {
            line("$op x$reg, [$where, #$offset]")
        } else if (offset in -256L..255L) {
            line("${UNSCALED.getValue(op)} x$reg, [$where, #$offset]")
        } else {
            immediate(SPARE, offset)
            line("$op x$reg, [$where, x$SPARE]")
        }
    }

    // -- whole functions --------------------------------------------------

    fun emit(): List<String> {
        out.add("\t.globl ${func.label}")
        out.add("\t.type ${func.label}, %function")
        label(func.label)
        prologue()
        val order = func.order
        for ((i, name) in order.withIndex()) {
            label(".L${func.label}_$name")
            block(func.blocks.getValue(name), order.getOrNull(i + 1))
        }
        label(epilogue)
        restore()
        line("mov sp, x29")
        line("ldp x29, x30, [sp], #16")
        line("ret")
        out.add("\t.size ${func.label}, .-${func.label}")
        return out
    }

    fun prologue() {
        line("stp x29, x30, [sp, #-16]!")
        line("mov x29, sp")
        if (frame.size != 0) {
            if (frame.size <= 4095) {
                line("sub sp, sp, #${frame.size}")
            } else {
                immediate(PROLOGUE_TEMP, frame.size.toLong())
                line("sub sp, sp, x$PROLOGUE_TEMP")
            }
        }
        for ((i, reg) in frame.saved.withIndex()) {
            access("str", reg, 29, frame.savedOffset(i).toLong())
        }
        copies(
            func.params.withIndex()
                .filter { (_, p) -> p in readSomewhere }
                .map { (i, p) -> colour(p) to Registers.ARGUMENT_REGS[i] },
        )
    }

    fun restore() {
        for ((i, reg) in frame.saved.withIndex()) {
            access("ldr", reg, 29, frame.savedOffset(i).toLong())
        }
    }

    fun block(block: Block, next: String?) {
        for (instr in block.instrs.dropLast(1)) instruction(instr)
        terminator(block, next)
    }

    fun terminator(block: Block, next: String?) {
        when (val term = block.terminator) {
            is Jmp -> if (term.target != next) line("b .L${func.label}_${term.target}")
            is CBr -> {
                val thenLabel = ".L${func.label}_${term.then}"
                val elseLabel = ".L${func.label}_${term.els}"
                if (term.code.isNotEmpty()) {
                    if (term.then == next) {
                        line("b.${OPPOSITE.getValue(term.code)} $elseLabel")
                    } else {
                        line("b.${term.code} $thenLabel")
                        if (term.els != next) line("b $elseLabel")
                    }
                } else if (term.then == next) {
                    line("cbz x${colour(term.cond)}, $elseLabel")
                } else {
                    line("cbnz x${colour(term.cond)}, $thenLabel")
                    if (term.els != next) line("b $elseLabel")
                }
            }
            is Ret -> {
                term.value?.let { mov(Registers.ARGUMENT_REGS[0], colour(it)) }
                if (next != null) line("b $epilogue") // the epilogue follows the last block
            }
        }
    }

    fun copies(moves: List<Pair<Int, Int>>) {
        for (step in sequentialize(moves, borrowed(moves))) {
            when (step) {
                is Mov -> mov(step.dst, step.src)
                is Swap -> {
                    line("eor x${step.a}, x${step.a}, x${step.b}")
                    line("eor x${step.b}, x${step.a}, x${step.b}")
                    line("eor x${step.a}, x${step.a}, x${step.b}")
                }
            }
        }
    }

    /**
     * A register free to clobber here, if the function left one over.
     *
     * A caller-saved register this function never gave to a value holds
     * nothing of ours anywhere, and one that this copy neither reads nor
     * writes holds nothing of the copy's either.  With no such register the
     * copies swap instead, which needs no scratch at all.
     */
    open fun borrowed(moves: List<Pair<Int, Int>>): Int? {
        val touched = moves.flatMap { listOf(it.first, it.second) }.toSet()
        return Registers.CALLER_SAVED.firstOrNull { it !in taken && it !in touched }
    }

    // -- one instruction --------------------------------------------------

    fun instruction(instr: Instr) {
        when (instr) {
            is Machine -> machine(instr)
            is Move -> mov(colour(instr.dst), colour(instr.src))
            is LoadSlot ->
                access("ldr", colour(instr.dst), 29, slotOffset(instr.slot).toLong())
            is StoreSlot ->
                access("str", colour(instr.src), 29, slotOffset(instr.slot).toLong())
            is FrameAddr -> mov(colour(instr.dst), 29)
            is Call -> call(instr.dst, instr.callee, instr.args)
            else -> throw AssertionError("cannot emit $instr")
        }
    }

    /** Write down one selected instruction, or the sequence it stands for. */
    fun machine(instr: Machine) {
        val srcs = instr.srcs.map { colour(it) }
        when (instr.form) {
            "const" -> immediate(colour(instr.dst!!), instr.imm)
            "adr" -> {
                val d = colour(instr.dst!!)
                line("adrp x$d, ${instr.symbol}")
                line("add x$d, x$d, :lo12:${instr.symbol}")
            }
            "ldr" -> access("ldr", colour(instr.dst!!), srcs[0], instr.imm)
            "str" -> access("str", srcs[1], srcs[0], instr.imm)
            else -> {
                var written = FORMS.getValue(instr.form)
                for ((i, c) in srcs.withIndex()) written = written.replace("{s$i}", "x$c")
                instr.dst?.let { written = written.replace("{d}", "x${colour(it)}") }
                written = written.replace("{imm}", instr.imm.toString())
                written = written.replace("{sym}", instr.symbol)
                line(written)
            }
        }
    }

    fun call(dst: Reg?, callee: String, args: List<Reg>) {
        val inRegisters = args.take(Registers.ARGUMENT_REGS.size)
            .mapIndexed { i, a -> Registers.ARGUMENT_REGS[i] to colour(a) }
        for ((i, a) in args.drop(Registers.ARGUMENT_REGS.size).withIndex()) {
            access("str", colour(a), 31, (WORD * i).toLong())
        }
        copies(inRegisters)
        line("bl $callee")
        dst?.let { mov(colour(it), Registers.ARGUMENT_REGS[0]) }
    }
}
