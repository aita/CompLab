// Instruction selection: cover the DAG with ARM instructions.
//
// Every node that has to become a register of its own is tiled, largest tile
// first, pulling its foldable operands into the tile as it goes.  The tiles are
// the things ARM can do in one instruction that the IR needs several nodes to say:
//
//	a + b * c            madd
//	a - b * c            msub
//	a + (b << k)         add with a shifted operand
//	a + 4095             add with an immediate
//	a * 8                lsl
//	[a + 24]             a load with the addition as its displacement
//	a < b, then branch   cmp, and a branch on the flags
//
// What comes out is still the same CFG, and still in SSA — a tile defines one new
// register — so liveness, the allocator and the verifier carry on as before.  What
// has gone is the guesswork the emitter used to do with its peepholes: an
// instruction is now chosen where the whole expression is visible, rather than by
// looking at the line before.

package main

import "math/bits"

// immediateMax is what `add`, `sub` and `cmp` take as an immediate operand.
const immediateMax = 4095

var logicalForm = map[string]string{"and": "and", "or": "orr", "xor": "eor"}
var shiftForm = map[string]string{"shl": "lsl", "shr": "asr"}

func selectModule(mod *Module) {
	for _, f := range mod.Funcs {
		selectFunc(f)
	}
}

func selectFunc(f *Func) {
	live := analyse(f)
	for _, b := range f.walk() {
		s := &selector{graph: buildDag(b, live.liveOut[b.Label]),
			done: map[int]bool{}, absorbed: map[int]bool{}}
		b.Instrs = s.run()
	}
}

// selectionGraphs are the DAGs a selection would work on, for `wolv emit -s dag`.
func selectionGraphs(f *Func) []*Dag {
	live := analyse(f)
	out := make([]*Dag, 0, len(f.Order))
	for _, b := range f.walk() {
		out = append(out, buildDag(b, live.liveOut[b.Label]))
	}
	return out
}

type selector struct {
	graph    *Dag
	out      []Instr
	done     map[int]bool
	absorbed map[int]bool
}

func (s *selector) run() []Instr {
	s.plan()
	for at, node := range s.graph.Nodes {
		if s.absorbed[at] {
			continue // part of the tile that reads it
		}
		if s.graph.rematerialisable(at) != nil {
			continue // a constant, computed only where a register wants it
		}
		if s.fuseComparison(at) {
			continue
		}
		s.done[at] = true
		s.tile(node)
	}
	return s.out
}

// plan decides which nodes a tile is going to swallow, before emitting any.
//
// Nothing may be deferred on the chance that its reader takes it.  A node left out
// of the order and then not absorbed would be computed at its reader instead, and
// a chain of those — `a + b + c + ...`, where every term has one reader — would
// move the whole sum to its last line and keep every term alive until then.
func (s *selector) plan() {
	for _, node := range s.graph.Nodes {
		if !node.alone() || node.Reader == noNode {
			continue
		}
		if s.swallows(s.graph.Nodes[node.Reader], node) {
			s.absorbed[node.Index] = true
		}
	}
}

// swallows says whether the instruction chosen for `reader` has room for `node`.
func (s *selector) swallows(reader, node *DagNode) bool {
	switch i := reader.Instr.(type) {
	case *Bin:
		if i.Op != "+" && i.Op != "-" {
			return false
		}
		if reader.Operands[1] != node.Index {
			return false
		}
		if _, _, ok := s.asShift(node.Index); ok {
			return true
		}
		return isBin(node, "*")
	case *Load:
		_, ok := s.displaces(node, i.Offset)
		return reader.Operands[0] == node.Index && ok
	case *Store:
		_, ok := s.displaces(node, i.Offset)
		return reader.Operands[0] == node.Index && ok
	}
	return false
}

// displaces is `[pointer + 24]`, when what is added to the pointer is a constant.
func (s *selector) displaces(node *DagNode, offset int) (int64, bool) {
	if !isBin(node, "+") {
		return 0, false
	}
	value, ok := s.graph.constant(node.Operands[1])
	if !ok {
		return 0, false
	}
	total := int64(offset) + value
	if total >= 0 && total <= 32760 && total%word == 0 {
		return total, true
	}
	if total >= -256 && total <= 255 {
		return total, true
	}
	return 0, false
}

// -- emitting ----------------------------------------------------------------

// mach appends one chosen instruction.  Every caller names Dst, because a
// zero value there would mean x0 rather than "writes nothing".
func (s *selector) mach(m *Mach) { s.out = append(s.out, m) }

// at is the register holding an operand, computing it here if it was deferred.
//
// Only two kinds of node were left out of the order: a constant, which is tiled
// the first time somebody needs it in a register and read from there afterwards,
// and a node the plan said would be absorbed, which ends up here only if the tile
// that was to absorb it changed its mind.
func (s *selector) at(index int, reg Reg) Reg {
	node := s.graph.of(index)
	if node == nil || s.done[node.Index] {
		return reg
	}
	deferred := s.absorbed[node.Index] || s.graph.rematerialisable(node.Index) != nil
	if !deferred {
		return reg
	}
	s.done[node.Index] = true
	return s.tile(node)
}

