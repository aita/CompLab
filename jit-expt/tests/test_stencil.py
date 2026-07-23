"""Tests for the compiled-stencil baseline JIT (minpython.jit.stencil).

Needs a C toolchain to build the stencils; skipped otherwise. Differential: the
stitched native function must return exactly what the interpreter does."""

from __future__ import annotations

import pytest

from minpython import VM
from minpython.compile import compile_module
from minpython.jit import stencil
from minpython.jit.stencil import compile_stencil
from jit import Runtime

pytestmark = pytest.mark.skipif(
    not stencil.available(), reason="no C toolchain for stencils")

# One Runtime held alive for the whole module: a compiled function's code lives
# in the Runtime's executable pages, so it must outlive the ctypes callable.
RT = Runtime()


def _fn(src: str, name: str):
    return next(k for k in compile_module(src).consts
               if getattr(k, "name", None) == name)


def _call_via_vm(src: str, name: str, arg: int) -> int:
    """What the interpreter computes for name(arg)."""
    vm = VM()
    vm.run(src + f"\nprint({name}({arg}))")
    return int(vm.output.splitlines()[-1])


def test_stencils_extracted():
    from minpython.bytecode import Op
    tbl = stencil._build()
    assert tbl is not None
    for op in (Op.ADD, Op.SUB, Op.MUL, Op.LT, Op.MOVE, Op.RSHIFT):
        st = tbl[op]
        assert st.code and st.code[-1] != 0xC3          # ret stripped
        assert all(r in ("a", "b", "c") for _off, r in st.holes)


def test_fib():
    src = ("def fib(n):\n    if n < 2:\n        return n\n"
           "    return fib(n-1) + fib(n-2)\n")
    f = compile_stencil(_fn(src, "fib"), RT)
    for n in (0, 1, 10, 20, 25):
        assert f(n) == _call_via_vm(src, "fib", n)


def test_recursive_factorial():
    src = "def f(n):\n    if n <= 1:\n        return 1\n    return n * f(n-1)\n"
    f = compile_stencil(_fn(src, "f"), RT)
    assert f(12) == 479001600


def test_ackermann():
    src = ("def a(m, n):\n    if m == 0:\n        return n + 1\n"
           "    if n == 0:\n        return a(m-1, 1)\n"
           "    return a(m-1, a(m, n-1))\n")
    a = compile_stencil(_fn(src, "a"), RT)
    assert a(2, 3) == 9
    assert a(3, 3) == 61


@pytest.mark.parametrize("expr, x, expected", [
    ("x + 3", 7, 10),
    ("x - 3", 7, 4),
    ("x * x", 6, 36),
    ("(x << 2) | 1", 5, 21),
    ("x >> 1", 41, 20),
    ("0 - x", 9, -9),
    ("~x", 5, -6),
    ("x & 12", 10, 8),
])
def test_arithmetic(expr, x, expected):
    src = f"def g(x):\n    return {expr}\n"
    g = compile_stencil(_fn(src, "g"), RT)
    assert g(x) == expected


def test_rejects_out_of_subset():
    # a loop -> not a method-JIT subset -> None (left to the tracing JIT)
    src = ("def s(n):\n    i = 0\n    t = 0\n"
           "    while i < n:\n        t = t + i\n        i = i + 1\n"
           "    return t\n")
    assert compile_stencil(_fn(src, "s"), RT) is None
