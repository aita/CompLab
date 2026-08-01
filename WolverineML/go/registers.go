// What the allocator and the emitter both have to agree about: the registers.
//
// x16 and x17 are the ABI's intra-procedure-call scratch registers, which a
// linker veneer may clobber at a `bl`.  Nothing of ours is ever live across a
// call in a caller-saved register, so x16 is allocatable like any other; x17 is
// the one register kept back, for an address the emitter has to compute after
// allocation is over.  x18 is the platform register, x29 the frame pointer, x30
// the link register.

package main

var (
	callerSaved  = []int{9, 10, 11, 12, 13, 14, 15, 16, 0, 1, 2, 3, 4, 5, 6, 7, 8}
	calleeSaved  = []int{19, 20, 21, 22, 23, 24, 25, 26, 27, 28}
	argumentRegs = []int{0, 1, 2, 3, 4, 5, 6, 7}
	scratch      = []int{17}
)

// Registers is the machine the allocator is colouring for.
type Registers struct {
	caller []int
	callee []int
}

func allRegisters() Registers { return Registers{caller: callerSaved, callee: calleeSaved} }

func (m Registers) anywhere() []int {
	out := make([]int, 0, len(m.caller)+len(m.callee))
	out = append(out, m.caller...)
	return append(out, m.callee...)
}

func (m Registers) count() int { return len(m.caller) + len(m.callee) }

// limitedRegisters is a smaller machine, so that the spiller can be tested on
// small programs.
func limitedRegisters(maxRegs int) Registers {
	// Go does not clamp a slice bound the way Python and Kotlin clamp theirs, so
	// asking for a machine larger than this one is capped rather than fatal.
	callee := calleeSaved[:min(len(calleeSaved), max(2, maxRegs/2))]
	caller := callerSaved[:min(len(callerSaved), max(1, maxRegs-len(callee)))]
	return Registers{caller: caller, callee: callee}
}

func isCalleeSaved(colour int) bool {
	for _, r := range calleeSaved {
		if r == colour {
			return true
		}
	}
	return false
}
