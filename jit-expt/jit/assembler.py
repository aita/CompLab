from __future__ import annotations

from .buffer import CodeBuffer
from .registers import Mem, Reg


class Assembler:
    """Encodes a small subset of x86-64 instructions into a CodeBuffer."""

    def __init__(self, code: CodeBuffer):
        self.code = code

    def _emit_prefixes(self, bitsize: int, reg, rm):
        # Operand-size prefix for 16-bit, then REX if required.
        #   reg -> the ModR/M.reg operand (None if none, e.g. reg-imm)
        #   rm  -> the ModR/M.rm operand or the memory base
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
        #   X ..... high bit of the SIB.index field (unused here)
        #   B ..... high bit of the ModR/M.rm / SIB.base field
        w = 1 if bitsize == 64 else 0
        r = (int(reg) >> 3) if reg is not None else 0
        b = (int(rm) >> 3) if rm is not None else 0
        # 8-bit SPL/BPL/SIL/DIL are only addressable when a REX prefix is
        # present, so force an (otherwise all-zero) REX for them.
        force = bitsize == 8 and (
            (reg is not None and getattr(reg, "needs_rex", False))
            or (rm is not None and getattr(rm, "needs_rex", False))
        )
        if w or r or b or force:
            self.code.emit(0x40 | (w << 3) | (r << 2) | b)

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

    def _emit_modrm_mem(self, reg: int, mem: Mem):
        # A [base + disp] memory operand is emitted as a sequence of bytes:
        #
        #   +--------+  +--------+  +------------------+
        #   | ModR/M |  |  SIB   |  |   displacement   |
        #   +--------+  +--------+  +------------------+
        #    1 byte      1 byte      0 / 1 / 4 bytes
        #    always      optional*   (see mod, below)
        #
        #   * SIB is only present when rm = 100 (base is RSP/R12).
        #
        # ModR/M byte (rm holds the base register, mod selects the disp size):
        #    7     6 5         3 2         0
        #   +-------+-----------+-----------+
        #   |  mod  |    reg    |  rm=base  |
        #   +-------+-----------+-----------+
        #   mod=00  no displacement
        #   mod=01  disp8   (1-byte signed)
        #   mod=10  disp32  (4-byte signed)
        reg_field = int(reg) & 7
        base = int(mem.base) & 7
        disp = mem.disp

        if disp == 0 and base != 5:  # base==5 (RBP/R13) can't use mod=00
            mod = 0x00
        elif -128 <= disp <= 127:
            mod = 0x40
        else:
            mod = 0x80

        # ModR/M:  mod(2) | reg(3) | rm(3=base)
        self.code.emit(mod | (reg_field << 3) | base)
        if base == 4:  # RSP/R12 require a SIB byte
            # SIB byte:
            #    7     6 5         3 2         0
            #   +-------+-----------+-----------+
            #   | scale |   index   |    base   |
            #   +-------+-----------+-----------+
            #   scale .. index is multiplied by 2^scale (00=1,01=2,10=4,11=8)
            #   index .. index register; 100 = none
            #   base ... base register
            #   0x24 = 00 100 100 -> scale=1, index=none, base=RSP/R12
            self.code.emit(0x24)
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

    def mov(self, dst, src):
        """Emit a MOV, dispatching on the operand types (and sizes)."""
        match dst, src:
            case Reg(), Reg():
                self._mov_reg_reg(dst, src)
            case Reg(), Mem():
                self._mov_reg_mem(dst, src)
            case Mem(), Reg():
                self._mov_mem_reg(dst, src)
            case Reg(), int():
                self._mov_reg_imm(dst, src)
            case _:
                raise TypeError(f"unsupported MOV operands: {dst!r}, {src!r}")

    def _mov_reg_reg(self, reg_dst: Reg, reg_src: Reg):
        self._check_sizes(reg_dst, reg_src)
        self._emit_prefixes(reg_dst.bitsize, reg_src, reg_dst)
        self.code.emit(0x88 if reg_dst.bitsize == 8 else 0x89)  # MOV r/m, r
        self._emit_modrm(reg_dst, reg_src)

    def _mov_reg_imm(self, reg_dst: Reg, imm: int):
        self._emit_prefixes(reg_dst.bitsize, None, reg_dst)
        base = 0xB0 if reg_dst.bitsize == 8 else 0xB8  # MOV r, imm
        self.code.emit(base + (int(reg_dst) & 7))
        imm_size = reg_dst.bitsize // 8  # full-width immediate (imm8/16/32/64)
        self.code.emit_int(self._encode_imm(imm, imm_size), imm_size)

    def _mov_reg_mem(self, reg_dst: Reg, mem_src: Mem):
        self._emit_prefixes(reg_dst.bitsize, reg_dst, mem_src.base)
        self.code.emit(0x8A if reg_dst.bitsize == 8 else 0x8B)  # MOV r, r/m (load)
        self._emit_modrm_mem(reg_dst, mem_src)

    def _mov_mem_reg(self, mem_dst: Mem, reg_src: Reg):
        self._emit_prefixes(reg_src.bitsize, reg_src, mem_dst.base)
        self.code.emit(0x88 if reg_src.bitsize == 8 else 0x89)  # MOV r/m, r (store)
        self._emit_modrm_mem(reg_src, mem_dst)

    def add(self, dst, src):
        """Emit an ADD, dispatching on the operand types (and sizes)."""
        self._alu(0x00, 0, dst, src)

    def sub(self, dst, src):
        """Emit a SUB, dispatching on the operand types (and sizes)."""
        self._alu(0x28, 5, dst, src)

    def cmp(self, dst, src):
        """Emit a CMP, dispatching on the operand types (and sizes)."""
        self._alu(0x38, 7, dst, src)

    def _alu(self, base: int, ext: int, dst, src):
        # `base` is the r/m<-r opcode of the ALU family (ADD=0x00, SUB=0x28,
        # CMP=0x38, ...); the other forms are fixed offsets from it. `ext` is
        # the ModR/M.reg extension digit used by the immediate forms.
        match dst, src:
            case Reg(), Reg():
                self._alu_reg_reg(base, dst, src)
            case Reg(), Mem():
                self._alu_reg_mem(base, dst, src)
            case Mem(), Reg():
                self._alu_mem_reg(base, dst, src)
            case Reg(), int():
                self._alu_reg_imm(ext, dst, src)
            case _:
                raise TypeError(f"unsupported ALU operands: {dst!r}, {src!r}")

    def _alu_reg_reg(self, base: int, dst: Reg, src: Reg):
        self._check_sizes(dst, src)
        self._emit_prefixes(dst.bitsize, src, dst)
        self.code.emit(base + (0 if dst.bitsize == 8 else 1))  # <op> r/m, r
        self._emit_modrm(dst, src)

    def _alu_reg_mem(self, base: int, dst: Reg, mem: Mem):
        self._emit_prefixes(dst.bitsize, dst, mem.base)
        self.code.emit(base + (2 if dst.bitsize == 8 else 3))  # <op> r, r/m (load)
        self._emit_modrm_mem(dst, mem)

    def _alu_mem_reg(self, base: int, mem: Mem, src: Reg):
        self._emit_prefixes(src.bitsize, src, mem.base)
        self.code.emit(base + (0 if src.bitsize == 8 else 1))  # <op> r/m, r (store)
        self._emit_modrm_mem(src, mem)

    def _alu_reg_imm(self, ext: int, dst: Reg, imm: int):
        self._emit_prefixes(dst.bitsize, None, dst)
        if dst.bitsize == 8:
            self.code.emit(0x80)  # <op> r/m8, imm8
            imm_size = 1
        elif -128 <= imm <= 127:
            self.code.emit(0x83)  # <op> r/m, imm8 (sign-extended)
            imm_size = 1
        else:
            self.code.emit(0x81)  # <op> r/m, imm16/32
            imm_size = min(dst.bitsize // 8, 4)  # imm32 is max (sign-extended on 64)
        self._emit_modrm(dst, ext)  # mod=11, reg=ext (opcode extension), rm=dst
        self.code.emit_int(self._encode_imm(imm, imm_size), imm_size)

    def ret(self):
        self.code.emit(0xC3)  # RET opcode
