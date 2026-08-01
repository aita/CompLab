// The three-address IR, and the control flow graph both IRs are written in.
//
// There are two instruction sets in this compiler.  This file has the first:
// three-address code over virtual registers, which is what lowering produces,
// what ssa.go puts into SSA and what opt.go rewrites.  The second is in mach.go,
// and instruction selection replaces the arithmetic of this one with it.
//
// What they share is everything else — the registers, the blocks, the graph, the
// frame — so the passes that only care about the shape of a function (liveness,
// dominance, the register allocator, the verifiers) work on either, and neither
// has to know what the other's instructions mean.  That is what the methods on
// Instr are for: an instruction says which register it writes and which it reads,
// and nothing outside it has to switch on what it is.
//
// Nothing here is ARM-specific except that a register holds exactly one 64-bit
// word, and the frame layout at the top, which the emitter and the nested
// functions have to agree about.

package main

import (
	"fmt"
	"sort"
	"strings"
)

// Reg is a virtual register.  Registers are numbered from zero, so noReg is a
// value no real one ever has, and every "does it write anything" question is
// answered with it rather than with a second return value.
type Reg int

const noReg Reg = -1

// nameFn is how a register is written in a dump; rewriteFn is how it is renamed.
type nameFn func(Reg) string
type rewriteFn func(Reg) Reg

const word = 8

// argumentRegisters is how many arguments AAPCS64 passes in registers.  The rest
// go on the stack, and the frame layout below knows where.
const argumentRegisters = 8

// slotOffset says where a frame slot sits, relative to the frame pointer.
//
// Slot 0 of every nested function holds its static link, so a frame chain can be
// walked without knowing whose frame it is.  Negative slots are the arguments the
// caller had to pass on the stack: they are already in the frame, above the saved
// frame record, so nothing has to be copied for them and they never take a
// register at entry.
func slotOffset(slot int) int {
	if slot < 0 {
		return 16 + word*(-slot-1)
	}
	return -word * (slot + 1)
}

// -- what every instruction of either set can be asked ------------------------

// Instr is the base of both instruction sets.
//
// A pass that walks a function asks these six questions and no others, which is
// why one liveness analysis and one register allocator serve both levels.
type Instr interface {
	defs() Reg // noReg when it writes none
	uses() []Reg
	mapUses(f rewriteFn)
	setDef(r Reg)
	hasEffect() bool // true when it has to be kept even if its result is dead
	show(name nameFn) string
}

// instrBase answers all six the boring way; every instruction embeds it and
// overrides what it actually does.  Go has no inheritance, so this is how the
// default is shared.
type instrBase struct{}

func (instrBase) defs() Reg          { return noReg }
func (instrBase) uses() []Reg        { return nil }
func (instrBase) mapUses(rewriteFn)  {}
func (instrBase) setDef(Reg)         { panic("this instruction defines nothing") }
func (instrBase) hasEffect() bool    { return false }
func (instrBase) show(nameFn) string { return "?" }

// -- the three-address instructions -------------------------------------------

type Const struct {
	instrBase
	Dst   Reg
	Value int64
}

func (i *Const) defs() Reg    { return i.Dst }
func (i *Const) setDef(r Reg) { i.Dst = r }
func (i *Const) show(name nameFn) string {
	return fmt.Sprintf("%s = %d", name(i.Dst), i.Value)
}

type StrConst struct {
	instrBase
	Dst    Reg
	Symbol string
}

func (i *StrConst) defs() Reg    { return i.Dst }
func (i *StrConst) setDef(r Reg) { i.Dst = r }
func (i *StrConst) show(name nameFn) string {
	return fmt.Sprintf("%s = &%s", name(i.Dst), i.Symbol)
}

type Move struct {
	instrBase
	Dst Reg
	Src Reg
}

