package wolv

import wolv.allocator.*
import wolv.ir.*

import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private const val FUNCTION =
    "fun f (a : int, b : int, c : int) : int = %s\nval () = printInt (f (1, 2, 3))"

class SelectTest {
    private fun selected(source: String, checks: Boolean = false): Module {
        val prog = parse(source)
        check(prog)
        val mod = lower(prog, Lowering(checks = checks))
        constructModule(mod)
        optimise(mod)
        for (func in mod.funcs) splitCriticalEdges(func)
        selectModule(mod)
        return mod
    }

    /** The instructions chosen inside one function, the caller's aside. */
    private fun forms(source: String, name: String = "f", checks: Boolean = false): List<String> {
        val func = selected(source, checks).funcs.first { it.name == name }
        return func.walk().flatMap { it.instrs }.filterIsInstance<Machine>().map { it.form }
    }

    private fun body(exp: String): String = FUNCTION.format(exp)

    private fun asm(source: String): String =
        compileToAsm(source, Options(checks = false))

    // -- the tiles ------------------------------------------------------------

    @Test
    fun `multiply-add is one instruction`() {
        val chosen = forms(body("a + b * c"))
        assertContains(chosen, "madd")
        assertFalse("mul" in chosen)
    }

    @Test
    fun `multiply-subtract is one instruction`() {
        val chosen = forms(body("a - b * c"))
        assertContains(chosen, "msub")
        assertFalse("mul" in chosen)
    }

    @Test
    fun `a shifted operand beats a multiply-add`() {
        // `a + b * 8` is one instruction with a shift and two as a multiply-add.
        val chosen = forms(body("a + b * 8"))
        assertEquals(1, chosen.count { it == "adds" })
        assertFalse("madd" in chosen)
        assertFalse("lsli" in chosen)
    }

    @Test
    fun `a small constant is an immediate`() {
        assertEquals(listOf("addi"), forms(body("a + 5")))
        assertEquals(listOf("addi", "subi"), forms(body("(a + 5) - 7")))
    }

    @Test
    fun `a large constant is not`() {
        assertContains(forms(body("a + 100000")), "const")
    }

    @Test
    fun `a multiply by a power of two is a shift`() {
        val chosen = forms(body("a * 8"))
        assertContains(chosen, "lsli")
        assertFalse("mul" in chosen)
    }

    @Test
    fun `a comparison read only by its branch sets the flags`() {
        val source = "fun f (a : int) : int = if a < 3 then 1 else 2\nval () = printInt (f (1))"
        val codes = selected(source).funcs
            .flatMap { it.walk() }
            .map { it.terminator }
            .filterIsInstance<CBr>()
            .map { it.code }
        assertContains(codes, "lt")
        assertFalse("cset" in forms(source))
    }

    @Test
    fun `a comparison read by something else is a value`() {
        assertContains(forms("fun f (a : int) : bool = a < 3\nval () = print (\"x\")"), "cset")
    }

    @Test
    fun `an array element takes two instructions`() {
        val text = asm("val a = array (4, 0)\nval () = printInt (a[2] + a[3])")
        assertTrue("lsl #3" in text || "ldr" in text)
        val body = text.lines().filter { it.startsWith("\t") }.map { it.trim() }
        assertEquals(2, body.count { it.startsWith("ldr ") })
    }

    // -- what the plan is for -------------------------------------------------

    @Test
    fun `a constant read twice is still an immediate`() {
        // It costs nothing to repeat, so two readers may both take it.
        val chosen = forms(body("(a + 1) * (b + 1)"))
        assertEquals(2, chosen.count { it == "addi" })
        assertFalse("const" in chosen)
    }

    @Test
    fun `a chain of additions is not deferred to its last line`() {
        // Folding a whole spine would keep every term live until the end.
        val source = "fun sum (a : int, b : int, c : int, d : int, e : int, f : int) : int =\n" +
            "  a + b + c + d + e + f\n" +
            "val () = printInt (sum (1, 2, 3, 4, 5, 6))\n"
        val func = selected(source).funcs.first { it.name == "sum" }
        assertTrue(func.pressure(func.liveness()) <= 8)
    }

    @Test
    fun `a node read twice is computed once`() {
        assertEquals(1, forms(body("let val t = a * b in t + t end")).count { it == "mul" })
    }

    @Test
    fun `the graph counts its readers`() {
        val func = selected(body("a + b")).funcs.first { it.name == "f" }
        val live = func.liveness()
        for (block in func.walk()) {
            val graph = Dag.build(block, live.liveOut.getValue(block.label))
            for (node in graph.nodes) {
                val expected = graph.nodes.sumOf { other ->
                    other.operands.count { it == node.index }
                }
                assertEquals(expected, node.users)
            }
        }
    }

    @Test
    fun `selection keeps ssa`() {
        for (func in selected(body("a + b * c + 8"), checks = true).funcs) verifySsa(func)
    }
}
