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
    """No two values that hold different things at once may share a colour.

    The check is made where the interference graph joins values -- at each
    definition, and at the top of a block for the phis and the parameters,
    which define several at once.  Looking at a whole live set instead would be
    wrong, not merely slower: both ends of a copy are live after it and hold the
    same value, so they may share a register, and that is the entire point of
    coalescing.  A verifier that rejected it would reject every program the
    coalescer had done its job on.

    Every value that interferes with another is caught this way, because the
    later of the two definitions that put the values there happens while the
    other is live.
    """
    live = liveness.analyse(func)
    for block in func.walk():
        alive = set(live.live_out[block.label])
        for instr in reversed(block.instrs):
            if isinstance(instr, ir.Move):
                alive.discard(instr.src)
            for r in instr.uses():
                assert r in func.colours, f"%{r} has no colour"
            d = instr.defs()
            if d is not None:
                assert d in func.colours, f"%{d} has no colour"
                alive.add(d)
                _no_clash(func, alive, d, block.label)
                alive.discard(d)
            alive |= set(instr.uses())

        entering = set(live.live_in[block.label])
        for phi in block.phis:
            assert phi.dst in func.colours, f"%{phi.dst} has no colour"
            entering.add(phi.dst)
            _no_clash(func, entering, phi.dst, block.label)
        if block.label == func.entry:
            for param in func.params:
                entering.add(param)
                _no_clash(func, entering, param, block.label)


def _no_clash(func: ir.Func, alive: set[ir.Reg], written: ir.Reg, where: str) -> None:
    """Nothing else live here may hold the colour `written` was just given."""
    colour = func.colours.get(written)
    if colour is None:
        return
    for other in sorted(alive):
        if other == written or func.colours.get(other) != colour:
            continue
        raise AssertionError(
            f"x{colour} holds %{written} and %{other} at once in {where}"
        )
