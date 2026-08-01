package main

import "testing"

func perform(steps []CopyStep, registers map[int]string) map[int]string {
	state := map[int]string{}
	for r, v := range registers {
		state[r] = v
	}
	for _, step := range steps {
		if step.Swap {
			state[step.Dst], state[step.Src] = state[step.Src], state[step.Dst]
			continue
		}
		state[step.Dst] = state[step.Src]
	}
	return state
}

// runCopy runs a parallel copy on a register file and insists it did what it said.
func runCopy(t *testing.T, moves []copyPair, borrowed int) []CopyStep {
	t.Helper()
	registers := map[int]string{}
	for r := 0; r < 32; r++ {
		registers[r] = "v" + string(rune('0'+r%10))
	}
	steps := sequentialize(moves, borrowed)
	after := perform(steps, registers)
	for _, m := range moves {
		if after[m.dst] != registers[m.src] {
			t.Errorf("x%d holds %s, should hold what x%d had (%s)",
				m.dst, after[m.dst], m.src, registers[m.src])
		}
	}
	return steps
}

func allMoves(steps []CopyStep) bool {
	for _, s := range steps {
		if s.Swap {
			return false
		}
	}
	return true
}

func allSwaps(steps []CopyStep) bool {
	for _, s := range steps {
		if !s.Swap {
			return false
		}
	}
	return true
}

func TestACopyWithNoCycleIsJustMoves(t *testing.T) {
	steps := runCopy(t, []copyPair{{1, 2}, {3, 4}, {5, 5}}, 9)
	if !allMoves(steps) || len(steps) != 2 {
		t.Errorf("got %v", steps)
	}
}

func TestAChainIsOrderedSoNothingIsLost(t *testing.T) {
	runCopy(t, []copyPair{{1, 2}, {2, 3}, {3, 4}}, 9)
}

func TestACycleBorrowsARegisterWhenThereIsOne(t *testing.T) {
	steps := runCopy(t, []copyPair{{1, 2}, {2, 1}}, 9)
	if !allMoves(steps) {
		t.Fatalf("got %v", steps)
	}
	borrowed := false
	for _, s := range steps {
		if s.Dst == 9 {
			borrowed = true
		}
	}
	if !borrowed {
		t.Error("nothing was borrowed")
	}
}

func TestACycleSwapsWhenThereIsNothingToBorrow(t *testing.T) {
	steps := runCopy(t, []copyPair{{1, 2}, {2, 1}}, -1)
	if len(steps) != 1 || !steps[0].Swap {
		t.Errorf("got %v", steps)
	}
}

func TestALongerCycleSwapsItsWayRound(t *testing.T) {
	steps := runCopy(t, []copyPair{{1, 2}, {2, 3}, {3, 1}}, -1)
	if !allSwaps(steps) || len(steps) != 2 {
		t.Errorf("got %v", steps)
	}
}

func TestTwoCyclesAtOnce(t *testing.T) {
	runCopy(t, []copyPair{{1, 2}, {2, 1}, {3, 4}, {4, 3}}, -1)
	runCopy(t, []copyPair{{1, 2}, {2, 1}, {3, 4}, {4, 3}}, 9)
}
