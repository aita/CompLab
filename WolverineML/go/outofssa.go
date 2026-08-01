// Leaving SSA before allocation.
//
// A phi is a copy that happens on an edge, so it becomes copies at the end of each
// predecessor.  Critical edges are already split, so a predecessor of a block with
// phis has nowhere else to go and the copies can simply be appended.
//
// The copies of one edge happen at once: every argument is read before any
// destination is written.  Usually that needs no care, because a phi's destination
// is defined nowhere else and so is nobody's argument — but a block that is its own
// predecessor can have two phis that swap, and then the copies go through
// temporaries, which is Sreedhar's answer and which coalescing is expected to
// remove again.
//
// That the copies are a cost to be paid is the point rather than a complaint:
// copies are what coalescing eats, and the allocator earns nearly all of them back.

package main

// destruct replaces every phi in `f` with copies in its predecessors.
func destruct(f *Func) {
	for _, b := range f.walk() {
		if len(b.Phis) == 0 {
			continue
		}
		for _, pred := range b.Preds {
			source := f.block(pred)
			if len(source.succs()) != 1 {
				panic(pred + " -> " + b.Label + " is a critical edge")
			}
			moves := make([]regPair, 0, len(b.Phis))
			for _, phi := range b.Phis {
				arg, ok := phi.arg(pred)
				if !ok {
					panic("a phi in " + b.Label + " does not name " + pred)
				}
				moves = append(moves, regPair{dst: phi.Dst, src: arg})
			}
			copyInParallel(f, source, moves)
		}
		b.Phis = nil
	}
	recomputePreds(f)
}

func destructModule(mod *Module) {
	for _, f := range mod.Funcs {
		destruct(f)
	}
}

type regPair struct{ dst, src Reg }

func copyInParallel(f *Func, b *Block, moves []regPair) {
	var real []regPair
	for _, m := range moves {
		if m.dst != m.src {
			real = append(real, m)
		}
	}
	if len(real) == 0 {
		return
	}
	written := regSet{}
	read := regSet{}
	for _, m := range real {
		written.add(m.dst)
		read.add(m.src)
	}
	clash := false
	for r := range written {
		if read.has(r) {
			clash = true
			break
		}
	}
	var copies []Instr
	if clash {
		through := map[Reg]Reg{}
		for _, m := range real {
			through[m.dst] = f.newReg()
		}
		for _, m := range real {
			copies = append(copies, &Move{Dst: through[m.dst], Src: m.src})
		}
		for _, m := range real {
			copies = append(copies, &Move{Dst: m.dst, Src: through[m.dst]})
		}
	} else {
		for _, m := range real {
			copies = append(copies, &Move{Dst: m.dst, Src: m.src})
		}
	}
	at := len(b.Instrs) - 1
	tail := append([]Instr(nil), b.Instrs[at:]...)
	b.Instrs = append(append(b.Instrs[:at], copies...), tail...)
}
