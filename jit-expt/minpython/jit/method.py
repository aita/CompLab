"""A method (function) JIT for MinPython -- the tier the loop-tracing JIT can't
reach.

The tracing JIT only fires on hot `while` back-edges, so a function with no loop
-- most importantly a recursive one like `fib_rec` -- never gets native code.
This compiler fills that gap: when a function is *called* often enough it
compiles the whole function body, both arms of every branch, to machine code,
with recursive calls becoming native calls.

It is int-specialised, like the traces: every value is a 64-bit int, and the
interpreter -> native boundary (`MethodJIT.on_call`) guards that the arguments
really are ints before entering. Inside, everything is int, so no further guards
are needed.

Codegen is deliberately a stack-frame template, not a register allocator: each
of the function's VM registers is a slot in a stack frame, and every op loads
its operands into RAX/RCX, computes, and stores back. That has one big payoff --
no cross-block register allocation -- so arbitrary control flow is trivial: bind
a label per bytecode offset and let branches jump between them. The speedup over
the interpreter comes from native call/return and branch handling, not from
keeping values in registers (that is the loop JIT's job).

v1 scope (anything else aborts, leaving the function to the interpreter):
  * int arithmetic, comparisons, if / and / or, return
  * no loops (a back-edge -> the loop JIT's job), no globals/print/closures,
    no `//` `%` `**`
  * calls must be direct self-recursion with <= 6 arguments

Public API:
    MethodJIT(vm, threshold=...)      # installs vm.on_call
"""

from __future__ import annotations

import ctypes

from jit import (AL, ARG_REGS, CL, R12, R13, R14, R15, RAX, RBP, RBX, RCX,
                 RSP, Assembler, Reg, Runtime, qword)

from ..bytecode import CodeObject, Op, Value
from .regalloc import Interval, Spill, linear_scan

# Allocatable registers: callee-saved, so a value in one survives the native
# `call` a self-recursive function makes -- no save/restore around calls needed.
# RAX/RCX stay scratch (per-op temporaries, spill reloads, shift counts).
_POOL = [RBX, R12, R13, R14, R15]

# Binary MinPython opcode -> Assembler method for `RAX op= <operand>`.
_BIN_METHOD = {
    Op.ADD: "add", Op.SUB: "sub", Op.BIT_AND: "and_", Op.BIT_OR: "or_",
    Op.BIT_XOR: "xor",
}
# Commutative binops (incl. MUL, handled separately): the destination may reuse
# either operand's register for an in-place two-address form.
_COMMUTATIVE = {Op.ADD, Op.BIT_AND, Op.BIT_OR, Op.BIT_XOR}
# The operators bool is closed under: True & True is True, while True + True is
# 2 and True << 1 is 2. Native code has no tag, so a result that could be a bool
# keeps the function out of this tier entirely.
_BOOL_CLOSED = {Op.BIT_AND, Op.BIT_OR, Op.BIT_XOR}
_SETCC = {
    Op.EQ: "sete", Op.NE: "setne", Op.LT: "setl",
    Op.LE: "setle", Op.GT: "setg", Op.GE: "setge",
}
# Opcodes v1 can compile (on a reachable path). Everything else aborts.
_SUPPORTED = (set(_BIN_METHOD) | set(_SETCC) | {
    Op.LOAD_CONST, Op.MOVE, Op.MUL, Op.LSHIFT, Op.RSHIFT,
    Op.NEG, Op.INVERT, Op.NOT,
    Op.JUMP, Op.JUMP_IF_FALSE, Op.JUMP_IF_TRUE,
    Op.CALL, Op.RETURN, Op.LOAD_GLOBAL,
})

_METHOD_FN_CACHE: dict[int, type] = {}


def _cfunctype(argc: int):
    fn = _METHOD_FN_CACHE.get(argc)
    if fn is None:
        fn = ctypes.CFUNCTYPE(ctypes.c_int64, *([ctypes.c_int64] * argc))
        _METHOD_FN_CACHE[argc] = fn
    return fn


