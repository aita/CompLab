"""Collatz benchmark: the same scalar loop through every backend there is --
pure Python, this library's JIT and AOT paths (naive and optimized), and Cython
at a range of C optimization levels.

    uv run python examples/collatz/bench.py
"""

import ctypes
import time
from collections.abc import Callable, Iterable, Mapping

from jit import (ARG_REGS, R8, R9, R10, R11, RAX, RCX, RDX, Assembler,
                 ObjectCode, Runtime, aot, disasm, gas_source, have_toolchain)

# One benchmark entry: how it was built, and the collatz function itself.
Impl = tuple[str, Callable[[int], int]]

ARG = ARG_REGS[0]  # the first integer argument register for this platform


def collatz_py(n: int) -> int:
    """Sum of the 3n+1 step counts for x = 1..n (pure Python baseline). A scalar
    loop with a branch and no calls -- it stresses loop/branch code generation,
    not call overhead."""
    total = 0
    for x in range(1, n + 1):
        y = x
        while y != 1:
            if y & 1:
                y = 3 * y + 1
            else:
                y >>= 1
            total += 1
    return total


def build_cython_variants(
        variants: Iterable[tuple[str, list[str]]]) -> list[Impl]:
    """Compile kernels.pyx once per (label, cflags) variant, each into its own
    module, so several Cython optimization levels can be benchmarked side by
    side. Returns a list of (label, collatz_fn); empty if Cython is missing.

    cython + setuptools are dev dependencies, so `uv run python main.py`
    includes them."""
    try:
        import importlib
        import os
        import shutil
        import sys
        import tempfile

        import pyximport
    except Exception as exc:  # Cython/compiler missing -> just skip those rows
        print(f"(Cython unavailable, skipping: {exc})\n")
        return []

    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kernels.pyx")
    tmp = tempfile.mkdtemp(prefix="cyvar_")
    sys.path.insert(0, tmp)
    pyximport.install(language_level=3, build_dir=os.path.join(tmp, "build"))

    out: list[Impl] = []
    for i, (label, cflags) in enumerate(variants):
        mod = f"kernels_v{i}"
        shutil.copy(src, os.path.join(tmp, f"{mod}.pyx"))
        # A per-module .pyxbld pins this variant's compile flags (pyximport
        # picks it up automatically); the flags override the default -O level.
        with open(os.path.join(tmp, f"{mod}.pyxbld"), "w") as fh:
            fh.write(
                "from setuptools import Extension\n"
                "def make_ext(m, p):\n"
                f"    return Extension(m, [p], extra_compile_args={cflags!r})\n"
            )
        try:
            out.append((label, importlib.import_module(mod).collatz_cy))
        except Exception as exc:  # e.g. -march=native unsupported -> skip it
            print(f"({label} build failed, skipping: {exc})")
    return out


# Every library loaded so far, kept alive with its temporary directory.
_AOT_MODULES: list[aot.Module] = []


def build_aot_variants(functions: Mapping[str, Assembler]) -> list[Impl]:
    """Compile `functions` -- {name: Assembler} -- ahead of time instead of into
    memory: the same programs are rendered as gas source, assembled by `as`,
    linked into a shared library and dlopen'd. Returns a list of
    (label, callable); empty if there is no toolchain to drive."""
    if not have_toolchain():
        print("(no assembler/C toolchain, skipping the AOT rows)\n")
        return []
    module = aot.load(functions)
    _AOT_MODULES.append(module)  # the library must outlive its functions
    return [(f"AOT{'-opt' if name.endswith('_opt') else ''}",
             module.func(name, ctypes.c_int64, ctypes.c_int64))
            for name in functions]


def bench(fn: Callable[[int], int], n: int,
          repeat: int = 3) -> tuple[int, float]:
    """Return (result, best-of-`repeat` milliseconds) for fn(n)."""
    best = float("inf")
    result = 0
    for _ in range(repeat):
        t0 = time.perf_counter()
        result = fn(n)
        best = min(best, (time.perf_counter() - t0) * 1e3)
    return result, best


def run_bench(title: str, n: int, impls: list[Impl]) -> None:
    """Run impls -- a list of (label, fn), the first being the baseline -- and
    print a table. Every implementation must return the same result."""
    base_label, base_fn = impls[0]
    base_result, base_ms = bench(base_fn, n)
    print(f"{title} (n={n}) = {base_result}")
    rows = [(base_label, base_ms)]
    for label, fn in impls[1:]:
        result, ms = bench(fn, n)
        assert result == base_result, f"{label}={result} != {base_label}={base_result}"
        rows.append((label, ms))
    for label, ms in rows:
        speedup = f"{base_ms / ms:8.1f}x" if ms > 0 else "        -"
        print(f"  {label:10}: {ms:9.3f} ms {speedup}")
    print()


