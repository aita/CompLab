package wolv

import wolv.allocator.*
import wolv.ir.*

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class EmitTest {
    private fun asm(source: String, opts: Options = Options()): String =
        compileToAsm(source, opts)

    // -- parallel copies ------------------------------------------------------

    private fun perform(steps: List<Step>, registers: Map<Int, String>): Map<Int, String> {
        val state = registers.toMutableMap()
        for (step in steps) {
            when (step) {
                is Mov -> state[step.dst] = state.getValue(step.src)
                is Swap -> {
                    val a = state.getValue(step.a)
                    state[step.a] = state.getValue(step.b)
                    state[step.b] = a
                }
            }
        }
        return state
    }

    /** Run a parallel copy on a register file and insist it did what it said. */
    private fun check(moves: List<Pair<Int, Int>>, borrowed: Int?): List<Step> {
        val registers = (0 until 32).associateWith { "v$it" }
        val steps = sequentialize(moves, borrowed)
        val after = perform(steps, registers)
        for ((dst, src) in moves) {
            assertEquals(registers.getValue(src), after.getValue(dst), "x$dst should hold v$src")
        }
        return steps
    }

    @Test
    fun `a copy with no cycle is just moves`() {
        val steps = check(listOf(1 to 2, 3 to 4, 5 to 5), borrowed = 9)
        assertTrue(steps.all { it is Mov })
        assertEquals(2, steps.size)
    }

    @Test
    fun `a chain is ordered so nothing is lost`() {
        check(listOf(1 to 2, 2 to 3, 3 to 4), borrowed = 9)
    }

    @Test
    fun `a cycle borrows a register when there is one`() {
        val steps = check(listOf(1 to 2, 2 to 1), borrowed = 9)
        assertTrue(steps.all { it is Mov })
        assertTrue(steps.filterIsInstance<Mov>().any { it.dst == 9 })
    }

    @Test
    fun `a cycle swaps when there is nothing to borrow`() {
        val steps = check(listOf(1 to 2, 2 to 1), borrowed = null)
        assertEquals(listOf(true), steps.map { it is Swap })
    }

    @Test
    fun `a longer cycle swaps its way round`() {
        val steps = check(listOf(1 to 2, 2 to 3, 3 to 1), borrowed = null)
        assertTrue(steps.all { it is Swap })
        assertEquals(2, steps.size)
    }

    @Test
    fun `two cycles at once`() {
        check(listOf(1 to 2, 2 to 1, 3 to 4, 4 to 3), borrowed = null)
        check(listOf(1 to 2, 2 to 1, 3 to 4, 4 to 3), borrowed = 9)
    }

    // -- what the scratch registers used to be for ----------------------------

    @Test
    fun `the remainder is a divide and an msub`() {
        val text = asm("fun f (a : int, b : int) : int = a mod b\nval () = printInt (f (7, 2))")
        assertEquals(1, Regex("sdiv").findAll(text).count())
        assertEquals(1, Regex("msub").findAll(text).count())
        assertFalse("mul" in text)
    }

    @Test
    fun `ordinary code keeps no register back`() {
        // x17 is only for an address the emitter cannot reach any other way.
        assertFalse("x17" in asm(Fixtures.example("tour.wol")))
    }

    @Test
    fun `x16 is allocatable`() {
        // It used to be held back for the emitter; a busy function should take it.
        val pressure = Fixtures.programs().first { it.name == "pressure.wol" }
        assertTrue("x16" in asm(pressure.readText()))
    }
}