def _reachable(code: CodeObject) -> set[int]:
    """The bytecode offsets reachable from entry, following both branch arms and
    stopping at RETURN. Only these are compiled; the trailing implicit
    `return None` a function never falls into stays unreachable (and uncompiled,
    so its non-int None is never a problem)."""
    seen: set[int] = set()
    stack = [0]
    while stack:
        pc = stack.pop()
        if pc in seen:
            continue
        seen.add(pc)
        op = code.code[pc].op
        if op == Op.RETURN:
            continue
        if op == Op.JUMP:
            stack.append(code.code[pc].a)
        elif op in (Op.JUMP_IF_FALSE, Op.JUMP_IF_TRUE):
            stack.append(code.code[pc].b)
            stack.append(pc + 1)
        else:
            stack.append(pc + 1)
    return seen


def _self_call_regs(code: CodeObject, reachable: set[int]) -> set[int] | None:
    """Validate that every reachable CALL is a direct self-recursive call, and
    return the set of registers that hold the (elided) callee. Returns None if
    any call isn't self-recursion the compiler can resolve."""
    callee_regs: set[int] = set()
    for pc in reachable:
        ins = code.code[pc]
        if ins.op != Op.CALL:
            continue
        func_reg = ins.b
        # find the LOAD_GLOBAL that last wrote func_reg before this call
        src = None
        for j in range(pc - 1, -1, -1):
            prev = code.code[j]
            if prev.op == Op.LOAD_GLOBAL and prev.a == func_reg:
                src = prev
                break
            if prev.a == func_reg and prev.op != Op.LOAD_GLOBAL:
                break                      # written by something else -> give up
        if src is None or code.names[src.b] != code.name:
            return None                    # not a resolvable self-call
        if ins.c > len(ARG_REGS):
            return None                    # too many args for the ABI registers
        callee_regs.add(func_reg)
    return callee_regs


# --- liveness + register allocation over the function CFG -------------------


def _successors(code: CodeObject, pc: int) -> tuple[int, ...]:
    ins = code.code[pc]
    op = ins.op
    if op == Op.RETURN:
        return ()
    if op == Op.JUMP:
        return (ins.a,)
    if op in (Op.JUMP_IF_FALSE, Op.JUMP_IF_TRUE):
        return (pc + 1, ins.b)
    return (pc + 1,)


def _def_use(ins) -> tuple[tuple[int, ...], tuple[int, ...]]:
    """The VM registers an instruction writes (def) and reads (use). The elided
    self-call callee load is a no-op, and CALL does not read its callee slot, so
    that register never becomes live."""
    op = ins.op
    if op == Op.LOAD_CONST:
        return (ins.a,), ()
    if op == Op.MOVE:
        return (ins.a,), (ins.b,)
    if op == Op.LOAD_GLOBAL:
        return (), ()
    if op in _BIN_METHOD or op == Op.MUL or op in (Op.LSHIFT, Op.RSHIFT) \
            or op in _SETCC:
        return (ins.a,), (ins.b, ins.c)
    if op in (Op.NEG, Op.INVERT, Op.NOT):
        return (ins.a,), (ins.b,)
    if op in (Op.JUMP_IF_FALSE, Op.JUMP_IF_TRUE):
        return (), (ins.a,)
    if op == Op.CALL:
        base = ins.b + 1
        return (ins.a,), tuple(range(base, base + ins.c))
    if op == Op.RETURN:
        return (), (ins.a,)
    return (), ()


def _live_ranges(code: CodeObject, reachable: set[int]) -> dict[int, list[int]]:
    """Backward-dataflow liveness, then a `[start, end]` interval per VM
    register. The function is loop-free, so a couple of reverse passes converge;
    the interval is the min/max pc where the register is live (a conservative
    contiguous approximation, which is all linear scan needs)."""
    order = sorted(reachable, reverse=True)
    live_in: dict[int, set[int]] = {pc: set() for pc in reachable}
    du = {pc: _def_use(code.code[pc]) for pc in reachable}
    changed = True
    while changed:
        changed = False
        for pc in order:
            lo: set[int] = set()
            for s in _successors(code, pc):
                if s in live_in:
                    lo |= live_in[s]
            d, u = du[pc]
            li = (lo - set(d)) | set(u)
            if li != live_in[pc]:
                live_in[pc] = li
                changed = True

    ranges: dict[int, list[int]] = {}
    for pc in sorted(reachable):
        d, u = du[pc]
        for r in live_in[pc] | set(d) | set(u):
            if r in ranges:
                ranges[r][1] = pc
            else:
                ranges[r] = [pc, pc]
    return ranges


