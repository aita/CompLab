"""Tests for the dual-mapping (memfd) executable-page runtime.

The runtime backs each page with one physical region mapped twice: a writable
view code is copied through and a permanently read+execute view it runs from.
This keeps every already-placed function continuously executable while add()
copies a new one in, so a thread may execute pooled code concurrently with adds.
"""

import ctypes
import threading

import pytest

from jit import RAX, RDI, Assembler, JITAllocator, Runtime


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


def test_concurrent_adds_from_many_threads():
    # Several threads call add() on the SAME runtime at once. The lock must
    # serialize them so the bump allocator/symbol tables aren't corrupted: every
    # function gets a distinct address and returns its own value.
    rt = Runtime()
    threads = 8
    per_thread = 300
    results: list[list[tuple[int, int]]] = [[] for _ in range(threads)]
    errors = []

    def worker(tid):
        try:
            for i in range(per_thread):
                value = tid * per_thread + i
                addr = rt.add(_const_fn(value))
                results[tid].append((addr, value))
        except Exception as exc:  # pragma: no cover - failure path
            errors.append(repr(exc))

    ts = [threading.Thread(target=worker, args=(t,)) for t in range(threads)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()

    assert errors == []
    placed = [pair for r in results for pair in r]
    assert len(placed) == threads * per_thread
    # No two functions were allocated the same address (no cursor race).
    assert len({addr for addr, _ in placed}) == len(placed)
    # Every function still executes and returns its own value.
    for addr, value in placed:
        assert ctypes.CFUNCTYPE(ctypes.c_int64)(addr)() == value


def test_release_recycles_slot():
    rt = Runtime()
    a = rt.add(_const_fn(1))
    c = rt.add(_const_fn(3))   # keep `a` from being the tail slot
    rt.release(a)              # `a`'s slot becomes a reusable hole
    b = rt.add(_const_fn(2))   # same size -> reuses the freed hole
    assert b == a
    # The reused function and the untouched neighbour both run correctly.
    assert ctypes.CFUNCTYPE(ctypes.c_int64)(b)() == 2
    assert ctypes.CFUNCTYPE(ctypes.c_int64)(c)() == 3


def test_release_unknown_address_raises():
    rt = Runtime()
    with pytest.raises(KeyError):
        rt.release(0xDEAD0000)


def test_reset_soft_rewinds_and_reuses_pages():
    rt = Runtime()
    for i in range(5):
        rt.add(_const_fn(i))
    pages_before = list(rt._pages)
    rt.reset()  # soft: keep pages, rewind cursors
    assert rt._pages is not None and rt._pages == pages_before  # same Page objects
    addr = rt.add(_const_fn(99))
    assert addr == rt._pages[0].base  # cursor was rewound to the page start
    assert ctypes.CFUNCTYPE(ctypes.c_int64)(addr)() == 99


def test_reset_hard_drops_pages():
    rt = Runtime()
    rt.add(_const_fn(5))
    rt.reset(hard=True)
    assert rt._pages == []
    addr = rt.add(_const_fn(6))  # allocates a fresh page
    assert len(rt._pages) == 1
    assert ctypes.CFUNCTYPE(ctypes.c_int64)(addr)() == 6


def test_define_survives_reset():
    rt = Runtime()
    rt.define("ext", 0x1234)
    rt.reset()
    assert rt._symbols.get("ext") == 0x1234
    rt.reset(hard=True)
    assert rt._symbols.get("ext") == 0x1234


def test_allocator_alloc_write_release_recycle():
    alloc = JITAllocator()  # keep alive: owns the executable pages
    code = bytes(_const_fn(77).code)
    span = alloc.alloc(len(code))
    alloc.write(span, 0, code)
    assert ctypes.CFUNCTYPE(ctypes.c_int64)(span.rx)() == 77
    keep = alloc.alloc(len(code))       # stop `span` from being tail-reclaimed
    alloc.release(span.rx)
    reused = alloc.alloc(len(code))     # same size -> recycles the freed slot
    assert reused.rx == span.rx
    assert keep.rx != span.rx
