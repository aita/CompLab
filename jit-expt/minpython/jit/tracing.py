"""A LuaJIT-shaped tracing JIT for the MinPython register VM, whole thing.

Attach `TracingJIT` to a VM and it compiles hot `while` loops to x86-64. This
one module holds the whole pipeline, in the order data flows through it:

  * IR          -- a linear, SSA, integer-only trace: a straight line of value
                   ops with control flow expressed only as `GUARD`s + snapshots.
  * recorder    -- `record()` runs one loop iteration, emitting IR and a guard
                   fixed to each branch's taken direction.
  * codegen     -- `compile_trace()` lowers the IR to machine code, allocating
                   SSA values to registers via the shared `regalloc.linear_scan`.
  * driver      -- `TracingJIT`: hot-loop counters, trace cache, blacklist, side
                   traces, and the dispatch/chain loop.

Every value in a trace is a 64-bit int, so guards are control-flow guards (which
branch was taken), not type guards -- a simplification MinPython's int-only
design buys over LuaJIT. Anything the integer core can't handle aborts the trace
and stays interpreted, so results always match the pure VM.
"""

from __future__ import annotations

import ctypes
import enum
import operator
from typing import NamedTuple

from jit import (AL, ARG_REGS, CL, R8, R9, R10, R11, RAX, RCX, RDX, RSI,
                 Assembler, Reg, Runtime, qword)

from ..bytecode import BIN_FN, CMP_FN, CodeObject, Op, Value
from ..vm import VM
from .regalloc import Interval, Spill, linear_scan

# ===========================================================================
# IR -- a linear, SSA, integer-only intermediate representation.
#
# A `Trace` is a straight-line list of instructions -- no basic blocks, because
# a trace *is* a single path. Each instruction's index is its SSA reference.
# Control flow shows up only as `GUARD`s, each carrying a `Snapshot`: enough of
# the VM's register state to rebuild the interpreter frame and resume it at a
# bytecode pc (the LuaJIT trick that lets a trace bail out mid-iteration).
# Only named locals ever appear in a snapshot: the compiler keeps no temporary
# live across a jump target, and every resume pc is a jump target.
# ===========================================================================


class IROp(enum.IntEnum):
    CONST = 1      # value: an integer constant
    LOAD = 2       # slot:  read VM register `slot` at trace entry (a live-in)
    ADD = 10       # binary: a <op> b
    SUB = 11
    MUL = 12
    BIT_AND = 13
    BIT_OR = 14
    BIT_XOR = 15
    SHL = 16
    SHR = 17       # arithmetic (signed) shift right -- MinPython ints are signed
    NEG = 20       # unary: <op> a
    INVERT = 21
    NOT = 22
    EQ = 30        # comparison: (a <cmp> b) -> 0/1
    NE = 31
    LT = 32
    LE = 33
    GT = 34
    GE = 35
    GUARD = 40     # a control-flow guard (produces no value)


BINARY_OPS = frozenset({IROp.ADD, IROp.SUB, IROp.MUL, IROp.BIT_AND,
                        IROp.BIT_OR, IROp.BIT_XOR, IROp.SHL, IROp.SHR})
UNARY_OPS = frozenset({IROp.NEG, IROp.INVERT, IROp.NOT})
COMPARE_OPS = frozenset({IROp.EQ, IROp.NE, IROp.LT, IROp.LE, IROp.GT, IROp.GE})


class Snapshot(NamedTuple):
    """The interpreter state to restore when a guard exits: the bytecode pc to
    resume at, and the local slots modified so far this iteration mapped to the
    IR value now held there (so codegen can write them back before exiting)."""
    resume_pc: int
    mapping: dict[int, int]   # vm local slot -> ir ref


class Guard:
    """One control-flow guard and its exit. `expected` is the truth value the
    recorded path took; the trace stays on course while `cond` matches it.
    `written` is the locals assigned before this guard this iteration; `snapshot`
    is the finished exit state, filled in by `Trace.finalize()`."""
    __slots__ = ("cond", "expected", "written", "resume_pc", "snapshot",
                 "exit_id")

    def __init__(self, cond: int, expected: bool, written: dict[int, int],
                 resume_pc: int, exit_id: int):
        self.cond = cond
        self.expected = expected
        self.written = written
        self.resume_pc = resume_pc
        self.snapshot: Snapshot | None = None
        self.exit_id = exit_id


class IRInst(NamedTuple):
    op: IROp
    a: int = -1        # operand ref (or -1)
    b: int = -1        # operand ref (or -1)
    value: int = 0     # CONST value
    slot: int = 0      # LOAD slot
    guard: Guard | None = None


