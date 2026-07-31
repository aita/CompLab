"""Two register allocators, and the seam they are chosen through.

They agree about everything except how a colour is decided:

    chordal   colours the SSA program itself, walking the dominator tree,
              because the interference graph of an SSA program is chordal and
              that walk is a perfect elimination order for it.  No graph.
    graph     leaves SSA first and then does what Chaitin's algorithm does:
              build the interference graph, simplify it, and colour what comes
              off the stack -- with iterated coalescing, which is what the
              copies that leaving SSA produced are there to be eaten by.

Both spill the same way and answer to the same verifier, so a program compiled
either way has to print the same thing.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from wolv import ir, liveness
from wolv.allocator import chordal, graph
from wolv.allocator.spill import OutOfRegisters
from wolv.registers import Registers

__all__ = [
    "ALLOCATORS",
    "Allocator",
    "OutOfRegisters",
    "Registers",
    "allocate_module",
    "verify",
]


@dataclass(frozen=True, slots=True)
class Allocator:
    name: str
    blurb: str
    on_ssa: bool
    run: Callable[[ir.Func, Registers], None]


ALLOCATORS: dict[str, Allocator] = {
    "chordal": Allocator(
        "chordal",
        "colour the SSA in dominance order, no graph",
        on_ssa=True,
        run=chordal.allocate,
    ),
    "graph": Allocator(
        "graph",
        "leave SSA, then graph colouring with iterated coalescing",
        on_ssa=False,
        run=graph.allocate,
    ),
}

DEFAULT = "chordal"


def allocate_module(
    mod: ir.Module,
    allocator: Allocator | None = None,
    machine: Registers | None = None,
) -> None:
    chosen = allocator or ALLOCATORS[DEFAULT]
    for func in mod.funcs:
        chosen.run(func, machine or Registers())


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
            for r in instr.uses():
                assert r in func.colours, f"%{r} has no colour"
            d = instr.defs()
            if d is not None:
                assert d in func.colours, f"%{d} has no colour"
        _no_clash(func, set(live.live_out[block.label]), block.label)


def _no_clash(func: ir.Func, alive: set[ir.Reg], where: str) -> None:
    seen: dict[int, ir.Reg] = {}
    for r in sorted(alive):
        colour = func.colours.get(r)
        if colour is None:
            continue
        other = seen.get(colour)
        assert other is None, f"x{colour} holds %{r} and %{other} at once in {where}"
        seen[colour] = r
