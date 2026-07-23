"""Tests for the method (function) JIT (minpython.jit.method).

Differential, like the trace tests: with the method JIT attached (low
threshold), every program must produce exactly what the pure VM does. Anything
outside the v1 subset aborts and stays interpreted, so a mismatch can only mean
the native function is wrong."""

from __future__ import annotations

import pytest

from minpython import VM
from minpython.jit.method import MethodJIT, compile_method
from minpython.compile import compile_module


def run_both(src: str, threshold: int = 3) -> tuple[str, MethodJIT]:
    ref = VM()
    ref.run(src)
    vm = VM()
    mj = MethodJIT(vm, threshold=threshold)
    vm.run(src)
    assert vm.output == ref.output, (
        f"method-JIT/VM disagree:\nMJIT: {vm.output!r}\nVM:   {ref.output!r}")
    return vm.output, mj


# --- recursion compiles and runs natively -----------------------------------

def test_fib_recursion():
    src = ("def fib(n):\n    if n < 2:\n        return n\n"
           "    return fib(n-1) + fib(n-2)\nprint(fib(25))")
    out, mj = run_both(src)
    assert out == "75025"
    assert mj.n_compiled == 1
    assert mj.n_calls_native >= 1


def test_recursive_factorial():
    src = ("def f(n):\n    if n <= 1:\n        return 1\n"
           "    return n * f(n-1)\nprint(f(15))")
    out, mj = run_both(src)
    assert out == "1307674368000"
    assert mj.n_compiled == 1


def test_regalloc_keeps_values_in_registers():
    # fib's values all fit the callee-saved pool with no spills; the point is
    # that they survive the recursive call (callee-saved) -- verified by the
    # result being correct
    from minpython.jit.method import _allocate, _live_ranges, _reachable
    from minpython.jit.regalloc import Spill

    f = next(k for k in compile_module(
        "def fib(n):\n    if n < 2:\n        return n\n"
        "    return fib(n-1) + fib(n-2)\n").consts
        if getattr(k, "name", None) == "fib")
    loc, used, n_spill = _allocate(_live_ranges(f, _reachable(f)),
                                   len(f.params))
    assert n_spill == 0
    assert not any(isinstance(v, Spill) for v in loc.values())


def test_recursion_with_register_spilling():
    # six parameters plus temporaries stay live across the self-call, exceeding
    # the five allocatable registers -> the allocator must spill, and the result
    # must still be exact
    src = ("def f(a, b, c, d, e, n):\n"
           "    if n <= 0:\n        return a + b + c + d + e\n"
           "    return (a + b + c + d + e) + f(a+1, b+2, c+3, d+4, e+5, n-1)\n"
           "print(f(1, 2, 3, 4, 5, 20))")
    out, mj = run_both(src)
    ref = VM()
    ref.run(src)
    assert out == ref.output
    assert mj.n_compiled == 1

    from minpython.jit.method import _allocate, _live_ranges, _reachable
    f = next(k for k in compile_module(src).consts
             if getattr(k, "name", None) == "f")
    _loc, _used, n_spill = _allocate(_live_ranges(f, _reachable(f)),
                                     len(f.params))
    assert n_spill > 0


def test_ackermann_two_args():
    src = ("def a(m, n):\n    if m == 0:\n        return n + 1\n"
           "    if n == 0:\n        return a(m-1, 1)\n"
           "    return a(m-1, a(m, n-1))\nprint(a(2, 3))")
    out, mj = run_both(src)
    assert out == "9"
    assert mj.n_compiled == 1


def test_branchy_no_loop_function():
    # both arms of the if are hot -- the case a single-path trace handles badly
    # but a method JIT compiles wholesale
    src = ("def classify(x):\n    if x < 0:\n        return 0 - x\n"
           "    return x + 1\n"
           "def go(n):\n    i = 0\n    s = 0\n"
           "    while i < n:\n        s = s + classify(i - 50)\n"
           "        i = i + 1\n    return s\nprint(go(100))")
    out, mj = run_both(src)
    # classify gets compiled (recursion-free, branchy); go has a loop -> aborts
    assert mj.n_compiled == 1
    ref = VM()
    ref.run(src)
    assert out == ref.output


# --- graceful abort keeps results correct -----------------------------------

def test_mutual_recursion_aborts():
    src = ("def ev(n):\n    if n == 0:\n        return 1\n    return od(n-1)\n"
           "def od(n):\n    if n == 0:\n        return 0\n    return ev(n-1)\n"
           "print(ev(10))")
    out, mj = run_both(src)
    assert out == "1"
    # neither is a resolvable self-call, so both blacklist and stay interpreted
    assert mj.n_compiled == 0
    assert len(mj.blacklist) == 2


def test_function_with_loop_is_not_method_compiled():
    src = ("def s(n):\n    i = 0\n    t = 0\n"
           "    while i < n:\n        t = t + i\n        i = i + 1\n"
           "    return t\n"
           "def go(k):\n    j = 0\n    r = 0\n"
           "    while j < k:\n        r = s(5)\n        j = j + 1\n"
           "    return r\nprint(go(20))")
    out, mj = run_both(src)
    ref = VM()
    ref.run(src)
    assert out == ref.output
    # `s` contains a loop -> compile_method refuses it
    s_code = next(k for k in compile_module(src).consts
                  if getattr(k, "name", None) == "s")
    from jit import Runtime  # a runtime for the attempt
    assert compile_method(s_code, Runtime()) is None


def test_global_read_aborts():
    src = ("k = 7\ndef f(n):\n    return n + k\n"
           "def go(m):\n    i = 0\n    s = 0\n"
           "    while i < m:\n        s = f(i)\n        i = i + 1\n"
           "    return s\nprint(go(50))")
    out, mj = run_both(src)
    ref = VM()
    ref.run(src)
    assert out == ref.output
    assert mj.n_compiled == 0            # f reads a real global -> aborts


# --- coexistence with the tracing JIT ---------------------------------------

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
    mj = MethodJIT(vm, threshold=5)
    tj = TracingJIT(vm, threshold=20)
    vm.run(src)
    assert vm.output == ref.output
    assert mj.n_compiled == 1            # fib -> method JIT
    assert tj.n_compiled >= 1            # sumloop's loop -> tracing JIT


# --- compile_method feasibility gate ----------------------------------------

@pytest.mark.parametrize("body, ok", [
    ("    return n + 1", True),
    ("    return n // 2", False),        # floor division not in v1
    ("    return n % 3", False),
    ("    print(n)\n    return n", False),  # print not supported
])
def test_feasibility_gate(body, ok):
    from jit import Runtime
    src = f"def f(n):\n{body}\n"
    code = next(k for k in compile_module(src).consts
                if getattr(k, "name", None) == "f")
    result = compile_method(code, Runtime())
    assert (result is not None) == ok
