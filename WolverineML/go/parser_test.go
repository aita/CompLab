package main

import (
	"fmt"
	"strings"
	"testing"
)

// shape is a parenthesised sketch of the tree, so precedence is easy to assert.
func shape(e Exp) string {
	switch e := e.(type) {
	case *IntLit:
		return fmt.Sprint(e.Value)
	case *StrLit:
		return `"` + e.Value + `"`
	case *BoolLit:
		if e.Value {
			return "true"
		}
		return "false"
	case *NilLit:
		return "nil"
	case *UnitLit:
		return "()"
	case *VarExp:
		return e.Name
	case *NegExp:
		return "(~ " + shape(e.Operand) + ")"
	case *BinExp:
		return "(" + e.Op + " " + shape(e.Lhs) + " " + shape(e.Rhs) + ")"
	case *LogicExp:
		return "(" + e.Op + " " + shape(e.Lhs) + " " + shape(e.Rhs) + ")"
	case *AssignExp:
		return "(:= " + shape(e.Target) + " " + shape(e.Value) + ")"
	case *IfExp:
		tail := ""
		if e.Else != nil {
			tail = " " + shape(e.Else)
		}
		return "(if " + shape(e.Cond) + " " + shape(e.Then) + tail + ")"
	case *WhileExp:
		return "(while " + shape(e.Cond) + " " + shape(e.Body) + ")"
	case *ForExp:
		return "(for " + e.Name + " " + shape(e.Lo) + " " + shape(e.Hi) + " " + shape(e.Body) + ")"
	case *BreakExp:
		return "break"
	case *SeqExp:
		return "(seq " + shapes(e.Items) + ")"
	case *CallExp:
		return "(" + e.Name + " " + shapes(e.Args) + ")"
	case *IndexExp:
		return "(index " + shape(e.Array) + " " + shape(e.Index) + ")"
	case *FieldExp:
		return "(field " + shape(e.Record) + " " + e.Name + ")"
	case *RecordLit:
		var parts []string
		for _, f := range e.Fields {
			parts = append(parts, f.Name+"="+shape(f.Value))
		}
		return "(record " + e.TyName + " " + strings.Join(parts, " ") + ")"
	case *LetExp:
		return fmt.Sprintf("(let %d %s)", len(e.Decls), shape(e.Body))
	}
	panic(fmt.Sprintf("unknown %T", e))
}

func shapes(items []Exp) string {
	parts := make([]string, len(items))
	for at, item := range items {
		parts[at] = shape(item)
	}
	return strings.Join(parts, " ")
}

func shapeOf(t *testing.T, source string) string {
	t.Helper()
	e, err := parseExp(source)
	if err != nil {
		t.Fatalf("parseExp(%q): %v", source, err)
	}
	return shape(e)
}

func wants(t *testing.T, source, want string) {
	t.Helper()
	if got := shapeOf(t, source); got != want {
		t.Errorf("%q parsed as %s, want %s", source, got, want)
	}
}

func refusesParse(t *testing.T, source, want string) {
	t.Helper()
	_, err := parseExp(source)
	if err == nil {
		t.Fatalf("parseExp(%q) was accepted", source)
	}
	if !strings.Contains(err.Error(), want) {
		t.Fatalf("parseExp(%q): %v, want %q in it", source, err, want)
	}
}

func TestArithmeticPrecedence(t *testing.T) {
	wants(t, "1 + 2 * 3", "(+ 1 (* 2 3))")
	wants(t, "1 * 2 + 3", "(+ (* 1 2) 3)")
	wants(t, "1 - 2 - 3", "(- (- 1 2) 3)")
	wants(t, "1 + 2 = 3", "(= (+ 1 2) 3)")
}

func TestLogicBindsLooserThanComparison(t *testing.T) {
	wants(t, "a < b andalso c > d", "(andalso (< a b) (> c d))")
	wants(t, "a orelse b andalso c", "(orelse a (andalso b c))")
}

func TestAssignmentIsRightAssociativeAndLoosest(t *testing.T) {
	wants(t, "x := y + 1", "(:= x (+ y 1))")
	wants(t, "a := b := c", "(:= a (:= b c))")
}

func TestABranchSwallowsWhatFollowsIt(t *testing.T) {
	wants(t, "if c then x := 1 else x := 2", "(if c (:= x 1) (:= x 2))")
	wants(t, "if c then a else b + 1", "(if c a (+ b 1))")
}

func TestPostfixChains(t *testing.T) {
	wants(t, "a[i].f[j]", "(index (field (index a i) f) j)")
	wants(t, "f(1, 2).g", "(field (f 1 2) g)")
}

func TestSequencesAndUnit(t *testing.T) {
	wants(t, "()", "()")
	wants(t, "(a; b; c)", "(seq a b c)")
	wants(t, "(a; b;)", "(seq a b)")
	wants(t, "(a)", "a")
}

func TestNegationIsATilde(t *testing.T) {
	wants(t, "~x + 1", "(+ (~ x) 1)")
	wants(t, "~x * y", "(* (~ x) y)")
	refusesParse(t, "-x", "negation is written")
}

func TestTheLargestLiteralIsTheOneThatWraps(t *testing.T) {
	wants(t, "~9223372036854775808", "(~ -9223372036854775808)")
	refusesParse(t, "18446744073709551616", "does not fit in 64 bits")
}

func TestRecordLiteralVersusCall(t *testing.T) {
	wants(t, "point { x = 1, y = 2 }", "(record point x=1 y=2)")
	wants(t, "point (1, 2)", "(point 1 2)")
}

func TestLetWithDeclarations(t *testing.T) {
	wants(t, "let val x = 1 var y = 2 in x + y end", "(let 2 (+ x y))")
	wants(t, "let val x = 1 in end", "(let 1 ())")
}

func TestAProgramIsDeclarations(t *testing.T) {
	prog, err := parse("type t = int\nval x = 1\nfun f (a : int) : int = a\n")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := prog.Decls[0].(*TypeDecl); !ok {
		t.Errorf("first is %T", prog.Decls[0])
	}
	if _, ok := prog.Decls[1].(*ValDecl); !ok {
		t.Errorf("second is %T", prog.Decls[1])
	}
	if _, ok := prog.Decls[2].(*FunDecl); !ok {
		t.Errorf("third is %T", prog.Decls[2])
	}
}

func TestMutualRecursionIsOneDeclaration(t *testing.T) {
	prog, err := parse("fun f () : int = g ()\nand g () : int = 1\n")
	if err != nil {
		t.Fatal(err)
	}
	decl, ok := prog.Decls[0].(*FunDecl)
	if !ok {
		t.Fatalf("got %T", prog.Decls[0])
	}
	if len(decl.Binds) != 2 || decl.Binds[0].Name != "f" || decl.Binds[1].Name != "g" {
		t.Errorf("got %d binds", len(decl.Binds))
	}
}

func TestOnlyAPlaceCanBeAssigned(t *testing.T) { refusesParse(t, "1 + 2 := 3", "not assignable") }

func TestErrorsNameWhatWasFound(t *testing.T) { refusesParse(t, "if a do b", "expected `then`") }

func TestPostfixOnlyFollowsAnAtom(t *testing.T) {
	// `(if …).f` is how it has to be written; the bare form is two expressions.
	wants(t, "(if c then a else b).f", "(field (if c a b) f)")
	refusesParse(t, "nil.f", "unexpected")
}