func (i *Move) defs() Reg               { return i.Dst }
func (i *Move) uses() []Reg             { return []Reg{i.Src} }
func (i *Move) mapUses(f rewriteFn)     { i.Src = f(i.Src) }
func (i *Move) setDef(r Reg)            { i.Dst = r }
func (i *Move) show(name nameFn) string { return fmt.Sprintf("%s = %s", name(i.Dst), name(i.Src)) }

type Bin struct {
	instrBase
	Dst Reg
	Op  string
	Lhs Reg
	Rhs Reg
}

func (i *Bin) defs() Reg   { return i.Dst }
func (i *Bin) uses() []Reg { return []Reg{i.Lhs, i.Rhs} }
func (i *Bin) mapUses(f rewriteFn) {
	i.Lhs = f(i.Lhs)
	i.Rhs = f(i.Rhs)
}
func (i *Bin) setDef(r Reg) { i.Dst = r }
func (i *Bin) show(name nameFn) string {
	return fmt.Sprintf("%s = %s %s %s", name(i.Dst), name(i.Lhs), i.Op, name(i.Rhs))
}

type Cmp struct {
	instrBase
	Dst Reg
	Op  string
	Lhs Reg
	Rhs Reg
}

func (i *Cmp) defs() Reg   { return i.Dst }
func (i *Cmp) uses() []Reg { return []Reg{i.Lhs, i.Rhs} }
func (i *Cmp) mapUses(f rewriteFn) {
	i.Lhs = f(i.Lhs)
	i.Rhs = f(i.Rhs)
}
func (i *Cmp) setDef(r Reg) { i.Dst = r }
func (i *Cmp) show(name nameFn) string {
	return fmt.Sprintf("%s = %s %s %s", name(i.Dst), name(i.Lhs), i.Op, name(i.Rhs))
}

type Load struct {
	instrBase
	Dst    Reg
	Base   Reg
	Offset int
}

func (i *Load) defs() Reg           { return i.Dst }
func (i *Load) uses() []Reg         { return []Reg{i.Base} }
func (i *Load) mapUses(f rewriteFn) { i.Base = f(i.Base) }
func (i *Load) setDef(r Reg)        { i.Dst = r }
func (i *Load) show(name nameFn) string {
	return fmt.Sprintf("%s = [%s + %d]", name(i.Dst), name(i.Base), i.Offset)
}

type Store struct {
	instrBase
	Base   Reg
	Offset int
	Src    Reg
}

func (i *Store) uses() []Reg { return []Reg{i.Base, i.Src} }
func (i *Store) mapUses(f rewriteFn) {
	i.Base = f(i.Base)
	i.Src = f(i.Src)
}
func (i *Store) hasEffect() bool { return true }
func (i *Store) show(name nameFn) string {
	return fmt.Sprintf("[%s + %d] = %s", name(i.Base), i.Offset, name(i.Src))
}

// -- the frame, calls and joins, which both instruction sets keep --------------

// LoadSlot reads a frame slot of this function — an escaping variable, or a spill.
type LoadSlot struct {
	instrBase
	Dst  Reg
	Slot int
}

func (i *LoadSlot) defs() Reg    { return i.Dst }
func (i *LoadSlot) setDef(r Reg) { i.Dst = r }
func (i *LoadSlot) show(name nameFn) string {
	return fmt.Sprintf("%s = slot%d", name(i.Dst), i.Slot)
}

type StoreSlot struct {
	instrBase
	Slot int
	Src  Reg
}

func (i *StoreSlot) uses() []Reg         { return []Reg{i.Src} }
func (i *StoreSlot) mapUses(f rewriteFn) { i.Src = f(i.Src) }
func (i *StoreSlot) hasEffect() bool     { return true }
func (i *StoreSlot) show(name nameFn) string {
	return fmt.Sprintf("slot%d = %s", i.Slot, name(i.Src))
}

// FrameAddr is the frame pointer itself, which is what a static link points at.
type FrameAddr struct {
	instrBase
	Dst Reg
}

