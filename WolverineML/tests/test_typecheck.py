from __future__ import annotations

import pytest

from wolv import ast
from wolv.diag import TypeCheckError
from wolv.parser import parse
from wolv.typecheck import check


def accepts(source: str) -> ast.Program:
    prog = parse(source)
    check(prog)
    return prog


def rejects(source: str, message: str) -> None:
    with pytest.raises(TypeCheckError, match=message):
        accepts(source)


def test_arithmetic_is_on_ints() -> None:
    accepts("val x = 1 + 2")
    rejects('val x = 1 + "a"', "expected `int`, found `string`")
    rejects("val x = true + 1", "expected `int`, found `bool`")


def test_concatenation_is_on_strings() -> None:
    accepts('val s = "a" ^ "b"')
    rejects('val s = "a" ^ 1', "expected `string`, found `int`")


def test_comparison_gives_bool() -> None:
    accepts("val b = 1 < 2 andalso 3 >= 4")
    rejects('val b = "a" < 1', "expected `string`, found `int`")
    rejects("val b = true < false", "compares int or string")


def test_equality_needs_one_type() -> None:
    accepts("val b = 1 = 2")
    accepts('val b = "a" <> "b"')
    rejects("val b = 1 = true", "compares `int` with `bool`")


def test_conditions_are_bool() -> None:
    accepts("val x = if true then 1 else 2")
    rejects("val x = if 1 then 1 else 2", "expected `bool`, found `int`")
    rejects("val x = if true then 1 else \"a\"", "the branches differ")
    rejects("val () = if true then 1", "in an `if` with no `else`")


def test_a_val_cannot_be_assigned() -> None:
    accepts("var x = 1 val () = x := 2")
    rejects("val x = 1 val () = x := 2", "is a `val`")


def test_functions_check_their_arguments() -> None:
    accepts("fun f (a : int) : int = a\nval x = f (1)")
    rejects("fun f (a : int) : int = a\nval x = f (1, 2)", "takes 1 argument")
    rejects('fun f (a : int) : int = a\nval x = f ("s")', "expected `int`")


def test_a_fun_without_a_result_is_a_procedure() -> None:
    accepts("fun f () = print (\"x\")\nval () = f ()")
    rejects("fun f () = 1", "expected `unit`, found `int`")


def test_functions_are_not_values() -> None:
    rejects("fun f () : int = 1\nval x = f", "functions are not values")


def test_records_are_nominal() -> None:
    accepts("type p = { x : int }\nval a = p { x = 1 }\nval b = a.x")
    rejects(
        "type p = { x : int } and q = { x : int }\n"
        "fun f (r : p) : int = r.x\nval x = f (q { x = 1 })",
        "expected `p`, found `q`",
    )
    rejects("type p = { x : int }\nval a = p { y = 1 }", "has no field `y`")
    rejects("type p = { x : int, y : int }\nval a = p { x = 1 }", "field `y` is missing")


def test_nil_is_a_record_of_any_type() -> None:
    accepts("type p = { x : int }\nval a : p = nil\nval b = a = nil")
    rejects("val a = nil", "needs a type annotation")
    rejects("type p = { x : int }\nval a : p = nil\nval b = a = 1", "compares")


def test_arrays_know_their_element() -> None:
    accepts("val a = array (3, 0)\nval x = a[0] + 1")
    accepts("type ints = int array\nval a : ints = array (3, 0)")
    rejects('val a = array (3, 0)\nval x = a[0] ^ "s"', "expected `string`")
    rejects("val a = array (3, 0)\nval x = a[true]", "as an array index")
    rejects("val x = length (1)", "`length` wants an array")


def test_break_is_inside_a_loop() -> None:
    accepts("val () = while true do break")
    accepts("val () = for i = 0 to 3 do break")
    rejects("val () = break", "outside any loop")
    rejects(
        "val () = while true do let fun f () = break in f () end",
        "outside any loop",
    )


def test_escape_analysis_marks_what_a_nested_function_reads() -> None:
    prog = accepts(
        "fun outer () : int =\n"
        "  let var kept = 1\n"
        "      val plain = 2\n"
        "      fun inner () : int = kept\n"
        "  in inner () + plain end\n"
    )
    decl = prog.decls[0]
    assert isinstance(decl, ast.FunDecl)
    body = decl.binds[0].body
    assert isinstance(body, ast.Let)
    kept, plain = body.decls[0], body.decls[1]
    assert isinstance(kept, ast.ValDecl)
    assert isinstance(plain, ast.ValDecl)
    assert kept.sym is not None and kept.sym.escapes
    assert plain.sym is not None and not plain.sym.escapes


def test_a_parameter_escapes_too() -> None:
    prog = accepts(
        "fun outer (n : int) : int =\n"
        "  let fun inner () : int = n in inner () end\n"
    )
    decl = prog.decls[0]
    assert isinstance(decl, ast.FunDecl)
    param = decl.binds[0].params[0]
    assert param.sym is not None and param.sym.escapes


def test_recursive_types() -> None:
    accepts(
        "type list = { head : int, tail : list }\n"
        "fun sum (l : list) : int = if l = nil then 0 else l.head + sum (l.tail)\n"
    )
    accepts("type a = b array and b = { next : a }")


def test_unbound_names() -> None:
    rejects("val x = y", "`y` is not bound")
    rejects("val x : t = 1", "`t` is not a type")
    rejects("val x = f ()", "`f` is not bound")
