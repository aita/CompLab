// SSA construction, the textbook way.
//
// Dominators by the iterative algorithm of Cooper, Harvey and Kennedy, dominance
// frontiers from those, phis at the frontiers of every definition, and then one
// walk of the dominator tree renaming as it goes.  This is minimal SSA and nothing
// cleverer: a phi is placed wherever the frontier says, whether or not the
// variable is live there, and the dead ones leave in deadCode.
//
// Only registers written more than once take part.  Everything lowering produced
// once — a temporary — is already in SSA and is left with the name it has.

package main

import (
	"fmt"
	"sort"
)

type Dominance struct {
	idom     map[string]string
	children map[string][]string
	frontier map[string]map[string]bool
	order    []string
}

func (d *Dominance) dominates(a, b string) bool {
	for at := b; ; {
		if a == at {
			return true
		}
		parent := d.idom[at]
		if parent == at {
			return false
		}
		at = parent
	}
}

func dominance(f *Func) *Dominance {
	order := rpo(f)
	rank := map[string]int{}
	for at, label := range order {
		rank[label] = at
	}
	idom := map[string]string{f.Entry: f.Entry}

	intersect := func(a, b string) string {
		for a != b {
			for rank[a] > rank[b] {
				a = idom[a]
			}
			for rank[b] > rank[a] {
				b = idom[b]
			}
		}
		return a
	}

	for changed := true; changed; {
		changed = false
		for _, label := range order[1:] {
			var preds []string
			for _, p := range f.block(label).Preds {
				if _, known := idom[p]; known {
					preds = append(preds, p)
				}
			}
			if len(preds) == 0 {
				continue
			}
			next := preds[0]
			for _, p := range preds[1:] {
				next = intersect(p, next)
			}
			if idom[label] != next {
				idom[label] = next
				changed = true
			}
		}
	}

	children := map[string][]string{}
	frontier := map[string]map[string]bool{}
	for _, label := range order {
		children[label] = nil
		frontier[label] = map[string]bool{}
	}
	for _, label := range order {
		if parent := idom[label]; parent != label {
			children[parent] = append(children[parent], label)
		}
	}
	for _, label := range order {
		b := f.block(label)
		if len(b.Preds) < 2 {
			continue
		}
		for _, pred := range b.Preds {
			for runner := pred; runner != idom[label]; {
				if _, known := idom[runner]; !known {
					break
				}
				frontier[runner][label] = true
				runner = idom[runner]
			}
		}
	}
	return &Dominance{idom: idom, children: children, frontier: frontier, order: order}
}

// ssaDefs is where each register is written, and how often.
//
// A register written twice in one block is as much a variable as one written in
// two blocks, so the count is what decides, and the blocks are what the frontier
// walk needs.
type ssaDefs struct {
	blocks map[Reg]map[string]bool
	count  map[Reg]int
}

func (d *ssaDefs) record(r Reg, label string) {
	if d.blocks[r] == nil {
		d.blocks[r] = map[string]bool{}
	}
	d.blocks[r][label] = true
	d.count[r]++
}

