from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from .operands import Mem, Reg


@dataclass(frozen=True)
class Symbol:
    """A named address referenced by an instruction. `call Symbol(name)` makes
    a direct relative call to it; `mov reg, Symbol(name)` loads its absolute
    address. The address is bound by the loader (Runtime) at map time."""

    name: str


class RelocKind(Enum):
    """How a relocation's field is patched with its symbol's address."""

    ABS64 = "abs64"   # write the absolute 64-bit address (movabs immediate)
    REL32 = "rel32"   # write a signed 32-bit distance from the field's end


@dataclass(frozen=True)
class Reloc:
    """Patch the field at `offset` with `symbol`'s address, per `kind`."""

    offset: int
    symbol: str
    kind: RelocKind


@dataclass(frozen=True)
class ObjectCode:
    """Assembled machine code produced by Assembler.finalize(): the resolved
    bytes, plus any absolute relocations still needing final addresses, which
    Runtime.add() fills in from its symbol table."""

    code: bytes
    relocs: tuple[Reloc, ...] = ()


class CodeBuffer:
    """A growable buffer of emitted machine-code bytes."""

    def __init__(self, data: bytes | bytearray = b""):
        self.code = bytearray(data)

    def emit(self, byte: int):
        self.code.append(byte)

    def emit_int(self, value: int, size: int):
        self.code.extend(value.to_bytes(size, byteorder="little"))

    def patch_int(self, offset: int, value: int, size: int, *, signed: bool = False):
        """Overwrite `size` bytes at `offset` (little-endian). The counterpart
        to emit_int, used to backpatch a jump displacement once it is known."""
        self.code[offset:offset + size] = value.to_bytes(
            size, byteorder="little", signed=signed)

    def __len__(self) -> int:
        return len(self.code)


class Label:
    """A jump target. `offset` is the byte position of the label in the code,
    or None until it is bound with Assembler.bind()."""

    def __init__(self, name: str | None = None):
        self.name = name
        self.offset: int | None = None

    def __repr__(self):
        where = "unbound" if self.offset is None else f"@{self.offset}"
        return f"Label({self.name or ''} {where})"


