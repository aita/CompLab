"""Tests for the MinPython register VM (minpython.vm) and compiler.

The VM is checked against hand-written expected output on each program; the JIT
suites then check every backend against this VM differentially."""

from __future__ import annotations

from pathlib import Path

import pytest

from minpython import VM, MinPythonError, compile_module, disassemble
from minpython.bytecode import CodeObject, Op

EXAMPLES = Path(__file__).resolve().parent.parent / "minpython" / "examples"


def both(source: str) -> str:
    """Run `source` on the VM and return its output."""
    vm = VM()
    vm.run(source)
    return vm.output


# --- expressions ------------------------------------------------------------

@pytest.mark.parametrize("expr, expected", [
    ("2 + 3 * 4", "14"),
    ("(2 + 3) * 4", "20"),
    ("17 // 5", "3"),
    ("17 % 5", "2"),
    ("2 ** 10", "1024"),
    ("-7", "-7"),
    ("~0", "-1"),
    ("13 & 6", "4"),
    ("1 | 4", "5"),
    ("5 ^ 3", "6"),
    ("1 << 8", "256"),
    ("1024 >> 3", "128"),
    ("not 0", "True"),
    ("not 5", "False"),
    ("1 < 2 < 3", "True"),
    ("1 < 2 > 3", "False"),
    ("0 or 7", "7"),
    ("3 and 4", "4"),
    ("0 and 9", "0"),
    ("2 or 9", "2"),
    ("10 if 1 else 20", "10"),
    ("10 if 0 else 20", "20"),
    ("True == 1", "True"),
])
def test_expr(expr, expected):
    assert both(f"print({expr})") == expected


def test_nested_expression():
    assert both("print(((1 + 2) * (3 + 4)) // 2 - 1)") == "9"


# --- control flow & statements ---------------------------------------------

def test_augassign_chain():
    assert both("x = 5\nx += 3\nx *= 2\nprint(x)") == "16"


def test_if_elif_else():
    src = """
def sign(n):
    if n > 0:
        return 1
    elif n < 0:
        return -1
    else:
        return 0
print(sign(5))
print(sign(-5))
print(sign(0))
"""
    assert both(src) == "1\n-1\n0"


def test_while_break_continue():
    src = """
i = 0
total = 0
while True:
    i = i + 1
    if i > 10:
        break
    if i % 2 == 0:
        continue
    total = total + i
print(total)
"""
    assert both(src) == "25"


def test_global():
    src = """
counter = 0
def bump():
    global counter
    counter = counter + 1
bump()
bump()
bump()
print(counter)
"""
    assert both(src) == "3"


def test_local_does_not_leak():
    src = """
x = 100
def f():
    x = 1
    return x
print(f())
print(x)
"""
    assert both(src) == "1\n100"


def test_recursion():
    assert both("def fact(n):\n"
                "    if n <= 1:\n        return 1\n"
                "    return n * fact(n - 1)\n"
                "print(fact(6))") == "720"


def test_mutual_recursion():
    src = """
def is_even(n):
    if n == 0:
        return True
    return is_odd(n - 1)
def is_odd(n):
    if n == 0:
        return False
    return is_even(n - 1)
print(is_even(10))
print(is_odd(10))
"""
    assert both(src) == "True\nFalse"


def test_implicit_return_none():
    assert both("def nop():\n    pass\nprint(nop())") == "None"


def test_print_multiple_args():
    assert both("print(1, 2, 3)") == "1 2 3"


# --- examples ---------------------------------------------------------------

def test_collatz_example():
    assert both((EXAMPLES / "collatz.mpy").read_text()) == "59542"


def test_fib_example():
    assert both((EXAMPLES / "fib.mpy").read_text()) == "832040\n6765"


# --- hot-loop profiling / tracing hooks ------------------------------------

def test_backedge_counts():
    vm = VM(profile=True)
    vm.run("i = 0\nwhile i < 5:\n    i = i + 1\n")
    # one back-edge, taken once per completed iteration (5)
    assert list(vm.loop_counts.values()) == [5]


