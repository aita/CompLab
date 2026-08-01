// The seam the register allocator is reached through, and what it promises.
//
// There is one allocator here: leave SSA, build the interference graph, and colour
// it the way Chaitin's algorithm does, with the iterated coalescing that eats the
// copies leaving SSA made.  The Python tree beside this one carries a second
// allocator that colours the SSA itself in dominance order, so that the two can be
// measured against each other; this tree keeps the graph.

package main

import "fmt"

func allocateModule(mod *Module, machine Registers) error {
	for _, f := range mod.Funcs {
		if err := allocate(f, machine); err != nil {
			return err
		}
	}
	return nil
}

// verifyColouring: no two values that hold different things at once may share a
// colour.
//
// The check is made where the interference graph joins values -- at each
// definition, and at the top of a block for the phis and the parameters, which
// define several at once.  Looking at a whole live set instead would be wrong,
// not merely slower: both ends of a copy are live after it and hold the same
// value, so they may share a register, and that is the entire point of
// coalescing.  A verifier that rejected it would reject every program the
// coalescer had done its job on.
//
// Nothing that interferes escapes this, because the later of the two definitions
// that put the values there happens while the other is live.
func verifyColouring(f *Func) {
	live := analyse(f)
	for _, b := range f.walk() {
		alive := live.liveOut[b.Label].clone()
		for at := len(b.Instrs) - 1; at >= 0; at-- {
			instr := b.Instrs[at]
			if mv, ok := instr.(*Move); ok {
				alive.remove(mv.Src)
			}
			for _, r := range instr.uses() {
				coloured(f, r)
			}
			if d := instr.defs(); d != noReg {
				coloured(f, d)
				alive.add(d)
				noClash(f, alive, d, b.Label)
				alive.remove(d)
			}
			alive.addAll(instr.uses())
		}

		entering := live.liveIn[b.Label].clone()
		for _, phi := range b.Phis {
			coloured(f, phi.Dst)
			entering.add(phi.Dst)
			noClash(f, entering, phi.Dst, b.Label)
		}
		if b.Label == f.Entry {
			for _, param := range f.Params {
				entering.add(param)
				noClash(f, entering, param, b.Label)
			}
		}
	}
}

func coloured(f *Func, r Reg) {
	if _, has := f.Colours[r]; !has {
		panic(fmt.Sprintf("%%%d has no colour", r))
	}
}

// noClash: nothing else live here may hold the colour `written` was just given.
func noClash(f *Func, alive regSet, written Reg, where string) {
	colour, has := f.Colours[written]
	if !has {
		return
	}
	for _, other := range alive.sorted() {
		// Two values, not one lookup: an absent colour reads as zero, and zero is
		// x0.
		theirs, has := f.Colours[other]
		if other == written || !has || theirs != colour {
			continue
		}
		panic(fmt.Sprintf("x%d holds %%%d and %%%d at once in %s", colour, written, other, where))
	}
}
