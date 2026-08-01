// Liveness.
//
// The only subtlety is the phi.  A phi does not read its arguments where it
// stands; it reads them on the edges, so an argument is live at the end of the
// predecessor it is paired with and not anywhere inside the block that holds the
// phi.  Getting that wrong is what makes phi-related values interfere when they
// should not.

package main

// regSet is a set of registers.  Go's maps have no order, so anything that has
// to be walked in a fixed order goes through sortedRegs first.
type regSet map[Reg]bool

func (s regSet) add(r Reg)      { s[r] = true }
func (s regSet) has(r Reg) bool { return s[r] }
func (s regSet) remove(r Reg)   { delete(s, r) }
func (s regSet) addAll(rs []Reg) {
	for _, r := range rs {
		s[r] = true
	}
}
func (s regSet) union(o regSet) {
	for r := range o {
		s[r] = true
	}
}

func (s regSet) clone() regSet {
	out := make(regSet, len(s))
	out.union(s)
	return out
}

func (s regSet) equal(o regSet) bool {
	if len(s) != len(o) {
		return false
	}
	for r := range s {
		if !o[r] {
			return false
		}
	}
	return true
}

func (s regSet) sorted() []Reg { return sortedRegs(s) }

type Liveness struct {
	liveIn  map[string]regSet
	liveOut map[string]regSet
}

func analyse(f *Func) *Liveness {
	upward := map[string]regSet{}
	killed := map[string]regSet{}
	for _, b := range f.walk() {
		use := regSet{}
		kill := regSet{}
		for _, phi := range b.Phis {
			kill.add(phi.Dst)
		}
		for _, instr := range b.Instrs {
			for _, r := range instr.uses() {
				if !kill.has(r) {
					use.add(r)
				}
			}
			if d := instr.defs(); d != noReg {
				kill.add(d)
			}
		}
		upward[b.Label] = use
		killed[b.Label] = kill
	}

	live := &Liveness{liveIn: map[string]regSet{}, liveOut: map[string]regSet{}}
	for label := range f.Blocks {
		live.liveIn[label] = regSet{}
		live.liveOut[label] = regSet{}
	}

	order := rpo(f)
	for i, j := 0, len(order)-1; i < j; i, j = i+1, j-1 {
		order[i], order[j] = order[j], order[i]
	}
	for changed := true; changed; {
		changed = false
		for _, label := range order {
			b := f.block(label)
			out := regSet{}
			for _, succ := range b.succs() {
				out.union(live.liveIn[succ])
				for _, phi := range f.block(succ).Phis {
					if arg, ok := phi.arg(label); ok {
						out.add(arg)
					}
				}
			}
			newIn := upward[label].clone()
			for r := range out {
				if !killed[label].has(r) {
					newIn.add(r)
				}
			}
			if !out.equal(live.liveOut[label]) || !newIn.equal(live.liveIn[label]) {
				live.liveOut[label] = out
				live.liveIn[label] = newIn
				changed = true
			}
		}
	}
	return live
}

// acrossCalls is the values live across a call, and so unable to sit in a
// scratch register.
func acrossCalls(f *Func, live *Liveness) regSet {
	out := regSet{}
	for _, b := range f.walk() {
		after := live.liveOut[b.Label].clone()
		for at := len(b.Instrs) - 1; at >= 0; at-- {
			instr := b.Instrs[at]
			if d := instr.defs(); d != noReg {
				after.remove(d)
			}
			if _, isCall := instr.(*Call); isCall {
				out.union(after)
			}
			after.addAll(instr.uses())
		}
	}
	return out
}

// pressure is the most values live at any one point — the registers the function
// wants.
func pressure(f *Func, live *Liveness) int {
	most := 0
	for _, b := range f.walk() {
		after := live.liveOut[b.Label].clone()
		most = max(most, len(after))
		for at := len(b.Instrs) - 1; at >= 0; at-- {
			instr := b.Instrs[at]
			if d := instr.defs(); d != noReg {
				after.remove(d)
			}
			after.addAll(instr.uses())
			most = max(most, len(after))
		}
		entry := live.liveIn[b.Label].clone()
		for _, phi := range b.Phis {
			entry.add(phi.Dst)
		}
		most = max(most, len(entry))
	}
	return most
}