class Trace:
    """A recorded loop trace for one back-edge of one CodeObject."""

    def __init__(self, code: CodeObject, entry_pc: int):
        self.code = code
        self.entry_pc = entry_pc
        self.n_locals = code.n_locals
        self.instrs: list[IRInst] = []
        self._cse: dict[tuple, int] = {}   # (op, a, b, value, slot) -> ref
        self.in_slots: set[int] = set()    # local slots read at entry
        self.out_slots: set[int] = set()   # local slots ever written
        self.load_refs: dict[int, int] = {}  # local slot -> its LOAD ref
        self.exits: list[Guard] = []       # exit_id -> Guard
        self.carried: dict[int, int] = {}  # local slot -> ref at the back-edge
        # A main trace is a self-loop (is_loop). A side trace is linear: it runs
        # from a hot guard exit to the loop header, then hands back to the main
        # trace via a terminal exit (recorded with add_terminal).
        self.is_loop = True
        self.terminal_id: int | None = None

    # -- value ops (hash-consed: identical pure ops share a ref) -------------

    def _pure(self, op: IROp, a: int = -1, b: int = -1, value: int = 0,
              slot: int = 0) -> int:
        key = (op, a, b, value, slot)
        ref = self._cse.get(key)
        if ref is not None:
            return ref
        ref = len(self.instrs)
        self.instrs.append(IRInst(op, a, b, value, slot))
        self._cse[key] = ref
        return ref

    def const(self, value: int) -> int:
        return self._pure(IROp.CONST, value=int(value))

    def load(self, slot: int) -> int:
        self.in_slots.add(slot)
        ref = self._pure(IROp.LOAD, slot=slot)
        self.load_refs[slot] = ref
        return ref

    def binop(self, op: IROp, a: int, b: int) -> int:
        return self._pure(op, a=a, b=b)

    def unop(self, op: IROp, a: int) -> int:
        return self._pure(op, a=a)

    def compare(self, op: IROp, a: int, b: int) -> int:
        return self._pure(op, a=a, b=b)

    # -- guards (never consed: they are ordered side effects) ----------------

    def guard(self, cond: int, expected: bool, written: dict[int, int],
              resume_pc: int) -> None:
        g = Guard(cond, expected, dict(written), resume_pc, len(self.exits))
        self.exits.append(g)
        self.instrs.append(IRInst(IROp.GUARD, a=cond, guard=g))

    def add_terminal(self, written: dict[int, int], resume_pc: int) -> None:
        """Record a side trace's terminal: an unconditional exit taken when the
        linear trace reaches the loop header, handing control to the main trace
        (which resumes at `resume_pc`, the header). Modelled as a guard with no
        condition (cond = -1)."""
        g = Guard(-1, True, dict(written), resume_pc, len(self.exits))
        self.exits.append(g)
        self.terminal_id = g.exit_id
        self.is_loop = False

    def finalize(self) -> bool:
        """Compute each guard's exit snapshot now that the loop is closed. Every
        output local maps to the IR value holding it at that exit: the value
        written before the guard this iteration, else its loop-entry value (its
        LOAD if read, or -- for a write-only local -- the carried value, whose
        register still holds the previous iteration's result at the top).

        That last case only holds while the carried value is computed *after*
        the guard. CSE can move it before: `r = i < n` inside `while i < n`
        becomes the same IR value as the loop condition, which is recomputed
        above the guard, so the exit would hand back this iteration's
        comparison instead of the previous one's. Returns False to abort the
        trace when that happens, rather than compile something wrong."""
        # A side trace's terminal exit is not an instruction, so positions come
        # from a lookup rather than from enumerating instrs -- every exit needs
        # a snapshot, including that one.
        pos = {id(ins.guard): i for i, ins in enumerate(self.instrs)
               if ins.op is IROp.GUARD and ins.guard is not None}
        for g in self.exits:
            g_pos = pos.get(id(g), len(self.instrs))
            mapping: dict[int, int] = {}
            for slot in self.out_slots:
                if slot in g.written:
                    mapping[slot] = g.written[slot]
                elif slot in self.load_refs:
                    mapping[slot] = self.load_refs[slot]
                else:
                    ref = self.carried[slot]
                    if self.is_loop and ref < g_pos:
                        return False       # recomputed above the guard
                    mapping[slot] = ref
            g.snapshot = Snapshot(g.resume_pc, mapping)
        return True


def loop_invariants(trace: Trace) -> set[int]:
    """The refs whose value is the same on every iteration, so they can be
    computed once in a preheader (loop-invariant code motion / peeling).

    A constant is invariant; a live-in `LOAD` is invariant unless its slot is
    loop-carried; a computed value is invariant iff all its operands are. One
    forward pass suffices because the IR is in definition order."""
    carried_slots = set(trace.carried)
    inv: set[int] = set()
    for ref, ins in enumerate(trace.instrs):
        op = ins.op
        if op == IROp.CONST:
            inv.add(ref)
        elif op == IROp.LOAD:
            if ins.slot not in carried_slots:
                inv.add(ref)
        elif op == IROp.GUARD:
            pass                                  # guards stay in the loop body
        elif op in UNARY_OPS:
            if ins.a in inv:
                inv.add(ref)
        elif op in BINARY_OPS or op in COMPARE_OPS:
            if ins.a in inv and ins.b in inv:
                inv.add(ref)
    return inv