def test_on_backedge_hook_fires():
    src = "i = 0\nwhile i < 3:\n    i = i + 1\n"
    hits = []
    vm = VM()
    vm.on_backedge = lambda code, target, regs, glb: hits.append(target) or None
    vm.run(src)
    assert len(hits) == 3
    assert len(set(hits)) == 1  # same back-edge target every time


def test_on_backedge_can_redirect_pc():
    # A hook returning an int redirects the interpreter to that pc -- the seam a
    # JIT uses to hand control back after running compiled code. Here we fake it:
    # jump a loop that would otherwise spin forever straight to its exit. The
    # <spin> ends with `LOAD_CONST None; RETURN`; resuming at that LOAD_CONST
    # ends the loop and returns None cleanly.
    src = """
def spin():
    while True:
        pass
print(spin())
"""
    from minpython import compile_module
    spin_code = next(k for k in compile_module(src).consts
                     if getattr(k, "name", None) == "spin")
    exit_pc = len(spin_code.code) - 2  # the trailing LOAD_CONST None
    vm = VM()
    vm.on_backedge = lambda code, target, regs, glb: exit_pc
    vm.run(src)
    assert vm.output == "None"


def test_profile_off_records_nothing():
    vm = VM(profile=False)
    vm.run("i = 0\nwhile i < 3:\n    i = i + 1\n")
    assert vm.loop_counts == {}


# --- compiler / disassembler -----------------------------------------------

def test_compile_module_returns_code_object():
    code = compile_module("x = 1\nprint(x)")
    assert isinstance(code, CodeObject)
    assert code.name == "<module>"
    assert code.code[-1].op == Op.RETURN  # always ends in a return


def test_disassemble_smoke():
    text = disassemble(compile_module("def f(a, b):\n    return a + b\nf(1, 2)"))
    assert "f(a, b)" in text
    assert "ADD" in text
    assert "RETURN" in text


# --- str / list ------------------------------------------------------------

def test_str_literal_concat_len():
    assert both("s = 'ab' + 'cd'\nprint(s)\nprint(len(s))") == "abcd\n4"


def test_str_index_and_compare():
    assert both("s = 'hello'\nprint(s[1])\nprint(s == 'hello')") == "e\nTrue"


def test_list_literal_index_len():
    assert both("xs = [10, 20, 30]\nprint(xs[1])\nprint(len(xs))") == "20\n3"


def test_empty_list():
    assert both("xs = []\nprint(len(xs))") == "0"


def test_list_concat():
    assert both("xs = [1, 2] + [3, 4]\nprint(len(xs))\nprint(xs[3])") == "4\n4"


def test_plus_across_int_str_list():
    assert both("print(1 + 2)\nprint('a' + 'b')\n"
                "print(len([1] + [2, 3]))") == "3\nab\n3"


def test_list_sum_loop():
    src = ("xs = [10, 20, 30, 40]\ni = 0\nt = 0\n"
           "while i < len(xs):\n    t = t + xs[i]\n    i = i + 1\nprint(t)")
    assert both(src) == "100"


# --- rejected constructs (compiler-time) -----------------------------------

@pytest.mark.parametrize("src, match", [
    ("print(1 / 2)", "not supported"),
    ("import os", "unsupported statement"),
    ("print(1.5)", "unsupported literal"),       # float still unsupported
    ("print(xs[1:3])", "slices are not supported"),
    ("while True:\n    pass\nelse:\n    pass", "while/else"),
    ("break", "outside loop"),
    ("continue", "outside loop"),
    ("f(a=1)", "keyword arguments"),
])
def test_rejected_at_compile(src, match):
    with pytest.raises(MinPythonError, match=match):
        compile_module(src)


def test_undefined_global_at_runtime():
    with pytest.raises(MinPythonError, match="not defined"):
        VM().run("print(nope)")
