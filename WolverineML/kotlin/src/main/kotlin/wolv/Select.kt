/**
 * Instruction selection: cover the DAG with ARM instructions.
 *
 * Every node that has to become a register of its own is tiled, largest tile
 * first, pulling its foldable operands into the tile as it goes.  The tiles are
 * the things ARM can do in one instruction that the IR needs several nodes to
 * say:
 *
 *     a + b * c            madd
 *     a - b * c            msub
 *     a + (b << k)         add with a shifted operand
 *     a + 4095             add with an immediate
 *     a * 8                lsl
 *     [a + 24]             a load with the addition as its displacement
 *     a < b, then branch   cmp, and a branch on the flags
 *
 * What comes out is still the same CFG, and still in SSA — a tile defines one new
 * register — so liveness, the allocator and the verifier carry on as before.
 * What has gone is the guesswork the emitter used to do with its peepholes: an
 * instruction is now chosen where the whole expression is visible, rather than by
 * looking at the line before.
 */

package wolv

import wolv.ir.*

/** What `add`, `sub` and `cmp` take as an immediate operand. */
const val IMMEDIATE = 4095L

val LOGICAL: Map<String, String> = mapOf("and" to "and", "or" to "orr", "xor" to "eor")
val SHIFTS: Map<String, String> = mapOf("shl" to "lsl", "shr" to "asr")

fun selectModule(mod: Module) {
    for (func in mod.funcs) select(func)
}

fun select(func: Func) {
    val live = func.liveness()
    for (block in func.walk()) {
        val graph = Dag.build(block, live.liveOut.getValue(block.label))
        block.instrs = Selector(graph).run()
    }
}

/** The DAGs a selection would work on, for `wolv emit -s dag`. */
fun graphs(func: Func): Map<String, Dag> {
    val live = func.liveness()
    return func.walk().associateTo(LinkedHashMap()) {
        it.label to Dag.build(it, live.liveOut.getValue(it.label))
    }
}

