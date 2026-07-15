from __future__ import annotations


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

    def __repr__(self):
        return self.name

    def __add__(self, disp: int) -> Mem:
        return Mem(self, disp)

    def __sub__(self, disp: int) -> Mem:
        return Mem(self, -disp)


class Mem:
    """A memory operand of the form [base + disp]."""

    def __init__(self, base: Reg, disp: int = 0):
        self.base = base
        self.disp = disp

    def __repr__(self):
        return f"[{self.base!r}{self.disp:+d}]"


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


__all__ = ["Reg", "Mem", *_R64, *_R32, *_R16, *_R8, "AH", "CH", "DH", "BH"]
