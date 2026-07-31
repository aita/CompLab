"""Which colour a value would like, which is the calling convention asking.

Neither allocator has to satisfy these — a preference is dropped the moment it
clashes with something the colouring actually requires — but taking one when it
is free is what stops the emitter having to move a value into `x2` on the way
into a call, or out of `x0` on the way back from one.

Both allocators want the same answers, so they ask here.  What differs between
them is what they do when a preference cannot be met, not what the preference
was.
"""

from __future__ import annotations

from wolv import ir
from wolv.registers import ARGUMENT_REGS


def preferences(func: ir.Func) -> dict[ir.Reg, int]:
    """The register each value is about to be wanted in, where there is one."""
    wanted: dict[ir.Reg, int] = {}
    for i, param in enumerate(func.params):
        if i < len(ARGUMENT_REGS):
            wanted[param] = ARGUMENT_REGS[i]
    for block in func.walk():
        for instr in block.instrs:
            match instr:
                case ir.Call(dst, _, args):
                    for i, arg in enumerate(args[: len(ARGUMENT_REGS)]):
                        wanted[arg] = ARGUMENT_REGS[i]
                    if dst is not None:
                        wanted[dst] = ARGUMENT_REGS[0]
                case ir.Ret(value) if value is not None:
                    wanted[value] = ARGUMENT_REGS[0]
    return wanted
