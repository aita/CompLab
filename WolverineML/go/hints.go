// Which colour a value would like, which is the calling convention asking.
//
// The allocator does not have to satisfy these — a preference is dropped the
// moment it clashes with something the colouring actually requires — but taking
// one when it is free is what stops the emitter having to move a value into `x2`
// on the way into a call, or out of `x0` on the way back from one.

package main

// preferences is the register each value is about to be wanted in, where there is
// one.
func preferences(f *Func) map[Reg]int {
	wanted := map[Reg]int{}
	for at, param := range f.Params {
		if at < len(argumentRegs) {
			wanted[param] = argumentRegs[at]
		}
	}
	for _, b := range f.walk() {
		for _, instr := range b.Instrs {
			switch i := instr.(type) {
			case *Call:
				for at, arg := range i.Args {
					if at >= len(argumentRegs) {
						break
					}
					wanted[arg] = argumentRegs[at]
				}
				if i.Dst != noReg {
					wanted[i.Dst] = argumentRegs[0]
				}
			case *Ret:
				if i.Value != noReg {
					wanted[i.Value] = argumentRegs[0]
				}
			}
		}
	}
	return wanted
}
