// Lowering: the typed syntax tree becomes a control flow graph.
//
// Two things are worth knowing about this pass.
//
// It never builds a phi.  A variable written in two branches is written to the
// same register twice, and ssa.go is what turns those two writes into one phi.
// Lowering only has to make sure a definition reaches every use, which structured
// control flow does for free.
//
// It decides where a variable lives.  A variable the checker did not mark as
// escaping becomes a register; one that escaped becomes a frame slot, reached
// through LoadSlot/StoreSlot in its own function and through a chain of static
// links from a nested one.

package main

import "fmt"

type lowerOptions struct{ checks bool }

func lower(prog *Program, opts lowerOptions) *Module {
	l := &lowerer{opts: opts, mod: &Module{}, symbols: map[string]string{}}
	main := newFuncLowerer(l, "wol_main", "main", 0)
	main.topLevel(prog.Decls)
	return l.mod
}

// lowerer owns what the whole module shares: string literals and the function list.
type lowerer struct {
	opts    lowerOptions
	mod     *Module
	symbols map[string]string // text -> symbol
}

func (l *lowerer) string(text string) string {
	if symbol, seen := l.symbols[text]; seen {
		return symbol
	}
	symbol := fmt.Sprintf(".Lstr%d", len(l.symbols))
	l.symbols[text] = symbol
	l.mod.Strings = append(l.mod.Strings, StringLit{Symbol: symbol, Text: text})
	return symbol
}

func (l *lowerer) function(bind *FunBind) {
	sym := bind.Sym
	fl := newFuncLowerer(l, sym.Label, sym.Name, sym.Depth)
	fl.functionBody(bind, sym)
}

type funcLowerer struct {
	up          *lowerer
	opts        lowerOptions
	fn          *Func
	cur         *Block
	breaks      []string
	counter     int
	hasChildren bool
}

func newFuncLowerer(up *lowerer, label, name string, depth int) *funcLowerer {
	fn := newFunc(label, name, depth)
	fl := &funcLowerer{up: up, opts: up.opts, fn: fn}
	fl.cur = fn.addBlock("entry")
	if depth > 0 {
		fn.LinkSlot = fn.newSlot()
	}
	up.mod.Funcs = append(up.mod.Funcs, fn)
	return fl
}

// -- block plumbing ----------------------------------------------------------

func (f *funcLowerer) fresh(hint string) *Block {
	f.counter++
	return f.fn.addBlock(fmt.Sprintf("%s%d", hint, f.counter))
}

func (f *funcLowerer) emit(instr Instr) { f.cur.Instrs = append(f.cur.Instrs, instr) }

func (f *funcLowerer) terminate(term Terminator) {
	f.emit(term)
	f.cur = f.fresh("dead")
}

func (f *funcLowerer) jump(b *Block) { f.terminate(&Jmp{Target: b.Label}) }

func (f *funcLowerer) branch(cond Reg, yes, no *Block) {
	f.terminate(&CBr{Cond: cond, Then: yes.Label, Else: no.Label})
}

func (f *funcLowerer) reg() Reg { return f.fn.newReg() }

func (f *funcLowerer) constant(value int64) Reg {
	r := f.reg()
	f.emit(&Const{Dst: r, Value: value})
	return r
}

// -- function bodies ---------------------------------------------------------

func (f *funcLowerer) topLevel(decls []Decl) {
	f.decls(decls)
	f.terminate(&Ret{Value: noReg})
	f.finish()
}

func (f *funcLowerer) functionBody(bind *FunBind, sym *FunSym) {
	if f.fn.Depth > 0 {
		link := f.reg()
		f.fn.Params = append(f.fn.Params, link)
		f.emit(&StoreSlot{Slot: f.fn.LinkSlot, Src: link})
	}
	first := len(f.fn.Params)
	for offset, psym := range sym.Params {
		index := first + offset
		if index >= argumentRegisters {
			psym.Escapes = true
			psym.Slot = -(index - argumentRegisters + 1)
			continue
		}
		r := f.reg()
		f.fn.Params = append(f.fn.Params, r)
		if psym.Escapes {
			psym.Slot = f.fn.newSlot()
			f.emit(&StoreSlot{Slot: psym.Slot, Src: r})
		} else {
			psym.Reg = r
		}
	}
	value := f.exp(bind.Body)
	if _, isUnit := sym.Result.(UnitT); isUnit {
		value = noReg
	}
	f.terminate(&Ret{Value: value})
	f.finish()
}

func (f *funcLowerer) finish() {
	dropUnreachable(f.fn)
	f.dropUnusedStaticLink()
}

