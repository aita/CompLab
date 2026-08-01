// Register allocation by graph colouring, with iterated coalescing.
//
// The idea is Chaitin's: build a graph whose nodes are values and whose edges join
// values that are live at the same time, then colour it with as many colours as the
// machine has registers.  Colouring a graph is hard in general, but Kempe's
// observation makes it practical: a node with fewer than K neighbours can always be
// coloured whatever happens to the rest of the graph.  So remove such nodes one at a
// time and push them on a stack; when the graph is empty, pop the stack and give
// each node a colour its neighbours have not taken.  If every remaining node has K
// or more neighbours, guess that one of them will not get a colour and carry on — if
// the guess was wrong the value is rewritten to live in memory and the whole thing
// runs again (Briggs' optimistic colouring).
//
// On top of that sits coalescing, which is why leaving SSA first costs nothing.
// Leaving SSA fills the predecessors of every join with copies; coalescing merges
// the two ends of a copy so that it disappears.  Merging aggressively can make a
// graph uncolourable, so a merge only happens when Briggs' test proves it cannot:
// the merged node must have fewer than K neighbours of significant degree.  That
// test is only exact enough to be useful if degrees are up to date, and simplifying
// lowers degrees while merging raises them — so the two run interleaved, with
// freezing (giving up on a copy so its nodes can be simplified) as the way out when
// neither applies.  Hence "iterated" (George and Appel, 1996).
//
// This machine has no fixed registers to colour against, so the calling convention
// is carried as a set of colours each node may not take: a value live across a call
// may not take a caller-saved one.  A node with `f` forbidden colours and `d`
// neighbours needs `d + f < K` to be trivially colourable, so that sum is what
// stands in for the degree everywhere below.

package main

import "sort"

// allocate colours `f`, rewriting and starting again for as long as it spills.
func allocate(f *Func, machine Registers) error {
	protected := regSet{}
	for {
		recomputePreds(f)
		c := newColouring(f, machine, protected)
		spilled := c.run()
		if len(spilled) == 0 {
			f.Colours = c.colour
			var saved []int
			seen := map[int]bool{}
			for _, colour := range c.colour {
				if isCalleeSaved(colour) && !seen[colour] {
					seen[colour] = true
					saved = append(saved, colour)
				}
			}
			sort.Ints(saved)
			f.Saved = saved
			return nil
		}
		for _, victim := range spilled.sorted() {
			if protected.has(victim) {
				return &outOfRegisters{
					msg: "`" + f.Name + "` needs more registers at once than the machine has",
				}
			}
			protected.union(spill(f, victim))
		}
	}
}

type moveEdge struct{ dst, src Reg }

type colouring struct {
	fn      *Func
	machine Registers
	// protected holds values a previous round produced by reloading something.
	// Their live ranges are a load and its one use, so spilling one again would
	// only make another of the same, and the rewriting would never end.
	protected regSet

	adjacent  map[Reg]regSet
	degree    map[Reg]int
	forbidden map[Reg]map[int]bool
	preferred map[Reg]int

	moves         []moveEdge
	movesOf       map[Reg]map[int]bool
	worklistMoves map[int]bool
	activeMoves   map[int]bool

	simplifyWorklist regSet
	freezeWorklist   regSet
	spillWorklist    regSet
	selectStack      []Reg
	onStack          regSet
	coalesced        regSet
	alias            map[Reg]Reg
	colour           map[Reg]int
}

func newColouring(f *Func, machine Registers, protected regSet) *colouring {
	return &colouring{
		fn: f, machine: machine, protected: protected,
		adjacent: map[Reg]regSet{}, degree: map[Reg]int{},
		forbidden: map[Reg]map[int]bool{}, preferred: map[Reg]int{},
		movesOf: map[Reg]map[int]bool{}, worklistMoves: map[int]bool{},
		activeMoves:      map[int]bool{},
		simplifyWorklist: regSet{}, freezeWorklist: regSet{}, spillWorklist: regSet{},
		onStack: regSet{}, coalesced: regSet{},
		alias: map[Reg]Reg{}, colour: map[Reg]int{},
	}
}