private class Selector(val graph: Dag) {
val out = mutableListOf<Instr>()
val done = mutableSetOf<Int>()
val absorbed = mutableSetOf<Int>()

fun run(): MutableList<Instr> {
    plan()
    for ((i, node) in graph.nodes.withIndex()) {
        if (i in absorbed) continue // part of the tile that reads it
        if (graph.rematerialisable(i) != null) continue // computed where a register wants it
        if (fuseComparison(i)) continue
        done.add(i)
        tile(node)
    }
    return out
}

/**
 * Decide which nodes a tile is going to swallow, before emitting any.
 *
 * Nothing may be deferred on the chance that its reader takes it.  A node
 * left out of the order and then not absorbed would be computed at its
 * reader instead, and a chain of those — `a + b + c + ...`, where every term
 * has one reader — would move the whole sum to its last line and keep every
 * term alive until then.
 */
fun plan() {
    for (node in graph.nodes) {
        val reader = node.reader
        if (!node.alone() || reader == null) continue
        if (swallows(graph.nodes[reader], node)) absorbed.add(node.index)
    }
}

/** Whether the instruction chosen for `reader` has room for `node`. */
fun swallows(reader: Dag.Node, node: Dag.Node): Boolean = when (val instr = reader.instr) {
    is Bin ->
        if (instr.op != "+" && instr.op != "-") false
        else if (reader.operands[1] != node.index) false
        else asShift(node.index) != null || isBin(node, "*")
    is Load ->
        reader.operands[0] == node.index && displaces(node, instr.offset) != null
    is Store ->
        reader.operands[0] == node.index && displaces(node, instr.offset) != null
    else -> false
}

/** `[pointer + 24]`, when what is added to the pointer is a constant. */
fun displaces(node: Dag.Node, offset: Int): Long? {
    if (!isBin(node, "+")) return null
    val value = constant(node.operands[1]) ?: return null
    val total = offset + value
    if (total in 0L..32760L && total % WORD == 0L) return total
    if (total in -256L..255L) return total
    return null
}

// -- emitting ---------------------------------------------------------

fun mach(
    form: String,
    dst: Reg?,
    srcs: List<Reg>,
    imm: Long = 0,
    symbol: String = "",
    effect: Boolean = false,
) {
    out.add(Machine(form, dst, srcs, imm, symbol, effect))
}

/**
 * The register holding an operand, computing it here if it was deferred.
 *
 * Only two kinds of node were left out of the order: a constant, which is
 * tiled the first time somebody needs it in a register and read from there
 * afterwards, and a node the plan said would be absorbed, which ends up here
 * only if the tile that was to absorb it changed its mind.
 */
fun at(index: Int?, reg: Reg): Reg {
    val node = graph.of(index)
    if (node == null || node.index in done) return reg
    val deferred = node.index in absorbed || graph.rematerialisable(node.index) != null
    if (!deferred) return reg
    done.add(node.index)
    return tile(node)
}

// -- one node ---------------------------------------------------------

fun tile(node: Dag.Node): Reg {
    when (val instr = node.instr) {
        is Const -> {
            mach("const", instr.dst, listOf(), imm = instr.value)
            return instr.dst
        }
        is StrConst -> {
            mach("adr", instr.dst, listOf(), symbol = instr.symbol)
            return instr.dst
        }
        is Bin -> {
            arithmetic(node, instr.dst, instr.op, instr.lhs, instr.rhs)
            return instr.dst
        }
        is Cmp -> {
            compare(node, instr.op, instr.lhs, instr.rhs)
            mach("cset", instr.dst, listOf(), symbol = CONDITION.getValue(instr.op))
            return instr.dst
        }
        is Load -> {
            load(node, instr.dst, instr.base, instr.offset)
            return instr.dst
        }
        is Store -> {
            store(node, instr.base, instr.offset, instr.src)
            return instr.src
        }
        else -> {
            // Moves, calls, slot accesses and the terminator are machine
            // instructions already, and a phi is not in this list at all.
            // None of them folds anything, so every operand that was left to
            // be folded has to be computed here instead.
            for (index in node.operands) force(index)
            out.add(instr)
            return instr.def ?: 0
        }
    }
}

// -- the tiles --------------------------------------------------------

fun arithmetic(node: Dag.Node, dst: Reg, op: String, lhs: Reg, rhs: Reg) {
    when (op) {
        "+", "-" -> additive(node, dst, op, lhs, rhs)
        "*" -> multiply(node, dst, lhs, rhs)
        "/" -> mach("sdiv", dst, both(node, lhs, rhs))
        "shl", "shr" -> shift(node, dst, op, lhs, rhs)
        "and", "or", "xor" -> logical(node, dst, op, lhs, rhs)
        else -> throw AssertionError("no instruction for `$op`")
    }
}

/** Both operands in registers, which is what the plain forms want. */
fun both(node: Dag.Node, lhs: Reg, rhs: Reg): List<Reg> =
    listOf(at(node.operands[0], lhs), at(node.operands[1], rhs))

/** `add` and `sub`, in whichever of their four forms fits. */
fun additive(node: Dag.Node, dst: Reg, op: String, lhs: Reg, rhs: Reg) {
    // A shifted operand comes first: `a + b * 8` is one instruction that way
    // and two as a multiply-add, because the 8 would need a register.
    if (shiftInto(node, dst, op, lhs, rhs)) return
    if (multiplyInto(node, dst, op, lhs, rhs)) return
    val left = node.operands[0]
    val right = node.operands[1]
    val value = constant(right)
    if (value != null && value in 0..IMMEDIATE) {
        mach(if (op == "+") "addi" else "subi", dst, listOf(at(left, lhs)), imm = value)
        return
    }
    if (op == "+") {
        // Only addition may take its constant from the other side.
        val other = constant(left)
        if (other != null && other in 0..IMMEDIATE) {
            mach("addi", dst, listOf(at(right, rhs)), imm = other)
            return
        }
    }
    mach(if (op == "+") "add" else "sub", dst, both(node, lhs, rhs))
}

fun multiply(node: Dag.Node, dst: Reg, lhs: Reg, rhs: Reg) {
    val value = constant(node.operands[1])
    if (value != null && value > 0 && value and (value - 1) == 0L) {
        mach("lsli", dst, listOf(at(node.operands[0], lhs)), imm = bitLength(value) - 1)
        return
    }
    mach("mul", dst, both(node, lhs, rhs))
}

fun shift(node: Dag.Node, dst: Reg, op: String, lhs: Reg, rhs: Reg) {
    val value = constant(node.operands[1])
    if (value != null && value in 0L..63L) {
        mach(SHIFTS.getValue(op) + "i", dst, listOf(at(node.operands[0], lhs)), imm = value)
        return
    }
    mach(SHIFTS.getValue(op), dst, both(node, lhs, rhs))
}

fun logical(node: Dag.Node, dst: Reg, op: String, lhs: Reg, rhs: Reg) {
    if (op == "xor" && constant(node.operands[1]) == 1L) {
        // Which is how `not` arrives.
        mach("eori", dst, listOf(at(node.operands[0], lhs)), imm = 1)
        return
    }
    mach(LOGICAL.getValue(op), dst, both(node, lhs, rhs))
}

/** `a + b * c` and `a - b * c` are one instruction each. */
fun multiplyInto(node: Dag.Node, dst: Reg, op: String, lhs: Reg, rhs: Reg): Boolean {
    val product = graph.of(node.operands[1])
    if (product == null || !product.alone() || !isBin(product, "*")) return false
    val instr = product.instr as Bin
    val factors = listOf(
        at(product.operands[0], instr.lhs),
        at(product.operands[1], instr.rhs),
    )
    mach(
        if (op == "+") "madd" else "msub",
        dst,
        factors + at(node.operands[0], lhs),
    )
    return true
}

/** The second operand of an `add` may be shifted on the way in. */
fun shiftInto(node: Dag.Node, dst: Reg, op: String, lhs: Reg, rhs: Reg): Boolean {
    val (shifted, amount) = asShift(node.operands[1]) ?: return false
    val instr = shifted.instr as Bin
    mach(
        if (op == "+") "adds" else "subs",
        dst,
        listOf(at(node.operands[0], lhs), at(shifted.operands[0], instr.lhs)),
        imm = amount,
    )
    return true
}

/**
 * A `x << k` that can be folded, however it was written: `* 8` says it too.
 *
 * This decides nothing and emits nothing, so the plan and the tiles can both
 * ask it and get the same answer.
 */
fun asShift(index: Int?): Pair<Dag.Node, Long>? {
    val node = graph.of(index)
    if (node == null || !node.alone() || node.instr !is Bin) return null
    var amount = constant(node.operands[1]) ?: return null
    if (node.instr.op == "*") {
        if (amount <= 0 || amount and (amount - 1) != 0L) return null
        amount = bitLength(amount) - 1
    } else if (node.instr.op != "shl") {
        return null
    }
    if (amount !in 0L..63L) return null
    return node to amount
}

fun load(node: Dag.Node, dst: Reg, base: Reg, offset: Int) {
    val (pointer, displacement) = address(node.operands[0], base, offset)
    mach("ldr", dst, listOf(pointer), imm = displacement)
}

fun store(node: Dag.Node, base: Reg, offset: Int, src: Reg) {
    val value = at(node.operands[1], src)
    val (pointer, displacement) = address(node.operands[0], base, offset)
    mach("str", null, listOf(pointer, value), imm = displacement, effect = true)
}

/** A pointer and a displacement, taking in an addition if there is one. */
fun address(index: Int?, base: Reg, offset: Int): Pair<Reg, Long> {
    val node = graph.of(index)
    if (node != null && node.alone()) {
        val displaced = displaces(node, offset)
        if (displaced != null) {
            val instr = node.instr as Bin
            return at(node.operands[0], instr.lhs) to displaced
        }
    }
    return at(index, base) to offset.toLong()
}

// -- comparisons and the branch that reads them ------------------------

fun compare(node: Dag.Node, op: String, lhs: Reg, rhs: Reg) {
    val left = node.operands[0]
    val right = node.operands[1]
    val value = constant(right)
    if (value != null && value in 0..IMMEDIATE) {
        mach("cmpi", null, listOf(at(left, lhs)), imm = value)
        return
    }
    mach("cmp", null, listOf(at(left, lhs), at(right, rhs)))
}

/** A comparison the branch below it is the only reader of sets the flags. */
fun fuseComparison(index: Int): Boolean {
    val nodes = graph.nodes
    val node = nodes[index]
    val instr = node.instr
    if (instr !is Cmp || index + 1 != nodes.size - 1) return false
    val terminator = nodes.last().instr
    if (terminator !is CBr || terminator.cond != instr.dst) return false
    if (node.users != 1 || node.escapes) return false
    compare(node, instr.op, instr.lhs, instr.rhs)
    terminator.code = CONDITION.getValue(instr.op)
    return true
}

// -- reading operands -------------------------------------------------

/** Compute a deferred operand for a reader that has no tile to take it. */
fun force(index: Int?) {
    val node = graph.of(index) ?: return
    at(index, node.value ?: 0)
}

fun constant(index: Int?): Long? = graph.constant(index)

fun isBin(node: Dag.Node, op: String): Boolean = node.instr is Bin && node.instr.op == op

/** Where the one set bit of a power of two is. */
private fun bitLength(value: Long): Long =
    (64 - java.lang.Long.numberOfLeadingZeros(value)).toLong()
}