// dropUnusedStaticLink: a function nobody nests inside, and that never looks
// outward, keeps no static link — the slot goes, and every later slot moves down
// one.
func (f *funcLowerer) dropUnusedStaticLink() {
	slot := f.fn.LinkSlot
	if slot < 0 || f.hasChildren {
		return
	}
	for _, b := range f.fn.walk() {
		for _, instr := range b.Instrs {
			if load, ok := instr.(*LoadSlot); ok && load.Slot == slot {
				return
			}
		}
	}
	for _, b := range f.fn.walk() {
		kept := b.Instrs[:0]
		for _, instr := range b.Instrs {
			switch i := instr.(type) {
			case *StoreSlot:
				if i.Slot == slot {
					continue
				}
				if i.Slot > slot {
					i.Slot--
				}
			case *LoadSlot:
				if i.Slot > slot {
					i.Slot--
				}
			}
			kept = append(kept, instr)
		}
		b.Instrs = kept
	}
	f.fn.NSlots--
	f.fn.LinkSlot = -1
}

// -- declarations ------------------------------------------------------------

func (f *funcLowerer) decls(decls []Decl) {
	for _, decl := range decls {
		switch d := decl.(type) {
		case *TypeDecl:
		case *ValDecl:
			f.valDecl(d)
		case *FunDecl:
			f.hasChildren = true
			for at := range d.Binds {
				f.up.function(&d.Binds[at])
			}
		}
	}
}

func (f *funcLowerer) valDecl(decl *ValDecl) {
	value := f.exp(decl.Init)
	if decl.Sym == nil {
		return
	}
	if _, isUnit := decl.Sym.Ty.(UnitT); isUnit {
		return
	}
	f.bind(decl.Sym, value)
}

// bind gives a variable its home, and puts the initial value in it.
func (f *funcLowerer) bind(sym *VarSym, value Reg) {
	if sym.Escapes {
		sym.Slot = f.fn.newSlot()
		f.emit(&StoreSlot{Slot: sym.Slot, Src: value})
		return
	}
	sym.Reg = f.reg()
	f.emit(&Move{Dst: sym.Reg, Src: value})
}

// -- reaching variables and frames -------------------------------------------

// frameAt is a register holding the frame pointer of the function at `depth`.
func (f *funcLowerer) frameAt(depth int) Reg {
	r := f.reg()
	if depth == f.fn.Depth {
		f.emit(&FrameAddr{Dst: r})
		return r
	}
	f.emit(&LoadSlot{Dst: r, Slot: f.fn.LinkSlot})
	for here := f.fn.Depth - 1; here > depth; here-- {
		next := f.reg()
		f.emit(&Load{Dst: next, Base: r, Offset: slotOffset(0)})
		r = next
	}
	return r
}

func (f *funcLowerer) readVar(sym *VarSym) Reg {
	if !sym.Escapes {
		return sym.Reg
	}
	if sym.Depth == f.fn.Depth {
		r := f.reg()
		f.emit(&LoadSlot{Dst: r, Slot: sym.Slot})
		return r
	}
	base := f.frameAt(sym.Depth)
	r := f.reg()
	f.emit(&Load{Dst: r, Base: base, Offset: slotOffset(sym.Slot)})
	return r
}

func (f *funcLowerer) writeVar(sym *VarSym, value Reg) {
	switch {
	case !sym.Escapes:
		f.emit(&Move{Dst: sym.Reg, Src: value})
	case sym.Depth == f.fn.Depth:
		f.emit(&StoreSlot{Slot: sym.Slot, Src: value})
	default:
		base := f.frameAt(sym.Depth)
		f.emit(&Store{Base: base, Offset: slotOffset(sym.Slot), Src: value})
	}
}

// -- expressions -------------------------------------------------------------

func (f *funcLowerer) value(e Exp) Reg {
	r := f.exp(e)
	if r == noReg {
		panic(fmt.Sprintf("expected a value from %T", e))
	}
	return r
}

func (f *funcLowerer) exp(e Exp) Reg {
	switch e := e.(type) {
	case *IntLit:
		return f.constant(e.Value)
	case *BoolLit:
		if e.Value {
			return f.constant(1)
		}
		return f.constant(0)
	case *NilLit:
		return f.constant(0)
	case *UnitLit:
		return noReg
	case *StrLit:
		r := f.reg()
		f.emit(&StrConst{Dst: r, Symbol: f.up.string(e.Value)})
		return r
	case *VarExp:
		return f.readVar(e.Sym)
	case *CallExp:
		return f.call(e)
	case *RecordLit:
		return f.record(e)
	case *IndexExp:
		return f.index(e)
	case *FieldExp:
		return f.field(e)
	case *NegExp:
		zero := f.constant(0)
		return f.binop("-", zero, f.value(e.Operand))
	case *BinExp:
		return f.bin(e)
	case *LogicExp:
		return f.logic(e)
	case *AssignExp:
		f.assign(e)
		return noReg
	case *IfExp:
		return f.ifExp(e)
	case *WhileExp:
		f.whileExp(e)
		return noReg
	case *ForExp:
		f.forExp(e)
		return noReg
	case *BreakExp:
		f.terminate(&Jmp{Target: f.breaks[len(f.breaks)-1]})
		return noReg
	case *SeqExp:
		last := noReg
		for _, item := range e.Items {
			last = f.exp(item)
		}
		return last
	case *LetExp:
		f.decls(e.Decls)
		return f.exp(e.Body)
	default:
		panic(fmt.Sprintf("unknown expression %T", e))
	}
}

