package wolv

import wolv.allocator.*
import wolv.ir.*

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private const val LOOP = """
fun count (n : int) : int =
  let var i = 0
      var total = 0
  in
    while i < n do (total := total + i; i := i + 1);
    total
  end
val () = printInt (count (10))
"""

class SsaTest {
    private fun build(source: String, checks: Boolean = false): Module {
        val prog = parse(source)
        check(prog)
        return lower(prog, Lowering(checks = checks))
    }

    private fun inSsa(source: String, checks: Boolean = false): Module =
        build(source, checks).also { constructModule(it) }

    @Test
    fun `lowering writes a variable more than once`() {
        val func = build(LOOP).funcs[1]
        val written = mutableMapOf<Reg, Int>()
        for (block in func.walk()) {
            for (instr in block.instrs) {
                instr.def?.let { written[it] = (written[it] ?: 0) + 1 }
            }
        }
        assertTrue(written.values.any { it > 1 })
        assertTrue(func.walk().all { it.phis.isEmpty() })
    }

    @Test
    fun `construction gives one definition and phis`() {
        val func = inSsa(LOOP).funcs[1]
        verifySsa(func)
        assertTrue(func.walk().any { it.phis.isNotEmpty() }, "a loop needs phis")
    }

    @Test
    fun `every function verifies`() {
        for (func in inSsa(Fixtures.example("tour.wol"), checks = true).funcs) verifySsa(func)
    }

    @Test
    fun `dominance of a diamond`() {
        val func = inSsa(
            "fun f (c : bool) : int = if c then 1 else 2\nval () = printInt (f (true))",
        ).funcs[1]
        val dom = dominance(func)
        for (label in func.blocks.keys) assertTrue(dom.dominates(func.entry, label))
        val joins = func.walk().filter { it.preds.size > 1 }
        assertTrue(joins.isNotEmpty(), "a diamond has a join")
        for (join in joins) assertEquals(func.entry, dom.idom[join.label])
    }

    @Test
    fun `a phi names exactly its predecessors`() {
        for (func in inSsa(LOOP).funcs) {
            for (block in func.walk()) {
                for (phi in block.phis) assertEquals(block.preds.toSet(), phi.args.keys)
            }
        }
    }

    @Test
    fun `optimisation keeps it in ssa`() {
        val mod = inSsa(LOOP)
        optimise(mod)
        for (func in mod.funcs) verifySsa(func)
    }

    @Test
    fun `constants fold`() {
        val mod = inSsa("val () = printInt (2 * 3 + 4)")
        optimise(mod)
        val values = mod.funcs[0].walk()
            .flatMap { it.instrs }
            .filterIsInstance<Const>()
            .map { it.value }
        assertEquals(listOf(10L), values)
    }

    @Test
    fun `dead code goes`() {
        val mod = inSsa(
            "fun f (n : int) : int = let val unused = n * n in n + 1 end\n" +
                "val () = printInt (f (2))",
        )
        optimise(mod)
        val func = mod.funcs[1]
        assertFalse(
            func.walk().flatMap { it.instrs }.any { it is Bin && it.op == "*" },
        )
    }

    @Test
    fun `unreachable blocks go`() {
        val mod = inSsa("val () = if true then print (\"a\") else print (\"b\")")
        optimise(mod)
        val calls = mod.funcs[0].walk()
            .flatMap { it.instrs }
            .filterIsInstance<Call>()
            .map { it.callee }
        assertEquals(listOf("wol_print"), calls)
    }

    @Test
    fun `splitting leaves phis only after a jump`() {
        val mod = inSsa(LOOP, checks = true)
        optimise(mod)
        for (func in mod.funcs) {
            splitCriticalEdges(func)
            verifySsa(func)
            for (block in func.walk()) {
                if (block.succs.size <= 1) continue
                for (succ in block.succs) {
                    assertTrue(func.blocks.getValue(succ).phis.isEmpty())
                }
            }
        }
    }
}
