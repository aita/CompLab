import ctypes
import mmap


class CodeBuffer:
    def __init__(self):
        self.code = bytearray()

    def emit(self, byte: int):
        self.code.append(byte)

    def emit_int(self, value: int, size: int):
        self.code.extend(value.to_bytes(size, byteorder="little"))

    def finish(self) -> int:
        size = mmap.PAGESIZE
        buf = mmap.mmap(
            -1,
            size,
            flags=mmap.MAP_PRIVATE | mmap.MAP_ANON,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
        )

        buf.write(self.code)

        addr = ctypes.addressof(ctypes.c_char.from_buffer(buf))

        libc = ctypes.CDLL(None)
        pagesize = mmap.PAGESIZE
        page_start = addr & ~(pagesize - 1)

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

        return addr


RAX = 0
RCX = 1
RDX = 2
RBX = 3
RSP = 4
RBP = 5
RSI = 6
RDI = 7
R8 = 8
R9 = 9
R10 = 10
R11 = 11
R12 = 12
R13 = 13
R14 = 14
R15 = 15


class Assembler:
    def __init__(self, code: CodeBuffer):
        self.code = code

    def _emit_modrm(self, reg_dst: int, reg_src: int):
        modrm = 0xC0 | (reg_src << 3) | reg_dst  # ModR/M byte for reg-to-reg
        self.code.emit(modrm)

    def mov_reg64_reg64(self, reg_dst: int, reg_src: int):
        self.code.emit(0x48)  # REX.W prefix for 64-bit operation
        self.code.emit(0x89)  # MOV r/m64, r64 opcode
        self._emit_modrm(reg_dst, reg_src)

    def mov_reg64_imm64(self, reg_dst: int, imm64: int):
        if reg_dst > 7:
            raise ValueError("Only registers RAX-R15 are supported")
        self.code.emit(0x48)  # REX.W prefix
        opcode = 0xB8 + reg_dst  # MOV r64, imm64 opcode
        self.code.emit(opcode)
        self.code.emit_int(imm64, 8)  # Emit the 64-bit immediate value

    def _aluop_reg64_reg64(self, opcode: int, reg_dst: int, reg_src: int):
        self.code.emit(0x48)  # REX.W prefix for 64-bit operation
        self.code.emit(opcode)  # ALU operation opcode
        self._emit_modrm(reg_dst, reg_src)

    def add_reg64_reg64(self, reg_dst: int, reg_src: int):
        self._aluop_reg64_reg64(0x01, reg_dst, reg_src)

    def sub_reg64_reg64(self, reg_dst: int, reg_src: int):
        self._aluop_reg64_reg64(0x29, reg_dst, reg_src)

    def imul_reg64_reg64(self, reg_dst: int, reg_src: int):
        self._aluop_reg64_reg64(0x0F, reg_dst, reg_src)  # IMUL r/m64, r64 opcode

    def cmp_reg64_reg64(self, reg1: int, reg2: int):
        self.code.emit(0x48)  # REX.W prefix for 64-bit operation
        self.code.emit(0x39)  # CMP r/m64, r64 opcode
        self._emit_modrm(reg1, reg2)

    def ret(self):
        self.code.emit(0xC3)  # RET opcode


def main():
    code = CodeBuffer()
    asm = Assembler(code)

    asm.mov_reg64_imm64(RAX, 42)  # Move the immediate value 42 into RAX
    asm.ret()  # Return from the function

    # print(code.code)  # Print the generated machine code for debugging

    addr = code.finish()
    fn_type = ctypes.CFUNCTYPE(ctypes.c_int64)
    fn = fn_type(addr)
    result = fn()
    print(f"Result: {result}")


if __name__ == "__main__":
    main()
