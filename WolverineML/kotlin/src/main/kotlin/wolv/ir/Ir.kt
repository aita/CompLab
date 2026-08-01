/**
 * The three-address IR, and the control flow graph both IRs are written in.
 *
 * There are two instruction sets in this compiler.  This file has the first:
 * three-address code over virtual registers, which is what lowering produces,
 * what `Ssa.kt` puts into SSA and what `Opt.kt` rewrites.  The second is
 * [Machine], declared in `Mach.kt` — the same package, which is what lets it join
 * a sealed hierarchy declared here.
 *
 * What they share is everything else — the registers, the blocks, the graph, the
 * frame — so the passes that only care about the shape of a function (liveness,
 * dominance, both register allocators, the verifiers) work on either.  They ask
 * through [def], [uses], [mapUses] and [hasEffect]: an instruction says which
 * register it writes and which it reads, and nothing outside this file matches on
 * what it is.
 *
 * Those four are extensions over a `sealed` hierarchy rather than open methods on
 * a base class, and that is the whole reason the hierarchy is sealed.  A method
 * per subclass lets a new instruction compile with the base class's default
 * quietly wrong; one `when` per question makes the same omission a compile error,
 * and lists every answer where they can be read together.
 *
 * Nothing here is ARM-specific except that a register holds exactly one 64-bit
 * word, and the frame layout at the top, which the emitter and the nested
 * functions have to agree about.
 */

package wolv.ir

/**
 * A virtual register.
 *
 * A value class and not `Int`, because three different numbers run through this
 * compiler — a virtual register, a machine register (a colour), and a frame slot
 * — and as plain `Int`s any of them typechecks where another was meant.  The
 * emitter is where the first two meet, and it is the one place that turns one
 * into the other.
 *
 * `toString` is the number alone, so `"%$reg"` still reads as a dump does.
 * Measured against the `Int` it replaced, on a function with 720 live values and
 * a machine of twelve registers, it costs nothing: the boxing it was avoided for
 * happens only at a `Map<Reg, _>` key, and that is not where the time goes.
 */
@JvmInline
value class Reg(val index: Int) : Comparable<Reg> {
    override fun compareTo(other: Reg): Int = index.compareTo(other.index)

    override fun toString(): String = index.toString()
}

/** How a register is written in a dump. */
typealias Name = (Reg) -> String

/** How a register is renamed. */
typealias Rewrite = (Reg) -> Reg

const val WORD = 8

/**
 * How many arguments AAPCS64 passes in registers.  The rest go on the stack, and
 * the frame layout below knows where.
 */
const val ARGUMENT_REGISTERS = 8

/**
 * Where a frame slot sits, relative to the frame pointer.
 *
 * Slot 0 of every nested function holds its static link, so a frame chain can be
 * walked without knowing whose frame it is.  Negative slots are the arguments the
 * caller had to pass on the stack: they are already in the frame, above the saved
 * frame record, so nothing has to be copied for them and they never take a
 * register at entry.
 */
fun slotOffset(slot: Int): Int =
    if (slot < 0) 16 + WORD * (-slot - 1) else -WORD * (slot + 1)

// -- the instructions ---------------------------------------------------------

sealed interface Instr

data class Const(val dst: Reg, val value: Long) : Instr

data class StrConst(val dst: Reg, val symbol: String) : Instr

data class Move(val dst: Reg, val src: Reg) : Instr

data class Bin(val dst: Reg, val op: String, val lhs: Reg, val rhs: Reg) : Instr

data class Cmp(val dst: Reg, val op: String, val lhs: Reg, val rhs: Reg) : Instr

data class Load(val dst: Reg, val base: Reg, val offset: Int) : Instr

data class Store(val base: Reg, val offset: Int, val src: Reg) : Instr

// -- the frame, calls and joins, which both instruction sets keep -------------

/** Read a frame slot of this function — an escaping variable, or a spill. */
data class LoadSlot(val dst: Reg, val slot: Int) : Instr

data class StoreSlot(val slot: Int, val src: Reg) : Instr

/** The frame pointer itself, which is what a static link points at. */
data class FrameAddr(val dst: Reg) : Instr

data class Call(val dst: Reg?, val callee: String, val args: List<Reg>) : Instr

/**
 * A phi reads its arguments on the edges and not where it stands, which is why
 * [uses] does not report them and liveness has to add them to the predecessor.
 */
data class Phi(val dst: Reg, val args: Map<String, Reg>) : Instr

// -- control flow -------------------------------------------------------------

/** Sealed in its own right, so [Block.succs] needs no `else`. */
sealed interface Terminator : Instr

data class Jmp(val target: String) : Terminator

data class CBr(
    val cond: Reg,
    val then: String,
    val els: String,
    // After selection a branch may read the flags a comparison just set instead
    // of testing a register, and then it reads no register at all.
    val code: String = "",
) : Terminator

data class Ret(val value: Reg?) : Terminator

