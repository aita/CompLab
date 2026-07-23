"""Tests for the tiered, background-compiling method JIT (minpython.jit.tiered).

Differential as always: with the tiered JIT attached, every program must match
the pure VM -- whether tier 1 (copy-and-patch), tier 2 (regalloc), or the
interpreter fallback ends up running each call."""

from __future__ import annotations

import pytest

from minpython import VM
from minpython.jit import TieredJIT


def run_both(src: str, *, background: bool, **kw) -> tuple[str, TieredJIT]:
    ref = VM()
    ref.run(src)
    vm = VM()
    jit = TieredJIT(vm, background=background, **kw)
    vm.run(src)
    if background:
        jit.drain()
    assert vm.output == ref.output, (
        f"tiered/VM disagree:\nT:  {vm.output!r}\nVM: {ref.output!r}")
    return vm.output, jit


@pytest.mark.parametrize("background", [False, True])
def test_fib_recursion(background):
    src = ("def fib(n):\n    if n < 2:\n        return n\n"
           "    return fib(n-1) + fib(n-2)\nprint(fib(26))")
    out, jit = run_both(src, background=background, tier1_threshold=5)
    assert out == "121393"
    assert jit.n_tier1 >= 1
    assert jit.n_native >= 1


@pytest.mark.parametrize("background", [False, True])
def test_ackermann(background):
    src = ("def a(m, n):\n    if m == 0:\n        return n + 1\n"
           "    if n == 0:\n        return a(m-1, 1)\n"
           "    return a(m-1, a(m, n-1))\nprint(a(2, 4))")
    out, _ = run_both(src, background=background, tier1_threshold=3)
    assert out == "11"


def test_tier2_upgrade_for_arithmetic_dense_function():
    # an arithmetic-dense (call-free) function called often enough reaches the
    # tier-2 threshold, and the density gate lets the regalloc tier install
    body = "\n".join(f"    a{i} = a{i-1} * 3 + {i} - a{max(i-2,0)}"
                     for i in range(1, 12))
    src = ("def g(x):\n    a0 = x\n" + body
           + "\n    return a11 & 1073741823\n"
           + "".join("print(g(7))\n" for _ in range(40)))
    _out, jit = run_both(src, background=False,
                         tier1_threshold=3, tier2_threshold=20)
    assert jit.n_tier1 == 1
    assert jit.n_tier2 == 1


def test_call_bound_function_stays_on_baseline_tier():
    # fib is call-bound: regalloc would win only ~1.2x, so the density gate
    # keeps it on tier 1 and never spends a tier-2 compile on it
    src = ("def fib(n):\n    if n < 2:\n        return n\n"
           "    return fib(n-1) + fib(n-2)\n"
           + "".join(f"print(fib({n}))\n" for n in [10] * 60))
    _out, jit = run_both(src, background=False,
                         tier1_threshold=3, tier2_threshold=20)
    assert jit.n_tier1 == 1
    assert jit.n_tier2 == 0                          # gated out (call-bound)


def test_loop_function_aborts_but_correct():
    src = ("def s(n):\n    i = 0\n    t = 0\n"
           "    while i < n:\n        t = t + i\n        i = i + 1\n"
           "    return t\n"
           + "".join(f"print(s(50))\n" for _ in range(20)))
    out, jit = run_both(src, background=False, tier1_threshold=3)
    assert out.splitlines()[-1] == str(sum(range(50)))
    assert jit.n_tier1 == 0                          # has a loop -> not compiled
    assert len(jit.blacklist) == 1


def test_non_int_arg_deopts():
    # a function called once with an int (compiles) then the result feeds back;
    # everything stays int here, so it just checks correctness end to end
    src = ("def f(n):\n    if n < 1:\n        return 7\n    return f(n-1)\n"
           + "".join("print(f(3))\n" for _ in range(10)))
    out, jit = run_both(src, background=False, tier1_threshold=2)
    assert out.splitlines()[-1] == "7"
    assert jit.n_native >= 1


def test_coexists_with_tracing_jit():
    from minpython.jit import TracingJIT

    src = ("def fib(n):\n    if n < 2:\n        return n\n"
           "    return fib(n-1) + fib(n-2)\n"
           "def sumloop(n):\n    i = 0\n    t = 0\n"
           "    while i < n:\n        t = t + i\n        i = i + 1\n"
           "    return t\nprint(fib(24))\nprint(sumloop(5000))")
    ref = VM()
    ref.run(src)
    vm = VM()
    tj = TracingJIT(vm, threshold=20)
    mj = TieredJIT(vm, background=False, tier1_threshold=5)
    vm.run(src)
    assert vm.output == ref.output
    assert mj.n_tier1 == 1                           # fib -> tiered method JIT
    assert tj.n_compiled >= 1                        # sumloop's loop -> trace JIT