// -- one node ----------------------------------------------------------------

func (s *selector) tile(node *DagNode) Reg {
	switch i := node.Instr.(type) {
	case *Const:
		s.mach(&Mach{Form: "const", Dst: i.Dst, Imm: i.Value})
		return i.Dst
	case *StrConst:
		s.mach(&Mach{Form: "adr", Dst: i.Dst, Symbol: i.Symbol})
		return i.Dst
	case *Bin:
		s.arithmetic(node, i.Dst, i.Op, i.Lhs, i.Rhs)
		return i.Dst
	case *Cmp:
		s.compare(node, i.Op, i.Lhs, i.Rhs)
		s.mach(&Mach{Form: "cset", Dst: i.Dst, Symbol: condition[i.Op]})
		return i.Dst
	case *Load:
		pointer, displacement := s.address(node.Operands[0], i.Base, i.Offset)
		s.mach(&Mach{Form: "ldr", Dst: i.Dst, Srcs: []Reg{pointer}, Imm: displacement})
		return i.Dst
	case *Store:
		value := s.at(node.Operands[1], i.Src)
		pointer, displacement := s.address(node.Operands[0], i.Base, i.Offset)
		s.mach(&Mach{Form: "str", Dst: noReg, Srcs: []Reg{pointer, value},
			Imm: displacement, Effect: true})
		return i.Src
	default:
		// Moves, calls, slot accesses and the terminator are machine instructions
		// already, and a phi is not in this list at all.  None of them folds
		// anything, so every operand that was left to be folded has to be computed
		// here instead.
		for _, operand := range node.Operands {
			s.force(operand)
		}
		s.out = append(s.out, node.Instr)
		if d := node.Instr.defs(); d != noReg {
			return d
		}
		return 0
	}
}

// -- the tiles ---------------------------------------------------------------

func (s *selector) arithmetic(node *DagNode, dst Reg, op string, lhs, rhs Reg) {
	switch op {
	case "+", "-":
		s.additive(node, dst, op, lhs, rhs)
	case "*":
		s.multiply(node, dst, lhs, rhs)
	case "/":
		s.mach(&Mach{Form: "sdiv", Dst: dst, Srcs: s.both(node, lhs, rhs)})
	case "shl", "shr":
		s.shift(node, dst, op, lhs, rhs)
	case "and", "or", "xor":
		s.logical(node, dst, op, lhs, rhs)
	default:
		panic("no instruction for `" + op + "`")
	}
}

// both is both operands in registers, which is what the plain forms want.
func (s *selector) both(node *DagNode, lhs, rhs Reg) []Reg {
	return []Reg{s.at(node.Operands[0], lhs), s.at(node.Operands[1], rhs)}
}

// additive is `add` and `sub`, in whichever of their four forms fits.
func (s *selector) additive(node *DagNode, dst Reg, op string, lhs, rhs Reg) {
	// A shifted operand comes first: `a + b * 8` is one instruction that way and
	// two as a multiply-add, because the 8 would need a register.
	if s.shiftInto(node, dst, op, lhs) {
		return
	}
	if s.multiplyInto(node, dst, op, lhs) {
		return
	}
	left, right := node.Operands[0], node.Operands[1]
	if value, ok := s.graph.constant(right); ok && value >= 0 && value <= immediateMax {
		form := "addi"
		if op == "-" {
			form = "subi"
		}
		s.mach(&Mach{Form: form, Dst: dst, Srcs: []Reg{s.at(left, lhs)}, Imm: value})
		return
	}
	if op == "+" {
		// Only addition may take its constant from the other side.
		if value, ok := s.graph.constant(left); ok && value >= 0 && value <= immediateMax {
			s.mach(&Mach{Form: "addi", Dst: dst, Srcs: []Reg{s.at(right, rhs)}, Imm: value})
			return
		}
	}
	form := "add"
	if op == "-" {
		form = "sub"
	}
	s.mach(&Mach{Form: form, Dst: dst, Srcs: s.both(node, lhs, rhs)})
}

func (s *selector) multiply(node *DagNode, dst Reg, lhs, rhs Reg) {
	if value, ok := s.graph.constant(node.Operands[1]); ok && value > 0 && value&(value-1) == 0 {
		s.mach(&Mach{Form: "lsli", Dst: dst, Srcs: []Reg{s.at(node.Operands[0], lhs)},
			Imm: int64(bits.Len64(uint64(value)) - 1)})
		return
	}
	s.mach(&Mach{Form: "mul", Dst: dst, Srcs: s.both(node, lhs, rhs)})
}

func (s *selector) shift(node *DagNode, dst Reg, op string, lhs, rhs Reg) {
	if value, ok := s.graph.constant(node.Operands[1]); ok && value >= 0 && value < 64 {
		s.mach(&Mach{Form: shiftForm[op] + "i", Dst: dst,
			Srcs: []Reg{s.at(node.Operands[0], lhs)}, Imm: value})
		return
	}
	s.mach(&Mach{Form: shiftForm[op], Dst: dst, Srcs: s.both(node, lhs, rhs)})
}

