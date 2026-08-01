/**
 * Optimisation on SSA.
 *
 * Five small passes run to a fixed point.  Each is cheap because SSA makes it
 * cheap: a register has one definition, so constant folding and copy propagation
 * are a lookup rather than a dataflow problem, and a phi whose arguments all
 * agree is a copy that was never needed.
 *
 *     fold constants   ->  arithmetic on known values
 *     propagate copies ->  `Move`, and phis that turned into one
 *     simplify phis    ->  a phi with one distinct argument is that argument
 *     fold branches    ->  a branch on a known value, and the blocks it strands
 *     dead code        ->  anything computed and not used
 */

package wolv

import wolv.ir.*

fun optimise(mod: Module) {
    for (func in mod.funcs) optimiseFunc(func)
}

fun optimiseFunc(func: Func) {
    val passes = listOf(
        ::foldConstants,
        ::propagateCopies,
        ::simplifyPhis,
        ::foldBranches,
        ::deadCode,
    )
    while (true) {
        // Every pass runs every round: they are cheap, and one enables another.
        val changes = passes.map { it(func) }
        if (changes.none { it }) return
    }
}

// -- rewriting ------------------------------------------------------------

/** Replace registers everywhere they are read, phi arguments included. */
fun rewrite(func: Func, mapping: Map<Reg, Reg>) {
    if (mapping.isEmpty()) return

    fun resolve(start: Reg): Reg {
        var r = start
        val seen = mutableSetOf<Reg>()
        while (r in mapping && seen.add(r)) r = mapping.getValue(r)
        return r
    }

    for (block in func.walk()) {
        block.phis.replaceAll { phi -> phi.copy(args = phi.args.mapValues { resolve(it.value) }) }
        block.instrs.replaceAll { it.mapUses(::resolve) }
    }
}

fun constants(func: Func): MutableMap<Reg, Long> {
    val known = mutableMapOf<Reg, Long>()
    for (block in func.walk()) {
        for (instr in block.instrs) {
            if (instr is Const) known[instr.dst] = instr.value
        }
    }
    return known
}

// -- the passes -----------------------------------------------------------

fun foldConstants(func: Func): Boolean {
    val known = constants(func)
    var changed = false
    for (block in func.walk()) {
        for ((i, instr) in block.instrs.withIndex()) {
            val folded = fold(instr, known) ?: continue
            block.instrs[i] = folded
            if (folded is Const) known[folded.dst] = folded.value
            changed = true
        }
    }
    return changed
}

private fun fold(instr: Instr, known: Map<Reg, Long>): Instr? = when (instr) {
    is Bin -> {
        val a = known[instr.lhs]
        val b = known[instr.rhs]
        when {
            a != null && b != null -> arith(instr.op, a, b)?.let { Const(instr.dst, it) }
            b == 0L && instr.op in listOf("+", "-", "or", "xor", "shl", "shr") ->
                Move(instr.dst, instr.lhs)
            b == 1L && instr.op in listOf("*", "/") -> Move(instr.dst, instr.lhs)
            a == 0L && instr.op == "+" -> Move(instr.dst, instr.rhs)
            else -> null
        }
    }
    is Cmp -> {
        val a = known[instr.lhs]
        val b = known[instr.rhs]
        if (a == null || b == null) null
        else Const(instr.dst, if (order(instr.op, a, b)) 1 else 0)
    }
    else -> null
}

/** The language's arithmetic, in the 64 bits it is done in. */
fun arith(op: String, a: Long, b: Long): Long? = when (op) {
    "+" -> a + b
    "-" -> a - b
    "*" -> a * b
    // `/` and `mod` truncate towards zero, which is what the JVM and `sdiv`
    // both do; the one case they disagree about anywhere is `MIN / -1`, and
    // there they agree that the answer wraps back to `MIN`.
    "/" -> if (b == 0L) null else a / b
    "mod" -> if (b == 0L) null else a % b
    "and" -> a and b
    "or" -> a or b
    "xor" -> a xor b
    // Kotlin's shifts take the amount modulo 64; the language's do not.
    "shl" -> if (b < 0) null else if (b >= 64) 0L else a shl b.toInt()
    "shr" -> if (b < 0) null else if (b >= 64) (if (a < 0) -1L else 0L) else a shr b.toInt()
    else -> null
}

fun order(op: String, a: Long, b: Long): Boolean = when (op) {
    "=" -> a == b
    "<>" -> a != b
    "<" -> a < b
    "<=" -> a <= b
    ">" -> a > b
    ">=" -> a >= b
    "u<" -> a.toULong() < b.toULong()
    "u>=" -> a.toULong() >= b.toULong()
    else -> throw AssertionError("unknown comparison $op")
}

fun propagateCopies(func: Func): Boolean {
    val mapping = mutableMapOf<Reg, Reg>()
    for (block in func.walk()) {
        for (instr in block.instrs) {
            if (instr is Move) mapping[instr.dst] = instr.src
        }
    }
    if (mapping.isEmpty()) return false
    rewrite(func, mapping)
    for (block in func.walk()) {
        block.instrs = block.instrs.filterNot { it is Move }.toMutableList()
    }
    return true
}

fun simplifyPhis(func: Func): Boolean {
    val mapping = mutableMapOf<Reg, Reg>()
    var changed = false
    for (block in func.walk()) {
        // A phi that names only itself and one other value is that other value.
        block.phis = block.phis.filterNotTo(mutableListOf()) { phi ->
            val others = phi.args.values.filterTo(mutableSetOf()) { it != phi.dst }
            (others.size == 1).also { only ->
                if (only) {
                    mapping[phi.dst] = others.first()
                    changed = true
                }
            }
        }
    }
    if (changed) rewrite(func, mapping)
    return changed
}

fun foldBranches(func: Func): Boolean {
    val known = constants(func)
    var changed = false
    for (block in func.walk()) {
        val term = block.terminator
        if (term !is CBr) continue
        val value = known[term.cond]
        if (value == null && term.then != term.els) continue
        val taken = if (value == null || value != 0L) term.then else term.els
        block.instrs[block.instrs.size - 1] = Jmp(taken)
        changed = true
    }
    if (changed) func.dropUnreachable()
    return changed
}

fun deadCode(func: Func): Boolean {
    var changed = false
    while (true) {
        val used = mutableSetOf<Reg>()
        for (block in func.walk()) {
            for (phi in block.phis) used.addAll(phi.args.values)
            for (instr in block.instrs) used.addAll(instr.uses)
        }
        var roundChanged = false
        for (block in func.walk()) {
            val phis = block.phis.filter { it.dst in used }.toMutableList()
            if (phis.size != block.phis.size) {
                block.phis = phis
                roundChanged = true
            }
            block.instrs = block.instrs.filterNotTo(mutableListOf()) { instr ->
                val dead = instr.def.let { it != null && it !in used } && !instr.hasEffect
                if (dead) roundChanged = true
                dead
            }
        }
        if (!roundChanged) return changed
        changed = true
    }
}
