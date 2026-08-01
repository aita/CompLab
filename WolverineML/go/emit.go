// ARMv8 assembly, in AAPCS64.
//
// The frame is the ordinary one.  `x29` points at the saved frame record, the slots
// an escaping variable or a spill lives in are below it, the callee-saved registers
// this function actually used are below those, and outgoing stack arguments sit at
// the bottom, at `sp`, where the callee expects them.
//
//	x29 -> | saved x29, x30 |
//	       | slot 0         |   x29 - 8      also where a static link points
//	       | slot 1         |   x29 - 16
//	       | ...            |
//	       | saved x19...   |
//	sp  -> | outgoing args  |
//
// The phis are gone before this point — the allocator left SSA to colour the
// interference graph — so what is left to do all at once is the arguments of a call
// and the parameters at the top of a function: the values are read before any is
// written, which is what sequentialize arranges.  When the copies form a cycle it
// borrows a register the function never used, and when there is none it swaps the
// two ends with three `eor`s, so no register has to be reserved for it.

package main

import (
	"fmt"
	"strconv"
	"strings"
)

var unscaled = map[string]string{"ldr": "ldur", "str": "stur"}

// spare is the one register kept back.  A frame big enough to put a slot out of
// reach of `ldur` is only discovered after allocation has added its spill slots, so
// the address has to be computed somewhere the allocator does not know about.
var spare = scratch[0]

// prologueTemp: nothing of ours is live at the top of the prologue except the
// incoming arguments, so a caller-saved register that is not one of them is free.
const prologueTemp = 9

type frame struct {
	slots     int
	saved     []int
	stackArgs int
	size      int
}

func frameOf(f *Func) frame {
	stackArgs := 0
	for _, b := range f.walk() {
		for _, instr := range b.Instrs {
			if call, ok := instr.(*Call); ok {
				stackArgs = max(stackArgs, len(call.Args)-len(argumentRegs))
			}
		}
	}
	fr := frame{slots: f.NSlots, saved: f.Saved, stackArgs: max(stackArgs, 0)}
	fr.size = (word*(fr.slots+len(fr.saved)+fr.stackArgs) + 15) &^ 15
	return fr
}

func (fr frame) savedOffset(index int) int { return -word * (fr.slots + index + 1) }

// escapeString: one character of a literal is one byte; write the ones `.ascii`
// cannot.
func escapeString(text string) string {
	var out strings.Builder
	for i := 0; i < len(text); i++ {
		ch := text[i]
		switch {
		case ch == 0x22:
			out.WriteString("\\\"")
		case ch == 0x5C:
			out.WriteString("\\\\")
		case ch >= 0x20 && ch < 0x7F:
			out.WriteByte(ch)
		default:
			out.WriteString(fmt.Sprintf("\\%03o", ch))
		}
	}
	return out.String()
}

// newEmitter is how a caller supplies a different emitter; the tests use it to
// force the copies to swap instead of borrowing.
type newEmitter func(*Func) *funcEmitter

func emitModule(mod *Module, make newEmitter) string {
	out := []string{"\t.text"}
	for _, f := range mod.Funcs {
		out = append(out, make(f).emit()...)
		out = append(out, "")
	}
	if len(mod.Strings) > 0 {
		out = append(out, "\t.section .rodata")
		for _, s := range mod.Strings {
			out = append(out, "\t.p2align 3")
			out = append(out, s.Symbol+":")
			out = append(out, fmt.Sprintf("\t.quad %d", len(s.Text)))
			out = append(out, "\t.ascii \""+escapeString(s.Text)+"\"")
			out = append(out, "\t.byte 0")
		}
	}
	out = append(out, "\t.section .note.GNU-stack,\"\",%progbits")
	return strings.Join(out, "\n") + "\n"
}

func registersRead(f *Func) regSet {
	read := regSet{}
	for _, b := range f.walk() {
		for _, instr := range b.Instrs {
			read.addAll(instr.uses())
		}
	}
	return read
}

type funcEmitter struct {
	fn       *Func
	frame    frame
	out      []string
	epilogue string
	read     regSet
	taken    map[int]bool
	// noBorrow forces every cycle of copies to swap, which is otherwise a path
	// only reached when a function has used every caller-saved register.
	noBorrow bool
}

func plainEmitter(f *Func) *funcEmitter {
	taken := map[int]bool{}
	for _, colour := range f.Colours {
		taken[colour] = true
	}
	return &funcEmitter{
		fn: f, frame: frameOf(f), epilogue: ".Lepi_" + f.Label,
		read: registersRead(f), taken: taken,
	}
}

func swappingEmitter(f *Func) *funcEmitter {
	e := plainEmitter(f)
	e.noBorrow = true
	return e
}

// -- helpers -----------------------------------------------------------------

