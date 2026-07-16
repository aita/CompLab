"""Tests for the dual-mapping (memfd) executable-page runtime.

The runtime backs each page with one physical region mapped twice: a writable
view code is copied through and a permanently read+execute view it runs from.
This keeps every already-placed function continuously executable while add()
copies a new one in, so a thread may execute pooled code concurrently with adds.
"""

import ctypes
import threading

from jit import Assembler, Runtime, RAX, RDI


def _const_fn(value):
    """Assemble `mov rax, value; ret` -> ObjectCode."""
    a = Assembler()
    a.mov(RAX, value)
    a.ret()
    return a.finalize()


def _identity_fn():
    """Assemble `mov rax, rdi; ret` -> ObjectCode (returns its first arg)."""
    a = Assembler()
    a.mov(RAX, RDI)
    a.ret()
    return a.finalize()


def test_basic_add_and_execute():
    rt = Runtime()  # keep alive: owns the executable pages
    addr = rt.add(_const_fn(42))
    fn = ctypes.CFUNCTYPE(ctypes.c_int64)(addr)
    assert fn() == 42


def test_basic_add_with_argument():
    rt = Runtime()
    addr = rt.add(_identity_fn())
    fn = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(addr)
    assert fn(1234) == 1234


def test_many_functions_share_pages_all_execute():
    # Each function is tiny, so many pack into shared pages. After every add,
    # each one must still return its own constant.
    rt = Runtime()
    count = 500
    fns = []
    for i in range(count):
        addr = rt.add(_const_fn(i))
        fns.append(ctypes.CFUNCTYPE(ctypes.c_int64)(addr))

    # Fewer pages than functions -> they really are packed together.
    assert len(rt._pages) < count

    for i, fn in enumerate(fns):
        assert fn() == i


def test_concurrent_execute_while_adding():
    # The property dual mapping enables: a thread can keep CALLING an
    # already-added function in a loop while the main thread adds many more
    # functions to the SAME runtime (writing into the same shared pages). The
    # looping thread must never crash and must always get the right result.
    rt = Runtime()
    victim_addr = rt.add(_const_fn(7))
    victim = ctypes.CFUNCTYPE(ctypes.c_int64)(victim_addr)

    errors = []
    stop = threading.Event()

    def hammer():
        try:
            while not stop.is_set():
                for _ in range(1000):
                    if victim() != 7:
                        errors.append("wrong result")
                        return
        except Exception as exc:  # pragma: no cover - failure path
            errors.append(repr(exc))

    t = threading.Thread(target=hammer)
    t.start()
    try:
        # Add enough functions to spill across many pages while the hammer runs.
        for i in range(2000):
            addr = rt.add(_const_fn(i))
            assert ctypes.CFUNCTYPE(ctypes.c_int64)(addr)() == i
    finally:
        stop.set()
        t.join()

    assert errors == []
    # The original function is still intact after all the concurrent adds.
    assert victim() == 7