// -- what every instruction of either set can be asked ------------------------

/** The register it writes, if it writes one. */
val Instr.def: Reg?
    get() = when (this) {
        is Const -> dst
        is StrConst -> dst
        is Move -> dst
        is Bin -> dst
        is Cmp -> dst
        is Load -> dst
        is LoadSlot -> dst
        is FrameAddr -> dst
        is Call -> dst
        is Phi -> dst
        is Machine -> dst
        is Store, is StoreSlot, is Jmp, is CBr, is Ret -> null
    }

/**
 * The same instruction, writing [r] instead.  Only ever asked of one that writes.
 *
 * An instruction is a value, so this answers with a new one rather than changing
 * the old, and the caller puts it back where the old one was.  Nothing
 * downstream notices, because no pass holds an instruction anywhere but in the
 * block it came out of.
 */
fun Instr.withDef(r: Reg): Instr = when (this) {
    is Const -> copy(dst = r)
    is StrConst -> copy(dst = r)
    is Move -> copy(dst = r)
    is Bin -> copy(dst = r)
    is Cmp -> copy(dst = r)
    is Load -> copy(dst = r)
    is LoadSlot -> copy(dst = r)
    is FrameAddr -> copy(dst = r)
    is Call -> copy(dst = r)
    is Phi -> copy(dst = r)
    is Machine -> copy(dst = r)
    is Store, is StoreSlot, is Jmp, is CBr, is Ret ->
        throw AssertionError("${this::class.simpleName} defines nothing")
}

/**
 * The registers it reads.  A phi's arguments are read on the edges, not here, so
 * they are not among them.
 */
val Instr.uses: List<Reg>
    get() = when (this) {
        is Move -> listOf(src)
        is Bin -> listOf(lhs, rhs)
        is Cmp -> listOf(lhs, rhs)
        is Load -> listOf(base)
        is Store -> listOf(base, src)
        is StoreSlot -> listOf(src)
        is Call -> args
        is Machine -> srcs
        is CBr -> if (code.isEmpty()) listOf(cond) else emptyList()
        is Ret -> listOfNotNull(value)
        is Const, is StrConst, is LoadSlot, is FrameAddr, is Phi, is Jmp -> emptyList()
    }

/** The same instruction with the registers it reads renamed. */
fun Instr.mapUses(rename: Rewrite): Instr = when (this) {
    is Move -> copy(src = rename(src))
    is Bin -> copy(lhs = rename(lhs), rhs = rename(rhs))
    is Cmp -> copy(lhs = rename(lhs), rhs = rename(rhs))
    is Load -> copy(base = rename(base))
    is Store -> copy(base = rename(base), src = rename(src))
    is StoreSlot -> copy(src = rename(src))
    is Call -> copy(args = args.map(rename))
    is Machine -> copy(srcs = srcs.map(rename))
    is CBr -> if (code.isEmpty()) copy(cond = rename(cond)) else this
    is Ret -> copy(value = value?.let(rename))
    is Const, is StrConst, is LoadSlot, is FrameAddr, is Phi, is Jmp -> this
}

/** True when it has to be kept even if its result is dead. */
val Instr.hasEffect: Boolean
    get() = when (this) {
        is Store, is StoreSlot, is Call, is Terminator -> true
        is Machine -> effect
        is Const, is StrConst, is Move, is Bin, is Cmp, is Load,
        is LoadSlot, is FrameAddr, is Phi,
        -> false
    }

// -- the graph ----------------------------------------------------------------

class Block(val label: String) {
    var phis: MutableList<Phi> = mutableListOf()
    var instrs: MutableList<Instr> = mutableListOf()
    var preds: MutableList<String> = mutableListOf()

    val terminator: Terminator
        get() = instrs.lastOrNull() as? Terminator
            ?: error(if (instrs.isEmpty()) "block $label is unterminated" else "block $label falls through")

    val succs: List<String>
        get() = when (val t = terminator) {
            is Jmp -> listOf(t.target)
            is CBr -> if (t.then != t.els) listOf(t.then, t.els) else listOf(t.then)
            is Ret -> emptyList()
        }
}

/** One function: a frame, a set of parameters, and a graph of blocks. */
class Func(
    val label: String,
    val name: String,
    val params: MutableList<Reg>,
    val depth: Int,
) {
    val entry: String = "entry"
    val blocks: MutableMap<String, Block> = LinkedHashMap()
    var order: MutableList<String> = mutableListOf()
    var nregs: Int = 0
    var nslots: Int = 0
    /** The slot the static link arrived in, or null for a function that keeps none. */
    var staticLinkSlot: Int? = null

    fun newReg(): Reg = Reg(nregs++)

    fun newSlot(): Int = nslots++

    operator fun get(label: String): Block = blocks.getValue(label)

    fun addBlock(label: String): Block {
        require(label !in blocks) { "block $label already exists" }
        return Block(label).also {
            blocks[label] = it
            order.add(label)
        }
    }

    /** Every block, in the order they were made. */
    fun walk(): List<Block> = order.map { this[it] }
}