func (i *FrameAddr) defs() Reg               { return i.Dst }
func (i *FrameAddr) setDef(r Reg)            { i.Dst = r }
func (i *FrameAddr) show(name nameFn) string { return fmt.Sprintf("%s = frame", name(i.Dst)) }

type Call struct {
	instrBase
	Dst    Reg // noReg for a procedure
	Callee string
	Args   []Reg
}

func (i *Call) defs() Reg   { return i.Dst }
func (i *Call) uses() []Reg { return append([]Reg(nil), i.Args...) }
func (i *Call) mapUses(f rewriteFn) {
	for at, a := range i.Args {
		i.Args[at] = f(a)
	}
}
func (i *Call) setDef(r Reg)    { i.Dst = r }
func (i *Call) hasEffect() bool { return true }
func (i *Call) show(name nameFn) string {
	parts := make([]string, len(i.Args))
	for at, a := range i.Args {
		parts[at] = name(a)
	}
	call := fmt.Sprintf("%s(%s)", i.Callee, strings.Join(parts, ", "))
	if i.Dst == noReg {
		return call
	}
	return name(i.Dst) + " = " + call
}

// PhiArg is one edge of a phi.  They are a slice and not a map because the order
// they were placed in is the order a dump has to print them in.
type PhiArg struct {
	Pred string
	Reg  Reg
}

type Phi struct {
	instrBase
	Dst  Reg
	Args []PhiArg
}

func (i *Phi) defs() Reg    { return i.Dst }
func (i *Phi) setDef(r Reg) { i.Dst = r }
func (i *Phi) show(name nameFn) string {
	parts := make([]string, len(i.Args))
	for at, a := range i.Args {
		parts[at] = fmt.Sprintf("%s: %s", a.Pred, name(a.Reg))
	}
	return fmt.Sprintf("%s = phi [%s]", name(i.Dst), strings.Join(parts, ", "))
}

func (i *Phi) arg(pred string) (Reg, bool) {
	for _, a := range i.Args {
		if a.Pred == pred {
			return a.Reg, true
		}
	}
	return noReg, false
}

// setArg keeps an argument where it was, and appends a new one at the end.
func (i *Phi) setArg(pred string, r Reg) {
	for at := range i.Args {
		if i.Args[at].Pred == pred {
			i.Args[at].Reg = r
			return
		}
	}
	i.Args = append(i.Args, PhiArg{Pred: pred, Reg: r})
}

func (i *Phi) removeArg(pred string) (Reg, bool) {
	for at, a := range i.Args {
		if a.Pred == pred {
			i.Args = append(i.Args[:at], i.Args[at+1:]...)
			return a.Reg, true
		}
	}
	return noReg, false
}

func (i *Phi) preds() []string {
	out := make([]string, len(i.Args))
	for at, a := range i.Args {
		out[at] = a.Pred
	}
	return out
}

// -- control flow -------------------------------------------------------------

// Terminator is the last instruction of every block.
type Terminator interface {
	Instr
	isTerminator()
}

type Jmp struct {
	instrBase
	Target string
}

func (*Jmp) isTerminator()        {}
func (i *Jmp) hasEffect() bool    { return true }
func (i *Jmp) show(nameFn) string { return "jmp " + i.Target }

type CBr struct {
	instrBase
	Cond Reg
	Then string
	Else string
	// After selection a branch may read the flags a comparison just set instead
	// of testing a register, and then it reads no register at all.
	Code string
}

func (*CBr) isTerminator() {}
func (i *CBr) uses() []Reg {
	if i.Code != "" {
		return nil
	}
	return []Reg{i.Cond}
}
func (i *CBr) mapUses(f rewriteFn) {
	if i.Code == "" {
		i.Cond = f(i.Cond)
	}
}
func (i *CBr) hasEffect() bool { return true }
func (i *CBr) show(name nameFn) string {
	test := name(i.Cond) + " ?"
	if i.Code != "" {
		test = i.Code + "?"
	}
	return fmt.Sprintf("br %s %s : %s", test, i.Then, i.Else)
}