func (e *funcEmitter) line(text string)  { e.out = append(e.out, "\t"+text) }
func (e *funcEmitter) label(text string) { e.out = append(e.out, text+":") }

func (e *funcEmitter) colour(r Reg) int {
	colour, has := e.fn.Colours[r]
	if !has {
		panic(fmt.Sprintf("%%%d was never coloured", r))
	}
	return colour
}

func (e *funcEmitter) mov(dst, src int) {
	if dst != src {
		e.line(fmt.Sprintf("mov x%d, x%d", dst, src))
	}
}

func (e *funcEmitter) immediate(dst int, value int64) {
	bits := uint64(value)
	if bits == 0 {
		e.line(fmt.Sprintf("mov x%d, #0", dst))
		return
	}
	first := true
	for i := 0; i < 4; i++ {
		chunk := (bits >> (i * 16)) & 0xFFFF
		if chunk == 0 {
			continue
		}
		shift := ""
		if i != 0 {
			shift = fmt.Sprintf(", lsl #%d", i*16)
		}
		op := "movk"
		if first {
			op = "movz"
		}
		e.line(fmt.Sprintf("%s x%d, #%d%s", op, dst, chunk, shift))
		first = false
	}
}

// access is `ldr`/`str`, in whichever addressing mode reaches this far.
func (e *funcEmitter) access(op string, reg, base int, offset int64) {
	where := fmt.Sprintf("x%d", base)
	if base == 31 {
		where = "sp"
	}
	switch {
	case offset >= 0 && offset <= 32760 && offset%word == 0:
		e.line(fmt.Sprintf("%s x%d, [%s, #%d]", op, reg, where, offset))
	case offset >= -256 && offset <= 255:
		e.line(fmt.Sprintf("%s x%d, [%s, #%d]", unscaled[op], reg, where, offset))
	default:
		e.immediate(spare, offset)
		e.line(fmt.Sprintf("%s x%d, [%s, x%d]", op, reg, where, spare))
	}
}

// -- whole functions ---------------------------------------------------------

func (e *funcEmitter) emit() []string {
	e.out = append(e.out, "\t.globl "+e.fn.Label)
	e.out = append(e.out, "\t.type "+e.fn.Label+", %function")
	e.label(e.fn.Label)
	e.prologue()
	for at, name := range e.fn.Order {
		e.label(fmt.Sprintf(".L%s_%s", e.fn.Label, name))
		next := ""
		if at+1 < len(e.fn.Order) {
			next = e.fn.Order[at+1]
		}
		e.block(e.fn.block(name), next, at+1 < len(e.fn.Order))
	}
	e.label(e.epilogue)
	e.restore()
	e.line("mov sp, x29")
	e.line("ldp x29, x30, [sp], #16")
	e.line("ret")
	e.out = append(e.out, fmt.Sprintf("\t.size %s, .-%s", e.fn.Label, e.fn.Label))
	return e.out
}

func (e *funcEmitter) prologue() {
	e.line("stp x29, x30, [sp, #-16]!")
	e.line("mov x29, sp")
	if e.frame.size != 0 {
		if e.frame.size <= 4095 {
			e.line(fmt.Sprintf("sub sp, sp, #%d", e.frame.size))
		} else {
			e.immediate(prologueTemp, int64(e.frame.size))
			e.line(fmt.Sprintf("sub sp, sp, x%d", prologueTemp))
		}
	}
	for at, reg := range e.frame.saved {
		e.access("str", reg, 29, int64(e.frame.savedOffset(at)))
	}
	var moves []copyPair
	for at, p := range e.fn.Params {
		if e.read.has(p) {
			moves = append(moves, copyPair{dst: e.colour(p), src: argumentRegs[at]})
		}
	}
	e.copies(moves)
}

func (e *funcEmitter) restore() {
	for at, reg := range e.frame.saved {
		e.access("ldr", reg, 29, int64(e.frame.savedOffset(at)))
	}
}

func (e *funcEmitter) block(b *Block, next string, hasNext bool) {
	for _, instr := range b.Instrs[:len(b.Instrs)-1] {
		e.instruction(instr)
	}
	e.terminator(b, next, hasNext)
}

