"""A tiered, background-compiling method JIT -- the whole point of the
free-threaded retarget.

Two tiers, the classic fast-compile-then-optimize shape:

  * tier 1 -- **baseline (stencil)** (`stencil.compile_stencil`). Stitches
    pre-built machine-code stencils, so it compiles almost instantly; stack-slot
    code quality. (This stitch-and-patch technique is "copy-and-patch" in the
    literature -- CPython's JIT.) Needs a C toolchain; without one there is no
    cheap baseline, so tier 1 falls back to the register allocator and the
    separate tier 2 is disabled.
  * tier 2 -- **register allocation** (`method.compile_method`). Slower to
    compile, much faster to run; kicks in only for the hottest *arithmetic-
    dense* functions (a call-bound function stays on the baseline -- see
    `_worth_tier2`).

Both compile on a **background thread**. When a function gets hot the driver
submits a compile job and *keeps interpreting* -- it never blocks at the trigger
point. When the job finishes it installs the native code under a lock, and the
next call picks it up. On free-threaded CPython 3.14 that compile genuinely runs
in parallel with the interpreter; under the GIL it still works, just serialized.

Correctness is unchanged from the other JITs: an int-only entry guard, and any
function outside the subset stays interpreted.
"""

from __future__ import annotations

import threading
from concurrent.futures import Future, ThreadPoolExecutor, wait
from typing import NamedTuple

from jit import Runtime

from ..bytecode import Op, Value
from . import stencil
from .method import compile_method


class _Compiled(NamedTuple):
    """A cached native function and which tier compiled it (so a tier-2 result
    can replace a tier-1 one, never the reverse)."""
    fn: object
    tier: int

# Value ops whose result the optimizing tier can keep in a register instead of a
# stack slot. Register allocation only pays off when there are many of these per
# call (arithmetic-dense code, ~2.8x); a call-bound function like fib does so
# little arithmetic between its `call`s that tier 2 wins only ~1.2x and is not
# worth its compile -- so tier 2 is gated on this density (see _worth_tier2).
_ARITH = frozenset({
    Op.ADD, Op.SUB, Op.MUL, Op.BIT_AND, Op.BIT_OR, Op.BIT_XOR,
    Op.LSHIFT, Op.RSHIFT, Op.NEG, Op.INVERT, Op.NOT,
    Op.EQ, Op.NE, Op.LT, Op.LE, Op.GT, Op.GE,
})


def _worth_tier2(code) -> bool:
    """Register allocation only earns its keep on arithmetic-dense functions.
    Upgrade to tier 2 only when the arithmetic op count dominates the call
    count; a call-bound function stays on the cheap baseline tier."""
    arith = sum(1 for ins in code.code if ins.op in _ARITH)
    calls = sum(1 for ins in code.code if ins.op == Op.CALL)
    return calls == 0 or arith >= 4 * calls


class TieredJIT:
    def __init__(self, vm, *, tier1_threshold: int = 10,
                 tier2_threshold: int = 500, background: bool = True,
                 workers: int = 1, runtime: Runtime | None = None,
                 log: bool = False):
        self.vm = vm
        self.rt = runtime or Runtime()
        self.t1 = tier1_threshold
        self.t2 = tier2_threshold
        self.background = background
        self.log = log

        # tier 1 is the C-compiled stencil baseline; without a toolchain there
        # is no cheap baseline, so tier 1 is the register allocator itself and
        # the separate tier-2 upgrade is turned off.
        self._have_baseline = stencil.available()
        self._tier1 = (stencil.compile_stencil if self._have_baseline
                       else compile_method)

        self._lock = threading.Lock()
        self.compiled: dict[int, _Compiled] = {}
        self.counts: dict[int, int] = {}
        self.pending: set[tuple[int, int]] = set()
        self.blacklist: set[int] = set()
        self._futures: list[Future] = []
        self._pool = ThreadPoolExecutor(workers) if background else None

        self.n_tier1 = 0
        self.n_tier2 = 0
        self.n_aborted = 0
        self.n_native = 0

        vm.on_call = self.on_call

    # -- dispatch ------------------------------------------------------------

    def on_call(self, callee, regs: list, arg_base: int, argc: int
                ) -> tuple[bool, Value]:
        code = callee.code
        cid = id(code)
        if cid in self.blacklist:
            return (False, None)

        # counts are only touched here (the interpreter thread), so no lock.
        cnt = self.counts.get(cid, 0) + 1
        self.counts[cid] = cnt
        if cnt == self.t1:
            self._request(code, cid, 1)
        elif (cnt == self.t2 and self._have_baseline
              and _worth_tier2(code)):
            self._request(code, cid, 2)     # only if arithmetic-dense

        with self._lock:
            entry = self.compiled.get(cid)
        if entry is None:
            return (False, None)                 # not ready: keep interpreting

        args = regs[arg_base:arg_base + argc]
        for v in args:                           # int-only entry guard
            if v.__class__ is not int and v.__class__ is not bool:
                return (False, None)
        self.n_native += 1
        return (True, entry.fn(*[int(v) for v in args]))

    # -- background compilation ---------------------------------------------

    def _request(self, code, cid: int, tier: int) -> None:
        with self._lock:
            if (cid, tier) in self.pending or cid in self.blacklist:
                return
            self.pending.add((cid, tier))
        compile_fn = self._tier1 if tier == 1 else compile_method
        if self._pool is not None:
            fut = self._pool.submit(self._job, code, cid, tier, compile_fn)
            with self._lock:
                self._futures.append(fut)
        else:
            self._job(code, cid, tier, compile_fn)

    def _job(self, code, cid: int, tier: int, compile_fn) -> None:
        try:
            fn = compile_fn(code, self.rt)
        except Exception:
            fn = None
        with self._lock:
            self.pending.discard((cid, tier))
            if fn is None:
                if tier == 1:                    # infeasible -> never JITtable
                    self.blacklist.add(cid)
                self.n_aborted += 1
                return
            cur = self.compiled.get(cid)
            if cur is None or tier > cur.tier:   # install first tier / upgrade
                self.compiled[cid] = _Compiled(fn, tier)
                if tier == 1:
                    self.n_tier1 += 1
                else:
                    self.n_tier2 += 1
                if self.log:
                    print(f"[tiered] install {code.name} tier{tier}")

    def drain(self) -> None:
        """Block until every submitted background compile has finished (for
        tests / deterministic measurement)."""
        with self._lock:
            futures = list(self._futures)
        wait(futures)

    def stats(self) -> dict[str, int]:
        return {
            "tier1": self.n_tier1,
            "tier2": self.n_tier2,
            "aborted": self.n_aborted,
            "native_calls": self.n_native,
            "blacklisted": len(self.blacklist),
        }
