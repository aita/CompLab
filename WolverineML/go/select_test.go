package main

import (
	"os"
	"strings"
	"testing"
)

const oneFunction = "fun f (a : int, b : int, c : int) : int = %s\n" +
	"val () = printInt (f (1, 2, 3))"

func selected(t *testing.T, source string, checks bool) *Module {
	t.Helper()
	mod := inSSA(t, source, checks)
	optimise(mod)
	for _, f := range mod.Funcs {
		splitCriticalEdges(f)
	}
	selectModule(mod)
	return mod
}

// forms are the instructions chosen inside one function, the caller's aside.
func forms(t *testing.T, source, name string) []string {
	t.Helper()
	var out []string
	for _, f := range selected(t, source, false).Funcs {
		if f.Name != name {
			continue
		}
		for _, b := range f.walk() {
			for _, instr := range b.Instrs {
				if m, ok := instr.(*Mach); ok {
					out = append(out, m.Form)
				}
			}
		}
	}
	return out
}

func body(exp string) string { return strings.Replace(oneFunction, "%s", exp, 1) }

func chosen(t *testing.T, exp string) []string { return forms(t, body(exp), "f") }

func counts(forms []string, want string) int {
	n := 0
	for _, form := range forms {
		if form == want {
			n++
		}
	}
	return n
}

func has(forms []string, want string) bool { return counts(forms, want) > 0 }

func asmOf(t *testing.T, source string) string {
	t.Helper()
	text, err := compileToAsm(source, options{checks: false}, plainEmitter)
	if err != nil {
		t.Fatal(err)
	}
	return text
}

// -- the tiles ---------------------------------------------------------------

func TestMultiplyAddIsOneInstruction(t *testing.T) {
	got := chosen(t, "a + b * c")
	if !has(got, "madd") || has(got, "mul") {
		t.Errorf("chose %v", got)
	}
}

func TestMultiplySubtractIsOneInstruction(t *testing.T) {
	got := chosen(t, "a - b * c")
	if !has(got, "msub") || has(got, "mul") {
		t.Errorf("chose %v", got)
	}
}

func TestAShiftedOperandBeatsAMultiplyAdd(t *testing.T) {
	// `a + b * 8` is one instruction with a shift and two as a multiply-add.
	got := chosen(t, "a + b * 8")
	if counts(got, "adds") != 1 || has(got, "madd") || has(got, "lsli") {
		t.Errorf("chose %v", got)
	}
}

func TestASmallConstantIsAnImmediate(t *testing.T) {
	if got := chosen(t, "a + 5"); len(got) != 1 || got[0] != "addi" {
		t.Errorf("chose %v", got)
	}
	got := chosen(t, "(a + 5) - 7")
	if len(got) != 2 || got[0] != "addi" || got[1] != "subi" {
		t.Errorf("chose %v", got)
	}
}

func TestALargeConstantIsNot(t *testing.T) {
	if got := chosen(t, "a + 100000"); !has(got, "const") {
		t.Errorf("chose %v", got)
	}
}

func TestAMultiplyByAPowerOfTwoIsAShift(t *testing.T) {
	got := chosen(t, "a * 8")
	if !has(got, "lsli") || has(got, "mul") {
		t.Errorf("chose %v", got)
	}
}

func TestAComparisonReadOnlyByItsBranchSetsTheFlags(t *testing.T) {
	source := "fun f (a : int) : int = if a < 3 then 1 else 2\nval () = printInt (f (1))"
	found := false
	for _, f := range selected(t, source, false).Funcs {
		for _, b := range f.walk() {
			if br, ok := b.terminator().(*CBr); ok && br.Code == "lt" {
				found = true
			}
		}
	}
	if !found {
		t.Error("no branch reads the flags")
	}
	if has(forms(t, source, "f"), "cset") {
		t.Error("the comparison still became a value")
	}
}

