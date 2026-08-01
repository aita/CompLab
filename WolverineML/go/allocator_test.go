package main

import (
	"strings"
	"testing"
)

const busySource = `
type point = { x : int, y : int }

fun busy (n : int) : int =
  let
    var a = n + 1
    var b = n + 2
    var c = n + 3
    var d = n + 4
    var total = 0
  in
    while a < n * 10 do (
      total := total + a * b + c * d;
      a := a + 1;
      b := b + 2;
      c := c + 3;
      d := d + 4
    );
    total
  end

fun caller (n : int) : int = busy (n) + busy (n + 1) + busy (n + 2)

val p = point { x = 1, y = 2 }
val () = printInt (caller (3) + p.x)
`

// prepared is the pipeline up to the point where the allocator takes over.
func prepared(t *testing.T, source string) *Module {
	t.Helper()
	mod := selected(t, source, true)
	destructModule(mod)
	return mod
}

func allocated(t *testing.T, machine Registers, source string) *Module {
	t.Helper()
	mod := prepared(t, source)
	if err := allocateModule(mod, machine); err != nil {
		t.Fatal(err)
	}
	return mod
}

// -- what it promises ----------------------------------------------------------

func TestEveryValueGetsAColour(t *testing.T) {
	for _, f := range allocated(t, allRegisters(), busySource).Funcs {
		for _, b := range f.walk() {
			for _, instr := range b.Instrs {
				for _, r := range instr.uses() {
					if _, has := f.Colours[r]; !has {
						t.Errorf("%%%d has no colour", r)
					}
				}
				if d := instr.defs(); d != noReg {
					if _, has := f.Colours[d]; !has {
						t.Errorf("%%%d has no colour", d)
					}
				}
			}
		}
	}
}

func TestValuesLiveTogetherDiffer(t *testing.T) {
	for _, f := range allocated(t, allRegisters(), busySource).Funcs {
		verifyColouring(f)
	}
}

// Without the optimiser the copies survive to the allocator, and coalescing gives
// both ends of one copy the same register.  That is right, and it is what a
// verifier reading whole live sets would reject.
func TestTheyDifferWithoutTheOptimiserToo(t *testing.T) {
	mod := inSSA(t, busySource, true)
	for _, f := range mod.Funcs {
		splitCriticalEdges(f)
	}
	selectModule(mod)
	destructModule(mod)
	if err := allocateModule(mod, allRegisters()); err != nil {
		t.Fatal(err)
	}
	for _, f := range mod.Funcs {
		verifyColouring(f)
	}
}

// Both ends of a copy hold the same value, so one register for the two is right.
func TestACoalescedCopyIsNotAClash(t *testing.T) {
	f := newFunc("f", "f", 0)
	entry := f.addBlock("entry")
	a, b := f.newReg(), f.newReg()
	entry.Instrs = append(entry.Instrs,
		&Const{Dst: a, Value: 1},
		&Move{Dst: b, Src: a},
		&Call{Dst: noReg, Callee: "wol_print_int", Args: []Reg{a}},
		&Ret{Value: b})
	f.Colours = map[Reg]int{a: 9, b: 9}
	verifyColouring(f)
}

// So the case above did not simply stop the verifier saying anything.
func TestOneColourForEverythingIsRejected(t *testing.T) {
	for _, f := range allocated(t, allRegisters(), busySource).Funcs {
		distinct := map[int]bool{}
		for _, c := range f.Colours {
			distinct[c] = true
		}
		if len(distinct) < 2 {
			continue
		}
		for r := range f.Colours {
			f.Colours[r] = 0
		}
		func() {
			defer func() {
				if recover() == nil {
					t.Fatal("one colour for everything was not rejected")
				}
			}()
			verifyColouring(f)
		}()
	}
}

func TestAValueLiveAcrossACallIsCalleeSaved(t *testing.T) {
	for _, f := range allocated(t, allRegisters(), busySource).Funcs {
		for r := range acrossCalls(f, analyse(f)) {
			if !isCalleeSaved(f.Colours[r]) {
				t.Errorf("%%%d is in x%d across a call", r, f.Colours[r])
			}
		}
	}
}

