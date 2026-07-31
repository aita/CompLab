"""Doing several copies at once, one at a time.

A phi is a copy that happens on an edge, and all the phis of a block happen
together: every argument is read before any destination is written.  Once the
allocator has given both ends real registers that is a permutation, and putting
a permutation into a sequence of instructions is this module.

Copies whose destination nobody else has still to read can go first.  When only
cycles are left, something has to be got out of the way, and there are two ways
to do it: a register the function never used can hold a value for one step, and
if there is no such register the two ends of the cycle swap.  A swap is three
`eor`s and needs nothing to borrow, which is why no register is reserved for
this anywhere in the compiler.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Mov:
    dst: int
    src: int


@dataclass(frozen=True, slots=True)
class Swap:
    a: int
    b: int


type Step = Mov | Swap


def sequentialize(moves: list[tuple[int, int]], borrowed: int | None) -> list[Step]:
    """Order `(destination, source)` pairs so that nothing is lost on the way."""
    real = [(dst, src) for dst, src in moves if dst != src]
    pending = dict(real)
    assert len(pending) == len(real), "a parallel copy writes a register twice"
    done: list[Step] = []
    while pending:
        sources = set(pending.values())
        ready = [dst for dst in pending if dst not in sources]
        if ready:
            for dst in ready:
                done.append(Mov(dst, pending.pop(dst)))
            continue
        stuck = next(iter(pending))
        if borrowed is not None:
            done.append(Mov(borrowed, stuck))
            _moved(pending, stuck, borrowed)
            continue
        # Swapping satisfies `stuck` outright and leaves its old value where the
        # other end was, so everything still to read it reads there instead.
        other = pending.pop(stuck)
        done.append(Swap(stuck, other))
        _moved(pending, stuck, other)
    return done


def _moved(pending: dict[int, int], was: int, now: int) -> None:
    """The value that was in `was` is in `now`; whoever wanted it looks there."""
    for dst, src in list(pending.items()):
        if src == was:
            if dst == now:
                del pending[dst]  # the swap already put it where it belongs
            else:
                pending[dst] = now
