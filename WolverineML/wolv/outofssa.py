"""Leaving SSA before allocation.

A phi is a copy that happens on an edge, so it becomes copies at the end of
each predecessor.  Critical edges are already split, so a predecessor of a
block with phis has nowhere else to go and the copies can simply be appended.

The copies of one edge happen at once: every argument is read before any
destination is written.  Usually that needs no care, because a phi's
destination is defined nowhere else and so is nobody's argument — but a block
that is its own predecessor can have two phis that swap, and then the copies go
through temporaries, which is Sreedhar's answer and which coalescing is
expected to remove again.

The graph-colouring allocator wants this; the dominance-order one does not,
because it colours the phis themselves and lets the emitter put the copies on
the edges afterwards.
"""

from __future__ import annotations

from wolv import ir


def destruct(func: ir.Func) -> None:
    """Replace every phi in `func` with copies in its predecessors."""
    for block in func.walk():
        if not block.phis:
            continue
        for pred in block.preds:
            source = func.blocks[pred]
            assert len(source.succs) == 1, f"{pred} -> {block.label} is a critical edge"
            _copy_in_parallel(
                func, source, [(phi.dst, phi.args[pred]) for phi in block.phis]
            )
        block.phis = []
    ir.recompute_preds(func)


def destruct_module(mod: ir.Module) -> None:
    for func in mod.funcs:
        destruct(func)


def _copy_in_parallel(
    func: ir.Func, block: ir.Block, moves: list[tuple[ir.Reg, ir.Reg]]
) -> None:
    real = [(dst, src) for dst, src in moves if dst != src]
    if not real:
        return
    written = {dst for dst, _ in real}
    read = {src for _, src in real}
    copies: list[ir.Instr] = []
    if written & read:
        through = {dst: func.new_reg() for dst, _ in real}
        copies += [ir.Move(through[dst], src) for dst, src in real]
        copies += [ir.Move(dst, through[dst]) for dst, _ in real]
    else:
        copies += [ir.Move(dst, src) for dst, src in real]
    at = len(block.instrs) - 1
    block.instrs[at:at] = copies
