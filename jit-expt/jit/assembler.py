from __future__ import annotations

from dataclasses import dataclass

from .operands import Mem, Reg


@dataclass(frozen=True)
class ObjectCode:
    """Assembled machine code produced by Assembler.finalize(): the resolved
    bytes, plus any relocations still needing the final load address (none
    yet — reserved for future absolute references)."""

    code: bytes
    relocs: tuple = ()


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

    def mov(self, dst: Reg | Mem, src: Reg | Mem | int):
        """Move src into dst."""
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
        self._emit_prefixes(reg_dst.bitsize, reg_dst, mem_src.base, mem_src.index)
        self.code.emit(0x8A if reg_dst.bitsize == 8 else 0x8B)  # MOV r, r/m (load)
        self._emit_modrm_mem(reg_dst, mem_src)

    def _mov_mem_reg(self, mem_dst: Mem, reg_src: Reg):
        self._emit_prefixes(reg_src.bitsize, reg_src, mem_dst.base, mem_dst.index)
        self.code.emit(0x88 if reg_src.bitsize == 8 else 0x89)  # MOV r/m, r (store)
        self._emit_modrm_mem(reg_src, mem_dst)

    def add(self, dst: Reg | Mem, src: Reg | Mem | int):
        """Add src into dst (dst += src)."""
        self._alu(0x00, 0, dst, src)

    def sub(self, dst: Reg | Mem, src: Reg | Mem | int):
        """Subtract src from dst (dst -= src)."""
        self._alu(0x28, 5, dst, src)

    def cmp(self, dst: Reg | Mem, src: Reg | Mem | int):
        """Compare dst with src (dst - src), setting flags only."""
        self._alu(0x38, 7, dst, src)

    def _alu(self, base: int, ext: int, dst: Reg | Mem, src: Reg | Mem | int):
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
        self._emit_prefixes(dst.bitsize, dst, mem.base, mem.index)
        self.code.emit(base + (2 if dst.bitsize == 8 else 3))  # <op> r, r/m (load)
        self._emit_modrm_mem(dst, mem)

    def _alu_mem_reg(self, base: int, mem: Mem, src: Reg):
        self._emit_prefixes(src.bitsize, src, mem.base, mem.index)
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

    def jmp(self, target: Label):
        """Unconditional near jump (E9 rel32)."""
        self.code.emit(0xE9)
        self._emit_rel32_fixup(target)

    def call(self, target: Reg | Label):
        """Call a function. A Reg is an indirect call through that register
        (FF /2), used to reach an absolute address loaded with `mov reg, addr`.
        A Label is a direct RIP-relative call (E8 rel32) within this code."""
        match target:
            case Reg():
                if int(target) >= 8:
                    self.code.emit(0x41)  # REX.B for r8..r15
                self.code.emit(0xFF)
                self.code.emit(0xD0 | (int(target) & 7))  # /2, mod=11, rm=reg
            case Label():
                self.code.emit(0xE8)
                self._emit_rel32_fixup(target)
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

    # Condition codes: the low nibble of the 0F 8x conditional-jump opcodes.
    _CC = {"e": 0x4, "z": 0x4, "ne": 0x5, "nz": 0x5,
           "l": 0xC, "ge": 0xD, "le": 0xE, "g": 0xF}

    def _jcc(self, cond: str, target: Label):
        # Conditional near jump: 0F 8x rel32, x = condition code.
        self.code.emit(0x0F)
        self.code.emit(0x80 | self._CC[cond])
        self._emit_rel32_fixup(target)

    def _emit_rel32_fixup(self, target: Label):
        # Record where the rel32 field starts, then emit a 4-byte placeholder.
        self._fixups.append((len(self.code), target))
        self.code.emit_int(0, 4)

    def finalize(self) -> ObjectCode:
        """Assemble the emitted instructions into machine code. Must be called
        explicitly, after all labels are bound, before running. Does not
        mutate the assembler, so it is safe to call more than once."""
        out = CodeBuffer(self.code.code)  # copy, so finalize stays non-destructive
        self._link(out)
        return ObjectCode(bytes(out.code))

    def _link(self, buf: CodeBuffer) -> None:
        """Backpatch each recorded jump fixup's rel32 field in `buf`."""
        for at, target in self._fixups:
            if target.offset is None:
                raise ValueError(f"jump to unbound label {target!r}")
            rel = target.offset - (at + 4)  # relative to end of the rel32 field
            if not (-(1 << 31) <= rel < (1 << 31)):
                raise ValueError(f"jump displacement {rel} does not fit in rel32")
            buf.patch_int(at, rel, 4, signed=True)
