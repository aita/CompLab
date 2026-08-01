// Optimisation on SSA.
//
// Five small passes run to a fixed point.  Each is cheap because SSA makes it
// cheap: a register has one definition, so constant folding and copy propagation
// are a lookup rather than a dataflow problem, and a phi whose arguments all agree
// is a copy that was never needed.
//
//	fold constants   ->  arithmetic on known values
//	propagate copies ->  Move, and phis that turned into one
//	simplify phis    ->  a phi with one distinct argument is that argument
//	fold branches    ->  a branch on a known value, and the blocks it strands
//	dead code        ->  anything computed and not used

package main

func optimise(mod *Module) {
	for _, f := range mod.Funcs {
		optimiseFunc(f)
	}
}

func optimiseFunc(f *Func) {
	passes := []func(*Func) bool{
		foldConstants, propagateCopies, simplifyPhis, foldBranches, deadCode,
	}
	for {
		// Every pass runs every round: they are cheap, and one enables another.
		changed := false
		for _, run := range passes {
			if run(f) {
				changed = true
			}
		}
		if !changed {
			return
		}
	}
}

// -- rewriting ---------------------------------------------------------------

// rewriteRegs replaces registers everywhere they are read, phi arguments included.
func rewriteRegs(f *Func, mapping map[Reg]Reg) {
	if len(mapping) == 0 {
		return
	}
	resolve := func(r Reg) Reg {
		seen := map[Reg]bool{}
		for {
			next, ok := mapping[r]
			if !ok || seen[r] {
				return r
			}
			seen[r] = true
			r = next
		}
	}
	for _, b := range f.walk() {
		for _, phi := range b.Phis {
			for at := range phi.Args {
				phi.Args[at].Reg = resolve(phi.Args[at].Reg)
			}
		}
		for _, instr := range b.Instrs {
			instr.mapUses(resolve)
		}
	}
}

func constants(f *Func) map[Reg]int64 {
	known := map[Reg]int64{}
	for _, b := range f.walk() {
		for _, instr := range b.Instrs {
			if c, ok := instr.(*Const); ok {
				known[c.Dst] = c.Value
			}
		}
	}
	return known
}

// -- the passes ---------------------------------------------------------------

func foldConstants(f *Func) bool {
	known := constants(f)
	changed := false
	for _, b := range f.walk() {
		for at, instr := range b.Instrs {
			folded := fold(instr, known)
			if folded == nil {
				continue
			}
			b.Instrs[at] = folded
			if c, ok := folded.(*Const); ok {
				known[c.Dst] = c.Value
			}
			changed = true
		}
	}
	return changed
}

func fold(instr Instr, known map[Reg]int64) Instr {
	switch i := instr.(type) {
	case *Bin:
		a, aKnown := known[i.Lhs]
		b, bKnown := known[i.Rhs]
		if aKnown && bKnown {
			if value, ok := arith(i.Op, a, b); ok {
				return &Const{Dst: i.Dst, Value: value}
			}
			return nil
		}
		switch {
		case bKnown && b == 0 && oneOf(i.Op, "+", "-", "or", "xor", "shl", "shr"):
			return &Move{Dst: i.Dst, Src: i.Lhs}
		case bKnown && b == 1 && oneOf(i.Op, "*", "/"):
			return &Move{Dst: i.Dst, Src: i.Lhs}
		case aKnown && a == 0 && i.Op == "+":
			return &Move{Dst: i.Dst, Src: i.Rhs}
		}
		return nil
	case *Cmp:
		a, aKnown := known[i.Lhs]
		b, bKnown := known[i.Rhs]
		if !aKnown || !bKnown {
			return nil
		}
		value := int64(0)
		if order(i.Op, a, b) {
			value = 1
		}
		return &Const{Dst: i.Dst, Value: value}
	}
	return nil
}

func oneOf(op string, wanted ...string) bool {
	for _, w := range wanted {
		if op == w {
			return true
		}
	}
	return false
}

