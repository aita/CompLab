from __future__ import annotations

import sys
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .assembler import Label


class Reg(int):
    """A register. Subclasses int so its 3/4-bit encoding number is usable
    directly in bit math, while carrying its operand size (`bitsize`) so it
    can be dispatched by type and encoded correctly.

    `high` marks the legacy high-byte registers (AH/CH/DH/BH), and
    `needs_rex` marks the 8-bit regs (SPL/BPL/SIL/DIL) that only exist when
    a REX prefix is present."""

    def __new__(cls, value: int, name: str, bitsize: int,
                high: bool = False, needs_rex: bool = False):
        obj = super().__new__(cls, value)
        obj.name = name
        obj.bitsize = bitsize
        obj.high = high
        obj.needs_rex = needs_rex
        return obj

    def __repr__(self) -> str:
        return self.name

    def __mul__(self, scale: int) -> Index:
        return Index(self, scale)

    def __add__(self, other: Index | Reg | int) -> Mem:
        # base + disp / base + index / base + index*scale
        if isinstance(other, Index):
            return Mem(self, index=other.reg, scale=other.scale)
        if isinstance(other, Reg):
            return Mem(self, index=other)
        return Mem(self, disp=other)

    def __sub__(self, disp: int) -> Mem:
        return Mem(self, disp=-disp)


class Xmm(int):
    """An XMM register (XMM0..XMM15) holding SSE scalar/packed data. A DISTINCT
    type from Reg (not a subclass) so instruction dispatch can require an XMM
    where the SSE encodings do and reject a general-purpose register. Subclasses
    int so its 0..15 encoding number is usable directly in REX/ModR/M bit math;
    XMM8..15 set REX.R/REX.B just like R8..15."""

    def __new__(cls, value: int, name: str):
        obj = super().__new__(cls, value)
        obj.name = name
        obj.bitsize = 128
        return obj

    def __repr__(self) -> str:
        return self.name


class Index:
    """An `index * scale` term, produced by `reg * scale` and folded into a
    Mem's SIB byte."""

    def __init__(self, reg: Reg, scale: int):
        self.reg = reg
        self.scale = scale


class Mem:
    """A memory operand of the form [base + index*scale + disp].

    `bitsize` is the access width. It stays None when a register operand
    already fixes the size (e.g. `mov rax, [rdi]`); it must be set via the
    byte/word/dword/qword helpers when the width is otherwise ambiguous, as
    in a store of an immediate (`mov qword [rdi], 5`).

    `base` may be None for a base-less `[index*scale + disp32]` operand, whose
    absolute address is index*scale plus the (sign-extended) 32-bit disp."""

    def __init__(self, base: Reg | None, disp: int = 0,
                 index: Reg | None = None, scale: int = 1,
                 bitsize: int | None = None):
        if base is None and index is None:
            raise ValueError("a memory operand needs a base or an index register")
        if index is not None:
            if scale not in (1, 2, 4, 8):
                raise ValueError(f"invalid scale {scale}; must be 1, 2, 4, or 8")
            # SIB index field 100 means "no index", so RSP (encoding 4) has no
            # index encoding and cannot be used. (R12 shares the low 3 bits but
            # is distinguished by REX.X, so it is fine.)
            if int(index) == 4:
                raise ValueError(f"{index!r} cannot be used as an index register")
        self.base = base
        self.disp = disp
        self.index = index
        self.scale = scale
        self.bitsize = bitsize

    def __add__(self, other: Index | Reg | int) -> Mem:
        if isinstance(other, Index):
            return Mem(self.base, self.disp, other.reg, other.scale, self.bitsize)
        if isinstance(other, Reg):
            return Mem(self.base, self.disp, other, self.scale, self.bitsize)
        return Mem(self.base, self.disp + other, self.index, self.scale,
                   self.bitsize)

    def __sub__(self, disp: int) -> Mem:
        return Mem(self.base, self.disp - disp, self.index, self.scale,
                   self.bitsize)

    def sized(self, bitsize: int) -> Mem:
        return Mem(self.base, self.disp, self.index, self.scale, bitsize)

    def __repr__(self) -> str:
        s = "[" if self.base is None else f"[{self.base!r}"
        if self.index is not None:
            sep = "" if self.base is None else "+"
            s += f"{sep}{self.index!r}*{self.scale}"
        if self.disp:
            s += f"{self.disp:+d}"
        return s + "]"


class RipRel(Mem):
    """A RIP-relative reference to a Label, encoded as `[rip + disp32]`
    (ModR/M mod=00, rm=101, no SIB, no base). The disp32 is resolved to the
    label's final offset by the assembler's fixup machinery at finalize(),
    making the reference fully position-independent.

    It subclasses Mem so the instruction encoders' `case Mem()` branches accept
    it; `base`/`index` are None so no base/index register is emitted."""

    def __init__(self, label: Label, bitsize: int | None = None):
        self.label = label
        self.base = None
        self.disp = 0
        self.index = None
        self.scale = 1
        self.bitsize = bitsize

    def sized(self, bitsize: int) -> RipRel:
        return RipRel(self.label, bitsize)

    def __repr__(self) -> str:
        return f"[rip {self.label!r}]"


