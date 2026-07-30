"""Liveness on SSA.

The only subtlety is the phi.  A phi does not read its arguments where it
stands; it reads them on the edges, so an argument is live at the end of the
predecessor it is paired with and not anywhere inside the block that holds the
phi.  Getting that wrong is what makes phi-related values interfere when they
should not.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from wolv import ir


@dataclass(slots=True)
class Liveness:
    live_in: dict[str, set[ir.Reg]] = field(default_factory=dict)
    live_out: dict[str, set[ir.Reg]] = field(default_factory=dict)


def analyse(func: ir.Func) -> Liveness:
    upward: dict[str, set[ir.Reg]] = {}
    killed: dict[str, set[ir.Reg]] = {}
    for block in func.walk():
        use: set[ir.Reg] = set()
        kill: set[ir.Reg] = set()
        for phi in block.phis:
            kill.add(phi.dst)
        for instr in block.instrs:
            for r in ir.uses(instr):
                if r not in kill:
                    use.add(r)
            d = ir.defs(instr)
            if d is not None:
                kill.add(d)
        upward[block.label] = use
        killed[block.label] = kill

    live = Liveness()
    for label in func.blocks:
        live.live_in[label] = set()
        live.live_out[label] = set()

    order = list(reversed(ir.rpo(func)))
    changed = True
    while changed:
        changed = False
        for label in order:
            block = func.blocks[label]
            out: set[ir.Reg] = set()
            for succ in block.succs:
                out |= live.live_in[succ]
                for phi in func.blocks[succ].phis:
                    arg = phi.args.get(label)
                    if arg is not None:
                        out.add(arg)
            new_in = upward[label] | (out - killed[label])
            if out != live.live_out[label] or new_in != live.live_in[label]:
                live.live_out[label] = out
                live.live_in[label] = new_in
                changed = True
    return live


def across_calls(func: ir.Func, live: Liveness) -> set[ir.Reg]:
    """Values that are live across a call, and so cannot sit in a scratch register."""
    out: set[ir.Reg] = set()
    for block in func.walk():
        after = set(live.live_out[block.label])
        for instr in reversed(block.instrs):
            d = ir.defs(instr)
            if d is not None:
                after.discard(d)
            if isinstance(instr, ir.Call):
                out |= after
            after.update(ir.uses(instr))
    return out


def pressure(func: ir.Func, live: Liveness) -> int:
    """The most values live at any one point — the registers the function wants."""
    most = 0
    for block in func.walk():
        after = set(live.live_out[block.label])
        most = max(most, len(after))
        for instr in reversed(block.instrs):
            d = ir.defs(instr)
            if d is not None:
                after.discard(d)
            after.update(ir.uses(instr))
            most = max(most, len(after))
        entry = set(live.live_in[block.label]) | {p.dst for p in block.phis}
        most = max(most, len(entry))
    return most