func TestAComparisonReadBySomethingElseIsAValue(t *testing.T) {
	got := forms(t, `fun f (a : int) : bool = a < 3`+"\n"+`val () = print ("x")`, "f")
	if !has(got, "cset") {
		t.Errorf("chose %v", got)
	}
}

func TestAnArrayElementTakesTwoInstructions(t *testing.T) {
	text := asmOf(t, "val a = array (4, 0)\nval () = printInt (a[2] + a[3])")
	if !strings.Contains(text, "lsl #3") && !strings.Contains(text, "ldr") {
		t.Error("neither a shift nor a load")
	}
	loads := 0
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "ldr ") && strings.HasPrefix(line, "\t") {
			loads++
		}
	}
	if loads != 2 {
		t.Errorf("%d loads, want 2", loads)
	}
}

// -- what the plan is for ------------------------------------------------------

func TestAConstantReadTwiceIsStillAnImmediate(t *testing.T) {
	// It costs nothing to repeat, so two readers may both take it.
	got := chosen(t, "(a + 1) * (b + 1)")
	if counts(got, "addi") != 2 || has(got, "const") {
		t.Errorf("chose %v", got)
	}
}

func TestAChainOfAdditionsIsNotDeferredToItsLastLine(t *testing.T) {
	// Folding a whole spine would keep every term live until the end.
	source := "fun sum (a : int, b : int, c : int, d : int, e : int, f : int) : int =\n" +
		"  a + b + c + d + e + f\n" +
		"val () = printInt (sum (1, 2, 3, 4, 5, 6))\n"
	for _, f := range selected(t, source, false).Funcs {
		if f.Name != "sum" {
			continue
		}
		if got := pressure(f, analyse(f)); got > 8 {
			t.Errorf("pressure is %d, want at most 8", got)
		}
	}
}

func TestANodeReadTwiceIsComputedOnce(t *testing.T) {
	if got := chosen(t, "let val t = a * b in t + t end"); counts(got, "mul") != 1 {
		t.Errorf("chose %v", got)
	}
}

func TestTheGraphCountsItsReaders(t *testing.T) {
	for _, f := range selected(t, body("a + b"), false).Funcs {
		if f.Name != "f" {
			continue
		}
		live := analyse(f)
		for _, b := range f.walk() {
			graph := buildDag(b, live.liveOut[b.Label])
			for _, node := range graph.Nodes {
				expected := 0
				for _, other := range graph.Nodes {
					for _, operand := range other.Operands {
						if operand == node.Index {
							expected++
						}
					}
				}
				if node.Users != expected {
					t.Errorf("node %d has %d users, counted %d", node.Index, node.Users, expected)
				}
			}
		}
	}
}

func TestSelectionKeepsSSA(t *testing.T) {
	for _, f := range selected(t, body("a + b * c + 8"), true).Funcs {
		verifySSA(f)
	}
}

func TestTheRemainderIsADivideAndAnMsub(t *testing.T) {
	text := asmOf(t, "fun f (a : int, b : int) : int = a mod b\nval () = printInt (f (7, 2))")
	if strings.Count(text, "sdiv") != 1 || strings.Count(text, "msub") != 1 {
		t.Error("the remainder is not one sdiv and one msub")
	}
	if strings.Contains(text, "mul") {
		t.Error("a multiply survived")
	}
}

func TestOrdinaryCodeKeepsNoRegisterBack(t *testing.T) {
	// x17 is only for an address the emitter cannot reach any other way.
	source, err := os.ReadFile("examples/tour.wol")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(asmOf(t, string(source)), "x17") {
		t.Error("x17 was used")
	}
}

func TestX16IsAllocatable(t *testing.T) {
	// It used to be held back for the emitter; a busy function should take it.
	source, err := os.ReadFile("testdata/programs/pressure.wol")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(asmOf(t, string(source)), "x16") {
		t.Error("x16 was never used")
	}
}