func (f *funcLowerer) binop(op string, lhs, rhs Reg) Reg {
	r := f.reg()
	f.emit(&Bin{Dst: r, Op: op, Lhs: lhs, Rhs: rhs})
	return r
}

func (f *funcLowerer) compare(op string, lhs, rhs Reg) Reg {
	r := f.reg()
	f.emit(&Cmp{Dst: r, Op: op, Lhs: lhs, Rhs: rhs})
	return r
}

func (f *funcLowerer) callRuntime(name string, args []Reg) Reg {
	r := f.reg()
	f.emit(&Call{Dst: r, Callee: name, Args: args})
	return r
}

func (f *funcLowerer) bin(e *BinExp) Reg {
	lhs := f.value(e.Lhs)
	rhs := f.value(e.Rhs)
	switch e.Op {
	case "^":
		return f.callRuntime("wol_concat", []Reg{lhs, rhs})
	case "/", "mod":
		f.checkNonzero(rhs)
		if e.Op == "/" {
			return f.binop("/", lhs, rhs)
		}
		// The remainder is spelled out rather than left to the emitter: the
		// quotient it needs in between is a value like any other, and the
		// allocator can find it a register.  The emitter fuses the last two back
		// into one `msub`.
		quotient := f.binop("/", lhs, rhs)
		product := f.binop("*", quotient, rhs)
		return f.binop("-", lhs, product)
	case "+", "-", "*":
		return f.binop(e.Op, lhs, rhs)
	}
	if _, isString := e.Lhs.ty().(StringT); isString {
		order := f.callRuntime("wol_string_cmp", []Reg{lhs, rhs})
		return f.compare(e.Op, order, f.constant(0))
	}
	return f.compare(e.Op, lhs, rhs)
}

// logic: `andalso` and `orelse` are branches, so the result needs a register.
func (f *funcLowerer) logic(e *LogicExp) Reg {
	result := f.reg()
	rhsBlock := f.fresh("logic")
	join := f.fresh("logicjoin")
	lhs := f.value(e.Lhs)
	f.emit(&Move{Dst: result, Src: lhs})
	if e.Op == "andalso" {
		f.branch(lhs, rhsBlock, join)
	} else {
		f.branch(lhs, join, rhsBlock)
	}
	f.cur = rhsBlock
	f.emit(&Move{Dst: result, Src: f.value(e.Rhs)})
	f.jump(join)
	f.cur = join
	return result
}

func (f *funcLowerer) call(e *CallExp) Reg {
	sym := e.Sym
	switch sym.Builtin {
	case "not":
		return f.binop("xor", f.value(e.Args[0]), f.constant(1))
	case "array":
		n := f.value(e.Args[0])
		init := f.value(e.Args[1])
		return f.callRuntime("wol_array", []Reg{n, init})
	case "length":
		arr := f.value(e.Args[0])
		f.checkNotNil(arr)
		r := f.reg()
		f.emit(&Load{Dst: r, Base: arr, Offset: 0})
		return r
	}
	args := make([]Reg, len(e.Args))
	for at, a := range e.Args {
		args[at] = f.value(a)
	}
	if sym.Builtin == "" {
		args = append([]Reg{f.frameAt(sym.Depth - 1)}, args...)
	}
	if _, isUnit := sym.Result.(UnitT); isUnit {
		f.emit(&Call{Dst: noReg, Callee: sym.Label, Args: args})
		return noReg
	}
	return f.callRuntime(sym.Label, args)
}

func (f *funcLowerer) record(e *RecordLit) Reg {
	rec := e.ty().(*RecordT)
	fields := len(rec.Fields)
	if fields < 1 {
		fields = 1
	}
	size := f.constant(int64(word * fields))
	base := f.callRuntime("wol_alloc", []Reg{size})
	for at, init := range e.Fields {
		f.emit(&Store{Base: base, Offset: word * at, Src: f.value(init.Value)})
	}
	return base
}

func (f *funcLowerer) index(e *IndexExp) Reg {
	addr := f.elementAddress(e)
	r := f.reg()
	f.emit(&Load{Dst: r, Base: addr, Offset: word})
	return r
}