def _allocate(ranges: dict[int, list[int]], argc: int
              ) -> tuple[dict[int, object], list[Reg], int]:
    """Linear-scan the function's VM registers to `_POOL` or stack spill slots
    via the shared `regalloc.linear_scan`. Parameters are live from *before* the
    first instruction, not at it: the scan retires an interval whose end is at
    the new one's start -- deliberately, so a result can take an operand's
    register -- and with every parameter starting at 0 that let one parameter
    take another's. Returns (loc, used pool registers, spill count)."""
    for p in range(argc):
        if p in ranges:
            ranges[p][0] = -1
    intervals = [Interval(s, e, r) for r, (s, e) in ranges.items()]
    return linear_scan(intervals, _POOL)


def _int_result_only(code: CodeObject, reachable: set[int], argc: int) -> bool:
    """Does every RETURN on a live path definitely hand back an `int` rather
    than a `bool`? Native code keeps values as raw int64 with no tag, so the
    driver boxes the result as an int -- which is wrong for `return a < b`,
    where the interpreter says True. Parameters count as int because the entry
    guard insists on it, and a slot never written counts as neither, which also
    keeps a read-before-assignment (None to the interpreter) out of this tier.

    A forward must-analysis: start optimistic and intersect at merges."""
    universe = set(range(code.n_regs))
    in_: dict[int, set[int]] = {pc: set(universe) for pc in reachable}
    in_[0] = set(range(argc))

    def transfer(s: set[int], ins) -> set[int]:
        o = set(s)
        op = ins.op
        if op is Op.LOAD_CONST:
            v = code.consts[ins.b]
            o.add(ins.a) if v.__class__ is int else o.discard(ins.a)
        elif op is Op.MOVE:
            o.add(ins.a) if ins.b in s else o.discard(ins.a)
        elif op in _SETCC or op is Op.NOT:
            o.discard(ins.a)                    # a bool, by definition
        elif op in _BOOL_CLOSED:
            # bool & bool is a bool; anything else is an int
            o.add(ins.a) if (ins.b in s and ins.c in s) else o.discard(ins.a)
        elif op in _BIN_METHOD or op in (Op.MUL, Op.LSHIFT, Op.RSHIFT,
                                         Op.NEG, Op.INVERT, Op.CALL):
            o.add(ins.a)
        return o

    changed = True
    while changed:
        changed = False
        for pc in sorted(reachable):
            out = transfer(in_[pc], code.code[pc])
            for succ in _successors(code, pc):
                if succ not in in_:
                    continue
                merged = in_[succ] & out
                if merged != in_[succ]:
                    in_[succ] = merged
                    changed = True
    return all(code.code[pc].a in in_[pc]
               for pc in reachable if code.code[pc].op is Op.RETURN)


def feasible(code: CodeObject) -> set[int] | None:
    """Both function compilers share this gate. Returns the set of reachable
    bytecode offsets if `code` is inside the v1 subset (int arithmetic, if,
    return, direct self-recursion, no loops/globals/print/`//`/`%`/`**`, <= 6
    params), else None to leave the function to the interpreter."""
    if len(code.params) > len(ARG_REGS):
        return None
    reachable = _reachable(code)
    callee_regs = _self_call_regs(code, reachable)
    if callee_regs is None:
        return None
    for pc in reachable:
        ins = code.code[pc]
        if ins.op not in _SUPPORTED:
            return None                    # unsupported op on a live path
        if ins.op == Op.LOAD_CONST:
            v = code.consts[ins.b]
            if v is None or not isinstance(v, int):   # bool is int -> ok
                return None
        if ins.op == Op.JUMP and ins.a <= pc:
            return None                    # a loop -> leave it to the trace JIT
        if ins.op == Op.LOAD_GLOBAL and ins.a not in callee_regs:
            return None                    # a real global read, not a self-call
    if not _int_result_only(code, reachable, len(code.params)):
        return None                        # could return a bool: no tag to say so
    return reachable