func (e *funcEmitter) terminator(b *Block, next string, hasNext bool) {
	switch t := b.terminator().(type) {
	case *Jmp:
		if t.Target != next {
			e.line(fmt.Sprintf("b .L%s_%s", e.fn.Label, t.Target))
		}
	case *CBr:
		thenLabel := fmt.Sprintf(".L%s_%s", e.fn.Label, t.Then)
		elseLabel := fmt.Sprintf(".L%s_%s", e.fn.Label, t.Else)
		switch {
		case t.Code != "":
			if t.Then == next {
				e.line("b." + opposite[t.Code] + " " + elseLabel)
			} else {
				e.line("b." + t.Code + " " + thenLabel)
				if t.Else != next {
					e.line("b " + elseLabel)
				}
			}
		case t.Then == next:
			e.line(fmt.Sprintf("cbz x%d, %s", e.colour(t.Cond), elseLabel))
		default:
			e.line(fmt.Sprintf("cbnz x%d, %s", e.colour(t.Cond), thenLabel))
			if t.Else != next {
				e.line("b " + elseLabel)
			}
		}
	case *Ret:
		if t.Value != noReg {
			e.mov(argumentRegs[0], e.colour(t.Value))
		}
		if hasNext { // the epilogue follows the last block
			e.line("b " + e.epilogue)
		}
	}
}

func (e *funcEmitter) copies(moves []copyPair) {
	for _, step := range sequentialize(moves, e.borrowed(moves)) {
		if !step.Swap {
			e.mov(step.Dst, step.Src)
			continue
		}
		a, b := step.Dst, step.Src
		e.line(fmt.Sprintf("eor x%d, x%d, x%d", a, a, b))
		e.line(fmt.Sprintf("eor x%d, x%d, x%d", b, a, b))
		e.line(fmt.Sprintf("eor x%d, x%d, x%d", a, a, b))
	}
}

// borrowed is a register free to clobber here, if the function left one over, and
// -1 when it did not.
//
// A caller-saved register this function never gave to a value holds nothing of ours
// anywhere, and one that this copy neither reads nor writes holds nothing of the
// copy's either.  With no such register the copies swap instead, which needs no
// scratch at all.
func (e *funcEmitter) borrowed(moves []copyPair) int {
	if e.noBorrow {
		return -1
	}
	touched := map[int]bool{}
	for _, m := range moves {
		touched[m.dst] = true
		touched[m.src] = true
	}
	for _, reg := range callerSaved {
		if !e.taken[reg] && !touched[reg] {
			return reg
		}
	}
	return -1
}

// -- one instruction ---------------------------------------------------------

func (e *funcEmitter) instruction(instr Instr) {
	switch i := instr.(type) {
	case *Mach:
		e.machine(i)
	case *Move:
		e.mov(e.colour(i.Dst), e.colour(i.Src))
	case *LoadSlot:
		e.access("ldr", e.colour(i.Dst), 29, int64(slotOffset(i.Slot)))
	case *StoreSlot:
		e.access("str", e.colour(i.Src), 29, int64(slotOffset(i.Slot)))
	case *FrameAddr:
		e.mov(e.colour(i.Dst), 29)
	case *Call:
		e.call(i)
	default:
		panic(fmt.Sprintf("cannot emit %T", instr))
	}
}

// machine writes down one selected instruction, or the sequence it stands for.
func (e *funcEmitter) machine(i *Mach) {
	srcs := make([]int, len(i.Srcs))
	for at, s := range i.Srcs {
		srcs[at] = e.colour(s)
	}
	switch i.Form {
	case "const":
		e.immediate(e.colour(i.Dst), i.Imm)
	case "adr":
		d := e.colour(i.Dst)
		e.line(fmt.Sprintf("adrp x%d, %s", d, i.Symbol))
		e.line(fmt.Sprintf("add x%d, x%d, :lo12:%s", d, d, i.Symbol))
	case "ldr":
		e.access("ldr", e.colour(i.Dst), srcs[0], i.Imm)
	case "str":
		e.access("str", srcs[1], srcs[0], i.Imm)
	default:
		written := machForms[i.Form]
		for at, colour := range srcs {
			written = strings.ReplaceAll(written,
				fmt.Sprintf("{s%d}", at), fmt.Sprintf("x%d", colour))
		}
		if i.Dst != noReg {
			written = strings.ReplaceAll(written, "{d}", fmt.Sprintf("x%d", e.colour(i.Dst)))
		}
		written = strings.ReplaceAll(written, "{imm}", strconv.FormatInt(i.Imm, 10))
		written = strings.ReplaceAll(written, "{sym}", i.Symbol)
		e.line(written)
	}
}

func (e *funcEmitter) call(i *Call) {
	var inRegisters []copyPair
	for at, a := range i.Args {
		if at >= len(argumentRegs) {
			break
		}
		inRegisters = append(inRegisters, copyPair{dst: argumentRegs[at], src: e.colour(a)})
	}
	for at, a := range i.Args[min(len(i.Args), len(argumentRegs)):] {
		e.access("str", e.colour(a), 31, int64(word*at))
	}
	e.copies(inRegisters)
	e.line("bl " + i.Callee)
	if i.Dst != noReg {
		e.mov(e.colour(i.Dst), argumentRegs[0])
	}
}