def format_trace(trace: Trace) -> str:
    """Render a Trace as readable IR text (for debugging / tests)."""
    lines = [f"TRACE {trace.code.name} @pc{trace.entry_pc}  "
             f"in={sorted(trace.in_slots)} out={sorted(trace.out_slots)}"]
    for ref, ins in enumerate(trace.instrs):
        if ins.op == IROp.CONST:
            body = f"const {ins.value}"
        elif ins.op == IROp.LOAD:
            body = f"load  slot{ins.slot}"
        elif ins.op == IROp.GUARD:
            g = ins.guard
            assert g is not None
            body = (f"guard {'T' if g.expected else 'F'}(%{g.cond}) "
                    f"-> exit{g.exit_id} @pc{g.snapshot.resume_pc} "
                    f"{ {s: f'%{r}' for s, r in g.snapshot.mapping.items()} }")
        elif ins.op in UNARY_OPS:
            body = f"{ins.op.name.lower():5} %{ins.a}"
        else:
            body = f"{ins.op.name.lower():5} %{ins.a}, %{ins.b}"
        lines.append(f"  %{ref:<3} {body}")
    carried = {s: f"%{r}" for s, r in trace.carried.items()}
    lines.append(f"  loop -> @pc{trace.entry_pc}  carry {carried}")
    return "\n".join(lines)


# ===========================================================================
# Recorder -- run one loop iteration and emit IR for it.
#
# A throwaway second interpreter: from a hot back-edge's target it walks the
# bytecode forward once, executing concretely on a copy of the registers (so
# branch directions are known and the real frame is untouched) while emitting
# IR. Each conditional branch becomes a GUARD fixed to the taken direction; when
# the walk reaches the back-edge it started from, the loop has closed. Anything
# the integer core can't compile aborts (returns None) and stays interpreted.
# ===========================================================================

MAX_STEPS = 400  # give up on traces longer than this (unrolled recursion etc.)

# VM binary/compare/unary opcodes the trace core supports -> their IR opcode.
# FLOORDIV/MOD/POW are absent on purpose: `//`/`%` have Python floor semantics
# that differ from a bare x86 idiv, and `**` has no single instruction.
_BIN = {
    Op.ADD: IROp.ADD, Op.SUB: IROp.SUB, Op.MUL: IROp.MUL,
    Op.BIT_AND: IROp.BIT_AND, Op.BIT_OR: IROp.BIT_OR, Op.BIT_XOR: IROp.BIT_XOR,
    Op.LSHIFT: IROp.SHL, Op.RSHIFT: IROp.SHR,
}
_CMP = {
    Op.EQ: IROp.EQ, Op.NE: IROp.NE, Op.LT: IROp.LT,
    Op.LE: IROp.LE, Op.GT: IROp.GT, Op.GE: IROp.GE,
}
_UN = {Op.NEG: IROp.NEG, Op.INVERT: IROp.INVERT, Op.NOT: IROp.NOT}
_UN_CONCRETE = {Op.NEG: operator.neg, Op.INVERT: operator.invert,
                Op.NOT: operator.not_}


