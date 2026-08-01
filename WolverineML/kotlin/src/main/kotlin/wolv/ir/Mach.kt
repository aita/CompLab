/**
 * The machine IR: what instruction selection replaces the arithmetic with.
 *
 * One class, because on this machine an instruction is a form, a register it
 * writes and some it reads.  The form names an entry in the table below, and the
 * table is the whole instruction set the compiler can choose from.
 *
 * The machine IR is this plus the part of `Ir.kt` that was already machine-level:
 * a call, a move, a frame slot, a phi and the three terminators.  What it may no
 * longer contain is the arithmetic — `Const`, `Bin`, `Cmp`, `Load`, `Store`,
 * `StrConst` — and [verify] is what says so, because a compiler that quietly kept
 * an abstract instruction until the emitter would only find out there.
 *
 * [Machine] is declared here but joins the sealed hierarchy of `Ir.kt`, which
 * Kotlin allows because the two files share a package.  So `Ir.kt` answers the
 * six questions for this instruction too, alongside the others, and this file is
 * left with only what a machine instruction *means*.
 *
 * Four forms are not one instruction each, and the emitter expands them:
 *
 *     const   a constant, which is a `mov` or up to four `movz`/`movk`
 *     adr     the address of a string, which is `adrp` and an `add`
 *     ldr     a load, whose addressing mode depends on how far the offset reaches
 *     str     a store, likewise
 */

package wolv.ir

/**
 * How each form is written down, once the registers have their colours.  `d` is
 * the register written and `s0`, `s1`, `s2` the ones read.
 */
val FORMS: Map<String, String> = mapOf(
    "add" to "add {d}, {s0}, {s1}",
    "addi" to "add {d}, {s0}, #{imm}",
    "adds" to "add {d}, {s0}, {s1}, lsl #{imm}",
    "sub" to "sub {d}, {s0}, {s1}",
    "subi" to "sub {d}, {s0}, #{imm}",
    "subs" to "sub {d}, {s0}, {s1}, lsl #{imm}",
    "mul" to "mul {d}, {s0}, {s1}",
    "madd" to "madd {d}, {s0}, {s1}, {s2}",
    "msub" to "msub {d}, {s0}, {s1}, {s2}",
    "sdiv" to "sdiv {d}, {s0}, {s1}",
    "and" to "and {d}, {s0}, {s1}",
    "orr" to "orr {d}, {s0}, {s1}",
    "eor" to "eor {d}, {s0}, {s1}",
    "eori" to "eor {d}, {s0}, #{imm}",
    "lsl" to "lsl {d}, {s0}, {s1}",
    "lsli" to "lsl {d}, {s0}, #{imm}",
    "asr" to "asr {d}, {s0}, {s1}",
    "asri" to "asr {d}, {s0}, #{imm}",
    "cmp" to "cmp {s0}, {s1}",
    "cmpi" to "cmp {s0}, #{imm}",
    "cset" to "cset {d}, {sym}",
)

/**
 * Which condition code each comparison sets, and which one says the opposite —
 * the emitter needs the opposite when the branch it is writing falls through to
 * the block the comparison was true for.
 */
val CONDITION: Map<String, String> = mapOf(
    "=" to "eq",
    "<>" to "ne",
    "<" to "lt",
    "<=" to "le",
    ">" to "gt",
    ">=" to "ge",
    "u<" to "lo",
    "u>=" to "hs",
)

val OPPOSITE: Map<String, String> = mapOf(
    "eq" to "ne", "ne" to "eq", "lt" to "ge", "ge" to "lt",
    "gt" to "le", "le" to "gt", "lo" to "hs", "hs" to "lo",
)

/** The ones the emitter writes itself, because they are not one instruction. */
val EXPANDED: Set<String> = setOf("const", "adr", "ldr", "str")

data class Machine(
    val form: String,
    val dst: Reg?,
    val srcs: List<Reg>,
    val imm: Long = 0,
    val symbol: String = "",
    val effect: Boolean = false,
) : Instr {
    /**
     * Not called `show`: `Instr.show` is an extension that dispatches here, and a
     * member of that name would make the two read as if one overrode the other.
     */
    fun render(name: Name): String {
        val operands = srcs.map(name) + when {
            symbol.isNotEmpty() -> listOf(symbol)
            imm != 0L || form == "const" -> listOf("#$imm")
            else -> emptyList()
        }
        val written = "$form ${operands.joinToString(", ")}".trimEnd()
        return dst?.let { "${name(it)} = $written" } ?: written
    }
}

/** The three-address instructions selection is required to have replaced. */
private val Instr.isAbstract: Boolean
    get() = this is Const || this is StrConst || this is Bin ||
        this is Cmp || this is Load || this is Store

/** Insist that selection left nothing of the three-address IR behind. */
fun Func.verifySelected() {
    for (block in walk()) {
        for (instr in block.instrs) {
            check(!instr.isAbstract) {
                "${instr::class.simpleName} survived selection in $name:${block.label}"
            }
            if (instr is Machine) {
                check(instr.form in FORMS || instr.form in EXPANDED) {
                    "no such instruction as `${instr.form}`"
                }
            }
        }
    }
}

fun Module.verifySelected() = funcs.forEach { it.verifySelected() }