type Ret struct {
	instrBase
	Value Reg // noReg for a procedure
}

func (*Ret) isTerminator() {}
func (i *Ret) uses() []Reg {
	if i.Value == noReg {
		return nil
	}
	return []Reg{i.Value}
}
func (i *Ret) mapUses(f rewriteFn) {
	if i.Value != noReg {
		i.Value = f(i.Value)
	}
}
func (i *Ret) hasEffect() bool { return true }
func (i *Ret) show(name nameFn) string {
	if i.Value == noReg {
		return "ret"
	}
	return "ret " + name(i.Value)
}

// -- the graph ----------------------------------------------------------------

type Block struct {
	Label  string
	Phis   []*Phi
	Instrs []Instr
	Preds  []string
}

func (b *Block) terminator() Terminator {
	if len(b.Instrs) == 0 {
		panic("block " + b.Label + " is unterminated")
	}
	last, ok := b.Instrs[len(b.Instrs)-1].(Terminator)
	if !ok {
		panic("block " + b.Label + " falls through")
	}
	return last
}

func (b *Block) succs() []string {
	switch t := b.terminator().(type) {
	case *Jmp:
		return []string{t.Target}
	case *CBr:
		if t.Then != t.Else {
			return []string{t.Then, t.Else}
		}
		return []string{t.Then}
	default:
		return nil
	}
}

// Func is one function: a frame, a set of parameters, and a graph of blocks.
type Func struct {
	Label      string
	Name       string
	Params     []Reg
	Depth      int
	Entry      string
	Blocks     map[string]*Block
	Order      []string
	NRegs      int
	NSlots     int
	LinkSlot   int // the static link's slot, or -1
	Colours    map[Reg]int
	SpillSlots map[Reg]int
	Saved      []int
}

func newFunc(label, name string, depth int) *Func {
	return &Func{
		Label: label, Name: name, Depth: depth, Entry: "entry",
		Blocks: map[string]*Block{}, LinkSlot: -1,
		Colours: map[Reg]int{}, SpillSlots: map[Reg]int{},
	}
}

func (f *Func) newReg() Reg {
	f.NRegs++
	return Reg(f.NRegs - 1)
}

func (f *Func) newSlot() int {
	f.NSlots++
	return f.NSlots - 1
}

func (f *Func) addBlock(label string) *Block {
	if _, seen := f.Blocks[label]; seen {
		panic("block " + label + " already exists")
	}
	b := &Block{Label: label}
	f.Blocks[label] = b
	f.Order = append(f.Order, label)
	return b
}

// walk is every block, in the order they were made.
func (f *Func) walk() []*Block {
	out := make([]*Block, len(f.Order))
	for at, label := range f.Order {
		out[at] = f.Blocks[label]
	}
	return out
}

func (f *Func) block(label string) *Block {
	b, ok := f.Blocks[label]
	if !ok {
		panic("no block " + label + " in " + f.Name)
	}
	return b
}

// StringLit is a literal and the symbol it is emitted under, in the order they
// were first seen.
type StringLit struct {
	Symbol string
	Text   string
}

type Module struct {
	Funcs   []*Func
	Strings []StringLit
}

func renameTarget(instr Instr, old, new string) {
	switch t := instr.(type) {
	case *Jmp:
		if t.Target == old {
			t.Target = new
		}
	case *CBr:
		if t.Then == old {
			t.Then = new
		}
		if t.Else == old {
			t.Else = new
		}
	}
}

func recomputePreds(f *Func) {
	for _, b := range f.Blocks {
		b.Preds = nil
	}
	for _, b := range f.walk() {
		for _, s := range b.succs() {
			f.block(s).Preds = append(f.block(s).Preds, b.Label)
		}
	}
}

func reachable(f *Func) map[string]bool {
	seen := map[string]bool{}
	stack := []string{f.Entry}
	for len(stack) > 0 {
		label := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[label] {
			continue
		}
		seen[label] = true
		stack = append(stack, f.block(label).succs()...)
	}
	return seen
}

