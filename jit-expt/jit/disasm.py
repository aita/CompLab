"""A small disassembler for the subset of x86-64 that this library's Assembler
emits, for eyeballing JIT output while debugging.

It is deliberately narrow: it decodes the encodings produced by
``jit.assembler`` (REX / ModR/M / SIB / disp / imm; the mov/alu/shift/bit
families; push/pop/call/jmp/jcc/ret/leave; setcc/cmovcc; movzx/movsx; the F2/F3/66
scalar-SSE ops; movabs and ``[rip+disp32]``) and degrades gracefully to a
``db 0xNN`` pseudo-op (advancing a single byte) on anything it does not
recognise. It is not a general-purpose x86 decoder.

Both public functions accept an ObjectCode or a raw bytes buffer.

Public API:
    disassemble(code, origin=0) -> list[Insn]   # Insn(offset, raw, text)
    disasm(code, origin=0) -> str
"""

from __future__ import annotations

from typing import TYPE_CHECKING, NamedTuple

if TYPE_CHECKING:
    from .assembler import ObjectCode


class Insn(NamedTuple):
    """One decoded instruction (or ``db`` data/fallback entry). A NamedTuple, so
    it still unpacks and indexes like the old ``(offset, raw, text)`` tuple."""

    offset: int   # byte offset from the start of the buffer
    raw: bytes    # the instruction's raw bytes
    text: str     # Intel-syntax mnemonic + operands


# --- Register name tables (lowercase for output), indexed by code 0..15 ------

_R64 = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
        "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
_R32 = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi",
        "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d"]
_R16 = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di",
        "r8w", "r9w", "r10w", "r11w", "r12w", "r13w", "r14w", "r15w"]
_R8 = ["al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil",
       "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b"]
_R8_NOREX = {4: "ah", 5: "ch", 6: "dh", 7: "bh"}  # legacy high-byte regs
_XMM = [f"xmm{i}" for i in range(16)]

_R = {64: _R64, 32: _R32, 16: _R16, 8: _R8}

# Condition-code suffixes, keyed by the low nibble of the 0F 4x/8x/9x opcodes.
_CC = {0x0: "o", 0x1: "no", 0x2: "b", 0x3: "ae", 0x4: "e", 0x5: "ne",
       0x6: "be", 0x7: "a", 0x8: "s", 0x9: "ns", 0xA: "p", 0xB: "np",
       0xC: "l", 0xD: "ge", 0xE: "le", 0xF: "g"}

# One-byte ALU family: opcode base (multiple of 8) -> mnemonic, and the
# ModR/M.reg extension digit -> mnemonic used by the immediate forms.
_ALU_BASE = {0x00: "add", 0x08: "or", 0x10: "adc", 0x18: "sbb",
             0x20: "and", 0x28: "sub", 0x30: "xor", 0x38: "cmp"}
_ALU_EXT = {0: "add", 1: "or", 2: "adc", 3: "sbb",
            4: "and", 5: "sub", 6: "xor", 7: "cmp"}

# Group-2 shift/rotate extension digit -> mnemonic.
_SHIFT_EXT = {0: "rol", 1: "ror", 2: "rcl", 3: "rcr",
              4: "shl", 5: "shr", 6: "sal", 7: "sar"}


class Trunc(Exception):
    """Raised when a decode would read past the end of the buffer."""


class Rex:
    __slots__ = ("w", "r", "x", "b", "present")

    def __init__(self, byte: int | None = None):
        if byte is None:
            self.w = self.r = self.x = self.b = 0
            self.present = False
        else:
            self.w = (byte >> 3) & 1
            self.r = (byte >> 2) & 1
            self.x = (byte >> 1) & 1
            self.b = byte & 1
            self.present = True


def _reg_name(code: int, size: int, rex_present: bool) -> str:
    if size == 8 and not rex_present and code in _R8_NOREX:
        return _R8_NOREX[code]
    return _R[size][code]


def _xmm_name(code: int) -> str:
    return _XMM[code]


def _fmt_disp(d: int) -> str:
    if d == 0:
        return ""
    if d < 0:
        return f"-0x{-d:x}"
    return f"+0x{d:x}"


