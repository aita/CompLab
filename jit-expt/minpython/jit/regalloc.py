"""Linear-scan register allocation (Poletto & Sarkar), shared by both function
compilers.

The tracing JIT (`tracing.py`) allocates over a trace's SSA values; the method
JIT (`method.py`) allocates over a function's VM registers. They differ only in
how the live intervals are built -- from a linear SSA trace vs. from a function's
control-flow graph -- so each builds its own `Interval` list and hands it here.
This module is just the scan itself, with no knowledge of either value space.
"""

from __future__ import annotations

from typing import NamedTuple

from jit import Reg


class Spill:
    """A value that lives in a stack/buffer slot rather than a register."""
    __slots__ = ("index",)

    def __init__(self, index: int):
        self.index = index

    def __repr__(self) -> str:
        return f"Spill({self.index})"


class Interval(NamedTuple):
    """A value's live range `[start, end]` and the key it belongs to. Ordered
    start-first so a plain `sort()` yields the linear-scan visitation order."""
    start: int
    end: int
    key: int


class Active(NamedTuple):
    """A value currently holding a register: its interval end and its key.
    Ordered end-first so `sort()` keeps the active set by increasing end."""
    end: int
    key: int


Loc = Reg | Spill


def linear_scan(intervals: list[Interval], pool: list[Reg]
                ) -> tuple[dict[int, Loc], list[Reg], int]:
    """Assign each interval's key a register from `pool` or a spill slot. Returns
    (location per key, the pool registers actually used, the spill-slot count).

    Expiry uses `<=`, so a value whose last use is at some instruction may hand
    its register to that instruction's result -- which is what lets codegen emit
    the two-address, in-place form."""
    loc: dict[int, Loc] = {}
    free = list(pool)
    active: list[Active] = []            # kept sorted by interval end
    used: set[Reg] = set()
    n_spill = 0

    def spill_slot() -> int:
        nonlocal n_spill
        n_spill += 1
        return n_spill - 1

    for start, end, key in sorted(intervals):
        # Expire intervals that ended before this one starts; reclaim their regs.
        keep: list[Active] = []
        for a in active:
            if a.end <= start:
                r = loc[a.key]
                if isinstance(r, Reg):
                    free.append(r)
            else:
                keep.append(a)
        active = keep

        if free:
            reg = free.pop()
            loc[key] = reg
            used.add(reg)
            active.append(Active(end, key))
        else:
            # No register: spill whichever of us reaches furthest.
            active.sort()
            furthest = active[-1]
            if furthest.end > end:
                loc[key] = loc[furthest.key]     # steal its register
                loc[furthest.key] = Spill(spill_slot())
                active[-1] = Active(end, key)
            else:
                loc[key] = Spill(spill_slot())
        active.sort()
    return loc, sorted(used, key=int), n_spill