def build_collatz(a: Assembler) -> None:
    # long collatz_sum(long N): sum of 3n+1 step counts for x = 1..N.
    #
    # A pure loop with a branch and NO calls, so there is no prologue at all --
    # it uses only registers that are caller-saved on both the SysV and Windows
    # ABIs (RAX/RCX/RDX/R8/R9), so nothing needs saving. N is copied out of the
    # argument register first so the code is ABI-independent.
    #   R8 = N,  R9 = x,  RCX = y,  RAX = total
    outer = a.label("c_outer")
    inner = a.label("c_inner")
    even = a.label("c_even")
    step = a.label("c_step")
    nextx = a.label("c_next")
    done = a.label("c_done")
    a.mov(R8, ARG)                 # N (stable, ABI-independent)
    a.xor(RAX, RAX)                # total = 0
    a.mov(R9, 1)                   # x = 1
    a.bind(outer)
    a.cmp(R9, R8)
    a.jg(done)                     # x > N -> done
    a.mov(RCX, R9)                 # y = x
    a.bind(inner)
    a.cmp(RCX, 1)
    a.je(nextx)                    # y == 1 -> next x
    a.test(RCX, 1)
    a.jz(even)                     # y even -> halve
    a.mov(RDX, RCX)                # y odd: y = 3y + 1
    a.shl(RCX, 1)                  #   RCX = 2y
    a.add(RCX, RDX)                #   RCX = 3y
    a.inc(RCX)                     #   RCX = 3y + 1
    a.jmp(step)
    a.bind(even)
    a.shr(RCX, 1)                  # y = y / 2
    a.bind(step)
    a.inc(RAX)                     # total += 1
    a.jmp(inner)
    a.bind(nextx)
    a.inc(R9)                      # x += 1
    a.jmp(outer)
    a.bind(done)
    a.ret()


def build_collatz_opt(a: Assembler) -> None:
    # Same result as build_collatz, with the two optimizations gcc -O3 applies:
    #
    #   1. Branchless. The parity of y in a Collatz walk is essentially
    #      unpredictable, so a `jz even` branch mispredicts ~half the time
    #      (~15-20 cycles each). Compute both candidates and select with cmov.
    #   2. Step fusion. Since 3y+1 is ALWAYS even, the odd step is always
    #      followed by a halving, so fuse them: y = (3y+1)>>1 counts two steps.
    #      Even: y = y>>1 counts one. That cuts the iteration count. The counter
    #      advances by 1 + parity (a lea), keeping it branchless too.
    #
    #   R8 = N,  R9 = x,  RCX = y,  RDX/R10 = candidates,  R11 = parity, RAX = total
    outer = a.label("cf_outer")
    inner = a.label("cf_inner")
    nextx = a.label("cf_next")
    done = a.label("cf_done")
    a.mov(R8, ARG)                 # N
    a.xor(RAX, RAX)                # total = 0
    a.mov(R9, 1)                   # x = 1
    a.bind(outer)
    a.cmp(R9, R8)
    a.jg(done)                     # x > N -> done
    a.mov(RCX, R9)                 # y = x
    a.bind(inner)
    a.cmp(RCX, 1)
    a.je(nextx)                    # y == 1 -> next x
    a.mov(RDX, RCX)
    a.shr(RDX, 1)                  # even candidate: y >> 1
    a.lea(R10, RCX + RCX * 2 + 1)  # 3y + 1
    a.shr(R10, 1)                  # odd candidate: (3y+1) >> 1  (fused)
    a.mov(R11, RCX)
    a.and_(R11, 1)                 # parity (0/1), sets ZF
    a.cmovnz(RDX, R10)             # y = odd ? (3y+1)>>1 : y>>1  (branchless)
    a.lea(RAX, RAX + R11 + 1)      # total += 1 + parity (2 if odd, 1 if even)
    a.mov(RCX, RDX)                # y = selected
    a.jmp(inner)
    a.bind(nextx)
    a.inc(R9)                      # x += 1
    a.jmp(outer)
    a.bind(done)
    a.ret()


def main() -> None:
    rt = Runtime()
    i64 = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)

    def jit_compile(
            builder: Callable[[Assembler], None], name: str
    ) -> tuple[Assembler, ObjectCode, Callable[[int], int]]:
        asm = Assembler()
        builder(asm)
        obj = asm.finalize()
        return asm, obj, i64(rt.add(obj, name=name))

    asm, obj, collatz_jit = jit_compile(build_collatz, "collatz")
    asm_opt, obj_opt, collatz_jit_opt = jit_compile(build_collatz_opt,
                                                    "collatz_opt")

    print("naive JIT collatz:")
    print(disasm(obj))
    print("\noptimized JIT collatz (branchless cmov + step fusion):")
    print(disasm(obj_opt))

    print("\nthe same naive program rendered for the ahead-of-time backend:")
    print(gas_source({"collatz": asm}))

    impls = [("Python", collatz_py),
             ("JIT", collatz_jit),
             ("JIT-opt", collatz_jit_opt)]
    impls += build_aot_variants({"collatz": asm, "collatz_opt": asm_opt})
    impls += build_cython_variants([
        ("Cython -O0", ["-O0"]),
        ("Cython -O2", ["-O2"]),
        ("Cython -O3", ["-O3"]),
        ("Cython -O3+native", ["-O3", "-march=native"]),
        ("Cython -Ofast+native", ["-Ofast", "-march=native", "-funroll-loops"]),
    ])
    run_bench("collatz", 50_000, impls)


if __name__ == "__main__":
    main()