// arith is the language's arithmetic, in the 64 bits it is done in.
//
// int64 already wraps, and `/` and `%` already truncate towards zero the way
// `sdiv` does, MIN/-1 included.  The shifts are the only ones that need saying,
// because Go takes an amount of 64 or more as the shift it is and the language
// does not.
func arith(op string, a, b int64) (int64, bool) {
	switch op {
	case "+":
		return a + b, true
	case "-":
		return a - b, true
	case "*":
		return a * b, true
	case "/":
		if b == 0 {
			return 0, false
		}
		return a / b, true
	case "mod":
		if b == 0 {
			return 0, false
		}
		return a % b, true
	case "and":
		return a & b, true
	case "or":
		return a | b, true
	case "xor":
		return a ^ b, true
	case "shl":
		if b < 0 {
			return 0, false
		}
		if b >= 64 {
			return 0, true
		}
		return a << uint(b), true
	case "shr":
		if b < 0 {
			return 0, false
		}
		if b >= 64 {
			if a < 0 {
				return -1, true
			}
			return 0, true
		}
		return a >> uint(b), true
	}
	return 0, false
}

func order(op string, a, b int64) bool {
	switch op {
	case "=":
		return a == b
	case "<>":
		return a != b
	case "<":
		return a < b
	case "<=":
		return a <= b
	case ">":
		return a > b
	case ">=":
		return a >= b
	case "u<":
		return uint64(a) < uint64(b)
	case "u>=":
		return uint64(a) >= uint64(b)
	}
	panic("unknown comparison " + op)
}

func propagateCopies(f *Func) bool {
	mapping := map[Reg]Reg{}
	for _, b := range f.walk() {
		for _, instr := range b.Instrs {
			if m, ok := instr.(*Move); ok {
				mapping[m.Dst] = m.Src
			}
		}
	}
	if len(mapping) == 0 {
		return false
	}
	rewriteRegs(f, mapping)
	for _, b := range f.walk() {
		kept := b.Instrs[:0]
		for _, instr := range b.Instrs {
			if _, isMove := instr.(*Move); !isMove {
				kept = append(kept, instr)
			}
		}
		b.Instrs = kept
	}
	return true
}

func simplifyPhis(f *Func) bool {
	mapping := map[Reg]Reg{}
	changed := false
	for _, b := range f.walk() {
		kept := b.Phis[:0]
		for _, phi := range b.Phis {
			others := map[Reg]bool{}
			only := noReg
			for _, a := range phi.Args {
				if a.Reg != phi.Dst {
					others[a.Reg] = true
					only = a.Reg
				}
			}
			if len(others) == 1 {
				mapping[phi.Dst] = only
				changed = true
			} else {
				kept = append(kept, phi)
			}
		}
		b.Phis = kept
	}
	if changed {
		rewriteRegs(f, mapping)
	}
	return changed
}

func foldBranches(f *Func) bool {
	known := constants(f)
	changed := false
	for _, b := range f.walk() {
		br, isBranch := b.terminator().(*CBr)
		if !isBranch {
			continue
		}
		value, isKnown := known[br.Cond]
		if !isKnown && br.Then != br.Else {
			continue
		}
		taken := br.Then
		if isKnown && value == 0 {
			taken = br.Else
		}
		b.Instrs[len(b.Instrs)-1] = &Jmp{Target: taken}
		changed = true
	}
	if changed {
		dropUnreachable(f)
	}
	return changed
}

func deadCode(f *Func) bool {
	changed := false
	for {
		used := regSet{}
		for _, b := range f.walk() {
			for _, phi := range b.Phis {
				for _, a := range phi.Args {
					used.add(a.Reg)
				}
			}
			for _, instr := range b.Instrs {
				used.addAll(instr.uses())
			}
		}
		roundChanged := false
		for _, b := range f.walk() {
			phis := b.Phis[:0]
			for _, phi := range b.Phis {
				if used.has(phi.Dst) {
					phis = append(phis, phi)
				}
			}
			if len(phis) != len(b.Phis) {
				b.Phis = phis
				roundChanged = true
			}
			kept := b.Instrs[:0]
			for _, instr := range b.Instrs {
				d := instr.defs()
				if d != noReg && !used.has(d) && !instr.hasEffect() {
					roundChanged = true
					continue
				}
				kept = append(kept, instr)
			}
			b.Instrs = kept
		}
		if !roundChanged {
			return changed
		}
		changed = true
	}
}