// variables are the registers written more than once, in order.
func (d *ssaDefs) variables() []Reg {
	var out []Reg
	for r, n := range d.count {
		if n > 1 {
			out = append(out, r)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func definitions(f *Func) *ssaDefs {
	defs := &ssaDefs{blocks: map[Reg]map[string]bool{}, count: map[Reg]int{}}
	for _, b := range f.walk() {
		for _, instr := range b.Instrs {
			if d := instr.defs(); d != noReg {
				defs.record(d, b.Label)
			}
		}
	}
	for _, r := range f.Params {
		defs.record(r, f.Entry)
	}
	return defs
}

func sortedLabels(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for label := range set {
		out = append(out, label)
	}
	sort.Strings(out)
	return out
}

// placePhis puts a phi for `v` at every dominance frontier of a block defining it.
func placePhis(f *Func, dom *Dominance, defs *ssaDefs) map[string][]Reg {
	phiVars := map[string][]Reg{}
	for label := range f.Blocks {
		phiVars[label] = nil
	}
	isVariable := map[Reg]bool{}
	for _, v := range defs.variables() {
		isVariable[v] = true
	}
	for _, v := range defs.variables() {
		placed := map[string]bool{}
		work := sortedLabels(defs.blocks[v])
		for len(work) > 0 {
			b := work[len(work)-1]
			work = work[:len(work)-1]
			for _, target := range sortedLabels(dom.frontier[b]) {
				if placed[target] {
					continue
				}
				placed[target] = true
				phiVars[target] = append(phiVars[target], v)
				phi := &Phi{Dst: v}
				for _, pred := range f.block(target).Preds {
					phi.Args = append(phi.Args, PhiArg{Pred: pred, Reg: v})
				}
				f.block(target).Phis = append(f.block(target).Phis, phi)
				if !defs.blocks[v][target] {
					work = append(work, target)
				}
			}
		}
	}
	return phiVars
}

type renamer struct {
	fn         *Func
	dom        *Dominance
	phiVars    map[string][]Reg
	variables  map[Reg]bool
	stacks     map[Reg][]Reg
	undefined  map[Reg]Reg
	undefOrder []Reg
}

func (r *renamer) top(v Reg) Reg {
	if stack := r.stacks[v]; len(stack) > 0 {
		return stack[len(stack)-1]
	}
	return r.undef(v)
}

// undef: a variable read on a path that never wrote it reads zero.
func (r *renamer) undef(v Reg) Reg {
	if fresh, seen := r.undefined[v]; seen {
		return fresh
	}
	fresh := r.fn.newReg()
	r.undefined[v] = fresh
	r.undefOrder = append(r.undefOrder, v)
	return fresh
}

func (r *renamer) plantUndefined() {
	entry := r.fn.block(r.fn.Entry)
	for _, v := range r.undefOrder {
		entry.Instrs = append([]Instr{&Const{Dst: r.undefined[v], Value: 0}}, entry.Instrs...)
	}
}

func (r *renamer) rename(v Reg) Reg {
	fresh := r.fn.newReg()
	r.stacks[v] = append(r.stacks[v], fresh)
	return fresh
}

func (r *renamer) run() {
	type frame struct {
		label   string
		popping bool
	}
	stack := []frame{{r.fn.Entry, false}}
	pushed := map[string][]Reg{}
	for len(stack) > 0 {
		top := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if top.popping {
			for _, v := range pushed[top.label] {
				r.stacks[v] = r.stacks[v][:len(r.stacks[v])-1]
			}
			continue
		}
		pushed[top.label] = r.block(top.label)
		stack = append(stack, frame{top.label, true})
		children := r.dom.children[top.label]
		for at := len(children) - 1; at >= 0; at-- {
			stack = append(stack, frame{children[at], false})
		}
	}
}

func (r *renamer) block(label string) []Reg {
	b := r.fn.block(label)
	var mine []Reg
	for at, phi := range b.Phis {
		v := r.phiVars[label][at]
		phi.Dst = r.rename(v)
		mine = append(mine, v)
	}
	for _, instr := range b.Instrs {
		instr.mapUses(r.use)
		if d := instr.defs(); d != noReg && r.variables[d] {
			instr.setDef(r.rename(d))
			mine = append(mine, d)
		}
	}
	for _, succ := range b.succs() {
		target := r.fn.block(succ)
		for at, phi := range target.Phis {
			phi.setArg(label, r.top(r.phiVars[succ][at]))
		}
	}
	return mine
}

func (r *renamer) use(reg Reg) Reg {
	if r.variables[reg] {
		return r.top(reg)
	}
	return reg
}

// constructSSA rewrites one function into SSA, in place.
func constructSSA(f *Func) {
	recomputePreds(f)
	dom := dominance(f)
	defs := definitions(f)
	phiVars := placePhis(f, dom, defs)
	variables := map[Reg]bool{}
	for _, v := range defs.variables() {
		variables[v] = true
	}
	r := &renamer{
		fn: f, dom: dom, phiVars: phiVars, variables: variables,
		stacks: map[Reg][]Reg{}, undefined: map[Reg]Reg{},
	}
	for at, p := range f.Params {
		if variables[p] {
			f.Params[at] = r.rename(p)
		}
	}
	r.run()
	r.plantUndefined()
}

func constructSSAModule(mod *Module) {
	for _, f := range mod.Funcs {
		constructSSA(f)
	}
}

// splitCriticalEdges gives every phi a place to put its copy in.
//
// An edge from a block with several successors into a block with several
// predecessors has nowhere to hold the copies a phi turns into, so it gets a block
// of its own.  The same goes for any edge into a block that still has a phi, so
// that the emitter only ever has to put copies before a `jmp`.
func splitCriticalEdges(f *Func) {
	for _, label := range append([]string(nil), f.Order...) {
		b := f.block(label)
		if len(b.succs()) < 2 {
			continue
		}
		for _, succ := range append([]string(nil), b.succs()...) {
			target := f.block(succ)
			if len(target.Preds) < 2 && len(target.Phis) == 0 {
				continue
			}
			split := f.addBlock(label + "." + succ)
			split.Instrs = append(split.Instrs, &Jmp{Target: succ})
			renameTarget(b.terminator(), succ, split.Label)
			for _, phi := range target.Phis {
				if arg, ok := phi.removeArg(label); ok {
					phi.setArg(split.Label, arg)
				}
			}
		}
	}
	recomputePreds(f)
}

// verifySSA checks what SSA promises: one definition per register, and it
// dominates every use.
func verifySSA(f *Func) {
	dom := dominance(f)
	definition := map[Reg]string{}
	claim := func(r Reg, label string) {
		if where, twice := definition[r]; twice {
			panic(fmt.Sprintf("%%%d defined twice, in %s and %s", r, where, label))
		}
		definition[r] = label
	}
	for _, b := range f.walk() {
		for _, phi := range b.Phis {
			claim(phi.Dst, b.Label)
		}
		for _, instr := range b.Instrs {
			if d := instr.defs(); d != noReg {
				claim(d, b.Label)
			}
		}
	}
	for _, p := range f.Params {
		if _, known := definition[p]; !known {
			definition[p] = f.Entry
		}
	}
	for _, b := range f.walk() {
		for _, phi := range b.Phis {
			if !sameLabels(phi.preds(), b.Preds) {
				panic(fmt.Sprintf("phi in %s names %v, preds are %v",
					b.Label, sortedCopy(phi.preds()), sortedCopy(b.Preds)))
			}
			for _, a := range phi.Args {
				where, known := definition[a.Reg]
				if !known {
					panic(fmt.Sprintf("%%%d is never defined", a.Reg))
				}
				if !dom.dominates(where, a.Pred) {
					panic(fmt.Sprintf("%%%d does not reach %s through %s", a.Reg, b.Label, a.Pred))
				}
			}
		}
		for _, instr := range b.Instrs {
			for _, r := range instr.uses() {
				where, known := definition[r]
				if !known {
					panic(fmt.Sprintf("%%%d is never defined", r))
				}
				if !dom.dominates(where, b.Label) {
					panic(fmt.Sprintf("%%%d does not dominate its use in %s", r, b.Label))
				}
			}
		}
	}
}

func sortedCopy(labels []string) []string {
	out := append([]string(nil), labels...)
	sort.Strings(out)
	return out
}

func sameLabels(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	seen := map[string]bool{}
	for _, label := range a {
		seen[label] = true
	}
	for _, label := range b {
		if !seen[label] {
			return false
		}
	}
	return len(seen) == len(a)
}