def rip(label: Label) -> RipRel:
    """Reference `label` RIP-relatively as a memory operand, e.g.
    `mov(RAX, rip(L))` / `lea(RAX, rip(L))`. Combine with byte/word/dword/qword
    when a store or immediate makes the access width ambiguous."""
    return RipRel(label)


def byte(mem: Mem) -> Mem:
    """Annotate a memory operand as an 8-bit access."""
    return mem.sized(8)


def word(mem: Mem) -> Mem:
    """Annotate a memory operand as a 16-bit access."""
    return mem.sized(16)


def dword(mem: Mem) -> Mem:
    """Annotate a memory operand as a 32-bit access."""
    return mem.sized(32)


def qword(mem: Mem) -> Mem:
    """Annotate a memory operand as a 64-bit access."""
    return mem.sized(64)


# Register tables, indexed by encoding number 0..15.
_R64 = ["RAX", "RCX", "RDX", "RBX", "RSP", "RBP", "RSI", "RDI",
        "R8", "R9", "R10", "R11", "R12", "R13", "R14", "R15"]
_R32 = ["EAX", "ECX", "EDX", "EBX", "ESP", "EBP", "ESI", "EDI",
        "R8D", "R9D", "R10D", "R11D", "R12D", "R13D", "R14D", "R15D"]
_R16 = ["AX", "CX", "DX", "BX", "SP", "BP", "SI", "DI",
        "R8W", "R9W", "R10W", "R11W", "R12W", "R13W", "R14W", "R15W"]
_R8 = ["AL", "CL", "DL", "BL", "SPL", "BPL", "SIL", "DIL",
       "R8B", "R9B", "R10B", "R11B", "R12B", "R13B", "R14B", "R15B"]
_R8H = {4: "AH", 5: "CH", 6: "DH", 7: "BH"}  # legacy high-byte regs


RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, \
    R8, R9, R10, R11, R12, R13, R14, R15 = \
    (Reg(code, name, 64) for code, name in enumerate(_R64))

EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI, \
    R8D, R9D, R10D, R11D, R12D, R13D, R14D, R15D = \
    (Reg(code, name, 32) for code, name in enumerate(_R32))

AX, CX, DX, BX, SP, BP, SI, DI, \
    R8W, R9W, R10W, R11W, R12W, R13W, R14W, R15W = \
    (Reg(code, name, 16) for code, name in enumerate(_R16))

# SPL/BPL/SIL/DIL (codes 4..7) require a REX prefix to be addressable.
AL, CL, DL, BL, SPL, BPL, SIL, DIL, \
    R8B, R9B, R10B, R11B, R12B, R13B, R14B, R15B = \
    (Reg(code, name, 8, needs_rex=code in (4, 5, 6, 7))
     for code, name in enumerate(_R8))

# Legacy high-byte registers.
AH, CH, DH, BH = (Reg(code, name, 8, high=True) for code, name in _R8H.items())

# XMM registers, indexed by encoding number 0..15.
_XMM = [f"XMM{i}" for i in range(16)]
XMM0, XMM1, XMM2, XMM3, XMM4, XMM5, XMM6, XMM7, \
    XMM8, XMM9, XMM10, XMM11, XMM12, XMM13, XMM14, XMM15 = \
    (Xmm(code, name) for code, name in enumerate(_XMM))


# Integer argument/return registers for the platform's C calling convention, so
# code that reads its arguments and returns a value can be written portably. The
# machine code is the same everywhere; only which registers the ABI uses differs
# -- Microsoft x64 (Windows) vs System V AMD64 (Linux/macOS). Note Windows also
# requires 32 bytes of shadow space and 16-byte stack alignment at each call.
if sys.platform == "win32":
    ARG_REGS = (RCX, RDX, R8, R9)
else:
    ARG_REGS = (RDI, RSI, RDX, RCX, R8, R9)
RET_REG = RAX

# Float/double argument/return registers (XMM), likewise platform-dependent.
if sys.platform == "win32":
    FARG_REGS = (XMM0, XMM1, XMM2, XMM3)
else:
    FARG_REGS = (XMM0, XMM1, XMM2, XMM3, XMM4, XMM5, XMM6, XMM7)
FRET_REG = XMM0


__all__ = ["Reg", "Xmm", "Mem", "rip", "byte", "word", "dword", "qword",
           "ARG_REGS", "RET_REG", "FARG_REGS", "FRET_REG",
           *_R64, *_R32, *_R16, *_R8, "AH", "CH", "DH", "BH", *_XMM]
