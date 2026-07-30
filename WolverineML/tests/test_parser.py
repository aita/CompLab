from __future__ import annotations

import pytest

from wolv import ast
from wolv.diag import ParseError
from wolv.parser import parse, parse_exp


def shape(e: ast.Exp) -> str:
    """A parenthesised sketch of the tree, so precedence is easy to assert."""
    match e:
        case ast.IntLit(_, value):
            return str(value)
        case ast.StrLit(_, value):
            return f'"{value}"'
        case ast.BoolLit(_, value):
            return "true" if value else "false"
        case ast.NilLit():
            return "nil"
        case ast.UnitLit():
            return "()"
        case ast.Var(_, name):
            return name
        case ast.Neg(_, operand):
            return f"(~ {shape(operand)})"
        case ast.Bin(_, op, lhs, rhs) | ast.Logic(_, op, lhs, rhs):
            return f"({op} {shape(lhs)} {shape(rhs)})"
        case ast.Assign(_, target, value):
            return f"(:= {shape(target)} {shape(value)})"
        case ast.If(_, cond, then, els):
            tail = "" if els is None else f" {shape(els)}"
            return f"(if {shape(cond)} {shape(then)}{tail})"
        case ast.While(_, cond, body):
            return f"(while {shape(cond)} {shape(body)})"
        case ast.For(_, name, lo, hi, body):
            return f"(for {name} {shape(lo)} {shape(hi)} {shape(body)})"
        case ast.Break():
            return "break"
        case ast.Seq(_, items):
            return "(seq " + " ".join(shape(i) for i in items) + ")"
        case ast.Call(_, name, args):
            return f"({name} " + " ".join(shape(a) for a in args) + ")"
        case ast.Index(_, array, index):
            return f"(index {shape(array)} {shape(index)})"
        case ast.Field(_, record, name):
            return f"(field {shape(record)} {name})"
        case ast.RecordLit(_, tyname, fields):
            inner = " ".join(f"{f.name}={shape(f.value)}" for f in fields)
            return f"(record {tyname} {inner})"
        case ast.Let(_, decls, body):
            return f"(let {len(decls)} {shape(body)})"
        case _:
            raise AssertionError(type(e).__name__)


def test_arithmetic_precedence() -> None:
    assert shape(parse_exp("1 + 2 * 3")) == "(+ 1 (* 2 3))"
    assert shape(parse_exp("1 * 2 + 3")) == "(+ (* 1 2) 3)"
    assert shape(parse_exp("1 - 2 - 3")) == "(- (- 1 2) 3)"
    assert shape(parse_exp("1 + 2 = 3")) == "(= (+ 1 2) 3)"


def test_logic_binds_looser_than_comparison() -> None:
    assert shape(parse_exp("a < b andalso c > d")) == "(andalso (< a b) (> c d))"
    assert shape(parse_exp("a orelse b andalso c")) == "(orelse a (andalso b c))"


def test_assignment_is_right_associative_and_loosest() -> None:
    assert shape(parse_exp("x := y + 1")) == "(:= x (+ y 1))"


def test_a_branch_swallows_what_follows_it() -> None:
    assert shape(parse_exp("if c then x := 1 else x := 2")) == (
        "(if c (:= x 1) (:= x 2))"
    )
    assert shape(parse_exp("if c then a else b + 1")) == "(if c a (+ b 1))"


def test_postfix_chains() -> None:
    assert shape(parse_exp("a[i].f[j]")) == "(index (field (index a i) f) j)"
    assert shape(parse_exp("f(1, 2).g")) == "(field (f 1 2) g)"


def test_sequences_and_unit() -> None:
    assert shape(parse_exp("()")) == "()"
    assert shape(parse_exp("(a; b; c)")) == "(seq a b c)"
    assert shape(parse_exp("(a)")) == "a"


def test_negation_is_a_tilde() -> None:
    assert shape(parse_exp("~x + 1")) == "(+ (~ x) 1)"
    with pytest.raises(ParseError, match="negation is written"):
        parse_exp("-x")


def test_record_literal_versus_call() -> None:
    assert shape(parse_exp("point { x = 1, y = 2 }")) == "(record point x=1 y=2)"
    assert shape(parse_exp("point (1, 2)")) == "(point 1 2)"


def test_let_with_declarations() -> None:
    assert shape(parse_exp("let val x = 1 var y = 2 in x + y end")) == (
        "(let 2 (+ x y))"
    )


def test_a_program_is_declarations() -> None:
    prog = parse("type t = int\nval x = 1\nfun f (a : int) : int = a\n")
    assert [type(d).__name__ for d in prog.decls] == [
        "TypeDecl",
        "ValDecl",
        "FunDecl",
    ]


def test_mutual_recursion_is_one_declaration() -> None:
    prog = parse("fun f () : int = g ()\nand g () : int = 1\n")
    decl = prog.decls[0]
    assert isinstance(decl, ast.FunDecl)
    assert [b.name for b in decl.binds] == ["f", "g"]


def test_only_a_place_can_be_assigned() -> None:
    with pytest.raises(ParseError, match="not assignable"):
        parse_exp("1 + 2 := 3")


def test_errors_name_what_was_found() -> None:
    with pytest.raises(ParseError, match="expected `then`"):
        parse_exp("if a do b")
