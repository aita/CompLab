"""The machine IR: what instruction selection replaces the arithmetic with.

One class, because on this machine an instruction is a form, a register it
writes and some it reads.  The form names an entry in the table below, and the
table is the whole instruction set the compiler can choose from.

The machine IR is this plus the part of `ir.py` that was already machine-level:
a call, a move, a frame slot, a phi and the three terminators.  What it may no
longer contain is the arithmetic — `Const`, `Bin`, `Cmp`, `Load`, `Store`,
`StrConst` — and `verify` is what says so, because a compiler that quietly kept
an abstract instruction until the emitter would only find out there.

Four forms are not one instruction each, and the emitter expands them:

    const   a constant, which is a `mov` or up to four `movz`/`movk`
    adr     the address of a string, which is `adrp` and an `add`
    ldr     a load, whose addressing mode depends on how far the offset reaches
    str     a store, likewise
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Final

from wolv import ir

# How each form is written down, once the registers have their colours.  `d` is
# the register written and `s0`, `s1`, `s2` the ones read.
FORMS: Final[dict[str, str]] = {
    "add": "add {d}, {s0}, {s1}",
    "addi": "add {d}, {s0}, #{imm}",
    "adds": "add {d}, {s0}, {s1}, lsl #{imm}",
    "sub": "sub {d}, {s0}, {s1}",
    "subi": "sub {d}, {s0}, #{imm}",
    "subs": "sub {d}, {s0}, {s1}, lsl #{imm}",
    "mul": "mul {d}, {s0}, {s1}",
    "madd": "madd {d}, {s0}, {s1}, {s2}",
    "msub": "msub {d}, {s0}, {s1}, {s2}",
    "sdiv": "sdiv {d}, {s0}, {s1}",
    "and": "and {d}, {s0}, {s1}",
    "orr": "orr {d}, {s0}, {s1}",
    "eor": "eor {d}, {s0}, {s1}",
    "eori": "eor {d}, {s0}, #{imm}",
    "lsl": "lsl {d}, {s0}, {s1}",
    "lsli": "lsl {d}, {s0}, #{imm}",
    "asr": "asr {d}, {s0}, {s1}",
    "asri": "asr {d}, {s0}, #{imm}",
    "cmp": "cmp {s0}, {s1}",
    "cmpi": "cmp {s0}, #{imm}",
    "cset": "cset {d}, {sym}",
}

# Which condition code each comparison sets, and which one says the opposite --
# the emitter needs the opposite when the branch it is writing falls through to
# the block the comparison was true for.
CONDITION: Final[dict[str, str]] = {
    "=": "eq",
    "<>": "ne",
    "<": "lt",
    "<=": "le",
    ">": "gt",
    ">=": "ge",
    "u<": "lo",
    "u>=": "hs",
}

OPPOSITE: Final[dict[str, str]] = {
    "eq": "ne", "ne": "eq", "lt": "ge", "ge": "lt",
    "gt": "le", "le": "gt", "lo": "hs", "hs": "lo",
}  # fmt: skip

# The ones the emitter writes itself, because they are not one instruction.
EXPANDED: Final[frozenset[str]] = frozenset({"const", "adr", "ldr", "str"})


@dataclass(slots=True)
class Mach(ir.Instr):
    form: str
    dst: ir.Reg | None
    srcs: list[ir.Reg]
    imm: int = 0
    symbol: str = ""
    effect: bool = False

    def defs(self) -> ir.Reg | None:
        return self.dst

    def uses(self) -> list[ir.Reg]:
        return list(self.srcs)

    def map_uses(self, f: ir.Rewrite) -> None:
        self.srcs = [f(s) for s in self.srcs]

    def set_def(self, r: ir.Reg) -> None:
        self.dst = r

    def has_effect(self) -> bool:
        return self.effect

    def show(self, name: ir.Name) -> str:
        operands = [name(s) for s in self.srcs]
        if self.symbol:
            operands.append(self.symbol)
        elif self.imm or self.form == "const":
            operands.append(f"#{self.imm}")
        written = f"{self.form} {', '.join(operands)}".rstrip()
        return written if self.dst is None else f"{name(self.dst)} = {written}"


ABSTRACT: Final[tuple[type[ir.Instr], ...]] = (
    ir.Const,
    ir.StrConst,
    ir.Bin,
    ir.Cmp,
    ir.Load,
    ir.Store,
)


def verify(func: ir.Func) -> None:
    """Insist that selection left nothing of the three-address IR behind."""
    for block in func.walk():
        for instr in block.instrs:
            assert not isinstance(instr, ABSTRACT), (
                f"{type(instr).__name__} survived selection in "
                f"{func.name}:{block.label}"
            )
            if isinstance(instr, Mach):
                assert instr.form in FORMS or instr.form in EXPANDED, (
                    f"no such instruction as `{instr.form}`"
                )


def verify_module(mod: ir.Module) -> None:
    for func in mod.funcs:
        verify(func)
