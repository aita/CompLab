import ctypes

from jit import RAX, RDI, Assembler, Label, Runtime


def main():
    # JIT a function computing sum(n) = n + (n-1) + ... + 1 with a loop:
    #
    #     rax = 0
    #   loop:
    #     cmp rdi, 0
    #     je done            ; exit when the counter reaches 0
    #     add rax, rdi       ; rax += rdi
    #     sub rdi, 1         ; rdi -= 1
    #     jmp loop
    #   done:
    #     ret                ; return rax
    asm = Assembler()
    loop = Label("loop")
    done = Label("done")

    asm.mov(RAX, 0)
    asm.bind(loop)
    asm.cmp(RDI, 0)
    asm.je(done)
    asm.add(RAX, RDI)
    asm.sub(RDI, 1)
    asm.jmp(loop)
    asm.bind(done)
    asm.ret()

    rt = Runtime()
    addr = rt.add(asm.finalize())
    fn = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(addr)

    for n in (5, 10, 100):
        print(f"sum(1..{n}) = {fn(n)}")


if __name__ == "__main__":
    main()
