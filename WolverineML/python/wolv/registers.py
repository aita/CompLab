"""What the allocators and the emitter both have to agree about: the registers.

x16 and x17 are the ABI's intra-procedure-call scratch registers, which a
linker veneer may clobber at a `bl`.  Nothing of ours is ever live across a
call in a caller-saved register, so x16 is allocatable like any other; x17 is
the one register kept back, for an address the emitter has to compute after
allocation is over.  x18 is the platform register, x29 the frame pointer, x30
the link register.
"""

from __future__ import annotations

from dataclasses import dataclass

CALLER_SAVED: tuple[int, ...] = (
    9, 10, 11, 12, 13, 14, 15, 16, 0, 1, 2, 3, 4, 5, 6, 7, 8,
)  # fmt: skip
CALLEE_SAVED: tuple[int, ...] = (19, 20, 21, 22, 23, 24, 25, 26, 27, 28)
ARGUMENT_REGS: tuple[int, ...] = (0, 1, 2, 3, 4, 5, 6, 7)
SCRATCH: tuple[int, ...] = (17,)


@dataclass(slots=True)
class Registers:
    """The machine an allocator is colouring for."""

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
