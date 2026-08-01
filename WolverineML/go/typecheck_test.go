package main

import (
	"strings"
	"testing"
)

func accepts(t *testing.T, source string) *Program {
	t.Helper()
	prog, err := parse(source)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if err := check(prog); err != nil {
		t.Fatalf("check(%q): %v", source, err)
	}
	return prog
}

func rejects(t *testing.T, source, want string) {
	t.Helper()
	prog, err := parse(source)
	if err == nil {
		err = check(prog)
	}
	if err == nil {
		t.Fatalf("%q was accepted", source)
	}
	if !strings.Contains(err.Error(), want) {
		t.Fatalf("%q: %v, want %q in it", source, err, want)
	}
}

func TestArithmeticIsOnInts(t *testing.T) {
	accepts(t, "val x = 1 + 2")
	rejects(t, `val x = 1 + "a"`, "expected `int`, found `string`")
	rejects(t, "val x = true + 1", "expected `int`, found `bool`")
}

func TestConcatenationIsOnStrings(t *testing.T) {
	accepts(t, `val s = "a" ^ "b"`)
	rejects(t, `val s = "a" ^ 1`, "expected `string`, found `int`")
}

func TestComparisonGivesBool(t *testing.T) {
	accepts(t, "val b = 1 < 2 andalso 3 >= 4")
	rejects(t, `val b = "a" < 1`, "expected `string`, found `int`")
	rejects(t, "val b = true < false", "compares int or string")
}

func TestEqualityNeedsOneType(t *testing.T) {
	accepts(t, "val b = 1 = 2")
	accepts(t, `val b = "a" <> "b"`)
	rejects(t, "val b = 1 = true", "compares `int` with `bool`")
}

func TestConditionsAreBool(t *testing.T) {
	accepts(t, "val x = if true then 1 else 2")
	rejects(t, "val x = if 1 then 1 else 2", "expected `bool`, found `int`")
	rejects(t, `val x = if true then 1 else "a"`, "the branches differ")
	rejects(t, "val () = if true then 1", "in an `if` with no `else`")
}

func TestAValCannotBeAssigned(t *testing.T) {
	accepts(t, "var x = 1 val () = x := 2")
	rejects(t, "val x = 1 val () = x := 2", "is a `val`")
}

func TestFunctionsCheckTheirArguments(t *testing.T) {
	accepts(t, "fun f (a : int) : int = a\nval x = f (1)")
	rejects(t, "fun f (a : int) : int = a\nval x = f (1, 2)", "takes 1 argument")
	rejects(t, `fun f (a : int) : int = a`+"\n"+`val x = f ("s")`, "expected `int`")
}

func TestAFunWithoutAResultIsAProcedure(t *testing.T) {
	accepts(t, `fun f () = print ("x")`+"\nval () = f ()")
	rejects(t, "fun f () = 1", "expected `unit`, found `int`")
}

func TestFunctionsAreNotValues(t *testing.T) {
	rejects(t, "fun f () : int = 1\nval x = f", "functions are not values")
}

func TestRecordsAreNominal(t *testing.T) {
	accepts(t, "type p = { x : int }\nval a = p { x = 1 }\nval b = a.x")
	rejects(t, "type p = { x : int } and q = { x : int }\n"+
		"fun f (r : p) : int = r.x\nval x = f (q { x = 1 })", "expected `p`, found `q`")
	rejects(t, "type p = { x : int }\nval a = p { y = 1 }", "has no field `y`")
	rejects(t, "type p = { x : int, y : int }\nval a = p { x = 1 }", "field `y` is missing")
}

func TestNilIsARecordOfAnyType(t *testing.T) {
	accepts(t, "type p = { x : int }\nval a : p = nil\nval b = a = nil")
	rejects(t, "val a = nil", "needs a type annotation")
	rejects(t, "type p = { x : int }\nval a : p = nil\nval b = a = 1", "compares")
}

func TestArraysKnowTheirElement(t *testing.T) {
	accepts(t, "val a = array (3, 0)\nval x = a[0] + 1")
	accepts(t, "type ints = int array\nval a : ints = array (3, 0)")
	rejects(t, "val a = array (3, 0)\n"+`val x = a[0] ^ "s"`, "expected `string`")
	rejects(t, "val a = array (3, 0)\nval x = a[true]", "as an array index")
	rejects(t, "val x = length (1)", "`length` wants an array")
}

func TestBreakIsInsideALoop(t *testing.T) {
	accepts(t, "val () = while true do break")
	accepts(t, "val () = for i = 0 to 3 do break")
	rejects(t, "val () = break", "outside any loop")
	rejects(t, "val () = while true do let fun f () = break in f () end", "outside any loop")
}

func TestEscapeAnalysisMarksWhatANestedFunctionReads(t *testing.T) {
	prog := accepts(t, "fun outer () : int =\n"+
		"  let var kept = 1\n"+
		"      val plain = 2\n"+
		"      fun inner () : int = kept\n"+
		"  in inner () + plain end\n")
	body := prog.Decls[0].(*FunDecl).Binds[0].Body.(*LetExp)
	kept := body.Decls[0].(*ValDecl)
	plain := body.Decls[1].(*ValDecl)
	if !kept.Sym.Escapes {
		t.Error("`kept` should escape")
	}
	if plain.Sym.Escapes {
		t.Error("`plain` should not escape")
	}
}

func TestAParameterEscapesToo(t *testing.T) {
	prog := accepts(t, "fun outer (n : int) : int =\n"+
		"  let fun inner () : int = n in inner () end\n")
	param := prog.Decls[0].(*FunDecl).Binds[0].Params[0]
	if !param.Sym.Escapes {
		t.Error("`n` should escape")
	}
}

func TestRecursiveTypes(t *testing.T) {
	accepts(t, "type list = { head : int, tail : list }\n"+
		"fun sum (l : list) : int = if l = nil then 0 else l.head + sum (l.tail)\n")
	accepts(t, "type a = b array and b = { next : a }")
}

func TestUnboundNames(t *testing.T) {
	rejects(t, "val x = y", "`y` is not bound")
	rejects(t, "val x : t = 1", "`t` is not a type")
	rejects(t, "val x = f ()", "`f` is not bound")
}
