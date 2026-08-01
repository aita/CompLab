/** Random programs, compiled and checked against what Kotlin says they mean. */

package wolv

import wolv.allocator.*
import wolv.ir.*

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments
import org.junit.jupiter.params.provider.MethodSource
import java.util.stream.Stream
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.fail

class OracleTest {
    companion object {
        val CONFIGURATIONS: Map<String, Options> = linkedMapOf(
            "default" to Options(),
            "no-opt" to Options(optimise = false),
            "no-checks" to Options(checks = false),
            "spilling" to Options(maxRegs = 10),
        )

        @JvmStatic
        fun seedsAndConfigurations(): Stream<Arguments> = listOf(1, 2).stream().flatMap { seed ->
            CONFIGURATIONS.keys.stream().map { Arguments.of(seed, it) }
        }
    }

    private fun check(source: String, expected: String, opts: Options) {
        val done = runSource(source, opts)
        assertEquals(0, done.exitCode, done.stderr)
        if (done.stdout == expected) return
        val got = done.stdout.lines()
        val want = expected.lines()
        for ((i, pair) in got.zip(want).withIndex()) {
            assertEquals(pair.second, pair.first, "line $i")
        }
        fail("${got.size} lines, want ${want.size}")
    }

    @ParameterizedTest(name = "seed {0} [{1}]")
    @MethodSource("seedsAndConfigurations")
    fun arithmetic(seed: Int, configuration: String) {
        Fixtures.toolchain()
        val (source, expected) = Oracle.arithmetic(seed, 25)
        check(source, expected, CONFIGURATIONS.getValue(configuration))
    }

    @ParameterizedTest(name = "seed {0} [{1}]")
    @MethodSource("seedsAndConfigurations")
    fun `arrays loops and branches`(seed: Int, configuration: String) {
        Fixtures.toolchain()
        val (source, expected) = Oracle.imperative(seed, 8)
        check(source, expected, CONFIGURATIONS.getValue(configuration))
    }

    /** Force the swap: the borrowed register is what usually hides this path. */
    private class NoBorrow(func: Func, alloc: Allocation) : FuncEmitter(func, alloc) {
        override fun borrowed(moves: List<Pair<Int, Int>>): Int? = null
    }

    @Test
    fun `a cycle of copies can be done without a scratch register`() {
        Fixtures.toolchain()
        val source = "fun swap (a : int, b : int) : int =\n" +
            "  if a > b then swap (b, a) else b * 10 + a\n" +
            "val () = (printInt (swap (1, 2)); print (\" \"); printInt (swap (7, 3)))\n"
        assertEquals("21 73", runSource(source, Options()).stdout)
        assertContains(compileToAsm(source, Options(), ::NoBorrow), "eor x")
        assertEquals(
            "21 73",
            runSource(source, Options(), newEmitter = ::NoBorrow).stdout,
        )
    }
}
