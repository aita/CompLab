/**
 * Random programs whose answer is known before they are compiled.
 *
 * The other tests say what the compiler should do; these say what the program
 * should print, which is the only thing a user cares about.  A program is built
 * at random, worked out here in Kotlin with the language's arithmetic, and then
 * compiled — so any disagreement is a bug in the compiler and not in a comparison
 * between two of its own configurations.
 */

package wolv

import wolv.allocator.*
import wolv.ir.*
import wolv.ast.*

import kotlin.random.Random

object Oracle {
    const val SIZE = 16
    val VARS = (0 until 4).map { "v$it" }
    val CONSTANTS = listOf<Long>(
        0, 1, 2, 3, 7, 8, 15, 16, 100, 4095, 4096, 65536, -1, -8, 1L shl 40,
    )
    val ARGUMENTS = listOf(
        Triple(0L, 0L, 0L),
        Triple(1L, 2L, 3L),
        Triple(-1L, 7L, -13L),
        Triple(Long.MAX_VALUE, Long.MIN_VALUE, 2L),
    )
    val COMPARISONS = listOf("=", "<>", "<", "<=", ">", ">=")

    /** Towards zero, which is what `sdiv` does. */
    fun divide(a: Long, b: Long): Long = a / b

    fun modulo(a: Long, b: Long): Long = a % b

    fun literal(value: Long): String = if (value < 0) "~${java.lang.Long.toUnsignedString(-value)}" else "$value"

    fun compare(op: String, a: Long, b: Long): Boolean = when (op) {
        "=" -> a == b
        "<>" -> a != b
        "<" -> a < b
        "<=" -> a <= b
        ">" -> a > b
        else -> a >= b
    }

    class DividedByZero : Exception()

    // -- expressions ----------------------------------------------------------

    sealed interface Node

    class Num(val value: Long) : Node

    class Read(val name: String) : Node

    class Bin(val op: String, val lhs: Node, val rhs: Node) : Node

    class Choose(val op: String, val x: Node, val y: Node, val then: Node, val els: Node) : Node

    /** `xs[index (e)]`, which only the imperative programs have. */
    class Get(val where: Node) : Node

    fun expression(rng: Random, depth: Int): Node {
        if (depth == 0 || rng.nextDouble() < 0.25) {
            return if (rng.nextDouble() < 0.5) {
                Read(listOf("a", "b", "c").random(rng))
            } else {
                Num(CONSTANTS.random(rng))
            }
        }
        if (rng.nextDouble() < 0.1) {
            return Choose(
                COMPARISONS.random(rng),
                expression(rng, depth - 1),
                expression(rng, depth - 1),
                expression(rng, depth - 1),
                expression(rng, depth - 1),
            )
        }
        return Bin(weighted(rng), expression(rng, depth - 1), expression(rng, depth - 1))
    }

    /** `+` four times as often as `/`, so that a program is mostly arithmetic. */
    private fun weighted(rng: Random): String {
        val ops = listOf("+" to 4, "-" to 3, "*" to 3, "/" to 1, "mod" to 1)
        var roll = rng.nextInt(ops.sumOf { it.second })
        for ((op, weight) in ops) {
            roll -= weight
            if (roll < 0) return op
        }
        return "+"
    }

    fun evaluate(node: Node, env: Map<String, Long>): Long = when (node) {
        is Read -> env.getValue(node.name)
        is Num -> node.value
        is Choose -> {
            val taken = compare(node.op, evaluate(node.x, env), evaluate(node.y, env))
            evaluate(if (taken) node.then else node.els, env)
        }
        is Bin -> {
            val a = evaluate(node.lhs, env)
            val b = evaluate(node.rhs, env)
            when (node.op) {
                "+" -> a + b
                "-" -> a - b
                "*" -> a * b
                else -> {
                    if (b == 0L) throw DividedByZero()
                    if (node.op == "/") divide(a, b) else modulo(a, b)
                }
            }
        }
        is Get -> throw AssertionError("an array read has no meaning here")
    }

    fun show(node: Node): String = when (node) {
        is Read -> node.name
        is Num -> literal(node.value)
        is Choose ->
            "(if ${show(node.x)} ${node.op} ${show(node.y)} " +
                "then ${show(node.then)} else ${show(node.els)})"
        is Bin -> "(${show(node.lhs)} ${node.op} ${show(node.rhs)})"
        is Get -> "xs[index (${show(node.where)})]"
    }

    /** `count` functions of three arguments, and what they print. */
    fun arithmetic(seed: Int, count: Int): Pair<String, String> {
        val rng = Random(seed)
        val definitions = mutableListOf<String>()
        val calls = mutableListOf<String>()
        val expected = mutableListOf<String>()
        var made = 0
        while (made < count) {
            val tree = expression(rng, rng.nextInt(1, 6))
            val values = try {
                ARGUMENTS.map { (a, b, c) -> evaluate(tree, mapOf("a" to a, "b" to b, "c" to c)) }
            } catch (_: DividedByZero) {
                continue
            }
            definitions.add("fun f$made (a : int, b : int, c : int) : int = ${show(tree)}")
            for ((arguments, want) in ARGUMENTS.zip(values)) {
                val (a, b, c) = arguments
                val written = listOf(a, b, c).joinToString(", ") { literal(it) }
                calls.add("val () = (printInt (f$made ($written)); print (\"\\n\"))")
                expected.add(want.toString())
            }
            made += 1
        }
        return (definitions + calls).joinToString("\n") + "\n" to expected.joinToString("\n") + "\n"
    }

