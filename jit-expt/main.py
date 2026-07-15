import ctypes

from jit import RAX, RBX, Assembler, CodeBuffer, Runtime


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