def record(code: CodeObject, entry_pc: int, regs: list[Value],
           *, header_pc: int | None = None) -> Trace | None:
    """Record a trace, using the live register values `regs` to resolve branch
    directions. Returns a finished `Trace`, or None if it can't be traced.

    Main trace (`header_pc` None): a self-loop whose back-edge targets
    `entry_pc`; recording closes when it returns there. Side trace (`header_pc`
    given): a linear path from `entry_pc` (a hot guard's resume pc, mid-body) to
    `header_pc` (the loop header), ending in a terminal exit back to the main
    trace."""
    is_side = header_pc is not None
    if header_pc is None:
        header_pc = entry_pc
    t = Trace(code, entry_pc)
    n_locals = code.n_locals
    slotref: dict[int, int] = {}   # VM slot -> current IR ref
    written: dict[int, int] = {}   # local slot -> IR ref, this iteration
    sregs = list(regs)             # concrete shadow registers
    insns = code.code

    def use(slot: int) -> int:
        ref = slotref.get(slot)
        if ref is None:
            ref = t.load(slot)     # first read -> a live-in
            slotref[slot] = ref
        return ref

    def write(slot: int, ref: int) -> None:
        slotref[slot] = ref
        if slot < n_locals:
            written[slot] = ref
            t.out_slots.add(slot)

    pc = entry_pc
    for _ in range(MAX_STEPS):
        ins = insns[pc]
        op = ins.op
        a, b, c = ins.a, ins.b, ins.c

        if op == Op.JUMP:
            if a == header_pc:             # the loop back-edge
                if any(s >= n_locals for s in t.in_slots):
                    # LOADs must only touch locals (temps are always written
                    # first); if that fails, the marshalling model breaks.
                    return None
                if is_side:                # linear side trace reaches the header
                    t.add_terminal(written, header_pc)
                    return t if t.finalize() else None
                t.carried = dict(written)  # main trace: self-loop closed
                return t if t.finalize() else None
            if a <= pc:                    # some other backward edge (nested)
                return None
            pc = a                         # forward jump: just follow it
            continue

        if op == Op.JUMP_IF_FALSE:
            ref = use(a)
            if sregs[a]:                   # truthy -> fall through; hold truthy
                t.guard(ref, True, written, b)
                pc += 1
            else:                          # falsy -> take jump; hold falsy
                t.guard(ref, False, written, pc + 1)
                pc = b
            continue

        if op == Op.JUMP_IF_TRUE:
            ref = use(a)
            if sregs[a]:                   # truthy -> take jump; hold truthy
                t.guard(ref, True, written, pc + 1)
                pc = b
            else:                          # falsy -> fall through; hold falsy
                t.guard(ref, False, written, b)
                pc += 1
            continue

        if op == Op.LOAD_CONST:
            v = code.consts[b]
            if v is None or not isinstance(v, int):   # bool is int -> allowed
                return None
            write(a, t.const(int(v)))
            sregs[a] = v
        elif op == Op.MOVE:
            write(a, use(b))
            sregs[a] = sregs[b]
        elif op in _BIN:
            # int-only guard: a non-int operand (str/list) means this op isn't
            # JIT-able, so bail and let the interpreter run the loop.
            if not (isinstance(sregs[b], int) and isinstance(sregs[c], int)):
                return None
            write(a, t.binop(_BIN[op], use(b), use(c)))
            sregs[a] = BIN_FN[op](sregs[b], sregs[c])
        elif op in _CMP:
            if not (isinstance(sregs[b], int) and isinstance(sregs[c], int)):
                return None
            write(a, t.compare(_CMP[op], use(b), use(c)))
            sregs[a] = CMP_FN[op](sregs[b], sregs[c])
        elif op in _UN:
            if not isinstance(sregs[b], int):
                return None
            write(a, t.unop(_UN[op], use(b)))
            sregs[a] = _UN_CONCRETE[op](sregs[b])
        else:
            # RETURN / CALL / PRINT / LOAD_GLOBAL / STORE_GLOBAL / MAKE_FUNCTION
            # / FLOORDIV / MOD / POW: not supported in a trace.
            return None
        # Every branch above writes slot `a`. Native code keeps values as raw
        # int64 with no tag, and the write-back hands each live-out local back
        # as a plain int -- so a bool that reaches a *named* local would come
        # out as 0/1 where the interpreter says False/True. Temporaries never
        # leave the trace, so int64 is all anyone looks at there.
        if a < n_locals and sregs[a].__class__ is bool:
            return None
        pc += 1

    return None  # ran past MAX_STEPS


# ===========================================================================
# Codegen -- lower a trace IR to x86-64 via `jit.Assembler`.
#
# The compiled trace is `int64 trace(int64 *buf)`: live-ins are loaded from buf
# once in the prologue, values live in registers across the loop, and buf is
# written only when a guard exits. Loop-carried values are shuttled between their
# result register and their phi register at the back-edge. Buffer layout:
#     buf[0 .. n_locals)              the VM's local registers (in/out)
#     buf[n_locals .. +n_spill)       spilled SSA values
#     buf[.. +n_phi)                  back-edge scratch for the phi copy
# ===========================================================================

_BUF = ARG_REGS[0]                     # buffer pointer (SysV: RDI)
# Allocatable registers: caller-saved, minus the buffer pointer and the two
# scratch registers (RAX general, RCX shift-count / big-immediate). No
# callee-saved registers are used, so the trace needs no prologue/epilogue.
_POOL = [RDX, RSI, R8, R9, R10, R11]

_TRACE_FN = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_void_p)

_BIN_METHOD = {
    IROp.ADD: "add", IROp.SUB: "sub", IROp.BIT_AND: "and_",
    IROp.BIT_OR: "or_", IROp.BIT_XOR: "xor",
}
# Operators where `a op b == b op a`, so the destination may reuse either
# operand's register for an in-place (two-address) form.
_COMMUTATIVE = {IROp.ADD, IROp.MUL, IROp.BIT_AND, IROp.BIT_OR, IROp.BIT_XOR}
_SETCC = {
    IROp.EQ: "sete", IROp.NE: "setne", IROp.LT: "setl",
    IROp.LE: "setle", IROp.GT: "setg", IROp.GE: "setge",
}


def _fits32(v: int) -> bool:
    return -(1 << 31) <= v < (1 << 31)


class Allocation:
    def __init__(self, loc: dict[int, object], n_spill: int):
        self.loc = loc
        self.n_spill = n_spill