func (c *colouring) k() int { return c.machine.count() }

func (c *colouring) run() regSet {
	c.build()
	c.makeWorklists()
	for len(c.simplifyWorklist) > 0 || len(c.worklistMoves) > 0 ||
		len(c.freezeWorklist) > 0 || len(c.spillWorklist) > 0 {
		switch {
		case len(c.simplifyWorklist) > 0:
			c.simplify()
		case len(c.worklistMoves) > 0:
			c.coalesce()
		case len(c.freezeWorklist) > 0:
			c.freeze()
		default:
			c.selectSpill()
		}
	}
	return c.assignColours()
}

// -- the graph ---------------------------------------------------------------

func (c *colouring) node(r Reg) {
	if _, seen := c.adjacent[r]; !seen {
		c.adjacent[r] = regSet{}
		c.degree[r] = 0
		c.forbidden[r] = map[int]bool{}
	}
}

func (c *colouring) addEdge(a, b Reg) {
	if a == b || c.adjacent[a].has(b) {
		return
	}
	c.adjacent[a].add(b)
	c.adjacent[b].add(a)
	c.degree[a]++
	c.degree[b]++
}

// weight is the degree, counting a forbidden colour as a neighbour holding it.
func (c *colouring) weight(r Reg) int { return c.degree[r] + len(c.forbidden[r]) }

func (c *colouring) build() {
	c.preferred = preferences(c.fn)
	live := analyse(c.fn)
	for _, b := range c.fn.walk() {
		for _, instr := range b.Instrs {
			for _, r := range instr.uses() {
				c.node(r)
			}
			if d := instr.defs(); d != noReg {
				c.node(d)
			}
		}
	}
	for _, r := range c.fn.Params {
		c.node(r)
	}

	for _, b := range c.fn.walk() {
		alive := live.liveOut[b.Label].clone()
		for at := len(b.Instrs) - 1; at >= 0; at-- {
			instr := b.Instrs[at]
			if m, isMove := instr.(*Move); isMove {
				alive.remove(m.Src)
				index := len(c.moves)
				c.moves = append(c.moves, moveEdge{dst: m.Dst, src: m.Src})
				c.noteMove(m.Dst, index)
				c.noteMove(m.Src, index)
				c.worklistMoves[index] = true
			}
			defined := instr.defs()
			if defined != noReg {
				alive.add(defined)
				for other := range alive {
					c.addEdge(defined, other)
				}
			}
			if _, isCall := instr.(*Call); isCall {
				for r := range alive {
					if r == defined {
						continue
					}
					for _, colour := range c.machine.caller {
						c.forbidden[r][colour] = true
					}
				}
			}
			if defined != noReg {
				alive.remove(defined)
			}
			alive.addAll(instr.uses())
		}
		if b.Label == c.fn.Entry {
			c.entryEdges(alive)
		}
	}
}

func (c *colouring) noteMove(r Reg, index int) {
	if c.movesOf[r] == nil {
		c.movesOf[r] = map[int]bool{}
	}
	c.movesOf[r][index] = true
}

// entryEdges: parameters arrive together, so they interfere with each other.
func (c *colouring) entryEdges(alive regSet) {
	for at, param := range c.fn.Params {
		for other := range alive {
			c.addEdge(param, other)
		}
		for _, another := range c.fn.Params[at+1:] {
			c.addEdge(param, another)
		}
	}
}

// -- the worklists -----------------------------------------------------------

