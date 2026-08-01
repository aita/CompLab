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
 * through [def], [uses], [rewriteUses] and [hasEffect]: an instruction says which
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

typealias Reg = Int

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

class Const(var dst: Reg, val value: Long) : Instr

class StrConst(var dst: Reg, val symbol: String) : Instr

class Move(var dst: Reg, var src: Reg) : Instr

class Bin(var dst: Reg, val op: String, var lhs: Reg, var rhs: Reg) : Instr

class Cmp(var dst: Reg, val op: String, var lhs: Reg, var rhs: Reg) : Instr

class Load(var dst: Reg, var base: Reg, val offset: Int) : Instr

class Store(var base: Reg, val offset: Int, var src: Reg) : Instr

// -- the frame, calls and joins, which both instruction sets keep -------------

/** Read a frame slot of this function — an escaping variable, or a spill. */
class LoadSlot(var dst: Reg, var slot: Int) : Instr

class StoreSlot(var slot: Int, var src: Reg) : Instr

/** The frame pointer itself, which is what a static link points at. */
class FrameAddr(var dst: Reg) : Instr

class Call(var dst: Reg?, val callee: String, var args: List<Reg>) : Instr

/**
 * A phi reads its arguments on the edges and not where it stands, which is why
 * [uses] does not report them and liveness has to add them to the predecessor.
 */
class Phi(var dst: Reg, var args: MutableMap<String, Reg>) : Instr

// -- control flow -------------------------------------------------------------

/** Sealed in its own right, so [Block.succs] needs no `else`. */
sealed interface Terminator : Instr

class Jmp(var target: String) : Terminator

class CBr(
    var cond: Reg,
    var then: String,
    var els: String,
    // After selection a branch may read the flags a comparison just set instead
    // of testing a register, and then it reads no register at all.
    var code: String = "",
) : Terminator

class Ret(var value: Reg?) : Terminator

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

/** Rewrite the register it writes.  Only ever asked of one that writes. */
fun Instr.redefine(r: Reg) {
    when (this) {
        is Const -> dst = r
        is StrConst -> dst = r
        is Move -> dst = r
        is Bin -> dst = r
        is Cmp -> dst = r
        is Load -> dst = r
        is LoadSlot -> dst = r
        is FrameAddr -> dst = r
        is Call -> dst = r
        is Phi -> dst = r
        is Machine -> dst = r
        is Store, is StoreSlot, is Jmp, is CBr, is Ret ->
            throw AssertionError("${this::class.simpleName} defines nothing")
    }
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

/** Rewrite the registers it reads, in place. */
fun Instr.rewriteUses(rename: Rewrite) {
    when (this) {
        is Move -> src = rename(src)
        is Bin -> {
            lhs = rename(lhs)
            rhs = rename(rhs)
        }
        is Cmp -> {
            lhs = rename(lhs)
            rhs = rename(rhs)
        }
        is Load -> base = rename(base)
        is Store -> {
            base = rename(base)
            src = rename(src)
        }
        is StoreSlot -> src = rename(src)
        is Call -> args = args.map(rename)
        is Machine -> srcs = srcs.map(rename)
        is CBr -> if (code.isEmpty()) cond = rename(cond)
        is Ret -> value = value?.let(rename)
        is Const, is StrConst, is LoadSlot, is FrameAddr, is Phi, is Jmp -> {}
    }
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
    var staticLinkSlot: Int = -1
    var colours: MutableMap<Reg, Int> = mutableMapOf()
    val spillSlots: MutableMap<Reg, Int> = mutableMapOf()
    var saved: List<Int> = emptyList()

    fun newReg(): Reg = nregs++

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

class Module {
    val funcs: MutableList<Func> = mutableListOf()

    /** symbol -> text, in the order the literals were first seen. */
    val strings: MutableMap<String, String> = LinkedHashMap()
}

// -- rewiring -----------------------------------------------------------------

fun Instr.renameTarget(old: String, new: String) {
    when (this) {
        is Jmp -> if (target == old) target = new
        is CBr -> {
            if (then == old) then = new
            if (els == old) els = new
        }
        else -> {}
    }
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
        for (phi in b.phis) phi.args.keys.retainAll(live)
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

fun Func.nameOf(r: Reg): String = colours[r]?.let { "%$r:$it" } ?: "%$r"

val Func.naming: Name get() = { r -> nameOf(r) }

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

fun Func.show(): String = buildString {
    appendLine("fun $label(${params.joinToString(", ") { nameOf(it) }})  ; depth $depth, $nslots slots")
    for (b in walk()) {
        append(b.label).append(":")
        if (b.preds.isNotEmpty()) append("  ; preds: ${b.preds.joinToString(", ")}")
        appendLine()
        for (phi in b.phis) appendLine("    ${phi.show(naming)}")
        for (instr in b.instrs) appendLine("    ${instr.show(naming)}")
    }
}.trimEnd('\n')

fun Module.show(): String {
    val parts = funcs.map { it.show() } +
        if (strings.isEmpty()) emptyList()
        else listOf(strings.entries.joinToString("\n") { "${it.key}: \"${it.value}\"" })
    return parts.joinToString("\n\n") + "\n"
}
