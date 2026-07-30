"""Register allocation on SSA.

The interference graph of an SSA program is chordal, and a perfect elimination
order for it is a preorder walk of the dominator tree.  So there is no graph
here, and no simplify/select stack: colouring a function is one walk, in
dominance order, holding the set of values that are live and giving every
definition a colour none of them has.  If `k` registers are enough — if no
program point has more than `k` values live — this always succeeds.

When it does not succeed, a value is spilled to a frame slot and the whole
thing is done again.  Spilling rewrites the function and keeps it in SSA: a
store after the single definition, and a reload in front of every use, each
reload being a new definition of its own.

Two more things fall out of the walk:

* Coalescing.  A definition prefers a colour already given to a value it is
  copy-related to — a phi and its arguments — so that the copy the phi becomes
  is a register moving to itself, which the emitter drops.
* The call convention.  A value that is live across a call may only be given a
  callee-saved register, which is what makes the caller's live values survive
  a `bl` without anything being saved around it.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from wolv import ir, liveness, ssa

# x16 and x17 are the ABI's intra-procedure-call scratch registers; the
# emitter uses them for parallel copies and large immediates, so they are not
# allocatable.  x18 is the platform register, x29 the frame pointer, x30 the
# link register.
CALLER_SAVED: tuple[int, ...] = (9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8)
CALLEE_SAVED: tuple[int, ...] = (19, 20, 21, 22, 23, 24, 25, 26, 27, 28)
ARGUMENT_REGS: tuple[int, ...] = (0, 1, 2, 3, 4, 5, 6, 7)
SCRATCH: tuple[int, int] = (16, 17)


class SpillNeeded(Exception):
    """Raised inside the walk when a definition has no colour left to take."""

    def __init__(self, live: set[ir.Reg]) -> None:
        super().__init__("out of registers")
        self.live = live


class OutOfRegisters(Exception):
    """Raised when spilling cannot help either."""


@dataclass(slots=True)
class Registers:
    caller: tuple[int, ...] = CALLER_SAVED
    callee: tuple[int, ...] = CALLEE_SAVED

    @property
    def anywhere(self) -> tuple[int, ...]:
        return self.caller + self.callee

    def count(self) -> int:
        return len(self.caller) + len(self.callee)


def limited(max_regs: int) -> Registers:
    """A smaller machine, so that the spiller can be tested on small programs."""
    callee = CALLEE_SAVED[: max(2, max_regs // 2)]
    caller = CALLER_SAVED[: max(1, max_regs - len(callee))]
    return Registers(caller, callee)


def allocate(func: ir.Func, regs: Registers | None = None) -> None:
    """Give every register in `func` a colour, spilling until they fit."""
    machine = regs or Registers()
    spilled: set[ir.Reg] = set()
    while True:
        ir.recompute_preds(func)
        live = liveness.analyse(func)
        across = liveness.across_calls(func, live)
        try:
            func.colours = _Colouring(func, live, across, machine).run()
        except SpillNeeded as need:
            victim = _choose_victim(func, need.live, spilled)
            spilled.add(victim)
            spilled |= spill(func, victim)
            continue
        func.saved = sorted(set(func.colours.values()) & set(CALLEE_SAVED))
        return


def allocate_module(mod: ir.Module, regs: Registers | None = None) -> None:
    for func in mod.funcs:
        allocate(func, regs)


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


# -- spilling -----------------------------------------------------------------


def _choose_victim(func: ir.Func, live: set[ir.Reg], spilled: set[ir.Reg]) -> ir.Reg:
    """Spill the value that is used least — reloads are what spilling costs.

    A value that is itself a reload is never chosen: spilling one of those
    would only produce another reload of the same thing, and the loop would
    not end.  When there is nothing else left, the instruction wants more
    registers at once than the machine has, and that is worth saying.
    """
    counts: dict[ir.Reg, int] = {}
    for block in func.walk():
        for phi in block.phis:
            for arg in phi.args.values():
                counts[arg] = counts.get(arg, 0) + 1
        for instr in block.instrs:
            for r in ir.uses(instr):
                counts[r] = counts.get(r, 0) + 1
    candidates = [r for r in live if r not in spilled]
    if not candidates:
        raise OutOfRegisters(
            f"`{func.name}` needs more registers at once than the machine has"
        )
    return min(candidates, key=lambda r: (counts.get(r, 0), r))


def _instead_of(old: ir.Reg, new: ir.Reg) -> Callable[[ir.Reg], ir.Reg]:
    return lambda r: new if r == old else r


def spill(func: ir.Func, victim: ir.Reg) -> set[ir.Reg]:
    """Give `victim` a frame slot: one store at its definition, reloads at uses.

    The function stays in SSA.  Every reload is a definition of its own, used
    once, right where it is needed, and the returned set names them so that
    they are never spilled again.
    """
    slot = func.new_slot()
    func.spill_slots[victim] = slot
    is_param = victim in func.params
    reloads: set[ir.Reg] = set()

    for block in func.walk():
        if any(phi.dst == victim for phi in block.phis):
            block.instrs.insert(0, ir.StoreSlot(slot, victim))
        if is_param and block.label == func.entry:
            block.instrs.insert(0, ir.StoreSlot(slot, victim))

        rebuilt: list[ir.Instr] = []
        for instr in block.instrs:
            spill_store = isinstance(instr, ir.StoreSlot) and instr.slot == slot
            if victim in ir.uses(instr) and not spill_store:
                fresh = func.new_reg()
                reloads.add(fresh)
                rebuilt.append(ir.LoadSlot(fresh, slot))
                ir.map_uses(instr, _instead_of(victim, fresh))
            rebuilt.append(instr)
            if ir.defs(instr) == victim:
                rebuilt.append(ir.StoreSlot(slot, victim))
        block.instrs = rebuilt

    for block in func.walk():
        for phi in block.phis:
            for pred, arg in list(phi.args.items()):
                if arg != victim:
                    continue
                source = func.blocks[pred]
                fresh = func.new_reg()
                reloads.add(fresh)
                source.instrs.insert(len(source.instrs) - 1, ir.LoadSlot(fresh, slot))
                phi.args[pred] = fresh
    return reloads


# -- checking the result ------------------------------------------------------


def verify(func: ir.Func) -> None:
    """No two values live at the same point may share a colour."""
    live = liveness.analyse(func)
    for block in func.walk():
        alive = set(live.live_in[block.label])
        _no_clash(func, alive, block.label)
        for phi in block.phis:
            alive.add(phi.dst)
            _no_clash(func, alive, block.label)
        for instr in block.instrs:
            d = ir.defs(instr)
            for r in ir.uses(instr):
                assert r in func.colours, f"%{r} has no colour"
            if d is not None:
                assert d in func.colours, f"%{d} has no colour"
        out = set(live.live_out[block.label])
        _no_clash(func, out, block.label)


def _no_clash(func: ir.Func, alive: set[ir.Reg], where: str) -> None:
    seen: dict[int, ir.Reg] = {}
    for r in alive:
        colour = func.colours.get(r)
        if colour is None:
            continue
        other = seen.get(colour)
        assert other is None, f"x{colour} holds %{r} and %{other} at once in {where}"
        seen[colour] = r