func (c *colouring) makeWorklists() {
	nodes := make([]Reg, 0, len(c.adjacent))
	for r := range c.adjacent {
		nodes = append(nodes, r)
	}
	sort.Slice(nodes, func(i, j int) bool { return nodes[i] < nodes[j] })
	for _, r := range nodes {
		switch {
		case c.weight(r) >= c.k():
			c.spillWorklist.add(r)
		case c.moveRelated(r):
			c.freezeWorklist.add(r)
		default:
			c.simplifyWorklist.add(r)
		}
	}
}

func (c *colouring) nodeMoves(r Reg) []int {
	var out []int
	for index := range c.movesOf[r] {
		if c.activeMoves[index] || c.worklistMoves[index] {
			out = append(out, index)
		}
	}
	sort.Ints(out)
	return out
}

func (c *colouring) moveRelated(r Reg) bool { return len(c.nodeMoves(r)) > 0 }

func (c *colouring) neighbours(r Reg) []Reg {
	var out []Reg
	for other := range c.adjacent[r] {
		if !c.onStack.has(other) && !c.coalesced.has(other) {
			out = append(out, other)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func least(set regSet) Reg {
	best := noReg
	for r := range set {
		if best == noReg || r < best {
			best = r
		}
	}
	return best
}

func (c *colouring) simplify() {
	r := least(c.simplifyWorklist)
	c.simplifyWorklist.remove(r)
	c.selectStack = append(c.selectStack, r)
	c.onStack.add(r)
	for _, other := range c.neighbours(r) {
		c.decrementDegree(other)
	}
}

func (c *colouring) decrementDegree(r Reg) {
	was := c.weight(r)
	c.degree[r]--
	if was != c.k() {
		return
	}
	// It has just become trivially colourable, so the copies around it may have
	// become safe to merge as well.
	c.enableMoves(append(c.neighbours(r), r))
	c.spillWorklist.remove(r)
	if c.moveRelated(r) {
		c.freezeWorklist.add(r)
	} else {
		c.simplifyWorklist.add(r)
	}
}

func (c *colouring) enableMoves(nodes []Reg) {
	for _, r := range nodes {
		for _, index := range c.nodeMoves(r) {
			if c.activeMoves[index] {
				delete(c.activeMoves, index)
				c.worklistMoves[index] = true
			}
		}
	}
}

// -- coalescing --------------------------------------------------------------

func (c *colouring) getAlias(r Reg) Reg {
	for c.coalesced.has(r) {
		r = c.alias[r]
	}
	return r
}

func leastMove(set map[int]bool) int {
	best := -1
	for index := range set {
		if best < 0 || index < best {
			best = index
		}
	}
	return best
}

func (c *colouring) coalesce() {
	index := leastMove(c.worklistMoves)
	move := c.moves[index]
	delete(c.worklistMoves, index)
	u, v := c.getAlias(move.dst), c.getAlias(move.src)
	switch {
	case u == v:
		c.addToWorklist(u)
	case c.adjacent[u].has(v):
		c.addToWorklist(u)
		c.addToWorklist(v)
	case c.conservative(u, v):
		c.combine(u, v)
		c.addToWorklist(u)
	default:
		c.activeMoves[index] = true
	}
}

func (c *colouring) addToWorklist(r Reg) {
	if c.weight(r) < c.k() && !c.moveRelated(r) {
		c.freezeWorklist.remove(r)
		c.simplifyWorklist.add(r)
	}
}

// conservative is Briggs' test: the merged node must have fewer than K significant
// neighbours.  The colours the two ends may not take add up as well, and a colour
// the merged node is barred from is one more thing standing in its way.
func (c *colouring) conservative(u, v Reg) bool {
	together := regSet{}
	together.addAll(c.neighbours(u))
	together.addAll(c.neighbours(v))
	barred := map[int]bool{}
	for colour := range c.forbidden[u] {
		barred[colour] = true
	}
	for colour := range c.forbidden[v] {
		barred[colour] = true
	}
	significant := 0
	for r := range together {
		if c.weight(r) >= c.k() {
			significant++
		}
	}
	return significant+len(barred) < c.k()
}

func (c *colouring) combine(u, v Reg) {
	c.freezeWorklist.remove(v)
	c.spillWorklist.remove(v)
	c.coalesced.add(v)
	c.alias[v] = u
	if c.movesOf[u] == nil {
		c.movesOf[u] = map[int]bool{}
	}
	for index := range c.movesOf[v] {
		c.movesOf[u][index] = true
	}
	for colour := range c.forbidden[v] {
		c.forbidden[u][colour] = true
	}
	if _, wants := c.preferred[v]; wants {
		if _, taken := c.preferred[u]; !taken {
			c.preferred[u] = c.preferred[v]
		}
	}
	c.enableMoves([]Reg{v})
	for _, other := range c.neighbours(v) {
		c.addEdge(other, u)
		c.decrementDegree(other)
	}
	if c.weight(u) >= c.k() && c.freezeWorklist.has(u) {
		c.freezeWorklist.remove(u)
		c.spillWorklist.add(u)
	}
}

// -- freezing and spilling ----------------------------------------------------

func (c *colouring) freeze() {
	r := least(c.freezeWorklist)
	c.freezeWorklist.remove(r)
	c.simplifyWorklist.add(r)
	c.freezeMoves(r)
}

func (c *colouring) freezeMoves(r Reg) {
	for _, index := range c.nodeMoves(r) {
		move := c.moves[index]
		delete(c.activeMoves, index)
		delete(c.worklistMoves, index)
		end := move.dst
		if c.getAlias(move.dst) == c.getAlias(r) {
			end = move.src
		}
		other := c.getAlias(end)
		if !c.moveRelated(other) && c.weight(other) < c.k() {
			c.freezeWorklist.remove(other)
			c.simplifyWorklist.add(other)
		}
	}
}

// selectSpill guesses that the value with the most neighbours per use will not fit.
//
// Never a reload, though: those are cheap by that measure precisely because they
// were made cheap, and choosing one would undo the last round's work instead of the
// pressure.
func (c *colouring) selectSpill() {
	weights := spillCosts(c.fn)
	var among []Reg
	for _, r := range c.spillWorklist.sorted() {
		if !c.protected.has(r) {
			among = append(among, r)
		}
	}
	if len(among) == 0 {
		among = c.spillWorklist.sorted()
	}
	chosen := among[0]
	best := float64(c.weight(chosen)) / (weights[chosen] + 1.0)
	for _, r := range among[1:] {
		if score := float64(c.weight(r)) / (weights[r] + 1.0); score > best {
			chosen, best = r, score
		}
	}
	c.spillWorklist.remove(chosen)
	c.simplifyWorklist.add(chosen)
	c.freezeMoves(chosen)
}

// -- handing out the colours --------------------------------------------------

func (c *colouring) assignColours() regSet {
	spilled := regSet{}
	for len(c.selectStack) > 0 {
		r := c.selectStack[len(c.selectStack)-1]
		c.selectStack = c.selectStack[:len(c.selectStack)-1]
		c.onStack.remove(r)
		taken := map[int]bool{}
		for other := range c.adjacent[r] {
			if colour, has := c.colour[c.getAlias(other)]; has {
				taken[colour] = true
			}
		}
		var free []int
		for _, colour := range c.machine.anywhere() {
			if !taken[colour] && !c.forbidden[r][colour] {
				free = append(free, colour)
			}
		}
		if len(free) == 0 {
			spilled.add(r)
			continue
		}
		chosen := free[0]
		if want, wants := c.preferred[r]; wants {
			for _, colour := range free {
				if colour == want {
					chosen = want
					break
				}
			}
		}
		c.colour[r] = chosen
	}
	for _, r := range c.coalesced.sorted() {
		if colour, has := c.colour[c.getAlias(r)]; has {
			c.colour[r] = colour
		} else {
			c.colour[r] = c.machine.anywhere()[0]
		}
	}
	return spilled
}
