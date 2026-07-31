"""Colouring in dominance order, on SSA.

The interference graph of an SSA program is chordal, and a perfect elimination
order for it is a preorder walk of the dominator tree.  So there is no graph
here, and no simplify/select stack: colouring a function is one walk, in
dominance order, holding the set of values that are live and giving every
definition a colour none of them has.  If `k` registers are enough — if no
program point has more than `k` values live — this always succeeds.

Why the graph is chordal is one theorem away.  A definition dominates its whole
live range, so a live range is a subtree of the dominator tree, and a graph is
chordal exactly when it is the intersection graph of subtrees of a tree
(Gavril).  The allocator is Hack, Grund and Goos (CC 2006).

When the walk does not succeed, a value is spilled and the whole thing is done
again.  Two more things fall out of the walk:

* Coalescing.  A definition prefers a colour already given to a value it is
  copy-related to — a phi and its arguments — so that the copy the phi becomes
  is a register moving to itself, which the emitter drops.  This is the weak
  point of the approach: merging two values, which is what a graph-colouring
  allocator does to remove a copy, is exactly what SSA forbids.
* The call convention.  A value that is live across a call may only be given a
  callee-saved register, which is what makes the caller's live values survive
  a `bl` without anything being saved around it.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from wolv import ir, liveness, ssa
from wolv.allocator.spill import choose_victim, spill
from wolv.machine import ARGUMENT_REGS, CALLEE_SAVED, Registers


class SpillNeeded(Exception):
    """Raised inside the walk when a definition has no colour left to take."""

    def __init__(self, live: set[ir.Reg]) -> None:
        super().__init__("out of registers")
        self.live = live


def allocate(func: ir.Func, machine: Registers) -> None:
    """Give every register in `func` a colour, spilling until they fit."""
    spilled: set[ir.Reg] = set()
    while True:
        ir.recompute_preds(func)
        live = liveness.analyse(func)
        across = liveness.across_calls(func, live)
        try:
            func.colours = _Colouring(func, live, across, machine).run()
        except SpillNeeded as need:
            victim = choose_victim(func, need.live, spilled)
            spilled.add(victim)
            spilled |= spill(func, victim)
            continue
        func.saved = sorted(set(func.colours.values()) & set(CALLEE_SAVED))
        return


# -- the colouring walk -------------------------------------------------------


@dataclass(slots=True)
class _Colouring:
    func: ir.Func
    live: liveness.Liveness
    across: set[ir.Reg]
    machine: Registers
    colours: dict[ir.Reg, int] = field(default_factory=dict)
    hints: dict[ir.Reg, list[ir.Reg]] = field(default_factory=dict)
    preferred: dict[ir.Reg, int] = field(default_factory=dict)

    def run(self) -> dict[ir.Reg, int]:
        self._collect_hints()
        dom = ssa.dominance(self.func)
        params: set[ir.Reg] = set()
        for reg in self.func.params:
            self._assign(reg, params)
            params.add(reg)
        for label in _preorder(dom, self.func.entry):
            self._block(label)
        return self.colours

    def _collect_hints(self) -> None:
        """Copy-related values want one colour; the ABI says which one."""
        for i, param in enumerate(self.func.params):
            if i < len(ARGUMENT_REGS):
                self.preferred[param] = ARGUMENT_REGS[i]
        for block in self.func.walk():
            for phi in block.phis:
                for arg in phi.args.values():
                    self.hints.setdefault(phi.dst, []).append(arg)
                    self.hints.setdefault(arg, []).append(phi.dst)
            for instr in block.instrs:
                match instr:
                    case ir.Move(dst, src):
                        self.hints.setdefault(dst, []).append(src)
                        self.hints.setdefault(src, []).append(dst)
                    case ir.Call(dst, _, args):
                        for i, arg in enumerate(args):
                            if i < len(ARGUMENT_REGS):
                                self.preferred[arg] = ARGUMENT_REGS[i]
                        if dst is not None:
                            self.preferred[dst] = ARGUMENT_REGS[0]
                    case ir.Ret(value) if value is not None:
                        self.preferred[value] = ARGUMENT_REGS[0]

    def _block(self, label: str) -> None:
        block = self.func.blocks[label]
        alive = set(self.live.live_in[label])
        for phi in block.phis:
            self._assign(phi.dst, alive)
            alive.add(phi.dst)
        last_use: dict[ir.Reg, int] = {}
        for i, instr in enumerate(block.instrs):
            for r in ir.uses(instr):
                last_use[r] = i
        out = self.live.live_out[label]
        for i, instr in enumerate(block.instrs):
            for r in ir.uses(instr):
                if last_use[r] == i and r not in out:
                    alive.discard(r)
            d = ir.defs(instr)
            if d is not None:
                self._assign(d, alive)
                alive.add(d)

    def _assign(self, reg: ir.Reg, alive: set[ir.Reg]) -> None:
        if reg in self.colours:
            return
        taken = {self.colours[r] for r in alive if r in self.colours}
        allowed = (
            self.machine.callee if reg in self.across else self.machine.anywhere
        )
        want = self.preferred.get(reg)
        if want is not None and want not in taken and want in allowed:
            self.colours[reg] = want
            return
        for hint in self.hints.get(reg, []):
            # A hint that has no colour yet still knows what it would like, and
            # taking that now is what removes the copy in the other direction.
            colour = self.colours.get(hint, self.preferred.get(hint))
            if colour is not None and colour not in taken and colour in allowed:
                self.colours[reg] = colour
                return
        for colour in allowed:
            if colour not in taken:
                self.colours[reg] = colour
                return
        raise SpillNeeded(alive | {reg})


def _preorder(dom: ssa.Dominance, entry: str) -> list[str]:
    order: list[str] = []
    stack = [entry]
    while stack:
        label = stack.pop()
        order.append(label)
        stack.extend(reversed(dom.children[label]))
    return order