func TestOnlyTheCalleeSavedItUsedAreSaved(t *testing.T) {
	for _, f := range allocated(t, allRegisters(), busySource).Funcs {
		want := map[int]bool{}
		for _, colour := range f.Colours {
			if isCalleeSaved(colour) {
				want[colour] = true
			}
		}
		if len(f.Saved) != len(want) {
			t.Errorf("%s saves %v, used %v", f.Name, f.Saved, want)
		}
		for _, colour := range f.Saved {
			if !want[colour] {
				t.Errorf("%s saves x%d for nothing", f.Name, colour)
			}
		}
	}
}

func TestASmallerMachineStillWorks(t *testing.T) {
	for _, size := range []int{5, 6, 8, 12, 16, 26} {
		machine := limitedRegisters(size)
		allowed := map[int]bool{}
		for _, colour := range machine.anywhere() {
			allowed[colour] = true
		}
		for _, f := range allocated(t, machine, busySource).Funcs {
			verifyColouring(f)
			for _, colour := range f.Colours {
				if !allowed[colour] {
					t.Errorf("size %d: x%d is not on the machine", size, colour)
				}
			}
		}
	}
}

func TestASmallMachineSpills(t *testing.T) {
	mod := allocated(t, limitedRegisters(6), busySource)
	spilled := false
	for _, f := range mod.Funcs {
		if len(f.SpillSlots) > 0 {
			spilled = true
		}
		for _, slot := range f.SpillSlots {
			if slot >= f.NSlots {
				t.Errorf("%s spills to slot %d of %d", f.Name, slot, f.NSlots)
			}
		}
	}
	if !spilled {
		t.Error("nothing spilled")
	}
}

func TestPressureFallsToWhatTheMachineHas(t *testing.T) {
	machine := limitedRegisters(5)
	for _, f := range allocated(t, machine, busySource).Funcs {
		if got := pressure(f, analyse(f)); got > machine.count() {
			t.Errorf("%s wants %d of %d registers", f.Name, got, machine.count())
		}
	}
}

func TestAnImpossibleDemandIsReported(t *testing.T) {
	source := "fun ten (a : int, b : int, c : int, d : int, e : int,\n" +
		"         f : int, g : int, h : int, i : int, j : int) : int = a + j\n" +
		"val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))\n"
	err := allocateModule(prepared(t, source), limitedRegisters(8))
	if err == nil {
		t.Fatal("it was allocated")
	}
	if !strings.Contains(err.Error(), "more registers") {
		t.Errorf("got %v", err)
	}
}

// -- what it does about copies --------------------------------------------------

func TestLeavingSSARemovesEveryPhi(t *testing.T) {
	for _, f := range prepared(t, busySource).Funcs {
		for _, b := range f.walk() {
			if len(b.Phis) > 0 {
				t.Errorf("%s:%s still has a phi", f.Name, b.Label)
			}
		}
	}
}

func TestLeavingSSAMakesCopiesAndCoalescingEatsThem(t *testing.T) {
	mod := prepared(t, busySource)
	before := 0
	for _, f := range mod.Funcs {
		for _, b := range f.walk() {
			for _, instr := range b.Instrs {
				if _, isMove := instr.(*Move); isMove {
					before++
				}
			}
		}
	}
	if before == 0 {
		t.Fatal("leaving SSA should have made copies")
	}
	if err := allocateModule(mod, allRegisters()); err != nil {
		t.Fatal(err)
	}
	left := 0
	for _, f := range mod.Funcs {
		for _, b := range f.walk() {
			for _, instr := range b.Instrs {
				if m, isMove := instr.(*Move); isMove && f.Colours[m.Dst] != f.Colours[m.Src] {
					left++
				}
			}
		}
	}
	if left > before/10 {
		t.Errorf("%d of %d copies survived", left, before)
	}
}