// elementAddress is the address of `a[i]`, without the length word the elements
// follow.
//
// The selector turns this into one `add` with a shifted operand, and the word is
// the load's displacement, so the two instructions that come out are the two the
// machine has.
func (f *funcLowerer) elementAddress(e *IndexExp) Reg {
	base := f.value(e.Array)
	idx := f.value(e.Index)
	f.checkNotNil(base)
	f.checkBounds(base, idx)
	return f.binop("+", base, f.binop("shl", idx, f.constant(3)))
}

func (f *funcLowerer) field(e *FieldExp) Reg {
	base := f.value(e.Record)
	f.checkNotNil(base)
	r := f.reg()
	f.emit(&Load{Dst: r, Base: base, Offset: word * e.Offset})
	return r
}

func (f *funcLowerer) assign(e *AssignExp) {
	switch target := e.Target.(type) {
	case *VarExp:
		f.writeVar(target.Sym, f.value(e.Value))
	case *IndexExp:
		addr := f.elementAddress(target)
		f.emit(&Store{Base: addr, Offset: word, Src: f.value(e.Value)})
	case *FieldExp:
		base := f.value(target.Record)
		f.checkNotNil(base)
		f.emit(&Store{Base: base, Offset: word * target.Offset, Src: f.value(e.Value)})
	default:
		panic("assignment to something that is not a place")
	}
}

func (f *funcLowerer) ifExp(e *IfExp) Reg {
	result := noReg
	if _, isUnit := e.ty().(UnitT); !isUnit {
		result = f.reg()
	}
	yes := f.fresh("then")
	no := f.fresh("else")
	join := f.fresh("join")
	f.branch(f.value(e.Cond), yes, no)

	f.cur = yes
	if taken := f.exp(e.Then); result != noReg && taken != noReg {
		f.emit(&Move{Dst: result, Src: taken})
	}
	f.jump(join)

	f.cur = no
	if e.Else != nil {
		if taken := f.exp(e.Else); result != noReg && taken != noReg {
			f.emit(&Move{Dst: result, Src: taken})
		}
	}
	f.jump(join)

	f.cur = join
	return result
}

func (f *funcLowerer) whileExp(e *WhileExp) {
	test := f.fresh("test")
	body := f.fresh("body")
	done := f.fresh("done")
	f.jump(test)
	f.cur = test
	f.branch(f.value(e.Cond), body, done)
	f.cur = body
	f.breaks = append(f.breaks, done.Label)
	f.exp(e.Body)
	f.breaks = f.breaks[:len(f.breaks)-1]
	f.jump(test)
	f.cur = done
}

// forExp: `for i = lo to hi` counts up, and stops before overflowing at `hi`.
func (f *funcLowerer) forExp(e *ForExp) {
	lo := f.value(e.Lo)
	hiValue := f.value(e.Hi)
	hi := f.reg()
	f.emit(&Move{Dst: hi, Src: hiValue})
	f.bind(e.Sym, lo)
	body := f.fresh("forbody")
	step := f.fresh("forstep")
	done := f.fresh("fordone")
	f.branch(f.compare("<=", lo, hi), body, done)

	f.cur = body
	f.breaks = append(f.breaks, done.Label)
	f.exp(e.Body)
	f.breaks = f.breaks[:len(f.breaks)-1]
	i := f.readVar(e.Sym)
	f.branch(f.compare("<", i, hi), step, done)

	f.cur = step
	f.writeVar(e.Sym, f.binop("+", f.readVar(e.Sym), f.constant(1)))
	f.jump(body)

	f.cur = done
}

// -- run-time checks ---------------------------------------------------------

func (f *funcLowerer) checkNotNil(base Reg) {
	if !f.opts.checks {
		return
	}
	bad := f.fresh("nil")
	ok := f.fresh("ok")
	f.branch(f.compare("=", base, f.constant(0)), bad, ok)
	f.cur = bad
	f.emit(&Call{Dst: noReg, Callee: "wol_nil_error"})
	f.jump(ok)
	f.cur = ok
}

func (f *funcLowerer) checkBounds(base, idx Reg) {
	if !f.opts.checks {
		return
	}
	length := f.reg()
	f.emit(&Load{Dst: length, Base: base, Offset: 0})
	bad := f.fresh("oob")
	ok := f.fresh("ok")
	f.branch(f.compare("u<", idx, length), ok, bad)
	f.cur = bad
	f.emit(&Call{Dst: noReg, Callee: "wol_bounds_error", Args: []Reg{idx, length}})
	f.jump(ok)
	f.cur = ok
}

func (f *funcLowerer) checkNonzero(rhs Reg) {
	if !f.opts.checks {
		return
	}
	bad := f.fresh("divzero")
	ok := f.fresh("ok")
	f.branch(f.compare("=", rhs, f.constant(0)), bad, ok)
	f.cur = bad
	f.emit(&Call{Dst: noReg, Callee: "wol_div_error"})
	f.jump(ok)
	f.cur = ok
}