class Assembler:
    """Encodes a small subset of x86-64 instructions into a CodeBuffer."""

    def __init__(self):
        self.code = CodeBuffer()
        self._fixups: list[tuple[int, Label]] = []  # (rel32 offset, target)
        self._relocs: list[Reloc] = []  # absolute symbol relocations

    def _emit_prefixes(self, bitsize: int, reg: Reg | None, rm: Reg | None,
                       index: Reg | None = None):
        # Operand-size prefix for 16-bit, then REX if required.
        #   reg   -> the ModR/M.reg operand (None if none, e.g. reg-imm)
        #   rm    -> the ModR/M.rm operand or the memory base
        #   index -> the SIB.index register, if any (None otherwise)
        # In 64-bit mode the default operand size is 32-bit. The 0x66
        # operand-size override prefix switches it to 16-bit (and REX.W,
        # below, switches it to 64-bit).
        if bitsize == 16:
            self.code.emit(0x66)

        # REX prefix byte:
        #     7   6   5   4   3   2   1   0
        #   +---+---+---+---+---+---+---+---+
        #   | 0 | 1 | 0 | 0 | W | R | X | B |
        #   +---+---+---+---+---+---+---+---+
        #   0100 .. fixed pattern (0x40) identifying REX
        #   W ..... 1 = 64-bit operand size
        #   R ..... high bit (bit 3) of the ModR/M.reg field
        #   X ..... high bit of the SIB.index field
        #   B ..... high bit of the ModR/M.rm / SIB.base field
        w = 1 if bitsize == 64 else 0
        r = (int(reg) >> 3) if reg is not None else 0
        x = (int(index) >> 3) if index is not None else 0
        b = (int(rm) >> 3) if rm is not None else 0
        # 8-bit SPL/BPL/SIL/DIL are only addressable when a REX prefix is
        # present, so force an (otherwise all-zero) REX for them.
        force = bitsize == 8 and (
            (reg is not None and getattr(reg, "needs_rex", False))
            or (rm is not None and getattr(rm, "needs_rex", False))
        )
        if w or r or x or b or force:
            self.code.emit(0x40 | (w << 3) | (r << 2) | (x << 1) | b)

    def _emit_modrm(self, reg_dst: int, reg_src: int):
        # ModR/M byte:
        #    7     6 5         3 2         0
        #   +-------+-----------+-----------+
        #   |  mod  |    reg    |     rm    |
        #   +-------+-----------+-----------+
        #   mod .. addressing mode; 11 = both operands are registers
        #   reg .. low 3 bits of the register operand
        #   rm .... low 3 bits of the register/memory operand
        # Reg-to-reg (mod=11): reg = source, rm = destination.
        modrm = 0xC0 | ((int(reg_src) & 7) << 3) | (int(reg_dst) & 7)
        self.code.emit(modrm)

    _SCALE_BITS = {1: 0, 2: 1, 4: 2, 8: 3}

    def _emit_modrm_mem(self, reg: int, mem: Mem):
        # A [base + index*scale + disp] memory operand is emitted as:
        #
        #   +--------+  +--------+  +------------------+
        #   | ModR/M |  |  SIB   |  |   displacement   |
        #   +--------+  +--------+  +------------------+
        #    1 byte      1 byte      0 / 1 / 4 bytes
        #    always      optional*   (see mod, below)
        #
        #   * SIB is present when there is an index register, or when the base
        #     is RSP/R12 (whose rm=100 encoding is what selects "SIB follows").
        #
        # ModR/M byte (mod selects the disp size; rm holds the base register,
        # or 100 to mean "a SIB byte follows"):
        #    7     6 5         3 2         0
        #   +-------+-----------+-----------+
        #   |  mod  |    reg    |     rm    |
        #   +-------+-----------+-----------+
        #   mod=00  no displacement
        #   mod=01  disp8   (1-byte signed)
        #   mod=10  disp32  (4-byte signed)
        reg_field = int(reg) & 7
        base = int(mem.base) & 7
        disp = mem.disp
        need_sib = mem.index is not None or base == 4  # index, or RSP/R12 base

        if disp == 0 and base != 5:  # base==5 (RBP/R13) can't use mod=00
            mod = 0x00
        elif -128 <= disp <= 127:
            mod = 0x40
        else:
            mod = 0x80

        # ModR/M:  mod(2) | reg(3) | rm(3);  rm=100 selects the SIB byte
        rm = 4 if need_sib else base
        self.code.emit(mod | (reg_field << 3) | rm)
        if need_sib:
            # SIB byte:
            #    7     6 5         3 2         0
            #   +-------+-----------+-----------+
            #   | scale |   index   |    base   |
            #   +-------+-----------+-----------+
            #   scale .. index is multiplied by 2^scale (00=1,01=2,10=4,11=8)
            #   index .. index register; 100 = none
            #   base ... base register
            if mem.index is not None:
                index = int(mem.index) & 7
                scale = self._SCALE_BITS[mem.scale]
            else:
                index = 4  # 100 = no index (plain [RSP]/[R12])
                scale = 0
            self.code.emit((scale << 6) | (index << 3) | base)
        if mod == 0x40:
            # disp8: one signed (two's-complement) byte
            #   +-----------+
            #   | disp[7:0] |
            #   +-----------+
            self.code.emit_int(disp & 0xFF, 1)
        elif mod == 0x80:
            # disp32: four signed bytes, little-endian (low byte first)
            #   +-------------+-------------+-------------+-------------+
            #   |  disp[7:0]  |  disp[15:8] | disp[23:16] | disp[31:24] |
            #   +-------------+-------------+-------------+-------------+
            #       byte 0        byte 1        byte 2        byte 3
            self.code.emit_int(disp & 0xFFFFFFFF, 4)

    @staticmethod
    def _check_sizes(a: Reg, b: Reg):
        if a.bitsize != b.bitsize:
            raise ValueError(f"operand size mismatch: {a!r} ({a.bitsize}) vs "
                             f"{b!r} ({b.bitsize})")

    @staticmethod
    def _encode_imm(imm: int, size: int) -> int:
        """Range-check `imm` for a `size`-byte immediate field and return its
        unsigned two's-complement encoding. Accepts either a signed value
        (-2**(n-1) .. 2**(n-1)-1) or an unsigned one (0 .. 2**n-1); anything
        outside that raises rather than being silently truncated."""
        bits = size * 8
        lo = -(1 << (bits - 1))
        hi = (1 << bits) - 1
        if not (lo <= imm <= hi):
            raise ValueError(f"immediate {imm} out of range for a "
                             f"{bits}-bit field [{lo}, {hi}]")
        return imm & hi

    def mov(self, dst: Reg | Mem, src: Reg | Mem | int | Symbol):
        """Move src into dst."""
        match dst, src:
            case Reg(), Symbol():
                if dst.bitsize != 64:
                    raise ValueError("a symbol address needs a 64-bit register")
                self._emit_prefixes(64, None, dst)  # REX.W movabs
                self.code.emit(0xB8 + (int(dst) & 7))  # MOV r64, imm64
                self._relocs.append(
                    Reloc(len(self.code), src.name, RelocKind.ABS64))
                self.code.emit_int(0, 8)  # 8-byte placeholder, patched at load
            case Reg(), Reg():
                self._check_sizes(dst, src)
                self._emit_prefixes(dst.bitsize, src, dst)
                self.code.emit(0x88 if dst.bitsize == 8 else 0x89)  # MOV r/m, r
                self._emit_modrm(dst, src)
            case Reg(), Mem():
                self._emit_prefixes(dst.bitsize, dst, src.base, src.index)
                self.code.emit(0x8A if dst.bitsize == 8 else 0x8B)  # MOV r, r/m
                self._emit_modrm_mem(dst, src)
            case Mem(), Reg():
                self._emit_prefixes(src.bitsize, src, dst.base, dst.index)
                self.code.emit(0x88 if src.bitsize == 8 else 0x89)  # MOV r/m, r
                self._emit_modrm_mem(src, dst)
            case Reg(), int():
                self._emit_prefixes(dst.bitsize, None, dst)
                self.code.emit((0xB0 if dst.bitsize == 8 else 0xB8) + (int(dst) & 7))
                size = dst.bitsize // 8  # full-width immediate (imm8/16/32/64)
                self.code.emit_int(self._encode_imm(src, size), size)
            case Mem(), int():
                bits = self._mem_bitsize(dst)
                self._emit_prefixes(bits, None, dst.base, dst.index)
                self.code.emit(0xC6 if bits == 8 else 0xC7)  # MOV r/m, imm (/0)
                self._emit_modrm_mem(0, dst)  # reg field = 0 (opcode extension /0)
                size = 1 if bits == 8 else min(bits // 8, 4)
                self.code.emit_int(self._encode_imm(src, size), size)
            case _:
                raise TypeError(f"unsupported MOV operands: {dst!r}, {src!r}")

    def add(self, dst: Reg | Mem, src: Reg | Mem | int):
        """Add src into dst (dst += src)."""
        self._alu(0x00, 0, dst, src)

    def sub(self, dst: Reg | Mem, src: Reg | Mem | int):
        """Subtract src from dst (dst -= src)."""
        self._alu(0x28, 5, dst, src)

    def cmp(self, dst: Reg | Mem, src: Reg | Mem | int):
        """Compare dst with src (dst - src), setting flags only."""
        self._alu(0x38, 7, dst, src)

    def and_(self, dst: Reg | Mem, src: Reg | Mem | int):
        """Bitwise AND src into dst (dst &= src)."""
        self._alu(0x20, 4, dst, src)

    def or_(self, dst: Reg | Mem, src: Reg | Mem | int):
        """Bitwise OR src into dst (dst |= src)."""
        self._alu(0x08, 1, dst, src)

    def xor(self, dst: Reg | Mem, src: Reg | Mem | int):
        """Bitwise XOR src into dst (dst ^= src)."""
        self._alu(0x30, 6, dst, src)

    def _alu(self, base: int, ext: int, dst: Reg | Mem, src: Reg | Mem | int):
        # `base` is the r/m<-r opcode of the ALU family (ADD=0x00, SUB=0x28,
        # CMP=0x38, AND=0x20, OR=0x08, XOR=0x30); the other forms are fixed
        # offsets from it. `ext` is the ModR/M.reg extension digit used by the
        # immediate forms.
        match dst, src:
            case Reg(), Reg():
                self._check_sizes(dst, src)
                self._emit_prefixes(dst.bitsize, src, dst)
                self.code.emit(base + (0 if dst.bitsize == 8 else 1))  # r/m, r
                self._emit_modrm(dst, src)
            case Reg(), Mem():
                self._emit_prefixes(dst.bitsize, dst, src.base, src.index)
                self.code.emit(base + (2 if dst.bitsize == 8 else 3))  # r, r/m
                self._emit_modrm_mem(dst, src)
            case Mem(), Reg():
                self._emit_prefixes(src.bitsize, src, dst.base, dst.index)
                self.code.emit(base + (0 if src.bitsize == 8 else 1))  # r/m, r
                self._emit_modrm_mem(src, dst)
            case Reg(), int():
                self._emit_prefixes(dst.bitsize, None, dst)
                size = self._emit_alu_imm_opcode(dst.bitsize, src)
                self._emit_modrm(dst, ext)  # reg=ext (opcode extension), rm=dst
                self.code.emit_int(self._encode_imm(src, size), size)
            case Mem(), int():
                bits = self._mem_bitsize(dst)
                self._emit_prefixes(bits, None, dst.base, dst.index)
                size = self._emit_alu_imm_opcode(bits, src)
                self._emit_modrm_mem(ext, dst)  # reg field = ext
                self.code.emit_int(self._encode_imm(src, size), size)
            case _:
                raise TypeError(f"unsupported ALU operands: {dst!r}, {src!r}")

    def _emit_alu_imm_opcode(self, bits: int, imm: int) -> int:
        # Emit the ALU immediate-form opcode for a `bits`-wide destination and
        # return the immediate's byte width.
        if bits == 8:
            self.code.emit(0x80)  # <op> r/m8, imm8
            return 1
        if -128 <= imm <= 127:
            self.code.emit(0x83)  # <op> r/m, imm8 (sign-extended)
            return 1
        self.code.emit(0x81)  # <op> r/m, imm16/32
        return min(bits // 8, 4)  # imm32 is max (sign-extended on 64)

    @staticmethod
    def _mem_bitsize(mem: Mem) -> int:
        if mem.bitsize is None:
            raise ValueError("memory operand needs a size; wrap it with "
                             "byte()/word()/dword()/qword()")
        return mem.bitsize

    def imul(self, dst: Reg, src: Reg | Mem | int):
        """Signed multiply into dst (dst *= src)."""
        match dst, src:
            case Reg(), Reg():
                self._emit_prefixes(dst.bitsize, dst, src)
                self.code.emit(0x0F)
                self.code.emit(0xAF)  # IMUL r, r/m
                self._emit_modrm(src, dst)  # reg=dst, rm=src
            case Reg(), Mem():
                self._emit_prefixes(dst.bitsize, dst, src.base, src.index)
                self.code.emit(0x0F)
                self.code.emit(0xAF)
                self._emit_modrm_mem(dst, src)
            case Reg(), int():
                # imul dst, dst, imm  (three-operand form with dst as source)
                self._emit_prefixes(dst.bitsize, dst, dst)
                if -128 <= src <= 127:
                    self.code.emit(0x6B)  # IMUL r, r/m, imm8
                    imm_size = 1
                else:
                    self.code.emit(0x69)  # IMUL r, r/m, imm32
                    imm_size = min(dst.bitsize // 8, 4)
                self._emit_modrm(dst, dst)  # reg=dst, rm=dst
                self.code.emit_int(self._encode_imm(src, imm_size), imm_size)
            case _:
                raise TypeError(f"unsupported IMUL operands: {dst!r}, {src!r}")

    def not_(self, dst: Reg):
        """Bitwise NOT in place (one's complement)."""
        self._unary(2, dst)

    def neg(self, dst: Reg):
        """Two's-complement negate in place (dst = -dst)."""
        self._unary(3, dst)

    def _unary(self, ext: int, dst: Reg):
        # F7 /ext (F6 for 8-bit): the ModR/M.reg field selects not(/2), neg(/3).
        self._emit_prefixes(dst.bitsize, None, dst)
        self.code.emit(0xF6 if dst.bitsize == 8 else 0xF7)
        self._emit_modrm(dst, ext)  # reg=ext, rm=dst

    def shl(self, dst: Reg | Mem, count: int | Reg):
        """Shift dst left by count, filling with zeros (dst <<= count)."""
        self._shift(4, dst, count)

    def shr(self, dst: Reg | Mem, count: int | Reg):
        """Logical shift dst right by count, filling with zeros
        (unsigned dst >>= count)."""
        self._shift(5, dst, count)

    def sar(self, dst: Reg | Mem, count: int | Reg):
        """Arithmetic shift dst right by count, preserving the sign bit
        (signed dst >>= count)."""
        self._shift(7, dst, count)

    def _shift(self, ext: int, dst: Reg | Mem, count: int | Reg):
        # Group 2 shifts: C1/C0 /ext with an imm8 count, or D3/D2 /ext to
        # shift by the count in CL. ext selects shl(/4), shr(/5), sar(/7);
        # the C0/D2 opcodes are the 8-bit forms.
        if isinstance(count, Reg):
            if int(count) != 1 or count.bitsize != 8:  # CL is code 1, 8-bit
                raise TypeError(f"shift count register must be CL, not {count!r}")
            by_cl = True
        elif isinstance(count, int):
            by_cl = False
        else:
            raise TypeError(f"unsupported shift count: {count!r}")
        match dst:
            case Reg():
                bits = dst.bitsize
                self._emit_prefixes(bits, None, dst)
            case Mem():
                bits = self._mem_bitsize(dst)
                self._emit_prefixes(bits, None, dst.base, dst.index)
            case _:
                raise TypeError(f"unsupported shift destination: {dst!r}")
        self.code.emit((0xD2 if by_cl else 0xC0) + (0 if bits == 8 else 1))
        if isinstance(dst, Reg):
            self._emit_modrm(dst, ext)  # reg=ext (extension), rm=dst
        else:
            self._emit_modrm_mem(ext, dst)
        if not by_cl:
            self.code.emit_int(self._encode_imm(count, 1), 1)  # imm8 count

    def inc(self, dst: Reg | Mem):
        """Increment dst in place (dst += 1)."""
        self._incdec(0, dst)

    def dec(self, dst: Reg | Mem):
        """Decrement dst in place (dst -= 1)."""
        self._incdec(1, dst)

    def _incdec(self, ext: int, dst: Reg | Mem):
        # FF /0 = inc, FF /1 = dec (FE for 8-bit); the ModR/M.reg field is the
        # extension digit.
        match dst:
            case Reg():
                self._emit_prefixes(dst.bitsize, None, dst)
                self.code.emit(0xFE if dst.bitsize == 8 else 0xFF)
                self._emit_modrm(dst, ext)
            case Mem():
                bits = self._mem_bitsize(dst)
                self._emit_prefixes(bits, None, dst.base, dst.index)
                self.code.emit(0xFE if bits == 8 else 0xFF)
                self._emit_modrm_mem(ext, dst)
            case _:
                raise TypeError(f"unsupported INC/DEC operand: {dst!r}")

    def movzx(self, dst: Reg, src: Reg | Mem):
        """Zero-extend a narrower src (reg/mem) into the wider register dst."""
        self._movx(dst, src, signed=False)

    def movsx(self, dst: Reg, src: Reg | Mem):
        """Sign-extend a narrower src (reg/mem) into the wider register dst.
        A 32-bit src uses the MOVSXD (63 /r) encoding."""
        self._movx(dst, src, signed=True)

    def _movx(self, dst: Reg, src: Reg | Mem, signed: bool):
        # movzx: 0F B6 (r/m8), 0F B7 (r/m16); movsx: 0F BE (r/m8), 0F BF
        # (r/m16); movsxd: 63 /r (r/m32 -> r64). The operand-size prefix / REX
        # follow the *destination* width; the opcode follows the source width.
        if not isinstance(dst, Reg):
            raise TypeError(f"movzx/movsx destination must be a register: {dst!r}")
        match src:
            case Reg():
                src_bits, base, index = src.bitsize, src, None
            case Mem():
                src_bits, base, index = self._mem_bitsize(src), src.base, src.index
            case _:
                raise TypeError(f"unsupported movzx/movsx source: {src!r}")
        if src_bits >= dst.bitsize:
            raise ValueError(f"source ({src_bits}-bit) is not narrower than "
                             f"destination ({dst.bitsize}-bit)")
        self._emit_prefixes(dst.bitsize, dst, base, index)
        if src_bits == 32:
            if not signed:
                raise ValueError("movzx from 32 bits is not encodable; a "
                                 "32-bit mov already zero-extends")
            self.code.emit(0x63)  # MOVSXD r64, r/m32
        else:
            self.code.emit(0x0F)
            self.code.emit((0xBE if signed else 0xB6) + (0 if src_bits == 8 else 1))
        if isinstance(src, Reg):
            self._emit_modrm(src, dst)  # reg=dst, rm=src
        else:
            self._emit_modrm_mem(dst, src)

    def test(self, a: Reg, b: Reg | int):
        """Set flags from a AND b, discarding the result."""
        match a, b:
            case Reg(), Reg():
                self._check_sizes(a, b)
                self._emit_prefixes(a.bitsize, b, a)
                self.code.emit(0x84 if a.bitsize == 8 else 0x85)  # TEST r/m, r
                self._emit_modrm(a, b)  # rm=a, reg=b
            case Reg(), int():
                self._emit_prefixes(a.bitsize, None, a)
                self.code.emit(0xF6 if a.bitsize == 8 else 0xF7)  # TEST r/m, imm /0
                self._emit_modrm(a, 0)  # reg=0, rm=a
                imm_size = 1 if a.bitsize == 8 else min(a.bitsize // 8, 4)
                self.code.emit_int(self._encode_imm(b, imm_size), imm_size)
            case _:
                raise TypeError(f"unsupported TEST operands: {a!r}, {b!r}")

    def lea(self, dst: Reg, src: Mem):
        """Load the effective address of src into dst (no memory access)."""
        self._emit_prefixes(dst.bitsize, dst, src.base, src.index)
        self.code.emit(0x8D)  # LEA r, m
        self._emit_modrm_mem(dst, src)

    def ret(self):
        self.code.emit(0xC3)  # RET opcode

    def push(self, reg: Reg):
        """Push a 64-bit register onto the stack (50+r)."""
        if int(reg) >= 8:
            self.code.emit(0x41)  # REX.B for r8..r15
        self.code.emit(0x50 + (int(reg) & 7))

    def pop(self, reg: Reg):
        """Pop the top of the stack into a 64-bit register (58+r)."""
        if int(reg) >= 8:
            self.code.emit(0x41)  # REX.B for r8..r15
        self.code.emit(0x58 + (int(reg) & 7))

    def leave(self):
        """Tear down a stack frame: mov rsp, rbp; pop rbp (C9)."""
        self.code.emit(0xC9)

    # --- Labels, jumps, and calls -------------------------------------------
    #
    # Jumps use RIP-relative rel32 displacements: the value stored is the
    # signed distance from the END of the jump instruction to the target.
    # Forward jumps reference labels that are not bound yet, so a placeholder
    # is emitted and recorded as a fixup; finalize() backpatches them all once
    # the labels are known.

    def bind(self, label: Label) -> Label:
        """Bind `label` to the current position in the code."""
        label.offset = len(self.code)
        return label

    def jmp(self, target: Label | Symbol):
        """Unconditional near jump (E9 rel32). A Label targets code within this
        object; a Symbol targets another object, resolved at load time."""
        self.code.emit(0xE9)
        self._emit_rel32_target(target)

    def call(self, target: Reg | Label | Symbol):
        """Call a function. A Reg is an indirect call through that register
        (FF /2), used to reach an absolute address loaded with `mov reg, addr`.
        A Label (internal) or Symbol (external) is a direct RIP-relative call
        (E8 rel32)."""
        match target:
            case Reg():
                if int(target) >= 8:
                    self.code.emit(0x41)  # REX.B for r8..r15
                self.code.emit(0xFF)
                self.code.emit(0xD0 | (int(target) & 7))  # /2, mod=11, rm=reg
            case Label() | Symbol():
                self.code.emit(0xE8)
                self._emit_rel32_target(target)
            case _:
                raise TypeError(f"unsupported CALL operand: {target!r}")

    # Conditional near jumps. The signed variants (jl/jle/jg/jge) read as
    # "dst <cond> src" after `cmp dst, src`.

    def je(self, target: Label):
        """Jump if equal (ZF=1)."""
        self._jcc("e", target)

    def jz(self, target: Label):
        """Jump if zero (ZF=1); same condition as je."""
        self._jcc("z", target)

    def jne(self, target: Label):
        """Jump if not equal (ZF=0)."""
        self._jcc("ne", target)

    def jnz(self, target: Label):
        """Jump if not zero (ZF=0); same condition as jne."""
        self._jcc("nz", target)

    def jl(self, target: Label):
        """Jump if less, signed (SF≠OF)."""
        self._jcc("l", target)

    def jle(self, target: Label):
        """Jump if less or equal, signed (ZF=1 or SF≠OF)."""
        self._jcc("le", target)

    def jg(self, target: Label):
        """Jump if greater, signed (ZF=0 and SF=OF)."""
        self._jcc("g", target)

    def jge(self, target: Label):
        """Jump if greater or equal, signed (SF=OF)."""
        self._jcc("ge", target)

    # Unsigned variants (ja/jae/jb/jbe) read as "dst <cond> src" after
    # `cmp dst, src` when the operands are treated as unsigned.

    def ja(self, target: Label):
        """Jump if above, unsigned (CF=0 and ZF=0)."""
        self._jcc("a", target)

    def jae(self, target: Label):
        """Jump if above or equal, unsigned (CF=0)."""
        self._jcc("ae", target)

    def jb(self, target: Label):
        """Jump if below, unsigned (CF=1)."""
        self._jcc("b", target)

    def jbe(self, target: Label):
        """Jump if below or equal, unsigned (CF=1 or ZF=1)."""
        self._jcc("be", target)

    def js(self, target: Label):
        """Jump if sign (SF=1), i.e. the result was negative."""
        self._jcc("s", target)

    def jns(self, target: Label):
        """Jump if not sign (SF=0), i.e. the result was non-negative."""
        self._jcc("ns", target)

    # Condition codes: the low nibble of the 0F 8x conditional-jump opcodes.
    _CC = {"e": 0x4, "z": 0x4, "ne": 0x5, "nz": 0x5,
           "l": 0xC, "ge": 0xD, "le": 0xE, "g": 0xF,
           "a": 0x7, "ae": 0x3, "b": 0x2, "be": 0x6, "s": 0x8, "ns": 0x9}

    def _jcc(self, cond: str, target: Label):
        # Conditional near jump: 0F 8x rel32, x = condition code.
        self.code.emit(0x0F)
        self.code.emit(0x80 | self._CC[cond])
        self._emit_rel32_target(target)

    # Conditional byte-set (0F 90+cc). Each writes 1 into an 8-bit r/m operand
    # when its condition holds, else 0. The condition set mirrors the jumps.

    def sete(self, dst: Reg | Mem):
        """Set dst (r/m8) to 1 if equal (ZF=1), else 0."""
        self._setcc("e", dst)

    def setz(self, dst: Reg | Mem):
        """Set dst to 1 if zero (ZF=1); same condition as sete."""
        self._setcc("z", dst)

    def setne(self, dst: Reg | Mem):
        """Set dst to 1 if not equal (ZF=0), else 0."""
        self._setcc("ne", dst)

    def setnz(self, dst: Reg | Mem):
        """Set dst to 1 if not zero (ZF=0); same condition as setne."""
        self._setcc("nz", dst)

    def setl(self, dst: Reg | Mem):
        """Set dst to 1 if less, signed (SF≠OF), else 0."""
        self._setcc("l", dst)

    def setle(self, dst: Reg | Mem):
        """Set dst to 1 if less or equal, signed (ZF=1 or SF≠OF), else 0."""
        self._setcc("le", dst)

    def setg(self, dst: Reg | Mem):
        """Set dst to 1 if greater, signed (ZF=0 and SF=OF), else 0."""
        self._setcc("g", dst)

    def setge(self, dst: Reg | Mem):
        """Set dst to 1 if greater or equal, signed (SF=OF), else 0."""
        self._setcc("ge", dst)

    def seta(self, dst: Reg | Mem):
        """Set dst to 1 if above, unsigned (CF=0 and ZF=0), else 0."""
        self._setcc("a", dst)

    def setae(self, dst: Reg | Mem):
        """Set dst to 1 if above or equal, unsigned (CF=0), else 0."""
        self._setcc("ae", dst)

    def setb(self, dst: Reg | Mem):
        """Set dst to 1 if below, unsigned (CF=1), else 0."""
        self._setcc("b", dst)

    def setbe(self, dst: Reg | Mem):
        """Set dst to 1 if below or equal, unsigned (CF=1 or ZF=1), else 0."""
        self._setcc("be", dst)

    def sets(self, dst: Reg | Mem):
        """Set dst to 1 if sign (SF=1), i.e. the result was negative."""
        self._setcc("s", dst)

    def setns(self, dst: Reg | Mem):
        """Set dst to 1 if not sign (SF=0), i.e. non-negative."""
        self._setcc("ns", dst)

    def _setcc(self, cond: str, dst: Reg | Mem):
        # 0F 90+cc /0: the ModR/M.reg field is unused (0); the r/m is an 8-bit
        # destination.
        match dst:
            case Reg():
                if dst.bitsize != 8:
                    raise ValueError("setcc needs an 8-bit register")
                self._emit_prefixes(8, None, dst)
                self.code.emit(0x0F)
                self.code.emit(0x90 | self._CC[cond])
                self._emit_modrm(dst, 0)
            case Mem():
                if self._mem_bitsize(dst) != 8:
                    raise ValueError("setcc writes a single byte; use byte()")
                self._emit_prefixes(8, None, dst.base, dst.index)
                self.code.emit(0x0F)
                self.code.emit(0x90 | self._CC[cond])
                self._emit_modrm_mem(0, dst)
            case _:
                raise TypeError(f"unsupported setcc operand: {dst!r}")

    # Conditional move (0F 40+cc): dst <- src when the condition holds. The
    # condition set mirrors the jumps.

    def cmove(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if equal (ZF=1)."""
        self._cmovcc("e", dst, src)

    def cmovz(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if zero (ZF=1); same condition as cmove."""
        self._cmovcc("z", dst, src)

    def cmovne(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if not equal (ZF=0)."""
        self._cmovcc("ne", dst, src)

    def cmovnz(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if not zero (ZF=0); same condition as cmovne."""
        self._cmovcc("nz", dst, src)

    def cmovl(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if less, signed (SF≠OF)."""
        self._cmovcc("l", dst, src)

    def cmovle(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if less or equal, signed (ZF=1 or SF≠OF)."""
        self._cmovcc("le", dst, src)

    def cmovg(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if greater, signed (ZF=0 and SF=OF)."""
        self._cmovcc("g", dst, src)

    def cmovge(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if greater or equal, signed (SF=OF)."""
        self._cmovcc("ge", dst, src)

    def cmova(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if above, unsigned (CF=0 and ZF=0)."""
        self._cmovcc("a", dst, src)

    def cmovae(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if above or equal, unsigned (CF=0)."""
        self._cmovcc("ae", dst, src)

    def cmovb(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if below, unsigned (CF=1)."""
        self._cmovcc("b", dst, src)

    def cmovbe(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if below or equal, unsigned (CF=1 or ZF=1)."""
        self._cmovcc("be", dst, src)

    def cmovs(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if sign (SF=1), i.e. the flag result was negative."""
        self._cmovcc("s", dst, src)

    def cmovns(self, dst: Reg, src: Reg | Mem):
        """Move src into dst if not sign (SF=0), i.e. non-negative."""
        self._cmovcc("ns", dst, src)

    def _cmovcc(self, cond: str, dst: Reg, src: Reg | Mem):
        # 0F 40+cc /r: dst is the ModR/M.reg operand, src the r/m operand. The
        # operand-size prefix / REX follow the destination width.
        if not isinstance(dst, Reg):
            raise TypeError(f"cmovcc destination must be a register: {dst!r}")
        match src:
            case Reg():
                self._emit_prefixes(dst.bitsize, dst, src)
                self.code.emit(0x0F)
                self.code.emit(0x40 | self._CC[cond])
                self._emit_modrm(src, dst)  # reg=dst, rm=src
            case Mem():
                self._emit_prefixes(dst.bitsize, dst, src.base, src.index)
                self.code.emit(0x0F)
                self.code.emit(0x40 | self._CC[cond])
                self._emit_modrm_mem(dst, src)
            case _:
                raise TypeError(f"unsupported cmovcc source: {src!r}")

    def _emit_rel32_target(self, target: Label | Symbol):
        # Emit a 4-byte rel32 placeholder for a Label (resolved internally by
        # finalize) or a Symbol (resolved externally by the loader).
        at = len(self.code)
        if isinstance(target, Symbol):
            self._relocs.append(Reloc(at, target.name, RelocKind.REL32))
        else:
            self._fixups.append((at, target))
        self.code.emit_int(0, 4)

    def finalize(self) -> ObjectCode:
        """Assemble the emitted instructions into machine code. Must be called
        explicitly, after all labels are bound, before running. Does not
        mutate the assembler, so it is safe to call more than once."""
        out = CodeBuffer(self.code.code)  # copy, so finalize stays non-destructive
        self._link(out)
        return ObjectCode(bytes(out.code), tuple(self._relocs))

    def _link(self, buf: CodeBuffer) -> None:
        """Backpatch each recorded jump fixup's rel32 field in `buf`."""
        for at, target in self._fixups:
            if target.offset is None:
                raise ValueError(f"jump to unbound label {target!r}")
            rel = target.offset - (at + 4)  # relative to end of the rel32 field
            if not (-(1 << 31) <= rel < (1 << 31)):
                raise ValueError(f"jump displacement {rel} does not fit in rel32")
            buf.patch_int(at, rel, 4, signed=True)
