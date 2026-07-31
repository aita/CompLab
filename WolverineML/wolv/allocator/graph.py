"""Register allocation by graph colouring, with iterated coalescing.

The idea is Chaitin's: build a graph whose nodes are values and whose edges
join values that are live at the same time, then colour it with as many colours
as the machine has registers.  Colouring a graph is hard in general, but
Kempe's observation makes it practical: a node with fewer than K neighbours can
always be coloured whatever happens to the rest of the graph.  So remove such
nodes one at a time and push them on a stack; when the graph is empty, pop the
stack and give each node a colour its neighbours have not taken.  If every
remaining node has K or more neighbours, guess that one of them will not get a
colour and carry on -- if the guess was wrong the value is rewritten to live in
memory and the whole thing runs again (Briggs' optimistic colouring).

On top of that sits coalescing, which is why this allocator is here at all.
Leaving SSA fills the predecessors of every join with copies; coalescing merges
the two ends of a copy so that it disappears.  Merging aggressively can make a
graph uncolourable, so a merge only happens when Briggs' test proves it cannot:
the merged node must have fewer than K neighbours of significant degree.  That
test is only exact enough to be useful if degrees are up to date, and
simplifying lowers degrees while merging raises them -- so the two run
interleaved, with freezing (giving up on a copy so its nodes can be simplified)
as the way out when neither applies.  Hence "iterated" (George and Appel, 1996).

This machine has no fixed registers to colour against, so the calling
convention is carried as a set of colours each node may not take: a value live
across a call may not take a caller-saved one.  A node with `f` forbidden
colours and `d` neighbours needs `d + f < K` to be trivially colourable, so
that sum is what stands in for the degree everywhere below.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from wolv import ir, liveness
from wolv.allocator.spill import OutOfRegisters, costs, spill
from wolv.machine import ARGUMENT_REGS, CALLEE_SAVED, Registers


def allocate(func: ir.Func, machine: Registers) -> None:
    """Colour `func`, rewriting and starting again for as long as it spills."""
    protected: set[ir.Reg] = set()
    while True:
        ir.recompute_preds(func)
        colouring = _Colouring(func, machine, protected)
        spilled = colouring.run()
        if not spilled:
            func.colours = colouring.colour
            func.saved = sorted(set(func.colours.values()) & set(CALLEE_SAVED))
            return
        for victim in sorted(spilled):
            if victim in protected:
                raise OutOfRegisters(
                    f"`{func.name}` needs more registers at once than the machine has"
                )
            protected |= spill(func, victim)


@dataclass(slots=True)
class _Move:
    dst: ir.Reg
    src: ir.Reg


@dataclass(slots=True)
class _Colouring:
    func: ir.Func
    machine: Registers
    # Values that a previous round produced by reloading something.  Their live
    # ranges are a load and its one use, so spilling one again would only make
    # another of the same, and the rewriting would never end.
    protected: set[ir.Reg] = field(default_factory=set)

    adjacent: dict[ir.Reg, set[ir.Reg]] = field(default_factory=dict)
    degree: dict[ir.Reg, int] = field(default_factory=dict)
    forbidden: dict[ir.Reg, set[int]] = field(default_factory=dict)
    preferred: dict[ir.Reg, int] = field(default_factory=dict)

    moves: list[_Move] = field(default_factory=list)
    moves_of: dict[ir.Reg, set[int]] = field(default_factory=dict)
    worklist_moves: set[int] = field(default_factory=set)
    active_moves: set[int] = field(default_factory=set)
    coalesced_moves: set[int] = field(default_factory=set)

    simplify_worklist: set[ir.Reg] = field(default_factory=set)
    freeze_worklist: set[ir.Reg] = field(default_factory=set)
    spill_worklist: set[ir.Reg] = field(default_factory=set)
    select_stack: list[ir.Reg] = field(default_factory=list)
    on_stack: set[ir.Reg] = field(default_factory=set)
    coalesced: set[ir.Reg] = field(default_factory=set)
    alias: dict[ir.Reg, ir.Reg] = field(default_factory=dict)
    colour: dict[ir.Reg, int] = field(default_factory=dict)

    @property
    def k(self) -> int:
        return self.machine.count()

    def run(self) -> set[ir.Reg]:
        self.build()
        self.make_worklists()
        while self.simplify_worklist or self.worklist_moves or (
            self.freeze_worklist or self.spill_worklist
        ):
            if self.simplify_worklist:
                self.simplify()
            elif self.worklist_moves:
                self.coalesce()
            elif self.freeze_worklist:
                self.freeze()
            else:
                self.select_spill()
        return self.assign_colours()

    # -- the graph --------------------------------------------------------

    def node(self, r: ir.Reg) -> None:
        self.adjacent.setdefault(r, set())
        self.degree.setdefault(r, 0)
        self.forbidden.setdefault(r, set())

    def add_edge(self, a: ir.Reg, b: ir.Reg) -> None:
        if a == b or b in self.adjacent[a]:
            return
        self.adjacent[a].add(b)
        self.adjacent[b].add(a)
        self.degree[a] += 1
        self.degree[b] += 1

    def weight(self, r: ir.Reg) -> int:
        """The degree, counting a forbidden colour as a neighbour holding it."""
        return self.degree[r] + len(self.forbidden[r])

    def build(self) -> None:
        live = liveness.analyse(self.func)
        caller_saved = set(self.machine.caller)
        for block in self.func.walk():
            for instr in block.instrs:
                for r in [*instr.uses(), instr.defs()]:
                    if r is not None:
                        self.node(r)
        for r in self.func.params:
            self.node(r)

        for block in self.func.walk():
            alive = set(live.live_out[block.label])
            for instr in reversed(block.instrs):
                if isinstance(instr, ir.Move):
                    alive.discard(instr.src)
                    index = len(self.moves)
                    self.moves.append(_Move(instr.dst, instr.src))
                    self.moves_of.setdefault(instr.dst, set()).add(index)
                    self.moves_of.setdefault(instr.src, set()).add(index)
                    self.worklist_moves.add(index)
                defined = instr.defs()
                if defined is not None:
                    alive.add(defined)
                    for other in alive:
                        self.add_edge(defined, other)
                if isinstance(instr, ir.Call):
                    for r in alive:
                        if r != defined:
                            self.forbidden[r] |= caller_saved
                    self.ABI_hints(instr)
                if defined is not None:
                    alive.discard(defined)
                alive |= set(instr.uses())
                if isinstance(instr, ir.Ret) and instr.value is not None:
                    self.preferred[instr.value] = ARGUMENT_REGS[0]
            if block.label == self.func.entry:
                self.entry_edges(alive)

    def ABI_hints(self, call: ir.Call) -> None:
        for i, arg in enumerate(call.args):
            if i < len(ARGUMENT_REGS):
                self.preferred[arg] = ARGUMENT_REGS[i]
        if call.dst is not None:
            self.preferred[call.dst] = ARGUMENT_REGS[0]

    def entry_edges(self, alive: set[ir.Reg]) -> None:
        """Parameters arrive together, so they interfere with each other."""
        for i, param in enumerate(self.func.params):
            if i < len(ARGUMENT_REGS):
                self.preferred[param] = ARGUMENT_REGS[i]
            for other in alive:
                self.add_edge(param, other)
            for another in self.func.params[i + 1 :]:
                self.add_edge(param, another)

    # -- the worklists ----------------------------------------------------

    def make_worklists(self) -> None:
        for r in sorted(self.adjacent):
            if self.weight(r) >= self.k:
                self.spill_worklist.add(r)
            elif self.move_related(r):
                self.freeze_worklist.add(r)
            else:
                self.simplify_worklist.add(r)

    def node_moves(self, r: ir.Reg) -> set[int]:
        return self.moves_of.get(r, set()) & (self.active_moves | self.worklist_moves)

    def move_related(self, r: ir.Reg) -> bool:
        return bool(self.node_moves(r))

    def neighbours(self, r: ir.Reg) -> set[ir.Reg]:
        return self.adjacent[r] - self.on_stack - self.coalesced

    def simplify(self) -> None:
        r = min(self.simplify_worklist)
        self.simplify_worklist.discard(r)
        self.select_stack.append(r)
        self.on_stack.add(r)
        for other in sorted(self.neighbours(r)):
            self.decrement_degree(other)

    def decrement_degree(self, r: ir.Reg) -> None:
        was = self.weight(r)
        self.degree[r] -= 1
        if was != self.k:
            return
        # It has just become trivially colourable, so the copies around it may
        # have become safe to merge as well.
        self.enable_moves({r, *self.neighbours(r)})
        self.spill_worklist.discard(r)
        if self.move_related(r):
            self.freeze_worklist.add(r)
        else:
            self.simplify_worklist.add(r)

    def enable_moves(self, nodes: set[ir.Reg]) -> None:
        for r in nodes:
            for index in list(self.node_moves(r)):
                if index in self.active_moves:
                    self.active_moves.discard(index)
                    self.worklist_moves.add(index)

    # -- coalescing -------------------------------------------------------

    def get_alias(self, r: ir.Reg) -> ir.Reg:
        while r in self.coalesced:
            r = self.alias[r]
        return r

    def coalesce(self) -> None:
        index = min(self.worklist_moves)
        move = self.moves[index]
        self.worklist_moves.discard(index)
        u, v = self.get_alias(move.dst), self.get_alias(move.src)
        if u == v:
            self.coalesced_moves.add(index)
            self.add_to_worklist(u)
        elif v in self.adjacent[u]:
            self.add_to_worklist(u)
            self.add_to_worklist(v)
        elif self.conservative(u, v):
            self.coalesced_moves.add(index)
            self.combine(u, v)
            self.add_to_worklist(u)
        else:
            self.active_moves.add(index)

    def add_to_worklist(self, r: ir.Reg) -> None:
        if self.weight(r) < self.k and not self.move_related(r):
            self.freeze_worklist.discard(r)
            self.simplify_worklist.add(r)

    def conservative(self, u: ir.Reg, v: ir.Reg) -> bool:
        """Briggs: the merged node must have fewer than K significant neighbours.

        The colours the two ends may not take add up as well, and a colour the
        merged node is barred from is one more thing standing in its way.
        """
        together = self.neighbours(u) | self.neighbours(v)
        barred = len(self.forbidden[u] | self.forbidden[v])
        significant = sum(1 for r in together if self.weight(r) >= self.k)
        return significant + barred < self.k

    def combine(self, u: ir.Reg, v: ir.Reg) -> None:
        self.freeze_worklist.discard(v)
        self.spill_worklist.discard(v)
        self.coalesced.add(v)
        self.alias[v] = u
        self.moves_of.setdefault(u, set())
        self.moves_of[u] |= self.moves_of.get(v, set())
        self.forbidden[u] |= self.forbidden[v]
        if v in self.preferred and u not in self.preferred:
            self.preferred[u] = self.preferred[v]
        self.enable_moves({v})
        for other in sorted(self.neighbours(v)):
            self.add_edge(other, u)
            self.decrement_degree(other)
        if self.weight(u) >= self.k and u in self.freeze_worklist:
            self.freeze_worklist.discard(u)
            self.spill_worklist.add(u)

    # -- freezing and spilling --------------------------------------------

    def freeze(self) -> None:
        r = min(self.freeze_worklist)
        self.freeze_worklist.discard(r)
        self.simplify_worklist.add(r)
        self.freeze_moves(r)

    def freeze_moves(self, r: ir.Reg) -> None:
        for index in list(self.node_moves(r)):
            move = self.moves[index]
            self.active_moves.discard(index)
            self.worklist_moves.discard(index)
            other = self.get_alias(
                move.src if self.get_alias(move.dst) == self.get_alias(r) else move.dst
            )
            if not self.move_related(other) and self.weight(other) < self.k:
                self.freeze_worklist.discard(other)
                self.simplify_worklist.add(other)

    def select_spill(self) -> None:
        """Guess that the value with the most neighbours per use will not fit.

        Never a reload, though: those are cheap by that measure precisely
        because they were made cheap, and choosing one would undo the last
        round's work instead of the pressure.
        """
        weights = costs(self.func)
        among = sorted(self.spill_worklist - self.protected) or sorted(
            self.spill_worklist
        )
        chosen = max(
            among, key=lambda r: self.weight(r) / (weights.get(r, 0.0) + 1.0)
        )
        self.spill_worklist.discard(chosen)
        self.simplify_worklist.add(chosen)
        self.freeze_moves(chosen)

    # -- handing out the colours ------------------------------------------

    def assign_colours(self) -> set[ir.Reg]:
        spilled: set[ir.Reg] = set()
        while self.select_stack:
            r = self.select_stack.pop()
            self.on_stack.discard(r)
            taken = {
                self.colour[a]
                for a in (self.get_alias(n) for n in self.adjacent[r])
                if a in self.colour
            }
            free = [
                c
                for c in self.machine.anywhere
                if c not in taken and c not in self.forbidden[r]
            ]
            if not free:
                spilled.add(r)
                continue
            want = self.preferred.get(r)
            self.colour[r] = want if want in free else free[0]
        for r in sorted(self.coalesced):
            self.colour[r] = self.colour.get(self.get_alias(r), self.machine.anywhere[0])
        return spilled

    def copies_left(self) -> int:
        """How many of the copies coalescing did not get rid of."""
        return sum(
            1
            for i, move in enumerate(self.moves)
            if i not in self.coalesced_moves
            and self.colour.get(move.dst) != self.colour.get(move.src)
        )
