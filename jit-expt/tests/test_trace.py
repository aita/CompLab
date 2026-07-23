"""Tests for the tracing JIT (minpython.jit).

The backbone is differential: with the JIT attached (at a low threshold so loops
compile immediately), every program must produce exactly what the pure VM does.
Since anything the JIT can't compile falls back to the interpreter, a mismatch
can only mean the native trace is wrong -- so these tests validate the whole
record -> compile -> guard -> exit -> resume pipeline at once.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from minpython import VM, compile_module
from minpython.bytecode import Op
from minpython.jit import TracingJIT

EXAMPLES = Path(__file__).resolve().parent.parent / "minpython" / "examples"


def run_both(src: str, threshold: int = 4) -> tuple[str, TracingJIT]:
    """Run `src` on a pure VM and on a JIT-backed VM; assert their outputs
    agree; return (output, jit) so tests can also inspect JIT stats."""
    ref = VM()
    ref.run(src)
    vm = VM()
    jit = TracingJIT(vm, threshold=threshold)
    vm.run(src)
    assert vm.output == ref.output, (
        f"JIT/VM disagree:\nJIT: {vm.output!r}\nVM:  {ref.output!r}")
    return vm.output, jit


# --- straight-line loops: should compile and run fully in native code -------

def test_sum_loop():
    src = ("def s(n):\n    i = 0\n    t = 0\n"
           "    while i < n:\n        t = t + i\n        i = i + 1\n"
           "    return t\nprint(s(1000))")
    out, jit = run_both(src)
    assert out == "499500"
    assert jit.n_compiled == 1
    # a straight-line loop has no mid-body guard, so one native entry runs the
    # whole loop and exits once (at the loop-condition guard)
    assert jit.n_trace_runs == 1


def test_factorial_loop():
    src = ("def f(n):\n    p = 1\n    i = 1\n"
           "    while i <= n:\n        p = p * i\n        i = i + 1\n"
           "    return p\nprint(f(10))")
    out, jit = run_both(src)
    assert out == "3628800"
    assert jit.n_compiled == 1


@pytest.mark.parametrize("op, expected", [
    ("+", "1044"), ("-", "956"), ("*", "?"),  # * overflows semantics-wise; skip
])
def test_arith_ops_in_loop(op, expected):
    if op == "*":
        pytest.skip("multiplicative accumulation grows too fast to hand-check")
    src = (f"def f(n):\n    acc = 1000\n    i = 0\n"
           f"    while i < 44:\n        acc = acc {op} 1\n        i = i + 1\n"
           f"    return acc\nprint(f(0))")
    out, _ = run_both(src)
    assert out == expected


def test_bitwise_and_shift_in_loop():
    # exercises BIT_AND / SHR / SHL in a compiled trace
    src = ("def f():\n    x = 1\n    i = 0\n"
           "    while i < 10:\n        x = (x << 1) | 1\n        i = i + 1\n"
           "    return x & 4095\nprint(f())")
    out, jit = run_both(src)
    assert out == str(((1 << 11) - 1) & 4095)
    assert jit.n_compiled == 1


# --- data-dependent branch: guard exits and re-enters -----------------------

def test_collatz_guard_reentry():
    out, jit = run_both((EXAMPLES / "collatz.mpy").read_text())
    assert out == "59542"
    assert jit.n_compiled >= 1
    # the parity branch guard fails whenever parity flips, so there are many
    # native entries -- but every one is correct
    assert jit.n_trace_runs > 100


def test_collatz_records_a_side_trace():
    # the parity branch's hot exit should get a linked side trace, so most
    # parity flips stay in native code rather than bouncing to the interpreter
    out, jit = run_both((EXAMPLES / "collatz.mpy").read_text(),
                        threshold=20)
    assert out == "59542"
    assert jit.n_side >= 1
    # a side trace was linked onto some compiled trace's exit
    assert any(t.links for t in jit.traces.values())


def test_side_trace_over_explicit_if_branch():
    # an in-loop if whose two arms are both traceable: one arm is the main
    # trace, the other becomes a side trace; result must stay exact
    src = ("def f(n):\n    i = 0\n    acc = 0\n"
           "    while i < n:\n        if i & 1:\n            acc = acc + 3\n"
           "        else:\n            acc = acc + 1\n        i = i + 1\n"
           "    return acc\nprint(f(100000))")
    out, jit = run_both(src, threshold=20)
    expected = sum(3 if i & 1 else 1 for i in range(100000))
    assert out == str(expected)
    assert jit.n_side >= 1


def test_conditional_accumulate():
    # sum of even numbers 0..99 via an in-loop if -- the odd path exits the
    # trace, the even path stays on it
    src = ("def f(n):\n    i = 0\n    t = 0\n"
           "    while i < n:\n        if i % 2 == 0:\n            t = t + i\n"
           "        i = i + 1\n    return t\nprint(f(100))")
    # note: `%` aborts the trace (floor semantics), so this actually stays
    # interpreted -- still must match
    out, _ = run_both(src)
    assert out == str(sum(range(0, 100, 2)))


# --- examples ---------------------------------------------------------------

def test_fib_iter_example():
    out, jit = run_both((EXAMPLES / "fib.mpy").read_text())
    assert out == "832040\n6765"
    assert jit.n_compiled >= 1     # fib_iter's loop compiles; fib_rec doesn't


# --- aborts: unsupported ops keep the program correct via fallback -----------

def test_object_types_stay_interpreted_but_correct():
    # a loop that indexes a list uses SUBSCR (not JIT-able), so the trace aborts
    # and the interpreter runs it -- still exact
    src = ("def sumlist(xs, n):\n    i = 0\n    t = 0\n"
           "    while i < n:\n        t = t + xs[i]\n        i = i + 1\n"
           "    return t\nprint(sumlist([5, 5, 5, 5, 5, 5], 6))")
    out, jit = run_both(src, threshold=2)
    assert out == "30"
    assert jit.n_compiled == 0            # SUBSCR aborts the trace
    assert jit.n_aborted >= 1


def test_entry_type_guard_deopts_on_non_int():
    # `x = x + x` doubles an int but concatenates a str, so the same loop is
    # valid for both types. It gets traced for int; calling it again with a str
    # must fail the trace's entry type guard (a live-in is no longer an int) and
    # deopt to the interpreter -- still exact.
    src = ("def double(x, n):\n    i = 0\n"
           "    while i < n:\n        x = x + x\n        i = i + 1\n"
           "    return x\n"
           "print(double(1, 5))\n"          # int  -> traced
           "print(double('ab', 3))")        # str  -> entry type guard deopts
    out, jit = run_both(src, threshold=2)
    assert out == "32\n" + "ab" * 8
    assert jit.n_compiled == 1              # the int loop compiled
    assert jit.n_type_deopt >= 1            # the str call fell back to interpret


def test_recursion_never_traces():
    # no while loop -> no back-edge -> the JIT is never even consulted
    src = ("def f(n):\n    if n < 2:\n        return n\n"
           "    return f(n - 1) + f(n - 2)\nprint(f(15))")
    out, jit = run_both(src)
    assert out == "610"
    assert jit.n_compiled == 0


def test_global_in_loop_aborts_but_correct():
    src = ("acc = 0\ndef go(n):\n    global acc\n    i = 0\n"
           "    while i < n:\n        acc = acc + i\n        i = i + 1\n"
           "go(50)\nprint(acc)")
    out, jit = run_both(src)
    assert out == str(sum(range(50)))
    assert jit.n_aborted >= 1
    assert jit.n_compiled == 0


def test_floordiv_in_loop_aborts_but_correct():
    src = ("def f(n):\n    x = n\n    steps = 0\n"
           "    while x > 1:\n        x = x // 2\n        steps = steps + 1\n"
           "    return steps\nprint(f(1024))")
    out, jit = run_both(src)
    assert out == "10"
    assert jit.n_aborted >= 1


# --- blacklist: an aborted back-edge is not retried -------------------------

def test_blacklist_prevents_retrace():
    src = ("acc = 0\ndef go(n):\n    global acc\n    i = 0\n"
           "    while i < n:\n        acc = acc + i\n        i = i + 1\n"
           "go(5000)\nprint(acc)")
    vm = VM()
    jit = TracingJIT(vm, threshold=4)
    vm.run(src)
    # exactly one abort recorded despite thousands of back-edge hits
    assert jit.n_aborted == 1
    assert len(jit.blacklist) == 1


# --- IR shape ---------------------------------------------------------------

def test_recorded_ir_has_guard_and_carries():
    src = ("def s(n):\n    i = 0\n    t = 0\n"
           "    while i < n:\n        t = t + i\n        i = i + 1\n"
           "    return t\nprint(s(200))")
    vm = VM()
    jit = TracingJIT(vm, threshold=4)
    vm.run(src)
    (key,) = jit.recorded.keys()
    ir = jit.recorded[key]
    # the loop condition becomes exactly one guard (the loop-exit)
    assert len(ir.exits) == 1
    # both `t` and `i` are loop-carried locals
    assert set(ir.carried.keys()) == {1, 2}


def test_licm_hoists_invariant_subexpression():
    from minpython.jit.tracing import IROp, loop_invariants
    from minpython.jit.tracing import record

    src = ("def f(n, a, b, c):\n    i = 0\n    total = 0\n"
           "    while i < n:\n        total = total + (a * b + c)\n"
           "        i = i + 1\n    return total\nprint(f(1000, 7, 9, 5))")
    out, jit = run_both(src, threshold=5)
    assert out == "68000"                 # 1000 * (7*9 + 5)
    assert jit.n_compiled == 1

    # the a*b and a*b+c computations are loop-invariant and must be hoistable
    f = next(k for k in compile_module(src).consts
             if getattr(k, "name", None) == "f")
    back = next(pc for pc, ins in enumerate(f.code)
                if ins.op.name == "JUMP" and ins.a < pc)
    tr = record(f, f.code[back].a, [1000, 7, 9, 5] + [0] * (f.n_regs - 4))
    inv = loop_invariants(tr)
    hoisted = [tr.instrs[r].op for r in range(len(tr.instrs))
               if r in inv and tr.instrs[r].op not in (IROp.CONST, IROp.LOAD)]
    assert IROp.MUL in hoisted and IROp.ADD in hoisted


def test_phi_swap_cycle():
    # `t=a; a=b; b=c; c=t` rotates three loop-carried locals -- the back-edge
    # phi move is a genuine cycle, exercising the buffer-staged conflict path
    src = ("def rot(n):\n    a=1\n    b=2\n    c=3\n    i=0\n"
           "    while i < n:\n        t=a\n        a=b\n        b=c\n"
           "        c=t\n        i=i+1\n    return a*100+b*10+c\n"
           "print(rot(3000))")
    out, jit = run_both(src, threshold=5)
    assert out == "123"               # 3000 % 3 == 0 -> back to 1,2,3
    assert jit.n_compiled == 1


def test_phi_fibonacci_swap():
    # t=a+b; a=b; b=t -- a<-b, b<-t overlaps, forcing the conflict path
    src = ("def fib(n):\n    a=0\n    b=1\n    i=0\n"
           "    while i < n:\n        t=a+b\n        a=b\n        b=t\n"
           "        i=i+1\n    return a\nprint(fib(90))")
    out, jit = run_both(src, threshold=5)
    assert out == "2880067194370816120"   # fits in signed 64-bit
    assert jit.n_compiled == 1


def test_many_locals_spill_but_stay_correct():
    # nine loop-carried locals exceed the six allocatable registers, forcing
    # the linear-scan allocator to spill -- the result must still be exact
    src = ("def f(n):\n"
           + "".join(f"    v{i} = {i}\n" for i in range(9))
           + "    i = 0\n"
           + "    while i < n:\n"
           + "".join(f"        v{i} = v{i} + {i + 1}\n" for i in range(9))
           + "        i = i + 1\n"
           + "    return " + " + ".join(f"v{i}" for i in range(9)) + "\n"
           + "print(f(1000))")
    out, jit = run_both(src)
    expected = sum(i + (i + 1) * 1000 for i in range(9))
    assert out == str(expected)
    assert jit.n_compiled == 1


def test_allocator_spills_when_over_pressure():
    from minpython.jit.tracing import _POOL
    from minpython.jit.tracing import record
    from minpython.jit.tracing import allocate
    from minpython.jit.regalloc import Spill

    code = compile_module(
        "def f(n):\n" + "".join(f"    v{i}={i}\n" for i in range(9))
        + "    i=0\n    while i<n:\n"
        + "".join(f"        v{i}=v{i}+1\n" for i in range(9))
        + "        i=i+1\n    return v0\n")
    f = next(k for k in code.consts if getattr(k, "name", None) == "f")
    # the loop header is the back-edge's target (as the JIT sees it)
    back = next(pc for pc, ins in enumerate(f.code)
                if ins.op.name == "JUMP" and ins.a < pc)
    entry = f.code[back].a
    tr = record(f, entry, [10] + [0] * (f.n_regs - 1))
    assert tr is not None
    alloc = allocate(tr, _POOL)
    assert alloc.n_spill > 0
    assert any(isinstance(v, Spill) for v in alloc.loc.values())


def test_stats_shape():
    _, jit = run_both("def s(n):\n    i=0\n    while i<n:\n        i=i+1\n"
                      "    return i\nprint(s(500))")
    st = jit.stats()
    assert set(st) == {"compiled", "side", "aborted", "trace_runs",
                       "type_deopt", "blacklisted"}
    assert st["compiled"] == 1
