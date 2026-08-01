package wolv

import wolv.allocator.*
import wolv.ast.*

import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs

class ParserTest {
    /** A parenthesised sketch of the tree, so precedence is easy to assert. */
    private fun shape(e: Exp): String = when (e) {
        is IntLit -> e.value.toString()
        is StrLit -> "\"${e.value}\""
        is BoolLit -> if (e.value) "true" else "false"
        is NilLit -> "nil"
        is UnitLit -> "()"
        is Var -> e.name
        is Neg -> "(~ ${shape(e.operand)})"
        is Bin -> "(${e.op} ${shape(e.lhs)} ${shape(e.rhs)})"
        is Logic -> "(${e.op} ${shape(e.lhs)} ${shape(e.rhs)})"
        is Assign -> "(:= ${shape(e.target)} ${shape(e.value)})"
        is If -> "(if ${shape(e.cond)} ${shape(e.then)}${e.els?.let { " ${shape(it)}" } ?: ""})"
        is While -> "(while ${shape(e.cond)} ${shape(e.body)})"
        is For -> "(for ${e.name} ${shape(e.lo)} ${shape(e.hi)} ${shape(e.body)})"
        is Break -> "break"
        is Seq -> "(seq " + e.items.joinToString(" ") { shape(it) } + ")"
        is Call -> "(${e.name} " + e.args.joinToString(" ") { shape(it) } + ")"
        is Index -> "(index ${shape(e.array)} ${shape(e.index)})"
        is Field -> "(field ${shape(e.record)} ${e.name})"
        is RecordLit ->
            "(record ${e.tyname} " + e.fields.joinToString(" ") { "${it.name}=${shape(it.value)}" } + ")"
        is Let -> "(let ${e.decls.size} ${shape(e.body)})"
    }

    private fun shape(source: String): String = shape(parseExp(source))

    private fun refuses(source: String, message: String) {
        val error = assertFailsWith<ParseError> { parseExp(source) }
        assertContains(error.message, message)
    }

    @Test
    fun `arithmetic precedence`() {
        assertEquals("(+ 1 (* 2 3))", shape("1 + 2 * 3"))
        assertEquals("(+ (* 1 2) 3)", shape("1 * 2 + 3"))
        assertEquals("(- (- 1 2) 3)", shape("1 - 2 - 3"))
        assertEquals("(= (+ 1 2) 3)", shape("1 + 2 = 3"))
    }

    @Test
    fun `logic binds looser than comparison`() {
        assertEquals("(andalso (< a b) (> c d))", shape("a < b andalso c > d"))
        assertEquals("(orelse a (andalso b c))", shape("a orelse b andalso c"))
    }

    @Test
    fun `assignment is right associative and loosest`() {
        assertEquals("(:= x (+ y 1))", shape("x := y + 1"))
    }

    @Test
    fun `a branch swallows what follows it`() {
        assertEquals("(if c (:= x 1) (:= x 2))", shape("if c then x := 1 else x := 2"))
        assertEquals("(if c a (+ b 1))", shape("if c then a else b + 1"))
    }

    @Test
    fun `postfix chains`() {
        assertEquals("(index (field (index a i) f) j)", shape("a[i].f[j]"))
        assertEquals("(field (f 1 2) g)", shape("f(1, 2).g"))
    }

    @Test
    fun `sequences and unit`() {
        assertEquals("()", shape("()"))
        assertEquals("(seq a b c)", shape("(a; b; c)"))
        assertEquals("a", shape("(a)"))
    }

    @Test
    fun `negation is a tilde`() {
        assertEquals("(+ (~ x) 1)", shape("~x + 1"))
        refuses("-x", "negation is written")
    }

    @Test
    fun `the largest literal is the one that wraps`() {
        assertEquals("(~ -9223372036854775808)", shape("~9223372036854775808"))
        refuses("18446744073709551616", "does not fit in 64 bits")
    }

    @Test
    fun `record literal versus call`() {
        assertEquals("(record point x=1 y=2)", shape("point { x = 1, y = 2 }"))
        assertEquals("(point 1 2)", shape("point (1, 2)"))
    }

    @Test
    fun `let with declarations`() {
        assertEquals("(let 2 (+ x y))", shape("let val x = 1 var y = 2 in x + y end"))
    }

    @Test
    fun `a program is declarations`() {
        val prog = parse("type t = int\nval x = 1\nfun f (a : int) : int = a\n")
        assertIs<TypeDecl>(prog.decls[0])
        assertIs<ValDecl>(prog.decls[1])
        assertIs<FunDecl>(prog.decls[2])
    }

    @Test
    fun `mutual recursion is one declaration`() {
        val prog = parse("fun f () : int = g ()\nand g () : int = 1\n")
        val decl = assertIs<FunDecl>(prog.decls[0])
        assertEquals(listOf("f", "g"), decl.binds.map { it.name })
    }

    @Test
    fun `only a place can be assigned`() = refuses("1 + 2 := 3", "not assignable")

    @Test
    fun `errors name what was found`() = refuses("if a do b", "expected `then`")
}
