package main

import (
	"os"
	"testing"
)

const loopSource = `
fun count (n : int) : int =
  let var i = 0
      var total = 0
  in
    while i < n do (total := total + i; i := i + 1);
    total
  end
val () = printInt (count (10))
`

func lowered(t *testing.T, source string, checks bool) *Module {
	t.Helper()
	prog, err := parse(source)
	if err != nil {
		t.Fatal(err)
	}
	if err := check(prog); err != nil {
		t.Fatal(err)
	}
	return lower(prog, lowerOptions{checks: checks})
}

func inSSA(t *testing.T, source string, checks bool) *Module {
	t.Helper()
	mod := lowered(t, source, checks)
	constructSSAModule(mod)
	return mod
}

func TestLoweringWritesAVariableMoreThanOnce(t *testing.T) {
	f := lowered(t, loopSource, false).Funcs[1]
	written := map[Reg]int{}
	for _, b := range f.walk() {
		for _, instr := range b.Instrs {
			if d := instr.defs(); d != noReg {
				written[d]++
			}
		}
		if len(b.Phis) != 0 {
			t.Error("lowering built a phi")
		}
	}
	twice := false
	for _, n := range written {
		if n > 1 {
			twice = true
		}
	}
	if !twice {
		t.Error("nothing was written twice")
	}
}

func TestConstructionGivesOneDefinitionAndPhis(t *testing.T) {
	f := inSSA(t, loopSource, false).Funcs[1]
	verifySSA(f)
	found := false
	for _, b := range f.walk() {
		if len(b.Phis) > 0 {
			found = true
		}
	}
	if !found {
		t.Error("a loop needs phis")
	}
}

func TestEveryFunctionVerifies(t *testing.T) {
	source, err := os.ReadFile("examples/tour.wol")
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range inSSA(t, string(source), true).Funcs {
		verifySSA(f)
	}
}

func TestDominanceOfADiamond(t *testing.T) {
	f := inSSA(t, "fun f (c : bool) : int = if c then 1 else 2\n"+
		"val () = printInt (f (true))", false).Funcs[1]
	dom := dominance(f)
	for label := range f.Blocks {
		if !dom.dominates(f.Entry, label) {
			t.Errorf("entry does not dominate %s", label)
		}
	}
	joins := 0
	for _, b := range f.walk() {
		if len(b.Preds) <= 1 {
			continue
		}
		joins++
		if dom.idom[b.Label] != f.Entry {
			t.Errorf("idom(%s) = %s", b.Label, dom.idom[b.Label])
		}
	}
	if joins == 0 {
		t.Error("a diamond has a join")
	}
}

func TestAPhiNamesExactlyItsPredecessors(t *testing.T) {
	for _, f := range inSSA(t, loopSource, false).Funcs {
		for _, b := range f.walk() {
			for _, phi := range b.Phis {
				if !sameLabels(phi.preds(), b.Preds) {
					t.Errorf("phi in %s names %v, preds are %v", b.Label, phi.preds(), b.Preds)
				}
			}
		}
	}
}

func TestOptimisationKeepsItInSSA(t *testing.T) {
	mod := inSSA(t, loopSource, false)
	optimise(mod)
	for _, f := range mod.Funcs {
		verifySSA(f)
	}
}

func TestConstantsFold(t *testing.T) {
	mod := inSSA(t, "val () = printInt (2 * 3 + 4)", false)
	optimise(mod)
	var values []int64
	for _, b := range mod.Funcs[0].walk() {
		for _, instr := range b.Instrs {
			if c, ok := instr.(*Const); ok {
				values = append(values, c.Value)
			}
		}
	}
	if len(values) != 1 || values[0] != 10 {
		t.Errorf("constants are %v, want [10]", values)
	}
}

func TestDeadCodeGoes(t *testing.T) {
	mod := inSSA(t, "fun f (n : int) : int = let val unused = n * n in n + 1 end\n"+
		"val () = printInt (f (2))", false)
	optimise(mod)
	for _, b := range mod.Funcs[1].walk() {
		for _, instr := range b.Instrs {
			if bin, ok := instr.(*Bin); ok && bin.Op == "*" {
				t.Error("the unused multiply survived")
			}
		}
	}
}

func TestUnreachableBlocksGo(t *testing.T) {
	mod := inSSA(t, `val () = if true then print ("a") else print ("b")`, false)
	optimise(mod)
	var callees []string
	for _, b := range mod.Funcs[0].walk() {
		for _, instr := range b.Instrs {
			if c, ok := instr.(*Call); ok {
				callees = append(callees, c.Callee)
			}
		}
	}
	if len(callees) != 1 || callees[0] != "wol_print" {
		t.Errorf("calls are %v, want [wol_print]", callees)
	}
}

func TestSplittingLeavesPhisOnlyAfterAJump(t *testing.T) {
	mod := inSSA(t, loopSource, true)
	optimise(mod)
	for _, f := range mod.Funcs {
		splitCriticalEdges(f)
		verifySSA(f)
		for _, b := range f.walk() {
			if len(b.succs()) <= 1 {
				continue
			}
			for _, succ := range b.succs() {
				if len(f.block(succ).Phis) > 0 {
					t.Errorf("%s -> %s still carries a phi", b.Label, succ)
				}
			}
		}
	}
}
