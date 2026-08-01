package wolv

import wolv.allocator.*
import wolv.ir.*

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import wolv.allocator.OutOfRegisters
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

private const val SOURCE = """
type point = { x : int, y : int }

fun busy (n : int) : int =
  let
    var a = n + 1
    var b = n + 2
    var c = n + 3
    var d = n + 4
    var total = 0
  in
    while a < n * 10 do (
      total := total + a * b + c * d;
      a := a + 1;
      b := b + 2;
      c := c + 3;
      d := d + 4
    );
    total
  end

fun caller (n : int) : int = busy (n) + busy (n + 1) + busy (n + 2)

val p = point { x = 1, y = 2 }
val () = printInt (caller (3) + p.x)
"""

class AllocatorTest {
    /** The pipeline up to the point where the allocator takes over. */
    private fun prepared(source: String = SOURCE): Module {
        val prog = parse(source)
        check(prog)
        val mod = lower(prog, Lowering(checks = true))
        constructModule(mod)
        optimise(mod)
        for (func in mod.funcs) splitCriticalEdges(func)
        selectModule(mod)
        destructModule(mod)
        return mod
    }

    private fun allocated(machine: Registers = Registers(), source: String = SOURCE): Module =
        prepared(source).also { allocateModule(it, machine) }

    // -- what it promises -----------------------------------------------------

    @Test
    fun `every value gets a colour`() {
        for (func in allocated().funcs) {
            for (block in func.walk()) {
                for (instr in block.instrs) {
                    for (r in instr.uses) assertContains(func.colours, r)
                    instr.def?.let { assertContains(func.colours, it) }
                }
            }
        }
    }

    @Test
    fun `values live together differ`() {
        for (func in allocated().funcs) verifyColouring(func)
    }

    /**
     * Without the optimiser the copies survive to the allocator, and coalescing
     * gives both ends of one copy the same register.  That is right, and it is
     * what a verifier reading whole live sets would reject.
     */
    @Test
    fun `they differ without the optimiser too`() {
        val prog = parse(SOURCE)
        check(prog)
        val mod = lower(prog, Lowering(checks = true))
        constructModule(mod)
        for (func in mod.funcs) splitCriticalEdges(func)
        selectModule(mod)
        destructModule(mod)
        allocateModule(mod, Registers())
        for (func in mod.funcs) verifyColouring(func)
    }

    /** Both ends of a copy hold the same value, so one register for the two is right. */
    @Test
    fun `a coalesced copy is not a clash`() {
        val func = Func("f", "f", mutableListOf(), 0)
        val entry = func.addBlock("entry")
        val a = func.newReg()
        val b = func.newReg()
        entry.instrs.add(Const(a, 1))
        entry.instrs.add(Move(b, a))
        entry.instrs.add(Call(null, "wol_print_int", listOf(a)))
        entry.instrs.add(Ret(b))
        func.colours = mutableMapOf(a to 9, b to 9)
        verifyColouring(func)
    }

    /** So the case above did not simply stop the verifier saying anything. */
    @Test
    fun `one colour for everything is rejected`() {
        val func = allocated().funcs.first { it.colours.values.toSet().size > 1 }
        func.colours = func.colours.keys.associateWith { 0 }.toMutableMap()
        val thrown = assertFailsWith<IllegalStateException> { verifyColouring(func) }
        assertContains(thrown.message ?: "", "at once")
    }

    @Test
    fun `a value live across a call is callee-saved`() {
        for (func in allocated().funcs) {
            val live = func.liveness()
            for (reg in func.acrossCalls(live)) {
                assertContains(Registers.CALLEE_SAVED, func.colours.getValue(reg))
            }
        }
    }

    @Test
    fun `only the callee-saved it used are saved`() {
        for (func in allocated().funcs) {
            assertEquals(
                func.colours.values.toSet().intersect(Registers.CALLEE_SAVED.toSet()),
                func.saved.toSet(),
            )
        }
    }

    @ParameterizedTest
    @ValueSource(ints = [5, 6, 8, 12, 16, 26])
    fun `a smaller machine still works`(size: Int) {
        val machine = Registers.limited(size)
        for (func in allocated(machine).funcs) {
            verifyColouring(func)
            for (colour in func.colours.values) assertContains(machine.anywhere, colour)
        }
    }

    @Test
    fun `a small machine spills`() {
        val mod = allocated(Registers.limited(6))
        assertTrue(mod.funcs.any { it.spillSlots.isNotEmpty() }, "nothing spilled")
        for (func in mod.funcs) {
            for (slot in func.spillSlots.values) assertTrue(slot < func.nslots)
        }
    }

    @Test
    fun `pressure falls to what the machine has`() {
        val machine = Registers.limited(5)
        for (func in allocated(machine).funcs) {
            assertTrue(func.pressure(func.liveness()) <= machine.count())
        }
    }

    @Test
    fun `an impossible demand is reported`() {
        val source = "fun ten (a : int, b : int, c : int, d : int, e : int,\n" +
            "         f : int, g : int, h : int, i : int, j : int) : int = a + j\n" +
            "val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))\n"
        val mod = prepared(source)
        val error = assertFailsWith<OutOfRegisters> {
            allocateModule(mod, Registers.limited(8))
        }
        assertContains(error.message!!, "more registers")
    }

    // -- what it does about copies --------------------------------------------

    @Test
    fun `leaving ssa removes every phi`() {
        for (func in prepared().funcs) {
            for (block in func.walk()) assertTrue(block.phis.isEmpty())
        }
    }

    @Test
    fun `leaving ssa makes copies and coalescing eats them`() {
        val mod = prepared()
        val before = mod.funcs.sumOf { func ->
            func.walk().sumOf { block -> block.instrs.count { it is Move } }
        }
        assertTrue(before > 0, "leaving SSA should have made copies")
        allocateModule(mod)
        val left = mod.funcs.sumOf { func ->
            func.walk().sumOf { block ->
                block.instrs.count {
                    it is Move && func.colours.getValue(it.dst) != func.colours.getValue(it.src)
                }
            }
        }
        assertTrue(left <= before / 10, "$left of $before copies survived")
    }
}
