import ctypes
import time

from jit import R12, RAX, RBP, RBX, RDI, RSP, Assembler, Label, Runtime, Symbol, disasm


def fib_py(n):
    """Naive recursive Fibonacci in pure Python (the interpreter baseline)."""
    return n if n < 2 else fib_py(n - 1) + fib_py(n - 2)


def build_fib(a):
    # int64 fib(int64 n)   (n arrives in RDI)
    #
    #   if n < 2: return n
    #   else:     return fib(n-1) + fib(n-2)
    #
    # RBX holds n and R12 holds fib(n-1) across the recursive calls -- both are
    # callee-saved, so they survive a call and are restored on the way out. The
    # push rbp / push rbx / push r12 prologue also leaves RSP 16-byte aligned,
    # as the ABI requires at each call.
    base = Label("base")
    done = Label("done")
    a.push(RBP)
    a.mov(RBP, RSP)
    a.push(RBX)
    a.push(R12)
    a.cmp(RDI, 2)
    a.jl(base)                 # n < 2 -> base case
    a.mov(RBX, RDI)            # rbx = n
    a.sub(RDI, 1)
    a.call(Symbol("fib"))      # rax = fib(n-1)
    a.mov(R12, RAX)            # r12 = fib(n-1)
    a.mov(RDI, RBX)
    a.sub(RDI, 2)
    a.call(Symbol("fib"))      # rax = fib(n-2)
    a.add(RAX, R12)            # rax = fib(n-1) + fib(n-2)
    a.jmp(done)
    a.bind(base)
    a.mov(RAX, RDI)            # return n
    a.bind(done)
    a.pop(R12)
    a.pop(RBX)
    a.leave()
    a.ret()


def main():
    asm = Assembler()
    build_fib(asm)
    obj = asm.finalize()

    print("disassembly of fib:")
    print(disasm(obj))
    print()

    rt = Runtime()
    fib_jit = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(
        rt.add(obj, name="fib"))   # name="fib" so call(Symbol("fib")) resolves

    n = 32
    assert fib_jit(n) == fib_py(n)  # same result

    t0 = time.perf_counter()
    result = fib_py(n)
    t1 = time.perf_counter()
    fib_jit(n)
    t2 = time.perf_counter()

    py_ms, jit_ms = (t1 - t0) * 1e3, (t2 - t1) * 1e3
    print(f"fib({n}) = {result}")
    print(f"  Python : {py_ms:8.2f} ms")
    print(f"  JIT    : {jit_ms:8.2f} ms")
    print(f"  speedup: {py_ms / jit_ms:8.1f}x")


if __name__ == "__main__":
    main()
