// Spilling.
//
// A spilled value gets a frame slot, a store after every definition of it and a
// reload in front of every use.  The reloads are new registers, live from the load
// to the instruction under it and nowhere else, which is what makes the pressure
// come down.  Nothing here assumes SSA: a value written twice gets two stores, and
// a phi argument is reloaded at the end of the predecessor it comes from, so the
// same rewrite would serve a walk of the dominator tree as well as the graph.

package main

import "math"

// outOfRegisters is raised when spilling cannot help either.
type outOfRegisters struct{ msg string }

func (e *outOfRegisters) Error() string { return e.msg }

// loopDepth is how deeply each block is nested in loops, for weighing what a use
// costs.
//
// A back edge is an edge into a block that dominates its source; everything that
// can reach the source without leaving the dominated region is in that loop.
func loopDepth(f *Func) map[string]int {
	dom := dominance(f)
	depth := map[string]int{}
	for label := range f.Blocks {
		depth[label] = 0
	}
	for _, b := range f.walk() {
		for _, succ := range b.succs() {
			if !dom.dominates(succ, b.Label) {
				continue
			}
			body := map[string]bool{succ: true}
			stack := []string{b.Label}
			for len(stack) > 0 {
				label := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				if body[label] {
					continue
				}
				body[label] = true
				stack = append(stack, f.block(label).Preds...)
			}
			for label := range body {
				depth[label]++
			}
		}
	}
	return depth
}

// spillCosts is what spilling a value would cost: its reads and writes, weighed by
// loops.
func spillCosts(f *Func) map[Reg]float64 {
	depth := loopDepth(f)
	weight := map[Reg]float64{}
	scaleOf := func(label string) float64 {
		return math.Pow(10, float64(min(depth[label], 4)))
	}
	for _, b := range f.walk() {
		scale := scaleOf(b.Label)
		for _, phi := range b.Phis {
			for _, a := range phi.Args {
				weight[a.Reg] += scaleOf(a.Pred)
			}
			weight[phi.Dst] += scale
		}
		for _, instr := range b.Instrs {
			for _, r := range instr.uses() {
				weight[r] += scale
			}
			if d := instr.defs(); d != noReg {
				weight[d] += scale
			}
		}
	}
	return weight
}

// spill gives `victim` a frame slot, and returns the reloads that replaced it.
func spill(f *Func, victim Reg) regSet {
	slot := f.newSlot()
	f.SpillSlots[victim] = slot
	isParam := false
	for _, p := range f.Params {
		if p == victim {
			isParam = true
		}
	}
	reloads := regSet{}

	for _, b := range f.walk() {
		definesHere := false
		for _, phi := range b.Phis {
			if phi.Dst == victim {
				definesHere = true
			}
		}
		if definesHere {
			b.Instrs = append([]Instr{&StoreSlot{Slot: slot, Src: victim}}, b.Instrs...)
		}
		if isParam && b.Label == f.Entry {
			b.Instrs = append([]Instr{&StoreSlot{Slot: slot, Src: victim}}, b.Instrs...)
		}

		var rebuilt []Instr
		for _, instr := range b.Instrs {
			store, isStore := instr.(*StoreSlot)
			spillStore := isStore && store.Slot == slot
			reads := false
			for _, r := range instr.uses() {
				if r == victim {
					reads = true
				}
			}
			if reads && !spillStore {
				fresh := f.newReg()
				reloads.add(fresh)
				rebuilt = append(rebuilt, &LoadSlot{Dst: fresh, Slot: slot})
				instr.mapUses(func(r Reg) Reg {
					if r == victim {
						return fresh
					}
					return r
				})
			}
			rebuilt = append(rebuilt, instr)
			if instr.defs() == victim {
				rebuilt = append(rebuilt, &StoreSlot{Slot: slot, Src: victim})
			}
		}
		b.Instrs = rebuilt
	}

	for _, b := range f.walk() {
		for _, phi := range b.Phis {
			for at := range phi.Args {
				if phi.Args[at].Reg != victim {
					continue
				}
				source := f.block(phi.Args[at].Pred)
				fresh := f.newReg()
				reloads.add(fresh)
				last := len(source.Instrs) - 1
				tail := append([]Instr(nil), source.Instrs[last:]...)
				source.Instrs = append(append(source.Instrs[:last],
					&LoadSlot{Dst: fresh, Slot: slot}), tail...)
				phi.Args[at].Reg = fresh
			}
		}
	}
	return reloads
}