def compile_method(code: CodeObject, rt: Runtime):
    """Compile `code` to a native `int64 f(int64...)` with linear-scan register
    allocation, or return None if it is outside the v1 subset."""
    reachable = feasible(code)
    if reachable is None:
        return None

    argc = len(code.params)
    ranges = _live_ranges(code, reachable)
    loc, used_callee, n_spill = _allocate(ranges, argc)

    a = Assembler()
    # Frame below rbp: [saved callee-saved regs][spill slots]. rbp is 16-aligned
    # on entry (the caller's `call` left rsp%16==8, `push rbp` makes it 0), and
    # framesize is a multiple of 16, so rsp stays aligned for our own calls.
    save_n = len(used_callee)
    framesize = (((save_n + n_spill) * 8 + 15) // 16) * 16

    def save_mem(i: int):
        return qword(RBP - (i + 1) * 8)

    def spill_mem(s: Spill):
        return qword(RBP - (save_n + s.index + 1) * 8)

    def mem(r: int):
        """The memory operand for a spilled VM register."""
        return spill_mem(loc[r])

    def is_reg(r: int) -> bool:
        return isinstance(loc[r], Reg)

    def reg_of(r: int):
        return loc[r] if is_reg(r) else None

    def rm(r: int):
        """A source operand for VM register `r`: its Reg or its spill memory."""
        lr = loc[r]
        return lr if isinstance(lr, Reg) else spill_mem(lr)

    def load(reg, r: int) -> None:
        match loc[r]:
            case Reg() as lr:
                if lr != reg:
                    a.mov(reg, lr)
            case Spill() as sp:
                a.mov(reg, spill_mem(sp))

    def store(r: int) -> None:               # loc(r) <- RAX
        match loc[r]:
            case Reg() as lr:
                if lr != RAX:
                    a.mov(lr, RAX)
            case Spill() as sp:
                a.mov(spill_mem(sp), RAX)

    labels = {pc: a.label(f"pc{pc}") for pc in reachable}
    entry = a.label("entry")
    a.bind(entry)
    a.push(RBP)
    a.mov(RBP, RSP)
    if framesize:
        a.sub(RSP, framesize)
    for i, reg in enumerate(used_callee):    # preserve callee-saved we allocate
        a.mov(save_mem(i), reg)
    for i in range(argc):                    # params: ARG_REGS -> their location
        if i in loc:
            dst = loc[i]
            if isinstance(dst, Reg):
                a.mov(dst, ARG_REGS[i])
            else:
                a.mov(spill_mem(dst), ARG_REGS[i])

    def epilogue() -> None:
        for i, reg in enumerate(used_callee):
            a.mov(reg, save_mem(i))
        a.mov(RSP, RBP)
        a.pop(RBP)
        a.ret()

    def emit_bin(x, y, z, method, commutative) -> None:
        d = reg_of(x)
        if d is not None:
            if reg_of(y) == d:
                method(d, rm(z))
            elif commutative and reg_of(z) == d:
                method(d, rm(y))
            elif reg_of(z) == d:              # non-commutative, z sits in dst
                a.mov(RAX, rm(y))
                method(RAX, d)
                a.mov(d, RAX)
            else:
                load(d, y)
                method(d, rm(z))
        else:
            load(RAX, y)
            method(RAX, rm(z))
            store(x)

    def emit_unary(x, y, method) -> None:
        d = reg_of(x)
        if d is not None:
            if reg_of(y) != d:
                load(d, y)
            method(d)
        else:
            load(RAX, y)
            method(RAX)
            store(x)

    for pc in range(len(code.code)):
        if pc not in reachable:
            continue                         # dead code (e.g. the None tail)
        a.bind(labels[pc])
        ins = code.code[pc]
        op, x, y, z = ins.op, ins.a, ins.b, ins.c

        if op == Op.LOAD_CONST:
            v = int(code.consts[y])
            d = reg_of(x)
            if d is not None:
                a.mov(d, v)
            else:
                a.mov(RAX, v)
                store(x)
        elif op == Op.MOVE:
            d = reg_of(x)
            if d is not None:
                load(d, y)
            else:
                load(RAX, y)
                store(x)
        elif op == Op.LOAD_GLOBAL:
            pass                             # self-call callee: resolved at CALL

        elif op in _BIN_METHOD:
            emit_bin(x, y, z, getattr(a, _BIN_METHOD[op]), op in _COMMUTATIVE)
        elif op == Op.MUL:
            emit_bin(x, y, z, a.imul, True)
        elif op in (Op.LSHIFT, Op.RSHIFT):
            tgt = reg_of(x)
            if tgt is None:
                tgt = RAX
            # Read the count *before* writing the destination. x and z are
            # different slots, but the scan hands a result the register of an
            # operand whose last use is right here -- so they can be the same
            # register, and loading y first destroyed the count.
            a.mov(RCX, rm(z))
            if reg_of(y) != tgt:
                load(tgt, y)
            (a.shl if op == Op.LSHIFT else a.sar)(tgt, CL)
            if reg_of(x) is None:
                store(x)                     # tgt is RAX here

        elif op == Op.NEG:
            emit_unary(x, y, a.neg)
        elif op == Op.INVERT:
            emit_unary(x, y, a.not_)
        elif op == Op.NOT:
            load(RAX, y)
            a.test(RAX, RAX)
            a.setz(AL)
            a.movzx(RAX, AL)
            store(x)

        elif op in _SETCC:
            lhs = reg_of(y)
            if lhs is None:
                a.mov(RAX, mem(y))
                lhs = RAX
            a.cmp(lhs, rm(z))
            getattr(a, _SETCC[op])(AL)
            a.movzx(RAX, AL)
            store(x)

        elif op == Op.JUMP:
            a.jmp(labels[x])
        elif op == Op.JUMP_IF_FALSE:
            cond = reg_of(x)
            if cond is None:
                a.mov(RAX, mem(x))
                cond = RAX
            a.test(cond, cond)
            a.jz(labels[y])
        elif op == Op.JUMP_IF_TRUE:
            cond = reg_of(x)
            if cond is None:
                a.mov(RAX, mem(x))
                cond = RAX
            a.test(cond, cond)
            a.jnz(labels[y])

        elif op == Op.CALL:
            arg_base = y + 1                 # y is the callee reg; args follow
            for i in range(z):
                load(ARG_REGS[i], arg_base + i)
            a.call(entry)                    # direct self-recursion
            store(x)                         # result in RAX -> dst
        elif op == Op.RETURN:
            load(RAX, x)
            epilogue()

    obj = a.finalize()
    addr = rt.add(obj)
    return _cfunctype(argc)(addr)


class MethodJIT:
    """Compiles whole int functions on call-hotness; installs `vm.on_call`."""

    def __init__(self, vm, *, threshold: int = 10,
                 runtime: Runtime | None = None, log: bool = False):
        self.vm = vm
        self.threshold = threshold
        self.rt = runtime or Runtime()
        self.log = log

        self.call_counts: dict[int, int] = {}
        self.compiled: dict[int, tuple] = {}    # code id -> (fn, argc)
        self.blacklist: set[int] = set()

        self.n_compiled = 0
        self.n_calls_native = 0

        vm.on_call = self.on_call

    def on_call(self, callee, regs: list, arg_base: int, argc: int
                ) -> tuple[bool, Value]:
        code = callee.code
        cid = id(code)

        comp = self.compiled.get(cid)
        if comp is None:
            if cid in self.blacklist:
                return (False, None)
            count = self.call_counts.get(cid, 0) + 1
            self.call_counts[cid] = count
            if count < self.threshold:
                return (False, None)
            fn = compile_method(code, self.rt)
            if fn is None:
                self.blacklist.add(cid)
                if self.log:
                    print(f"[method] abort   {code.name}")
                return (False, None)
            comp = (fn, argc)
            self.compiled[cid] = comp
            self.n_compiled += 1
            if self.log:
                print(f"[method] compile {code.name}/{argc}")

        fn, _ = comp
        # Entry type guard: every argument must be an `int`, not merely
        # int-like. A bool argument would let `a & b` produce a bool, which raw
        # int64 registers have no way to carry back out.
        args = regs[arg_base:arg_base + argc]
        for v in args:
            if v.__class__ is not int:
                return (False, None)       # deopt to the interpreter
        self.n_calls_native += 1
        return (True, fn(*args))

    def stats(self) -> dict[str, int]:
        return {
            "compiled": self.n_compiled,
            "blacklisted": len(self.blacklist),
            "native_calls": self.n_calls_native,
        }