def _trace_intervals(trace: Trace, extra_live) -> list[Interval]:
    """Build the live intervals for a trace's SSA values. A value that must
    survive between iterations -- a live-in phi, a loop-carried result, a value
    some guard's snapshot needs, or a hoisted invariant (`extra_live`) -- gets
    the interval `[0, N]` so linear scan keeps it live for the whole loop."""
    instrs = trace.instrs
    N = len(instrs)
    loop_live = (set(trace.load_refs.values()) | set(trace.carried.values())
                 | set(extra_live))
    for g in trace.exits:
        assert g.snapshot is not None
        loop_live |= set(g.snapshot.mapping.values())

    # A value a guard's snapshot reads but that is computed *later* in the body
    # is the previous iteration's: its range wraps the back-edge, so it has to
    # be reserved from the top of the loop too. Without this the scan reused its
    # register for something computed earlier in the body, and the guard handed
    # that back as the local's value.
    wraps: set[int] = set()
    for i, ins in enumerate(instrs):
        if ins.op != IROp.GUARD:
            continue
        g = ins.guard
        assert g is not None and g.snapshot is not None
        wraps |= {ref for ref in g.snapshot.mapping.values() if ref > i}

    last_use: dict[int, int] = {}

    def note(ref: int, pos: int) -> None:
        if ref >= 0 and last_use.get(ref, -1) < pos:
            last_use[ref] = pos

    for i, ins in enumerate(instrs):
        if ins.op == IROp.GUARD or ins.op in UNARY_OPS:
            note(ins.a, i)
        elif ins.op not in (IROp.CONST, IROp.LOAD):
            note(ins.a, i)
            note(ins.b, i)

    intervals: list[Interval] = []
    for ref, ins in enumerate(instrs):
        if ins.op in (IROp.GUARD, IROp.CONST):
            continue                       # guards have no value; consts inline
        start = 0 if (ins.op == IROp.LOAD or ref in wraps) else ref
        end = N if ref in loop_live else last_use.get(ref, ref)
        intervals.append(Interval(start, end, ref))
    return intervals


def allocate(trace: Trace, pool: list[Reg],
             extra_live: frozenset[int] = frozenset()) -> Allocation:
    """Assign every value in `trace` a register from `pool` or a spill slot."""
    loc, _used, n_spill = linear_scan(_trace_intervals(trace, extra_live), pool)
    return Allocation(loc, n_spill)


class CompiledTrace:
    """A finished native trace plus the marshalling metadata to run it.

    `links` maps an exit id to another trace to jump straight into (a linked side
    trace, or a side trace's terminal back to its main trace); the JIT follows
    those to chain traces without touching the interpreter. `code`/`header_pc`
    identify which loop this trace belongs to, for side-tracing."""

    def __init__(self, fn, buf, marshal: list[int], out_slots: list[int],
                 resume_pcs: list[int]):
        self._fn = fn
        self._buf = buf
        self._ptr = ctypes.cast(buf, ctypes.c_void_p)
        self.marshal = marshal
        self.out_slots = out_slots
        self.resume_pcs = resume_pcs
        self.links: dict[int, "CompiledTrace"] = {}
        self.code = None          # set by the JIT
        self.header_pc = -1       # set by the JIT

    def run_raw(self, regs: list[Value]) -> int | None:
        """Run the trace once (it may loop internally). Marshals live-ins in and
        live-outs back through `regs`; returns the id of the guard that exited,
        or None if a live-in was not an int (integer assumptions broken)."""
        buf = self._buf
        for s in self.marshal:
            v = regs[s]
            if v.__class__ is int or v.__class__ is bool:
                buf[s] = v
            else:
                return None            # entry type guard failed -> interpret
        exit_id = self._fn(self._ptr)
        for s in self.out_slots:
            regs[s] = buf[s]
        return exit_id


