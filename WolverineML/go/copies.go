// Doing several copies at once, one at a time.
//
// Every argument of a call is read before any of them is written, and so is every
// parameter at the top of a function.  Once the allocator has given both ends real
// registers that is a permutation, and putting a permutation into a sequence of
// instructions is this file.
//
// Copies whose destination nobody else has still to read can go first.  When only
// cycles are left, something has to be got out of the way, and there are two ways
// to do it: a register the function never used can hold a value for one step, and
// if there is no such register the two ends of the cycle swap.  A swap is three
// `eor`s and needs nothing to borrow, which is why no register is reserved for
// this anywhere in the compiler.

package main

// CopyStep is one instruction of the sequence: a move, or a swap.
type CopyStep struct {
	Dst  int
	Src  int
	Swap bool
}

func mov(dst, src int) CopyStep { return CopyStep{Dst: dst, Src: src} }
func swap(a, b int) CopyStep    { return CopyStep{Dst: a, Src: b, Swap: true} }

// copyPair is `destination, source`, in the order the caller wrote them.
type copyPair struct{ dst, src int }

// sequentialize orders the pairs so that nothing is lost on the way.  `borrowed`
// of -1 means there is no register free to hold a value for a step.
func sequentialize(moves []copyPair, borrowed int) []CopyStep {
	// pending keeps its insertion order, because which one is picked when only
	// cycles are left has to be the same every run.
	var order []int
	pending := map[int]int{}
	for _, m := range moves {
		if m.dst == m.src {
			continue
		}
		if _, twice := pending[m.dst]; twice {
			panic("a parallel copy writes a register twice")
		}
		pending[m.dst] = m.src
		order = append(order, m.dst)
	}

	drop := func(dst int) {
		delete(pending, dst)
		for at, d := range order {
			if d == dst {
				order = append(order[:at], order[at+1:]...)
				return
			}
		}
	}

	// moved says the value that was in `was` is in `now`; whoever wanted it looks
	// there instead.
	moved := func(was, now int) {
		for _, dst := range append([]int(nil), order...) {
			if pending[dst] != was {
				continue
			}
			if dst == now {
				drop(dst) // the swap already put it where it belongs
			} else {
				pending[dst] = now
			}
		}
	}

	var done []CopyStep
	for len(pending) > 0 {
		sources := map[int]bool{}
		for _, src := range pending {
			sources[src] = true
		}
		var ready []int
		for _, dst := range order {
			if !sources[dst] {
				ready = append(ready, dst)
			}
		}
		if len(ready) > 0 {
			for _, dst := range ready {
				done = append(done, mov(dst, pending[dst]))
				drop(dst)
			}
			continue
		}
		stuck := order[0]
		if borrowed >= 0 {
			done = append(done, mov(borrowed, stuck))
			moved(stuck, borrowed)
			continue
		}
		// Swapping satisfies `stuck` outright and leaves its old value where the
		// other end was, so everything still to read it reads there instead.
		other := pending[stuck]
		drop(stuck)
		done = append(done, swap(stuck, other))
		moved(stuck, other)
	}
	return done
}