    // -- statements -----------------------------------------------------------

    sealed interface Stmt

    class Set(val name: String, val value: Node) : Stmt

    class Put(val where: Node, val value: Node) : Stmt

    class Seq(val items: List<Stmt>) : Stmt

    class If(val op: String, val x: Node, val y: Node, val then: Stmt, val els: Stmt) : Stmt

    class For(val name: String, val lo: Int, val hi: Int, val body: Stmt) : Stmt

    private class Fresh {
        var n = 0
    }

    private fun statement(rng: Random, depth: Int, scope: List<String>, fresh: Fresh): Stmt {
        val roll = rng.nextDouble()
        if (depth > 0 && roll < 0.2) {
            return If(
                COMPARISONS.random(rng),
                place(rng, scope),
                place(rng, scope),
                statement(rng, depth - 1, scope, fresh),
                statement(rng, depth - 1, scope, fresh),
            )
        }
        if (depth > 0 && roll < 0.45) {
            fresh.n += 1
            val name = "i${fresh.n}"
            return For(
                name,
                rng.nextInt(0, 3),
                rng.nextInt(2, 6),
                statement(rng, depth - 1, scope + name, fresh),
            )
        }
        if (depth > 0 && roll < 0.55) {
            return Seq(List(2) { statement(rng, depth - 1, scope, fresh) })
        }
        if (roll < 0.8) return Set(VARS.random(rng), place(rng, scope))
        return Put(place(rng, scope), place(rng, scope))
    }

    /** An expression over the variables in scope and the array. */
    private fun place(rng: Random, scope: List<String>): Node {
        val roll = rng.nextDouble()
        if (roll < 0.35) return Read(scope.random(rng))
        if (roll < 0.5) return Num(CONSTANTS.random(rng))
        if (roll < 0.65) return Get(place(rng, scope))
        return Bin(listOf("+", "-", "*").random(rng), place(rng, scope), place(rng, scope))
    }

    /** `index` in the generated program: the remainder, made positive. */
    fun cell(value: Long): Int = (((value % SIZE) + SIZE) % SIZE).toInt()

    private fun runPlace(node: Node, env: Map<String, Long>, array: LongArray): Long = when (node) {
        is Read -> env.getValue(node.name)
        is Num -> node.value
        is Get -> array[cell(runPlace(node.where, env, array))]
        is Bin -> {
            val a = runPlace(node.lhs, env, array)
            val b = runPlace(node.rhs, env, array)
            when (node.op) {
                "+" -> a + b
                "-" -> a - b
                else -> a * b
            }
        }
        is Choose -> throw AssertionError("a branch is not a place")
    }

    private fun runStatement(node: Stmt, env: MutableMap<String, Long>, array: LongArray) {
        when (node) {
            is Set -> env[node.name] = runPlace(node.value, env, array)
            is Put -> array[cell(runPlace(node.where, env, array))] =
                runPlace(node.value, env, array)
            is Seq -> for (item in node.items) runStatement(item, env, array)
            is If -> {
                val a = runPlace(node.x, env, array)
                val b = runPlace(node.y, env, array)
                runStatement(if (compare(node.op, a, b)) node.then else node.els, env, array)
            }
            is For -> for (i in node.lo..node.hi) {
                env[node.name] = i.toLong()
                runStatement(node.body, env, array)
            }
        }
    }

    private fun showStatement(node: Stmt, indent: String): String = when (node) {
        is Set -> "$indent${node.name} := ${show(node.value)}"
        is Put -> "${indent}xs[index (${show(node.where)})] := ${show(node.value)}"
        is Seq -> {
            val inner = node.items.joinToString(";\n") { showStatement(it, "$indent  ") }
            "$indent(\n$inner\n$indent)"
        }
        is If ->
            "${indent}if ${show(node.x)} ${node.op} ${show(node.y)} then\n" +
                "${showStatement(node.then, "$indent  ")}\n${indent}else\n" +
                showStatement(node.els, "$indent  ")
        is For ->
            "${indent}for ${node.name} = ${node.lo} to ${node.hi} do\n" +
                showStatement(node.body, "$indent  ")
    }

    private val PREAMBLE = """
        val xs = array (16, 0)
        fun index (n : int) : int =
          let val r = n - n / 16 * 16 in
            if r < 0 then r + 16 else r
          end
    """.trimIndent()

    /** A program of assignments, loops and branches over an array. */
    fun imperative(seed: Int, count: Int): Pair<String, String> {
        val rng = Random(seed)
        val fresh = Fresh()
        val body = List(count) { statement(rng, 3, VARS, fresh) }
        val env = VARS.associateWithTo(mutableMapOf()) { 0L }
        val array = LongArray(SIZE)
        for (item in body) runStatement(item, env, array)
        val expected = VARS.map { env.getValue(it).toString() } + array.map { it.toString() }

        val lines = mutableListOf(PREAMBLE)
        lines += VARS.map { "var $it = 0" }
        lines += "val () = ("
        lines += body.joinToString(";\n") { showStatement(it, "  ") }
        lines += ")"
        lines += VARS.map { "val () = (printInt ($it); print (\"\\n\"))" }
        lines += "val () = for k = 0 to 15 do (printInt (xs[k]); print (\"\\n\"))"
        return lines.joinToString("\n") + "\n" to expected.joinToString("\n") + "\n"
    }
}