def compile_trace(trace: Trace, rt: Runtime, *, name: str | None = None
                  ) -> CompiledTrace:
    """Assemble `trace` into a `CompiledTrace` mapped into `rt`."""
    a = Assembler()
    instrs = trace.instrs
    n_locals = trace.n_locals

    # Loop-invariant code motion: hoist invariant value ops to a preheader that
    # runs once. They must then stay live for the whole loop, so the allocator
    # is told to treat them as loop-live.
    invariant = loop_invariants(trace) if trace.is_loop else set()
    hoist = [ref for ref in range(len(instrs))
             if ref in invariant
             and instrs[ref].op not in (IROp.CONST, IROp.LOAD)]
    hoist_set = set(hoist)

    alloc = allocate(trace, _POOL, frozenset(hoist_set))
    loc = alloc.loc

    phi_slots = [s for s in trace.carried if s in trace.load_refs]
    spill_base = n_locals
    scratch_base = n_locals + alloc.n_spill

    def mem_local(slot: int):
        return qword(_BUF + slot * 8)

    def mem_spill(idx: int):
        return qword(_BUF + (spill_base + idx) * 8)

    def mem_scratch(k: int):
        return qword(_BUF + (scratch_base + k) * 8)

    def is_const(ref: int) -> bool:
        return instrs[ref].op == IROp.CONST

    def operand(ref: int):
        """A flexible source operand: a register, a memory location, or (for a
        constant that fits) an immediate. A too-big constant goes via RCX."""
        if is_const(ref):
            v = instrs[ref].value
            if _fits32(v):
                return v
            a.mov(RCX, v)
            return RCX
        l = loc[ref]
        return l if isinstance(l, Reg) else mem_spill(l.index)

    def into(reg, ref: int):
        """Emit `reg <- value of ref`, unless the value is already in `reg`."""
        if is_const(ref):
            a.mov(reg, instrs[ref].value)
            return
        match loc[ref]:
            case Reg() as l:
                if l != reg:
                    a.mov(reg, l)
            case Spill(index=idx):
                a.mov(reg, mem_spill(idx))

    def as_reg(ref: int):
        """A register holding `ref`, loading into RAX if not already in one."""
        if not is_const(ref):
            l = loc[ref]
            if isinstance(l, Reg):
                return l
        into(RAX, ref)
        return RAX

    def store(ref: int) -> None:
        """Emit `location of ref <- RAX`."""
        match loc[ref]:
            case Reg() as l:
                if l != RAX:
                    a.mov(l, RAX)
            case Spill(index=idx):
                a.mov(mem_spill(idx), RAX)

    def dst_reg(ref: int):
        """The register a result is written to, or None if it is spilled."""
        l = loc[ref]
        return l if isinstance(l, Reg) else None

    def reg_of(ref: int):
        """The register currently holding `ref`, or None (constant / spilled)."""
        if is_const(ref):
            return None
        l = loc[ref]
        return l if isinstance(l, Reg) else None

    # -- two-address lowering: compute in the destination register when we can,
    # falling back to RAX + a store only when the destination is a spill slot.

    def emit_binop(ref: int, method, commutative: bool) -> None:
        ins = instrs[ref]
        D = dst_reg(ref)
        if D is not None:
            if reg_of(ins.a) == D:                    # D = D op b
                method(D, operand(ins.b))
            elif commutative and reg_of(ins.b) == D:  # D = D op a
                method(D, operand(ins.a))
            elif reg_of(ins.b) == D:                  # non-commutative, b in D
                a.mov(RAX, operand(ins.a))
                method(RAX, D)
                a.mov(D, RAX)
            else:
                into(D, ins.a)
                method(D, operand(ins.b))
        else:
            into(RAX, ins.a)
            method(RAX, operand(ins.b))
            store(ref)

    def emit_shift(ref: int, is_shl: bool) -> None:
        ins = instrs[ref]
        D = dst_reg(ref)
        tgt = D if D is not None else RAX
        if reg_of(ins.a) != tgt:
            into(tgt, ins.a)
        shift = a.shl if is_shl else a.sar
        cnt = instrs[ins.b]
        if cnt.op == IROp.CONST:
            shift(tgt, cnt.value & 63)
        else:
            a.mov(RCX, operand(ins.b))
            shift(tgt, CL)
        if D is None:
            store(ref)

    def emit_unary(ref: int, method) -> None:
        ins = instrs[ref]
        D = dst_reg(ref)
        if D is not None:
            if reg_of(ins.a) != D:
                into(D, ins.a)
            method(D)
        else:
            into(RAX, ins.a)
            method(RAX)
            store(ref)

    def emit_value(ref: int) -> None:
        """Emit code for one value-producing op (not CONST/LOAD/GUARD)."""
        ins = instrs[ref]
        op = ins.op
        if op in _BIN_METHOD:                   # add/sub/and/or/xor
            emit_binop(ref, getattr(a, _BIN_METHOD[op]), op in _COMMUTATIVE)
        elif op == IROp.MUL:
            emit_binop(ref, a.imul, True)
        elif op in (IROp.SHL, IROp.SHR):
            emit_shift(ref, op == IROp.SHL)
        elif op == IROp.NEG:
            emit_unary(ref, a.neg)
        elif op == IROp.INVERT:
            emit_unary(ref, a.not_)
        elif op == IROp.NOT:
            into(RAX, ins.a)
            a.test(RAX, RAX)
            a.setz(AL)
            a.movzx(RAX, AL)
            store(ref)
        elif op in _SETCC:                      # eq/ne/lt/le/gt/ge -> 0/1
            lhs = as_reg(ins.a)
            a.cmp(lhs, operand(ins.b))
            getattr(a, _SETCC[op])(AL)
            a.movzx(RAX, AL)
            store(ref)

    # -- prologue: load each live-in into its allocated location -------------
    def seed(slot: int, ref: int) -> None:
        l = loc.get(ref)
        if isinstance(l, Reg):
            a.mov(l, mem_local(slot))
        elif l is not None:
            a.mov(RAX, mem_local(slot))
            a.mov(mem_spill(l.index), RAX)

    for slot, ref in trace.load_refs.items():
        seed(slot, ref)


    # Preheader: the hoisted loop-invariant computations, run once.
    for ref in hoist:
        emit_value(ref)

    top = a.label("trace_top")
    a.bind(top)
    exit_stubs: list = []   # (Guard, Label)

    for ref, ins in enumerate(instrs):
        op = ins.op
        if op in (IROp.CONST, IROp.LOAD) or ref in hoist_set:
            continue                            # immediate / prologue / hoisted

        if op == IROp.GUARD:
            g = ins.guard
            assert g is not None
            cond = as_reg(g.cond)
            a.test(cond, cond)
            stub = a.label(f"exit{g.exit_id}")
            (a.jz if g.expected else a.jnz)(stub)
            exit_stubs.append((g, stub))
        else:
            emit_value(ref)

    # -- back-edge: move each carried live-in into its phi location ----------
    def loc_key(l):
        return ("r", int(l)) if isinstance(l, Reg) else ("s", l.index)

    def move_to(dst, src_ref: int) -> None:
        """Emit `dst location <- value of src_ref` (dst is a Reg or Spill)."""
        if isinstance(dst, Reg):
            into(dst, src_ref)
            return
        if is_const(src_ref):
            v = instrs[src_ref].value
            if _fits32(v):
                a.mov(mem_spill(dst.index), v)
            else:
                a.mov(RAX, v)
                a.mov(mem_spill(dst.index), RAX)
        else:
            sl = loc[src_ref]
            if isinstance(sl, Reg):
                a.mov(mem_spill(dst.index), sl)
            else:
                a.mov(RAX, mem_spill(sl.index))
                a.mov(mem_spill(dst.index), RAX)

    resume_pcs = [0] * len(trace.exits)

    if trace.is_loop:
        dests = [loc[trace.load_refs[s]] for s in phi_slots]
        src_refs = [trace.carried[s] for s in phi_slots]
        dest_keys = {loc_key(d) for d in dests}
        src_keys = {loc_key(loc[r]) for r in src_refs if not is_const(r)}
        if dest_keys & src_keys:
            # Some phi's new value sits in another phi's target (a swap-like
            # cycle): stage every source through scratch, then land them all.
            for k, src in enumerate(src_refs):
                into(RAX, src)
                a.mov(mem_scratch(k), RAX)
            for k, dst in enumerate(dests):
                a.mov(RAX, mem_scratch(k))
                if isinstance(dst, Reg):
                    a.mov(dst, RAX)
                else:
                    a.mov(mem_spill(dst.index), RAX)
        else:
            # No overlap between sources and destinations: move directly, in
            # any order -- the common case, register-to-register, no memory.
            for dst, src in zip(dests, src_refs):
                move_to(dst, src)
        a.jmp(top)
    else:
        # Side trace: reached the loop header. Write the terminal snapshot and
        # return its exit id; the JIT links this exit to the main trace.
        assert trace.terminal_id is not None
        g = trace.exits[trace.terminal_id]
        assert g.snapshot is not None
        for slot, ref in g.snapshot.mapping.items():
            a.mov(mem_local(slot), as_reg(ref))
        a.mov(RAX, g.exit_id)
        a.ret()
        resume_pcs[g.exit_id] = g.snapshot.resume_pc

    # -- exit stubs: write the snapshot to the buffer, return the exit id -----
    for g, stub in exit_stubs:
        assert g.snapshot is not None
        a.bind(stub)
        for slot, ref in g.snapshot.mapping.items():
            a.mov(mem_local(slot), as_reg(ref))
        a.mov(RAX, g.exit_id)
        a.ret()
        resume_pcs[g.exit_id] = g.snapshot.resume_pc

    obj = a.finalize()
    addr = rt.add(obj, name=name)
    fn = _TRACE_FN(addr)
    bufsize = n_locals + alloc.n_spill + len(phi_slots)
    buf = (ctypes.c_int64 * bufsize)()
    marshal = sorted(trace.in_slots | trace.out_slots)
    return CompiledTrace(fn, buf, marshal, sorted(trace.out_slots), resume_pcs)


