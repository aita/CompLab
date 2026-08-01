// The machine IR: what instruction selection replaces the arithmetic with.
//
// One type, because on this machine an instruction is a form, a register it
// writes and some it reads.  The form names an entry in the table below, and the
// table is the whole instruction set the compiler can choose from.
//
// The machine IR is this plus the part of ir.go that was already machine-level: a
// call, a move, a frame slot, a phi and the three terminators.  What it may no
// longer contain is the arithmetic — Const, Bin, Cmp, Load, Store, StrConst — and
// verifyMach is what says so, because a compiler that quietly kept an abstract
// instruction until the emitter would only find out there.
//
// Four forms are not one instruction each, and the emitter expands them:
//
//	const   a constant, which is a `mov` or up to four `movz`/`movk`
//	adr     the address of a string, which is `adrp` and an `add`
//	ldr     a load, whose addressing mode depends on how far the offset reaches
//	str     a store, likewise

package main

import (
	"fmt"
	"strconv"
	"strings"
)

// machForms is how each form is written down, once the registers have their
// colours.  `d` is the register written and `s0`, `s1`, `s2` the ones read.
var machForms = map[string]string{
	"add":  "add {d}, {s0}, {s1}",
	"addi": "add {d}, {s0}, #{imm}",
	"adds": "add {d}, {s0}, {s1}, lsl #{imm}",
	"sub":  "sub {d}, {s0}, {s1}",
	"subi": "sub {d}, {s0}, #{imm}",
	"subs": "sub {d}, {s0}, {s1}, lsl #{imm}",
	"mul":  "mul {d}, {s0}, {s1}",
	"madd": "madd {d}, {s0}, {s1}, {s2}",
	"msub": "msub {d}, {s0}, {s1}, {s2}",
	"sdiv": "sdiv {d}, {s0}, {s1}",
	"and":  "and {d}, {s0}, {s1}",
	"orr":  "orr {d}, {s0}, {s1}",
	"eor":  "eor {d}, {s0}, {s1}",
	"eori": "eor {d}, {s0}, #{imm}",
	"lsl":  "lsl {d}, {s0}, {s1}",
	"lsli": "lsl {d}, {s0}, #{imm}",
	"asr":  "asr {d}, {s0}, {s1}",
	"asri": "asr {d}, {s0}, #{imm}",
	"cmp":  "cmp {s0}, {s1}",
	"cmpi": "cmp {s0}, #{imm}",
	"cset": "cset {d}, {sym}",
}

// condition is which code each comparison sets, and opposite is the one that says
// the reverse — the emitter needs that when the branch it is writing falls
// through to the block the comparison was true for.
var condition = map[string]string{
	"=": "eq", "<>": "ne", "<": "lt", "<=": "le",
	">": "gt", ">=": "ge", "u<": "lo", "u>=": "hs",
}

var opposite = map[string]string{
	"eq": "ne", "ne": "eq", "lt": "ge", "ge": "lt",
	"gt": "le", "le": "gt", "lo": "hs", "hs": "lo",
}

// expanded are the ones the emitter writes itself, because they are not one
// instruction.
var expanded = map[string]bool{"const": true, "adr": true, "ldr": true, "str": true}

type Mach struct {
	instrBase
	Form   string
	Dst    Reg // noReg when it writes none
	Srcs   []Reg
	Imm    int64
	Symbol string
	Effect bool
}

func (i *Mach) defs() Reg   { return i.Dst }
func (i *Mach) uses() []Reg { return append([]Reg(nil), i.Srcs...) }
func (i *Mach) mapUses(f rewriteFn) {
	for at, s := range i.Srcs {
		i.Srcs[at] = f(s)
	}
}
func (i *Mach) setDef(r Reg)    { i.Dst = r }
func (i *Mach) hasEffect() bool { return i.Effect }
func (i *Mach) show(name nameFn) string {
	operands := make([]string, 0, len(i.Srcs)+1)
	for _, s := range i.Srcs {
		operands = append(operands, name(s))
	}
	switch {
	case i.Symbol != "":
		operands = append(operands, i.Symbol)
	case i.Imm != 0 || i.Form == "const":
		operands = append(operands, "#"+strconv.FormatInt(i.Imm, 10))
	}
	written := strings.TrimRight(i.Form+" "+strings.Join(operands, ", "), " ")
	if i.Dst == noReg {
		return written
	}
	return name(i.Dst) + " = " + written
}

func isAbstract(instr Instr) bool {
	switch instr.(type) {
	case *Const, *StrConst, *Bin, *Cmp, *Load, *Store:
		return true
	}
	return false
}

// verifyMach insists that selection left nothing of the three-address IR behind.
func verifyMach(f *Func) {
	for _, b := range f.walk() {
		for _, instr := range b.Instrs {
			if isAbstract(instr) {
				panic(fmt.Sprintf("%T survived selection in %s:%s", instr, f.Name, b.Label))
			}
			if m, ok := instr.(*Mach); ok {
				if _, known := machForms[m.Form]; !known && !expanded[m.Form] {
					panic(fmt.Sprintf("no such instruction as `%s`", m.Form))
				}
			}
		}
	}
}

func verifyMachModule(mod *Module) {
	for _, f := range mod.Funcs {
		verifyMach(f)
	}
}