func (s *selector) logical(node *DagNode, dst Reg, op string, lhs, rhs Reg) {
	if value, ok := s.graph.constant(node.Operands[1]); op == "xor" && ok && value == 1 {
		// Which is how `not` arrives.
		s.mach(&Mach{Form: "eori", Dst: dst, Srcs: []Reg{s.at(node.Operands[0], lhs)}, Imm: 1})
		return
	}
	s.mach(&Mach{Form: logicalForm[op], Dst: dst, Srcs: s.both(node, lhs, rhs)})
}

// multiplyInto: `a + b * c` and `a - b * c` are one instruction each.
func (s *selector) multiplyInto(node *DagNode, dst Reg, op string, lhs Reg) bool {
	product := s.graph.of(node.Operands[1])
	if product == nil || !product.alone() || !isBin(product, "*") {
		return false
	}
	inner := product.Instr.(*Bin)
	form := "madd"
	if op == "-" {
		form = "msub"
	}
	s.mach(&Mach{Form: form, Dst: dst, Srcs: []Reg{
		s.at(product.Operands[0], inner.Lhs),
		s.at(product.Operands[1], inner.Rhs),
		s.at(node.Operands[0], lhs),
	}})
	return true
}

// shiftInto: the second operand of an `add` may be shifted on the way in.
func (s *selector) shiftInto(node *DagNode, dst Reg, op string, lhs Reg) bool {
	shifted, amount, ok := s.asShift(node.Operands[1])
	if !ok {
		return false
	}
	inner := shifted.Instr.(*Bin)
	form := "adds"
	if op == "-" {
		form = "subs"
	}
	s.mach(&Mach{Form: form, Dst: dst, Srcs: []Reg{
		s.at(node.Operands[0], lhs),
		s.at(shifted.Operands[0], inner.Lhs),
	}, Imm: amount})
	return true
}

// asShift is a `x << k` that can be folded, however it was written: `* 8` says it
// too.  This decides nothing and emits nothing, so the plan and the tiles can both
// ask it and get the same answer.
func (s *selector) asShift(index int) (*DagNode, int64, bool) {
	node := s.graph.of(index)
	if node == nil || !node.alone() {
		return nil, 0, false
	}
	inner, isBin := node.Instr.(*Bin)
	if !isBin {
		return nil, 0, false
	}
	amount, ok := s.graph.constant(node.Operands[1])
	if !ok {
		return nil, 0, false
	}
	if inner.Op == "*" {
		if amount <= 0 || amount&(amount-1) != 0 {
			return nil, 0, false
		}
		amount = int64(bits.Len64(uint64(amount)) - 1)
	} else if inner.Op != "shl" {
		return nil, 0, false
	}
	if amount < 0 || amount >= 64 {
		return nil, 0, false
	}
	return node, amount, true
}

// address is a pointer and a displacement, taking in an addition if there is one.
func (s *selector) address(index int, base Reg, offset int) (Reg, int64) {
	node := s.graph.of(index)
	if node != nil && node.alone() {
		if displaced, ok := s.displaces(node, offset); ok {
			inner := node.Instr.(*Bin)
			return s.at(node.Operands[0], inner.Lhs), displaced
		}
	}
	return s.at(index, base), int64(offset)
}

// -- comparisons and the branch that reads them -------------------------------

func (s *selector) compare(node *DagNode, op string, lhs, rhs Reg) {
	left, right := node.Operands[0], node.Operands[1]
	if value, ok := s.graph.constant(right); ok && value >= 0 && value <= immediateMax {
		s.mach(&Mach{Form: "cmpi", Dst: noReg, Srcs: []Reg{s.at(left, lhs)}, Imm: value})
		return
	}
	s.mach(&Mach{Form: "cmp", Dst: noReg, Srcs: []Reg{s.at(left, lhs), s.at(right, rhs)}})
}

// fuseComparison: a comparison the branch below it is the only reader of sets the
// flags rather than a register.
func (s *selector) fuseComparison(index int) bool {
	nodes := s.graph.Nodes
	node := nodes[index]
	cmp, isCmp := node.Instr.(*Cmp)
	if !isCmp || index+1 != len(nodes)-1 {
		return false
	}
	branch, isBranch := nodes[len(nodes)-1].Instr.(*CBr)
	if !isBranch || branch.Cond != cmp.Dst {
		return false
	}
	if node.Users != 1 || node.Escapes {
		return false
	}
	s.compare(node, cmp.Op, cmp.Lhs, cmp.Rhs)
	branch.Code = condition[cmp.Op]
	return true
}

// -- reading operands ---------------------------------------------------------

// force computes a deferred operand for a reader that has no tile to take it.
func (s *selector) force(index int) {
	node := s.graph.of(index)
	if node == nil {
		return
	}
	if v := node.value(); v != noReg {
		s.at(index, v)
	} else {
		s.at(index, 0)
	}
}

func isBin(node *DagNode, op string) bool {
	b, ok := node.Instr.(*Bin)
	return ok && b.Op == op
}