def _fmt_imm(v: int) -> str:
    if v < 0:
        return f"-0x{-v:x}"
    return f"0x{v:x}"


class Decoder:
    def __init__(self, code: bytes, origin: int):
        self.code = code
        self.origin = origin
        self.pos = 0
        self.start = 0

    # -- primitive readers --------------------------------------------------

    def _u8(self) -> int:
        if self.pos >= len(self.code):
            raise Trunc()
        b = self.code[self.pos]
        self.pos += 1
        return b

    def _read(self, n: int, signed: bool) -> int:
        if self.pos + n > len(self.code):
            raise Trunc()
        v = int.from_bytes(self.code[self.pos:self.pos + n], "little",
                           signed=signed)
        self.pos += n
        return v

    def _i8(self) -> int:
        return self._read(1, True)

    def _u32(self) -> int:
        return self._read(4, False)

    def _i32(self) -> int:
        return self._read(4, True)

    # -- ModR/M + SIB + displacement ---------------------------------------

    def _modrm(self) -> tuple[int, int, int]:
        """Read a ModR/M byte and return (mod, reg3, rm3)."""
        b = self._u8()
        return b >> 6, (b >> 3) & 7, b & 7

    def _mem(self, mod: int, rm3: int, rex: Rex) -> str:
        """Decode a memory operand (mod != 3) into an address string. Assumes
        the ModR/M byte has already been consumed; reads SIB/disp as needed."""
        if rm3 == 4:  # SIB byte follows
            sib = self._u8()
            scale = 1 << (sib >> 6)
            index_code = ((sib >> 3) & 7) | (rex.x << 3)
            base3 = sib & 7
            base_code = base3 | (rex.b << 3)
            index_str = None if index_code == 4 else _R64[index_code]
            if base3 == 5 and mod == 0:  # no base, absolute disp32
                base_str = None
                disp = self._i32()
            else:
                base_str = _R64[base_code]
                disp = self._disp(mod)
            return self._join_mem(base_str, index_str, scale, disp,
                                  force_disp=base_str is None)
        if rm3 == 5 and mod == 0:  # RIP-relative
            disp = self._i32()
            return f"[rip{_fmt_disp(disp)}]"
        base_str = _R64[rm3 | (rex.b << 3)]
        disp = self._disp(mod)
        return self._join_mem(base_str, None, 1, disp)

    def _disp(self, mod: int) -> int:
        if mod == 1:
            return self._i8()
        if mod == 2:
            return self._i32()
        return 0

    @staticmethod
    def _join_mem(base: str | None, index: str | None, scale: int, disp: int,
                  force_disp: bool = False) -> str:
        inner = ""
        if base is not None:
            inner = base
        if index is not None:
            sep = "+" if inner else ""
            inner += f"{sep}{index}*{scale}"
        d = _fmt_disp(disp)
        if not d and force_disp:
            d = "+0x0"
        return f"[{inner}{d}]"

    def _rm_operand(self, mod: int, rm3: int, rex: Rex, size: int,
                    xmm: bool = False) -> str:
        """Return the r/m operand string for a register (mod==3) or memory."""
        if mod == 3:
            code = rm3 | (rex.b << 3)
            return _xmm_name(code) if xmm else _reg_name(code, size, rex.present)
        return self._mem(mod, rm3, rex)

    # -- per-instruction size -----------------------------------------------

    @staticmethod
    def _op_size(rex: Rex, has66: bool, byte8: bool) -> int:
        if byte8:
            return 8
        if rex.w:
            return 64
        if has66:
            return 16
        return 32

    # -- top-level single-instruction decode --------------------------------

    def decode_one(self) -> str | None:
        """Decode one instruction starting at self.pos. Returns text, or
        raises Trunc / returns None to signal a graceful fallback."""
        self.start = self.pos
        has66 = hasf2 = hasf3 = False
        while True:
            b = self._u8()
            if b == 0x66:
                has66 = True
            elif b == 0xF2:
                hasf2 = True
            elif b == 0xF3:
                hasf3 = True
            else:
                break
        rex = Rex()
        if 0x40 <= b <= 0x4F:
            rex = Rex(b)
            b = self._u8()

        if b == 0x0F:
            return self._decode_0f(rex, has66, hasf2, hasf3)
        return self._decode_1(b, rex, has66)

    # -- one-byte opcode map -------------------------------------------------

    def _decode_1(self, op: int, rex: Rex, has66: bool) -> str | None:
        # MOV r/m, r  and  MOV r, r/m
        if op in (0x88, 0x89, 0x8A, 0x8B):
            size = self._op_size(rex, has66, op in (0x88, 0x8A))
            mod, reg3, rm3 = self._modrm()
            rm = self._rm_operand(mod, rm3, rex, size)
            r = _reg_name(reg3 | (rex.r << 3), size, rex.present)
            if op in (0x88, 0x89):  # store: r/m <- r
                return f"mov {rm}, {r}"
            return f"mov {r}, {rm}"

        # ALU r/m,r and r,r/m
        if (op & 0xF8) in _ALU_BASE and (op & 7) in (0, 1, 2, 3):
            mn = _ALU_BASE[op & 0xF8]
            form = op & 7
            size = self._op_size(rex, has66, form in (0, 2))
            mod, reg3, rm3 = self._modrm()
            rm = self._rm_operand(mod, rm3, rex, size)
            r = _reg_name(reg3 | (rex.r << 3), size, rex.present)
            if form in (0, 1):  # r/m <- r
                return f"{mn} {rm}, {r}"
            return f"{mn} {r}, {rm}"

        # ALU with immediate: 80 (r/m8), 81 (r/m,imm32), 83 (r/m,imm8)
        if op in (0x80, 0x81, 0x83):
            size = self._op_size(rex, has66, op == 0x80)
            mod, reg3, rm3 = self._modrm()
            mn = _ALU_EXT[reg3]
            rm = self._rm_operand(mod, rm3, rex, size)
            if op == 0x80:
                imm = self._i8()
            elif op == 0x83:
                imm = self._i8()
            else:
                imm = self._read(min(size // 8, 4), True)
            return f"{mn} {rm}, {_fmt_imm(imm)}"

        # TEST r/m, r
        if op in (0x84, 0x85):
            size = self._op_size(rex, has66, op == 0x84)
            mod, reg3, rm3 = self._modrm()
            rm = self._rm_operand(mod, rm3, rex, size)
            r = _reg_name(reg3 | (rex.r << 3), size, rex.present)
            return f"test {rm}, {r}"

        # LEA
        if op == 0x8D:
            size = self._op_size(rex, has66, False)
            mod, reg3, rm3 = self._modrm()
            rm = self._rm_operand(mod, rm3, rex, size)
            r = _reg_name(reg3 | (rex.r << 3), size, rex.present)
            return f"lea {r}, {rm}"

        # MOVSXD r64, r/m32
        if op == 0x63:
            mod, reg3, rm3 = self._modrm()
            dst = _reg_name(reg3 | (rex.r << 3), 64 if rex.w else 32, rex.present)
            rm = self._rm_operand(mod, rm3, rex, 32)
            return f"movsxd {dst}, {rm}"

        # IMUL r, r/m, imm
        if op in (0x69, 0x6B):
            size = self._op_size(rex, has66, False)
            mod, reg3, rm3 = self._modrm()
            rm = self._rm_operand(mod, rm3, rex, size)
            r = _reg_name(reg3 | (rex.r << 3), size, rex.present)
            imm = self._i8() if op == 0x6B else self._read(min(size // 8, 4), True)
            return f"imul {r}, {rm}, {_fmt_imm(imm)}"

        # MOV r/m, imm (/0)
        if op in (0xC6, 0xC7):
            size = self._op_size(rex, has66, op == 0xC6)
            mod, reg3, rm3 = self._modrm()
            rm = self._rm_operand(mod, rm3, rex, size)
            imm = self._i8() if op == 0xC6 else self._read(min(size // 8, 4), True)
            return f"mov {rm}, {_fmt_imm(imm)}"

        # MOV r, imm  (B8+r; movabs with REX.W)  and MOV r8, imm8 (B0+r)
        if 0xB8 <= op <= 0xBF:
            size = self._op_size(rex, has66, False)
            code = (op - 0xB8) | (rex.b << 3)
            if size == 64:
                imm = self._read(8, False)
                return f"movabs {_reg_name(code, 64, rex.present)}, {_fmt_imm(imm)}"
            n = size // 8
            imm = self._read(n, False)
            return f"mov {_reg_name(code, size, rex.present)}, {_fmt_imm(imm)}"
        if 0xB0 <= op <= 0xB7:
            code = (op - 0xB0) | (rex.b << 3)
            imm = self._read(1, False)
            return f"mov {_reg_name(code, 8, rex.present)}, {_fmt_imm(imm)}"

        # Group 3: F6/F7  (test/not/neg/mul/imul/div/idiv)
        if op in (0xF6, 0xF7):
            size = self._op_size(rex, has66, op == 0xF6)
            mod, reg3, rm3 = self._modrm()
            rm = self._rm_operand(mod, rm3, rex, size)
            names = {0: "test", 1: "test", 2: "not", 3: "neg",
                     4: "mul", 5: "imul", 6: "div", 7: "idiv"}
            mn = names[reg3]
            if reg3 in (0, 1):  # test r/m, imm
                imm = self._i8() if op == 0xF6 else self._read(min(size // 8, 4), True)
                return f"test {rm}, {_fmt_imm(imm)}"
            return f"{mn} {rm}"

        # Group 2 shifts/rotates: C0/C1 (imm8), D2/D3 (by CL)
        if op in (0xC0, 0xC1, 0xD2, 0xD3):
            size = self._op_size(rex, has66, op in (0xC0, 0xD2))
            mod, reg3, rm3 = self._modrm()
            mn = _SHIFT_EXT[reg3]
            rm = self._rm_operand(mod, rm3, rex, size)
            if op in (0xC0, 0xC1):
                return f"{mn} {rm}, {_fmt_imm(self._i8())}"
            return f"{mn} {rm}, cl"

        # Group 5: FE/FF (inc/dec/call/jmp/push)
        if op in (0xFE, 0xFF):
            size = self._op_size(rex, has66, op == 0xFE)
            mod, reg3, rm3 = self._modrm()
            if reg3 == 0:
                return f"inc {self._rm_operand(mod, rm3, rex, size)}"
            if reg3 == 1:
                return f"dec {self._rm_operand(mod, rm3, rex, size)}"
            if reg3 == 2:  # indirect call: operand is 64-bit
                return f"call {self._rm_operand(mod, rm3, rex, 64)}"
            if reg3 == 4:
                return f"jmp {self._rm_operand(mod, rm3, rex, 64)}"
            if reg3 == 6:
                return f"push {self._rm_operand(mod, rm3, rex, 64)}"
            return None

        # PUSH/POP r64  (50+r / 58+r)
        if 0x50 <= op <= 0x57:
            return f"push {_R64[(op - 0x50) | (rex.b << 3)]}"
        if 0x58 <= op <= 0x5F:
            return f"pop {_R64[(op - 0x58) | (rex.b << 3)]}"

        # Direct rel32 jmp / call
        if op == 0xE9:
            return f"jmp {self._rel32_target()}"
        if op == 0xE8:
            return f"call {self._rel32_target()}"

        if op == 0xC3:
            return "ret"
        if op == 0xC9:
            return "leave"
        if op == 0x90:
            return "nop"
        if op == 0xCC:
            return "int3"
        if op == 0x99:
            return "cqo" if rex.w else "cdq"

        return None

    # -- two-byte (0F) opcode map -------------------------------------------

    def _decode_0f(self, rex: Rex, has66: bool, hasf2: bool, hasf3: bool) -> str | None:
        op = self._u8()

        # jcc rel32
        if 0x80 <= op <= 0x8F:
            return f"j{_CC[op & 0xF]} {self._rel32_target()}"

        # setcc r/m8
        if 0x90 <= op <= 0x9F:
            mod, reg3, rm3 = self._modrm()
            rm = self._rm_operand(mod, rm3, rex, 8)
            return f"set{_CC[op & 0xF]} {rm}"

        # cmovcc r, r/m
        if 0x40 <= op <= 0x4F:
            size = self._op_size(rex, has66, False)
            mod, reg3, rm3 = self._modrm()
            rm = self._rm_operand(mod, rm3, rex, size)
            r = _reg_name(reg3 | (rex.r << 3), size, rex.present)
            return f"cmov{_CC[op & 0xF]} {r}, {rm}"

        # IMUL r, r/m
        if op == 0xAF:
            size = self._op_size(rex, has66, False)
            mod, reg3, rm3 = self._modrm()
            rm = self._rm_operand(mod, rm3, rex, size)
            r = _reg_name(reg3 | (rex.r << 3), size, rex.present)
            return f"imul {r}, {rm}"

        # movzx / movsx
        if op in (0xB6, 0xB7, 0xBE, 0xBF):
            dsize = self._op_size(rex, has66, False)
            ssize = 8 if op in (0xB6, 0xBE) else 16
            mn = "movzx" if op in (0xB6, 0xB7) else "movsx"
            mod, reg3, rm3 = self._modrm()
            dst = _reg_name(reg3 | (rex.r << 3), dsize, rex.present)
            rm = self._rm_operand(mod, rm3, rex, ssize)
            return f"{mn} {dst}, {rm}"

        # popcnt (F3) / bsf / bsr
        if op in (0xB8, 0xBC, 0xBD):
            size = self._op_size(rex, has66, False)
            mod, reg3, rm3 = self._modrm()
            rm = self._rm_operand(mod, rm3, rex, size)
            r = _reg_name(reg3 | (rex.r << 3), size, rex.present)
            mn = {0xB8: "popcnt", 0xBC: "bsf", 0xBD: "bsr"}[op]
            return f"{mn} {r}, {rm}"

        # bt r/m, imm8  (/4)
        if op == 0xBA:
            size = self._op_size(rex, has66, False)
            mod, reg3, rm3 = self._modrm()
            rm = self._rm_operand(mod, rm3, rex, size)
            return f"bt {rm}, {_fmt_imm(self._i8())}"

        # bswap r
        if 0xC8 <= op <= 0xCF:
            size = 64 if rex.w else 32
            return f"bswap {_reg_name((op - 0xC8) | (rex.b << 3), size, rex.present)}"

        # -- scalar SSE ----------------------------------------------------
        return self._decode_sse(op, rex, has66, hasf2, hasf3)

    def _decode_sse(self, op: int, rex: Rex, has66: bool, hasf2: bool, hasf3: bool) -> str | None:
        # movss/movsd load (10) and store (11)
        if op in (0x10, 0x11):
            if hasf2:
                mn = "movsd"
            elif hasf3:
                mn = "movss"
            else:
                return None
            mod, reg3, rm3 = self._modrm()
            reg = _xmm_name(reg3 | (rex.r << 3))
            rm = self._rm_operand(mod, rm3, rex, 128, xmm=True)
            if op == 0x11:  # store: r/m <- xmm
                return f"{mn} {rm}, {reg}"
            return f"{mn} {reg}, {rm}"

        # binary/convert scalar ops distinguished by the mandatory prefix
        sd = "sd" if hasf2 else "ss"
        binops = {0x58: "add", 0x59: "mul", 0x5C: "sub", 0x5E: "div",
                  0x51: "sqrt"}
        if op in binops and (hasf2 or hasf3):
            mod, reg3, rm3 = self._modrm()
            reg = _xmm_name(reg3 | (rex.r << 3))
            rm = self._rm_operand(mod, rm3, rex, 128, xmm=True)
            return f"{binops[op]}{sd} {reg}, {rm}"

        # cvtss2sd (F3) / cvtsd2ss (F2)
        if op == 0x5A and (hasf2 or hasf3):
            mn = "cvtsd2ss" if hasf2 else "cvtss2sd"
            mod, reg3, rm3 = self._modrm()
            reg = _xmm_name(reg3 | (rex.r << 3))
            rm = self._rm_operand(mod, rm3, rex, 128, xmm=True)
            return f"{mn} {reg}, {rm}"

        # ucomis*/comis*: 66 -> double, none -> single
        if op in (0x2E, 0x2F):
            mn = ("ucomi" if op == 0x2E else "comi") + ("sd" if has66 else "ss")
            mod, reg3, rm3 = self._modrm()
            reg = _xmm_name(reg3 | (rex.r << 3))
            rm = self._rm_operand(mod, rm3, rex, 128, xmm=True)
            return f"{mn} {reg}, {rm}"

        # cvtsi2sd/ss: xmm <- gp reg/m (REX.W -> 64-bit source)
        if op == 0x2A and (hasf2 or hasf3):
            mn = "cvtsi2sd" if hasf2 else "cvtsi2ss"
            gp = 64 if rex.w else 32
            mod, reg3, rm3 = self._modrm()
            reg = _xmm_name(reg3 | (rex.r << 3))
            rm = self._rm_operand(mod, rm3, rex, gp)  # GP source
            return f"{mn} {reg}, {rm}"

        # cvttsd2si/ss: gp reg <- xmm/m
        if op == 0x2C and (hasf2 or hasf3):
            mn = "cvttsd2si" if hasf2 else "cvttss2si"
            gp = 64 if rex.w else 32
            mod, reg3, rm3 = self._modrm()
            r = _reg_name(reg3 | (rex.r << 3), gp, rex.present)
            rm = self._rm_operand(mod, rm3, rex, 128, xmm=True)
            return f"{mn} {r}, {rm}"

        return None

    def _rel32_target(self) -> int:
        rel = self._i32()
        return f"0x{self.origin + self.pos + rel:x}"


def disassemble(code: ObjectCode | bytes, origin: int = 0,
                code_size: int | None = None) -> list[Insn]:
    """Decode `code` into a list of `Insn` (offset, raw, text) rows, one per
    instruction. `offset`/target addresses are computed relative to `origin`.
    Bytes that are not part of a recognised encoding become a single-byte
    ``db 0xNN`` entry so decoding always makes forward progress.

    `code` may be an ObjectCode or a raw bytes buffer. `code_size` marks where
    the instruction section ends (e.g. ``ObjectCode.code_size``); bytes past it
    are the read-only data section and are dumped as ``db`` rather than decoded
    as instructions. Defaults to the whole buffer."""
    if hasattr(code, "code"):  # an ObjectCode
        if code_size is None:
            code_size = code.code_size
        code = code.code
    if code_size is None:
        code_size = len(code)
    dec = Decoder(code, origin)
    out: list[Insn] = []
    while dec.pos < code_size:
        start = dec.pos
        try:
            text = dec.decode_one()
        except Trunc:
            text = None
        if text is None:
            dec.pos = start + 1  # graceful fallback: one raw byte
            out.append(Insn(start, bytes(code[start:start + 1]),
                            f"db 0x{code[start]:02x}"))
        else:
            out.append(Insn(start, bytes(code[start:dec.pos]), text))
    # Remaining bytes are the data section: dump as db lines (8 bytes each).
    i = dec.pos
    while i < len(code):
        chunk = bytes(code[i:i + 8])
        text = "db " + ", ".join(f"0x{b:02x}" for b in chunk)
        out.append(Insn(i, chunk, text))
        i += len(chunk)
    return out


def disasm(code: ObjectCode | bytes, origin: int = 0,
           code_size: int | None = None) -> str:
    """Render assembled code as a multi-line dump, one instruction per line::

        0000: 48 89 d8    mov rax, rbx

    `code` may be an ObjectCode (its ``.code`` bytes are used, and its
    ``.code_size`` marks where the data section starts) or a raw bytes buffer.
    """
    if hasattr(code, "code"):  # an ObjectCode
        if code_size is None:
            code_size = code.code_size
        code = code.code
    rows = disassemble(code, origin, code_size)
    hexw = max((len(row.raw) for row in rows), default=0) * 3
    lines = []
    for row in rows:
        hexed = " ".join(f"{b:02x}" for b in row.raw)
        lines.append(f"{origin + row.offset:04x}: {hexed:<{hexw}}  {row.text}")
    return "\n".join(lines)