# ===========================================================================
# Driver -- the TracingJIT: hot-loop counters, trace cache, side traces.
# ===========================================================================


class TracingJIT:
    """Attach to a VM; compiles hot `while` loops via the `on_backedge` hook.

    State machine per back-edge: cold --(hits >= threshold)--> record; record ok
    -> compile+cache+run; record abort -> blacklist and keep interpreting;
    cached -> run. A guard that fails often gets its own side trace (recorded
    from that exit's resume pc to the loop header) linked in, so a data-dependent
    branch (collatz's parity split) keeps running native across the flip; `_run_
    chain` follows those links."""

    def __init__(self, vm: VM, *, threshold: int = 50,
                 side_threshold: int = 10, runtime: Runtime | None = None,
                 log: bool = False):
        self.vm = vm
        self.threshold = threshold
        self.side_threshold = side_threshold
        self.rt = runtime or Runtime()
        self.log = log

        self.hot: dict[tuple[int, int], int] = {}
        self.traces: dict[tuple[int, int], CompiledTrace] = {}
        self.blacklist: set[tuple[int, int]] = set()
        self.recorded: dict[tuple[int, int], Trace] = {}  # for inspection

        self.exit_counts: dict[tuple[int, int], int] = {}
        self.side_done: set[tuple[int, int]] = set()

        self.n_compiled = 0
        self.n_side = 0
        self.n_aborted = 0
        self.n_trace_runs = 0
        self.n_type_deopt = 0     # trace runs skipped: a live-in was not an int

        vm.on_backedge = self.on_backedge

    # -- dispatch ------------------------------------------------------------

    def on_backedge(self, code: CodeObject, target: int, regs: list[Value],
                    glb: dict) -> int | None:
        key = (id(code), target)

        trace = self.traces.get(key)
        if trace is not None:
            return self._run_chain(trace, regs)

        if key in self.blacklist:
            return None

        count = self.hot.get(key, 0) + 1
        self.hot[key] = count
        if count < self.threshold:
            return None

        ir = record(code, target, regs)
        if ir is None:
            self.blacklist.add(key)
            self.n_aborted += 1
            if self.log:
                print(f"[jit] abort   {code.name} @pc{target}")
            return None

        compiled = self._install(ir, code, target, key)
        return self._run_chain(compiled, regs)

    def _install(self, ir: Trace, code: CodeObject, header_pc: int,
                 key: tuple[int, int]) -> CompiledTrace:
        compiled = compile_trace(ir, self.rt)
        compiled.code = code
        compiled.header_pc = header_pc
        self.traces[key] = compiled
        self.recorded[key] = ir
        self.n_compiled += 1
        if self.log:
            print(f"[jit] compile {code.name} @pc{header_pc} "
                  f"({len(ir.instrs)} ir, {len(ir.exits)} exits)")
        return compiled

    def _run_chain(self, trace: CompiledTrace, regs: list[Value]) -> int | None:
        """Run a trace, then follow links / record side traces, staying in
        native code until an exit has nowhere to go. Returns the interpreter
        resume pc (or None if a trace bailed on its entry type guard)."""
        while True:
            exit_id = trace.run_raw(regs)
            if exit_id is None:
                # entry type guard failed: a live-in is no longer an int, so the
                # trace's int assumptions don't hold -> deopt to the interpreter.
                self.n_type_deopt += 1
                return None
            self.n_trace_runs += 1

            nxt = trace.links.get(exit_id)
            if nxt is not None:
                trace = nxt
                continue

            resume_pc = trace.resume_pcs[exit_id]
            side = self._maybe_side_trace(trace, exit_id, resume_pc, regs)
            if side is not None:
                trace = side
                continue
            return resume_pc

    # -- side tracing --------------------------------------------------------

    def _maybe_side_trace(self, trace: CompiledTrace, exit_id: int,
                          resume_pc: int, regs: list[Value]
                          ) -> CompiledTrace | None:
        """If this guard exit is hot, record a side trace from its resume pc to
        the loop header, link it in, and return it to continue the chain."""
        ekey = (id(trace), exit_id)
        if ekey in self.side_done:
            return None
        cnt = self.exit_counts.get(ekey, 0) + 1
        self.exit_counts[ekey] = cnt
        if cnt < self.side_threshold:
            return None
        self.side_done.add(ekey)   # decide once, either way

        code, header_pc = trace.code, trace.header_pc
        assert code is not None
        ir = record(code, resume_pc, regs, header_pc=header_pc)
        if ir is None:
            self.n_aborted += 1
            if self.log:
                print(f"[jit] side abort {code.name} @pc{resume_pc}")
            return None

        side = compile_trace(ir, self.rt)
        side.code = code
        side.header_pc = header_pc
        self.n_compiled += 1
        self.n_side += 1
        trace.links[exit_id] = side
        # the side trace's terminal hands back to the loop's main trace
        main = self.traces.get((id(code), header_pc))
        if main is not None and ir.terminal_id is not None:
            side.links[ir.terminal_id] = main
        if self.log:
            print(f"[jit] side    {code.name} @pc{resume_pc} -> header "
                  f"{header_pc} ({len(ir.instrs)} ir)")
        return side

    # -- introspection -------------------------------------------------------

    def stats(self) -> dict[str, int]:
        return {
            "compiled": self.n_compiled,
            "side": self.n_side,
            "aborted": self.n_aborted,
            "trace_runs": self.n_trace_runs,
            "type_deopt": self.n_type_deopt,
            "blacklisted": len(self.blacklist),
        }

    def trace_ir(self, code: CodeObject, target: int) -> str:
        """Human-readable IR for a recorded trace (debugging / tests)."""
        return format_trace(self.recorded[(id(code), target)])