/**
 * What the allocator decided.
 *
 * Not fields of [Func], because none of it is part of the program: a colouring is
 * an assignment from the program's registers to the machine's, and the emitter is
 * the only thing that has to read one.  A pass answers with its result rather
 * than writing it back into what it was given.
 */
data class Allocation(
    val colours: Map<Reg, Int> = emptyMap(),
    /** The callee-saved registers this function actually used, in order. */
    val saved: List<Int> = emptyList(),
    /** Which frame slot each spilled register went to. */
    val spilled: Map<Reg, Int> = emptyMap(),
)

class Module {
    val funcs: MutableList<Func> = mutableListOf()

    /** symbol -> text, in the order the literals were first seen. */
    val strings: MutableMap<String, String> = LinkedHashMap()
}

// -- rewiring -----------------------------------------------------------------

/** The same terminator, with one of its targets renamed. */
fun Instr.renameTarget(old: String, new: String): Instr = when (this) {
    is Jmp -> if (target == old) copy(target = new) else this
    is CBr -> copy(then = if (then == old) new else then, els = if (els == old) new else els)
    else -> this
}

fun Func.recomputePreds() {
    for (b in blocks.values) b.preds = mutableListOf()
    for (b in walk()) {
        for (s in b.succs) this[s].preds.add(b.label)
    }
}

fun Func.reachable(): Set<String> = buildSet {
    fun visit(label: String) {
        if (add(label)) this@reachable[label].succs.forEach(::visit)
    }
    visit(entry)
}

fun Func.dropUnreachable() {
    val live = reachable()
    blocks.keys.retainAll(live)
    order.retainAll(live)
    for (b in walk()) {
        b.phis.replaceAll { phi -> phi.copy(args = phi.args.filterKeys { it in live }) }
    }
    recomputePreds()
}

/** Reverse post-order, which is the order every dataflow pass walks in. */
fun Func.rpo(): List<String> {
    val seen = mutableSetOf<String>()
    val post = mutableListOf<String>()
    fun visit(label: String) {
        if (!seen.add(label)) return
        this[label].succs.forEach(::visit)
        post.add(label)
    }
    visit(entry)
    return post.asReversed()
}

// -- printing -----------------------------------------------------------------

fun Allocation.nameOf(r: Reg): String = colours[r]?.let { "%$r:$it" } ?: "%$r"

val Allocation.naming: Name get() = { r -> nameOf(r) }

fun Instr.show(name: Name): String {
    fun joined(rs: List<Reg>) = rs.joinToString(", ", transform = name)
    return when (this) {
        is Const -> "${name(dst)} = $value"
        is StrConst -> "${name(dst)} = &$symbol"
        is Move -> "${name(dst)} = ${name(src)}"
        is Bin -> "${name(dst)} = ${name(lhs)} $op ${name(rhs)}"
        is Cmp -> "${name(dst)} = ${name(lhs)} $op ${name(rhs)}"
        is Load -> "${name(dst)} = [${name(base)} + $offset]"
        is Store -> "[${name(base)} + $offset] = ${name(src)}"
        is LoadSlot -> "${name(dst)} = slot$slot"
        is StoreSlot -> "slot$slot = ${name(src)}"
        is FrameAddr -> "${name(dst)} = frame"
        is Call -> "$callee(${joined(args)})".let { c -> dst?.let { "${name(it)} = $c" } ?: c }
        is Phi -> "${name(dst)} = phi [${args.entries.joinToString(", ") { "${it.key}: ${name(it.value)}" }}]"
        is Jmp -> "jmp $target"
        is CBr -> "br ${if (code.isEmpty()) "${name(cond)} ?" else "$code?"} $then : $els"
        is Ret -> value?.let { "ret ${name(it)}" } ?: "ret"
        is Machine -> render(name)
    }
}

fun Func.show(alloc: Allocation = Allocation()): String = buildString {
    val naming = alloc.naming
    appendLine(
        "fun $label(${params.joinToString(", ") { alloc.nameOf(it) }})" +
            "  ; depth $depth, $nslots slots",
    )
    for (b in walk()) {
        append(b.label).append(":")
        if (b.preds.isNotEmpty()) append("  ; preds: ${b.preds.joinToString(", ")}")
        appendLine()
        for (phi in b.phis) appendLine("    ${phi.show(naming)}")
        for (instr in b.instrs) appendLine("    ${instr.show(naming)}")
    }
}.trimEnd('\n')

fun Module.show(allocs: Map<String, Allocation> = emptyMap()): String {
    val parts = funcs.map { it.show(allocs[it.label] ?: Allocation()) } +
        if (strings.isEmpty()) emptyList()
        else listOf(strings.entries.joinToString("\n") { "${it.key}: \"${it.value}\"" })
    return parts.joinToString("\n\n") + "\n"
}
