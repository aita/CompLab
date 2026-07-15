import ctypes
import mmap


class CodeBuffer:
    def __init__(self):
        self.code = bytearray()

    def emit(self, byte: int):
        self.code.append(byte)

    def emit_int(self, value: int, size: int):
        self.code.extend(value.to_bytes(size, byteorder="little"))


class Reg(int):
    """A register. Subclasses int so its 3/4-bit encoding number is usable
    directly in bit math, while carrying its operand size (in bits) so it
    can be dispatched by type and encoded correctly.

    `high` marks the legacy high-byte registers (AH/CH/DH/BH), and
    `needs_rex` marks the 8-bit regs (SPL/BPL/SIL/DIL) that only exist when
    a REX prefix is present."""

    def __new__(cls, value: int, name: str, size: int,
                high: bool = False, needs_rex: bool = False):
        obj = super().__new__(cls, value)
        obj.name = name
        obj.size = size
        obj.high = high
        obj.needs_rex = needs_rex
        return obj

    def __repr__(self):
        return self.name

    def __add__(self, disp: int) -> "Mem":
        return Mem(self, disp)

    def __sub__(self, disp: int) -> "Mem":
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


class Runtime:
    def __init__(self):
        self._buffers = []

    def add(self, code: CodeBuffer) -> int:
        size = mmap.PAGESIZE
        buf = mmap.mmap(
            -1,
            size,
            flags=mmap.MAP_PRIVATE | mmap.MAP_ANON,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
        )
        buf.write(code.code)

        addr = ctypes.addressof(ctypes.c_char.from_buffer(buf))

        libc = ctypes.CDLL(None)
        page_start = addr & ~(size - 1)

        PROT_READ = 1
        PROT_EXEC = 4
        res = libc.mprotect(
            ctypes.c_void_p(page_start),
            ctypes.c_size_t(size),
            PROT_READ | PROT_EXEC,
        )
        if res != 0:
            err = ctypes.get_errno()
            raise OSError(err, "mprotect failed")

        self._buffers.append(buf)
        return addr


class Assembler:
    def __init__(self, code: CodeBuffer):
        self.code = code

    def _emit_prefixes(self, size: int, reg, rm):
        # Operand-size prefix for 16-bit, then REX if required.
        #   reg -> the ModR/M.reg operand (None if none, e.g. reg-imm)
        #   rm  -> the ModR/M.rm operand or the memory base
        if size == 16:
            self.code.emit(0x66)  # operand-size override prefix

        w = 1 if size == 64 else 0
        r = (int(reg) >> 3) if reg is not None else 0
        b = (int(rm) >> 3) if rm is not None else 0
        force = size == 8 and (
            (reg is not None and getattr(reg, "needs_rex", False))
            or (rm is not None and getattr(rm, "needs_rex", False))
        )
        if w or r or b or force:
            self.code.emit(0x40 | (w << 3) | (r << 2) | b)

    def _emit_modrm(self, reg_dst: int, reg_src: int):
        # ModR/M byte for reg-to-reg (mod=11)
        modrm = 0xC0 | ((int(reg_src) & 7) << 3) | (int(reg_dst) & 7)
        self.code.emit(modrm)

    def _emit_modrm_mem(self, reg: int, mem: "Mem"):
        # ModR/M (+ SIB + disp) for a [base + disp] memory operand.
        reg_field = int(reg) & 7
        base = int(mem.base) & 7
        disp = mem.disp

        if disp == 0 and base != 5:  # base==5 (RBP/R13) can't use mod=00
            mod = 0x00
        elif -128 <= disp <= 127:
            mod = 0x40
        else:
            mod = 0x80

        self.code.emit(mod | (reg_field << 3) | base)
        if base == 4:  # RSP/R12 require a SIB byte
            self.code.emit(0x24)  # scale=1, index=none, base=RSP/R12
        if mod == 0x40:
            self.code.emit_int(disp & 0xFF, 1)
        elif mod == 0x80:
            self.code.emit_int(disp & 0xFFFFFFFF, 4)

    @staticmethod
    def _check_sizes(a: Reg, b: Reg):
        if a.size != b.size:
            raise ValueError(f"operand size mismatch: {a!r} ({a.size}) vs "
                             f"{b!r} ({b.size})")

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
        self._emit_prefixes(reg_dst.size, reg_src, reg_dst)
        self.code.emit(0x88 if reg_dst.size == 8 else 0x89)  # MOV r/m, r
        self._emit_modrm(reg_dst, reg_src)

    def _mov_reg_imm(self, reg_dst: Reg, imm: int):
        self._emit_prefixes(reg_dst.size, None, reg_dst)
        base = 0xB0 if reg_dst.size == 8 else 0xB8  # MOV r, imm
        self.code.emit(base + (int(reg_dst) & 7))
        self.code.emit_int(imm, reg_dst.size // 8)

    def _mov_reg_mem(self, reg_dst: Reg, mem_src: "Mem"):
        self._emit_prefixes(reg_dst.size, reg_dst, mem_src.base)
        self.code.emit(0x8A if reg_dst.size == 8 else 0x8B)  # MOV r, r/m (load)
        self._emit_modrm_mem(reg_dst, mem_src)

    def _mov_mem_reg(self, mem_dst: "Mem", reg_src: Reg):
        self._emit_prefixes(reg_src.size, reg_src, mem_dst.base)
        self.code.emit(0x88 if reg_src.size == 8 else 0x89)  # MOV r/m, r (store)
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
        self._emit_prefixes(dst.size, src, dst)
        self.code.emit(base + (0 if dst.size == 8 else 1))  # <op> r/m, r
        self._emit_modrm(dst, src)

    def _alu_reg_mem(self, base: int, dst: Reg, mem: "Mem"):
        self._emit_prefixes(dst.size, dst, mem.base)
        self.code.emit(base + (2 if dst.size == 8 else 3))  # <op> r, r/m (load)
        self._emit_modrm_mem(dst, mem)

    def _alu_mem_reg(self, base: int, mem: "Mem", src: Reg):
        self._emit_prefixes(src.size, src, mem.base)
        self.code.emit(base + (0 if src.size == 8 else 1))  # <op> r/m, r (store)
        self._emit_modrm_mem(src, mem)

    def _alu_reg_imm(self, ext: int, dst: Reg, imm: int):
        self._emit_prefixes(dst.size, None, dst)
        if dst.size == 8:
            self.code.emit(0x80)  # <op> r/m8, imm8
            imm_size = 1
        elif -128 <= imm <= 127:
            self.code.emit(0x83)  # <op> r/m, imm8 (sign-extended)
            imm_size = 1
        else:
            self.code.emit(0x81)  # <op> r/m, imm16/32
            imm_size = min(dst.size // 8, 4)  # imm32 is max (sign-extended on 64)
        self._emit_modrm(dst, ext)  # mod=11, reg=ext (opcode extension), rm=dst
        self.code.emit_int(imm & ((1 << (imm_size * 8)) - 1), imm_size)

    def ret(self):
        self.code.emit(0xC3)  # RET opcode


def main():
    code = CodeBuffer()
    asm = Assembler(code)

    asm.mov(RAX, 1)
    asm.mov(RBX, 1)
    asm.add(RAX, RBX)  # Add RBX to RAX
    asm.ret()  # Return from the function

    rt = Runtime()
    addr = rt.add(code)
    fn_type = ctypes.CFUNCTYPE(ctypes.c_int64)
    fn = fn_type(addr)
    result = fn()
    print(f"Result: {result}")


if __name__ == "__main__":
    main()
