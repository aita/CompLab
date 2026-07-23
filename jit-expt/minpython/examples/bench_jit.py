"""Benchmark the tracing JIT against the plain bytecode VM and the Cython VM.

    uv run python -m minpython.examples.bench_jit

Each row runs the same MinPython program three ways and checks they all agree.
The straight-line loops (sum, factorial) run entirely in one native trace and
show the JIT at its best; collatz's parity branch makes its trace exit and
re-enter on every flip, so its speedup is smaller but still real -- and it
exercises the guard/snapshot path hard.
"""

from __future__ import annotations

import time

from minpython import VM
from minpython.jit import TracingJIT

PROGRAMS = {
    "sum 1..N": ("def go(n):\n    i = 0\n    t = 0\n"
                 "    while i < n:\n        t = t + i\n        i = i + 1\n"
                 "    return t\n", 2_000_000),
    "factorial-ish": ("def go(n):\n    p = 1\n    i = 1\n"
                      "    while i < n:\n        p = (p + i) & 1073741823\n"
                      "        i = i + 1\n    return p\n", 2_000_000),
    "invariant body": ("def go(n):\n    a = 7\n    b = 9\n    c = 5\n"
                       "    i = 0\n    total = 0\n"
                       "    while i < n:\n"
                       "        total = total + (a * b + c)\n"
                       "        i = i + 1\n    return total\n", 2_000_000),
    "collatz sum": ("def go(n):\n    total = 0\n    x = 1\n"
                    "    while x <= n:\n        y = x\n"
                    "        while y != 1:\n"
                    "            if y & 1:\n                y = 3 * y + 1\n"
                    "            else:\n                y = y >> 1\n"
                    "            total = total + 1\n        x = x + 1\n"
                    "    return total\n", 30_000),
}


def time_call(make_vm, defs: str, call: str, reps: int = 3) -> tuple[float, str]:
    best = float("inf")
    out = ""
    for _ in range(reps):
        vm = make_vm()
        vm.run(defs)
        t = time.perf_counter()
        vm.run(call)
        best = min(best, time.perf_counter() - t)
        out = vm.output
    return best, out


def main() -> None:
    have_cy = VM(cython=True).using_cython
    print(f"{'program':<16}{'vm':>11}{'cython':>11}{'jit':>11}{'jit/vm':>9}")
    print("-" * 59)
    for label, (defs, n) in PROGRAMS.items():
        call = f"print(go({n}))"

        t_vm, o_vm = time_call(lambda: VM(), defs, call)
        if have_cy:
            t_cy, o_cy = time_call(lambda: VM(cython=True), defs, call)
        else:
            t_cy, o_cy = float("nan"), o_vm

        def mk_jit() -> VM:
            vm = VM()
            TracingJIT(vm, threshold=50)
            return vm

        t_jit, o_jit = time_call(mk_jit, defs, call)

        assert o_vm == o_cy == o_jit, (label, o_vm, o_cy, o_jit)
        print(f"{label:<16}{t_vm*1e3:>9.1f}ms{t_cy*1e3:>9.1f}ms"
              f"{t_jit*1e3:>9.1f}ms{t_vm/t_jit:>8.0f}x")
    print("\n(register allocation + LICM + side traces. collatz's parity split "
          "now\n stays in native code via linked traces; the residual cost is "
          "the\n Python-level chain between them -- native trace linking is the "
          "next step.)")


if __name__ == "__main__":
    main()