func dropUnreachable(f *Func) {
	live := reachable(f)
	for label := range f.Blocks {
		if !live[label] {
			delete(f.Blocks, label)
		}
	}
	kept := f.Order[:0]
	for _, label := range f.Order {
		if live[label] {
			kept = append(kept, label)
		}
	}
	f.Order = kept
	for _, b := range f.walk() {
		for _, phi := range b.Phis {
			args := phi.Args[:0]
			for _, a := range phi.Args {
				if live[a.Pred] {
					args = append(args, a)
				}
			}
			phi.Args = args
		}
	}
	recomputePreds(f)
}

// rpo is reverse post-order, which is the order every dataflow pass walks in.
func rpo(f *Func) []string {
	var order []string
	seen := map[string]bool{}
	type frame struct {
		label    string
		expanded bool
	}
	stack := []frame{{f.Entry, false}}
	for len(stack) > 0 {
		top := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if top.expanded {
			order = append(order, top.label)
			continue
		}
		if seen[top.label] {
			continue
		}
		seen[top.label] = true
		stack = append(stack, frame{top.label, true})
		succs := f.block(top.label).succs()
		for at := len(succs) - 1; at >= 0; at-- {
			if !seen[succs[at]] {
				stack = append(stack, frame{succs[at], false})
			}
		}
	}
	for i, j := 0, len(order)-1; i < j; i, j = i+1, j-1 {
		order[i], order[j] = order[j], order[i]
	}
	return order
}

// -- printing -----------------------------------------------------------------

func regName(f *Func, r Reg) string {
	if colour, ok := f.Colours[r]; ok {
		return fmt.Sprintf("%%%d:%d", r, colour)
	}
	return fmt.Sprintf("%%%d", r)
}

func naming(f *Func) nameFn {
	return func(r Reg) string { return regName(f, r) }
}

func showInstr(f *Func, instr Instr) string { return instr.show(naming(f)) }

func showFunc(f *Func) string {
	var out []string
	params := make([]string, len(f.Params))
	for at, r := range f.Params {
		params[at] = regName(f, r)
	}
	out = append(out, fmt.Sprintf("fun %s(%s)  ; depth %d, %d slots",
		f.Label, strings.Join(params, ", "), f.Depth, f.NSlots))
	for _, b := range f.walk() {
		preds := ""
		if len(b.Preds) > 0 {
			preds = "  ; preds: " + strings.Join(b.Preds, ", ")
		}
		out = append(out, b.Label+":"+preds)
		for _, phi := range b.Phis {
			out = append(out, "    "+showInstr(f, phi))
		}
		for _, instr := range b.Instrs {
			out = append(out, "    "+showInstr(f, instr))
		}
	}
	return strings.Join(out, "\n")
}

func showModule(mod *Module) string {
	parts := make([]string, 0, len(mod.Funcs)+1)
	for _, f := range mod.Funcs {
		parts = append(parts, showFunc(f))
	}
	if len(mod.Strings) > 0 {
		var lines []string
		for _, s := range mod.Strings {
			lines = append(lines, fmt.Sprintf("%s: \"%s\"", s.Symbol, asText(s.Text)))
		}
		parts = append(parts, strings.Join(lines, "\n"))
	}
	return strings.Join(parts, "\n\n") + "\n"
}

// asText widens every byte of a literal to the character of the same number, which
// is what a dump shows.  A literal is bytes and a dump is text, so the two have to
// be told apart somewhere; here is where.
func asText(literal string) string {
	var out strings.Builder
	for i := 0; i < len(literal); i++ {
		out.WriteRune(rune(literal[i]))
	}
	return out.String()
}

// sortedRegs is what a pass reaches for when a set has to be walked in a fixed
// order; Go's maps have none of their own.
func sortedRegs(set map[Reg]bool) []Reg {
	out := make([]Reg, 0, len(set))
	for r := range set {
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}
