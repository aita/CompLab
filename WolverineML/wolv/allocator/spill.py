"""Spilling, which both allocators do the same way.

A spilled value gets a frame slot, a store after every definition of it and a
reload in front of every use.  The reloads are new registers, live from the
load to the instruction under it and nowhere else, which is what makes the
pressure come down.  Nothing here assumes SSA: a value written twice gets two
stores, and a phi argument is reloaded at the end of the predecessor it comes
from, so the same rewrite serves the walk and the graph.
"""

from __future__ import annotations

from collections.abc import Callable

from wolv import ir


class OutOfRegisters(Exception):
    """Raised when spilling cannot help either."""


def loop_depth(func: ir.Func) -> dict[str, int]:
    """How deeply each block is nested in loops, for weighing what a use costs.

    A back edge is an edge into a block that dominates its source; everything
    that can reach the source without leaving the dominated region is in that
    loop.
    """
    from wolv import ssa

    dom = ssa.dominance(func)
    depth = dict.fromkeys(func.blocks, 0)
    for block in func.walk():
        for succ in block.succs:
            if not dom.dominates(succ, block.label):
                continue
            body = {succ}
            stack = [block.label]
            while stack:
                label = stack.pop()
                if label in body:
                    continue
                body.add(label)
                stack.extend(func.blocks[label].preds)
            for label in body:
                depth[label] += 1
    return depth


def costs(func: ir.Func) -> dict[ir.Reg, float]:
    """What spilling a value would cost: its reads and writes, weighed by loops."""
    depth = loop_depth(func)
    weight: dict[ir.Reg, float] = {}
    for block in func.walk():
        scale = float(10 ** min(depth[block.label], 4))
        for phi in block.phis:
            for pred, arg in phi.args.items():
                weight[arg] = weight.get(arg, 0.0) + 10.0 ** min(depth[pred], 4)
            weight[phi.dst] = weight.get(phi.dst, 0.0) + scale
        for instr in block.instrs:
            for r in ir.uses(instr):
                weight[r] = weight.get(r, 0.0) + scale
            d = ir.defs(instr)
            if d is not None:
                weight[d] = weight.get(d, 0.0) + scale
    return weight


def choose_victim(
    func: ir.Func, among: set[ir.Reg], spilled: set[ir.Reg]
) -> ir.Reg:
    """Spill what is touched least — reloads are what spilling costs.

    A value that is itself a reload is never chosen: spilling one of those
    would only produce another reload of the same thing, and the loop would
    not end.  When there is nothing else left, the instruction wants more
    registers at once than the machine has, and that is worth saying.
    """
    weight = costs(func)
    candidates = [r for r in among if r not in spilled]
    if not candidates:
        raise OutOfRegisters(
            f"`{func.name}` needs more registers at once than the machine has"
        )
    return min(candidates, key=lambda r: (weight.get(r, 0.0), r))


def _instead_of(old: ir.Reg, new: ir.Reg) -> Callable[[ir.Reg], ir.Reg]:
    return lambda r: new if r == old else r


def spill(func: ir.Func, victim: ir.Reg) -> set[ir.Reg]:
    """Give `victim` a frame slot, and return the reloads that replaced it."""
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
