"""Tests for the optional Cython dispatch loop (minpython._dispatch).

These need Cython and a C compiler; the whole module is skipped if the extension
can't be built, so a toolchain-less environment still passes the rest of the
suite. The core check is differential: the Cython VM must agree with the pure
Python VM on every program."""

from __future__ import annotations

from pathlib import Path

import pytest

from minpython import VM
from minpython._cydispatch import load

pytestmark = pytest.mark.skipif(
    load() is None, reason="Cython or a C compiler is unavailable")

EXAMPLES = Path(__file__).resolve().parent.parent / "minpython" / "examples"


def agree(src: str) -> str:
    """Run on the pure VM and the Cython VM; assert they agree; return the
    output."""
    py = VM()
    py.run(src)
    cy = VM(cython=True)
    cy.run(src)
    assert cy.using_cython
    assert py.output == cy.output
    return cy.output


def test_cython_available():
    assert VM(cython=True).using_cython


@pytest.mark.parametrize("expr, expected", [
    ("2 + 3 * 4", "14"),
    ("17 // 5", "3"),
    ("2 ** 10", "1024"),
    ("13 & 6", "4"),
    ("1 << 8", "256"),
    ("1024 >> 3", "128"),
    ("~0", "-1"),
    ("not 0", "True"),
    ("1 < 2 < 3", "True"),
    ("0 or 7", "7"),
])
def test_expressions(expr, expected):
    assert agree(f"print({expr})") == expected


def test_loops_and_branches():
    src = ("def collatz(n):\n    total = 0\n    x = 1\n"
           "    while x <= n:\n        y = x\n"
           "        while y != 1:\n            if y & 1:\n"
           "                y = 3 * y + 1\n            else:\n"
           "                y = y >> 1\n            total = total + 1\n"
           "        x = x + 1\n    return total\nprint(collatz(300))")
    assert agree(src) == "14167"


def test_recursion():
    assert agree("def f(n):\n    if n < 2:\n        return n\n"
                 "    return f(n-1) + f(n-2)\nprint(f(20))") == "6765"


def test_global_and_augassign():
    assert agree("acc = 0\ndef go(n):\n    global acc\n    i = 0\n"
                 "    while i < n:\n        acc = acc + i\n        i = i + 1\n"
                 "go(100)\nprint(acc)") == "4950"


def test_examples():
    assert agree((EXAMPLES / "collatz.mpy").read_text()) == "59542"
    assert agree((EXAMPLES / "fib.mpy").read_text()) == "832040\n6765"


def test_cython_vm_drives_the_jit():
    # the JIT's on_backedge hook must fire from inside the compiled loop
    from minpython.jit import TracingJIT

    src = (EXAMPLES / "collatz.mpy").read_text()
    ref = VM()
    ref.run(src)
    vm = VM(cython=True)
    jit = TracingJIT(vm, threshold=20)
    vm.run(src)
    assert vm.output == ref.output
    assert jit.n_compiled >= 1
