package wolv

import wolv.allocator.*
import wolv.ast.*

import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class TypecheckTest {
    private fun accepts(source: String): Program {
        val prog = parse(source)
        check(prog)
        return prog
    }

    private fun rejects(source: String, message: String) {
        val error = assertFailsWith<TypeCheckError> { accepts(source) }
        assertContains(error.message, message)
    }

    @Test
    fun `arithmetic is on ints`() {
        accepts("val x = 1 + 2")
        rejects("val x = 1 + \"a\"", "expected `int`, found `string`")
        rejects("val x = true + 1", "expected `int`, found `bool`")
    }

    @Test
    fun `concatenation is on strings`() {
        accepts("val s = \"a\" ^ \"b\"")
        rejects("val s = \"a\" ^ 1", "expected `string`, found `int`")
    }

    @Test
    fun `comparison gives bool`() {
        accepts("val b = 1 < 2 andalso 3 >= 4")
        rejects("val b = \"a\" < 1", "expected `string`, found `int`")
        rejects("val b = true < false", "compares int or string")
    }

    @Test
    fun `equality needs one type`() {
        accepts("val b = 1 = 2")
        accepts("val b = \"a\" <> \"b\"")
        rejects("val b = 1 = true", "compares `int` with `bool`")
    }

    @Test
    fun `conditions are bool`() {
        accepts("val x = if true then 1 else 2")
        rejects("val x = if 1 then 1 else 2", "expected `bool`, found `int`")
        rejects("val x = if true then 1 else \"a\"", "the branches differ")
        rejects("val () = if true then 1", "in an `if` with no `else`")
    }

    @Test
    fun `a val cannot be assigned`() {
        accepts("var x = 1 val () = x := 2")
        rejects("val x = 1 val () = x := 2", "is a `val`")
    }

    @Test
    fun `functions check their arguments`() {
        accepts("fun f (a : int) : int = a\nval x = f (1)")
        rejects("fun f (a : int) : int = a\nval x = f (1, 2)", "takes 1 argument")
        rejects("fun f (a : int) : int = a\nval x = f (\"s\")", "expected `int`")
    }

    @Test
    fun `a fun without a result is a procedure`() {
        accepts("fun f () = print (\"x\")\nval () = f ()")
        rejects("fun f () = 1", "expected `unit`, found `int`")
    }

    @Test
    fun `functions are not values`() {
        rejects("fun f () : int = 1\nval x = f", "functions are not values")
    }

    @Test
    fun `records are nominal`() {
        accepts("type p = { x : int }\nval a = p { x = 1 }\nval b = a.x")
        rejects(
            "type p = { x : int } and q = { x : int }\n" +
                "fun f (r : p) : int = r.x\nval x = f (q { x = 1 })",
            "expected `p`, found `q`",
        )
        rejects("type p = { x : int }\nval a = p { y = 1 }", "has no field `y`")
        rejects("type p = { x : int, y : int }\nval a = p { x = 1 }", "field `y` is missing")
    }

    @Test
    fun `nil is a record of any type`() {
        accepts("type p = { x : int }\nval a : p = nil\nval b = a = nil")
        rejects("val a = nil", "needs a type annotation")
        rejects("type p = { x : int }\nval a : p = nil\nval b = a = 1", "compares")
    }

    @Test
    fun `arrays know their element`() {
        accepts("val a = array (3, 0)\nval x = a[0] + 1")
        accepts("type ints = int array\nval a : ints = array (3, 0)")
        rejects("val a = array (3, 0)\nval x = a[0] ^ \"s\"", "expected `string`")
        rejects("val a = array (3, 0)\nval x = a[true]", "as an array index")
        rejects("val x = length (1)", "`length` wants an array")
    }

    @Test
    fun `break is inside a loop`() {
        accepts("val () = while true do break")
        accepts("val () = for i = 0 to 3 do break")
        rejects("val () = break", "outside any loop")
        rejects("val () = while true do let fun f () = break in f () end", "outside any loop")
    }

    @Test
    fun `escape analysis marks what a nested function reads`() {
        val prog = accepts(
            "fun outer () : int =\n" +
                "  let var kept = 1\n" +
                "      val plain = 2\n" +
                "      fun inner () : int = kept\n" +
                "  in inner () + plain end\n",
        )
        val decl = assertIs<FunDecl>(prog.decls[0])
        val body = assertIs<Let>(decl.binds[0].body)
        val kept = assertIs<ValDecl>(body.decls[0])
        val plain = assertIs<ValDecl>(body.decls[1])
        assertTrue(kept.sym!!.escapes)
        assertFalse(plain.sym!!.escapes)
    }

    @Test
    fun `a parameter escapes too`() {
        val prog = accepts(
            "fun outer (n : int) : int =\n  let fun inner () : int = n in inner () end\n",
        )
        val decl = assertIs<FunDecl>(prog.decls[0])
        assertTrue(decl.binds[0].params[0].sym!!.escapes)
    }

    @Test
    fun `recursive types`() {
        accepts(
            "type list = { head : int, tail : list }\n" +
                "fun sum (l : list) : int = if l = nil then 0 else l.head + sum (l.tail)\n",
        )
        accepts("type a = b array and b = { next : a }")
    }

    @Test
    fun `unbound names`() {
        rejects("val x = y", "`y` is not bound")
        rejects("val x : t = 1", "`t` is not a type")
        rejects("val x = f ()", "`f` is not bound")
    }
}
