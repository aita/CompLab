"""The intermediate representation: a control flow graph of three-address code.

One IR serves the whole back end.  It comes out of lowering with variables
written many times, goes through `ssa.py` and comes back with one definition
per register and phis at the joins, and leaves register allocation with a
colour attached to every register.  Nothing about it is ARM-specific except
that a register holds exactly one 64-bit word.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from typing import Final

type Reg = int

WORD: Final = 8

# How many arguments AAPCS64 passes in registers.  The rest go on the stack,
# and the frame layout below knows where.
ARGUMENT_REGISTERS: Final = 8


def slot_offset(slot: int) -> int:
    """Where a frame slot sits, relative to the frame pointer.

    Slot 0 of every nested function holds its static link, so a frame chain
    can be walked without knowing whose frame it is.  Negative slots are the
    arguments the caller had to pass on the stack: they are already in the
    frame, above the saved frame record, so nothing has to be copied for them
    and they never take a register at entry.
    """
    if slot < 0:
        return 16 + WORD * (-slot - 1)
    return -WORD * (slot + 1)


@dataclass(slots=True)
class Instr:
    pass


@dataclass(slots=True)
class Const(Instr):
    dst: Reg
    value: int


@dataclass(slots=True)
class StrConst(Instr):
    dst: Reg
    symbol: str


@dataclass(slots=True)
class Move(Instr):
    dst: Reg
    src: Reg


@dataclass(slots=True)
class Bin(Instr):
    dst: Reg
    op: str
    lhs: Reg
    rhs: Reg


@dataclass(slots=True)
class Cmp(Instr):
    dst: Reg
    op: str
    lhs: Reg
    rhs: Reg


@dataclass(slots=True)
class Load(Instr):
    dst: Reg
    base: Reg
    offset: int


@dataclass(slots=True)
class Store(Instr):
    base: Reg
    offset: int
    src: Reg


@dataclass(slots=True)
class LoadSlot(Instr):
    """Read a frame slot of this function — an escaping variable, or a spill."""

    dst: Reg
    slot: int


@dataclass(slots=True)
class StoreSlot(Instr):
    slot: int
    src: Reg


@dataclass(slots=True)
class FrameAddr(Instr):
    """The frame pointer itself, which is what a static link points at."""

    dst: Reg


@dataclass(slots=True)
class Call(Instr):
    dst: Reg | None
    callee: str
    args: list[Reg]


@dataclass(slots=True)
class Phi(Instr):
    dst: Reg
    args: dict[str, Reg]


@dataclass(slots=True)
class Jmp(Instr):
    target: str


@dataclass(slots=True)
class CBr(Instr):
    cond: Reg
    then: str
    els: str


@dataclass(slots=True)
class Ret(Instr):
    value: Reg | None


type Terminator = Jmp | CBr | Ret


@dataclass(slots=True)
class Block:
    label: str
    phis: list[Phi] = field(default_factory=list)
    instrs: list[Instr] = field(default_factory=list)
    preds: list[str] = field(default_factory=list)

    @property
    def terminator(self) -> Terminator:
        assert self.instrs, f"block {self.label} is unterminated"
        last = self.instrs[-1]
        assert isinstance(last, (Jmp, CBr, Ret)), f"block {self.label} falls through"
        return last

    @property
    def succs(self) -> list[str]:
        match self.terminator:
            case Jmp(target):
                return [target]
            case CBr(_, then, els):
                return [then, els] if then != els else [then]
            case Ret():
                return []


@dataclass(slots=True)
class Func:
    """One function: a frame, a set of parameters, and a graph of blocks."""

    label: str
    name: str
    params: list[Reg]
    depth: int
    entry: str = "entry"
    blocks: dict[str, Block] = field(default_factory=dict)
    order: list[str] = field(default_factory=list)
    nregs: int = 0
    nslots: int = 0
    static_link_slot: int = -1
    returns_value: bool = False
    colours: dict[Reg, int] = field(default_factory=dict)
    spill_slots: dict[Reg, int] = field(default_factory=dict)
    saved: list[int] = field(default_factory=list)

    def new_reg(self) -> Reg:
        self.nregs += 1
        return self.nregs - 1

    def new_slot(self) -> int:
        self.nslots += 1
        return self.nslots - 1

    def add_block(self, label: str) -> Block:
        assert label not in self.blocks
        b = Block(label)
        self.blocks[label] = b
        self.order.append(label)
        return b

    def walk(self) -> Iterator[Block]:
        for label in self.order:
            yield self.blocks[label]


@dataclass(slots=True)
class Module:
    funcs: list[Func] = field(default_factory=list)
    strings: dict[str, str] = field(default_factory=dict)  # symbol -> text


# -- reading and rewriting registers ------------------------------------------


def defs(instr: Instr) -> Reg | None:
    match instr:
        case Const(dst) | StrConst(dst) | Move(dst) | FrameAddr(dst) | Phi(dst):
            return dst
        case Bin(dst) | Cmp(dst) | Load(dst) | LoadSlot(dst):
            return dst
        case Call(dst):
            return dst
        case _:
            return None


def uses(instr: Instr) -> list[Reg]:
    """The registers read, not counting a phi's — those belong to the edges."""
    match instr:
        case Move(_, src) | StoreSlot(_, src) | Ret(src) if src is not None:
            return [src]
        case Bin(_, _, a, b) | Cmp(_, _, a, b):
            return [a, b]
        case Load(_, base, _):
            return [base]
        case Store(base, _, src):
            return [base, src]
        case Call(_, _, args):
            return list(args)
        case CBr(cond, _, _):
            return [cond]
        case _:
            return []


def map_uses(instr: Instr, f: Callable[[Reg], Reg]) -> None:
    """Rewrite the registers an instruction reads, in place."""
    match instr:
        case Move():
            instr.src = f(instr.src)
        case StoreSlot():
            instr.src = f(instr.src)
        case Ret() if instr.value is not None:
            instr.value = f(instr.value)
        case Bin() | Cmp():
            instr.lhs = f(instr.lhs)
            instr.rhs = f(instr.rhs)
        case Load():
            instr.base = f(instr.base)
        case Store():
            instr.base = f(instr.base)
            instr.src = f(instr.src)
        case Call():
            instr.args = [f(a) for a in instr.args]
        case CBr():
            instr.cond = f(instr.cond)
        case _:
            pass


def set_def(instr: Instr, r: Reg) -> None:
    match instr:
        case Const() | StrConst() | Move() | FrameAddr() | Phi():
            instr.dst = r
        case Bin() | Cmp() | Load() | LoadSlot():
            instr.dst = r
        case Call():
            instr.dst = r
        case _:
            raise AssertionError("instruction defines nothing")


def has_effect(instr: Instr) -> bool:
    """True when an instruction has to be kept even if its result is dead."""
    return isinstance(instr, (Store, StoreSlot, Call, Jmp, CBr, Ret))


def rename_target(instr: Instr, old: str, new: str) -> None:
    match instr:
        case Jmp() if instr.target == old:
            instr.target = new
        case CBr():
            if instr.then == old:
                instr.then = new
            if instr.els == old:
                instr.els = new
        case _:
            pass


def recompute_preds(func: Func) -> None:
    for b in func.blocks.values():
        b.preds = []
    for b in func.walk():
        for s in b.succs:
            func.blocks[s].preds.append(b.label)


def reachable(func: Func) -> set[str]:
    seen: set[str] = set()
    stack = [func.entry]
    while stack:
        label = stack.pop()
        if label in seen:
            continue
        seen.add(label)
        stack.extend(func.blocks[label].succs)
    return seen


def drop_unreachable(func: Func) -> None:
    live = reachable(func)
    for label in list(func.blocks):
        if label not in live:
            del func.blocks[label]
    func.order = [label for label in func.order if label in live]
    for b in func.walk():
        for phi in b.phis:
            phi.args = {p: r for p, r in phi.args.items() if p in live}
    recompute_preds(func)


def rpo(func: Func) -> list[str]:
    """Reverse post-order, which is the order every dataflow pass walks in."""
    order: list[str] = []
    seen: set[str] = set()
    stack: list[tuple[str, bool]] = [(func.entry, False)]
    while stack:
        label, done = stack.pop()
        if done:
            order.append(label)
            continue
        if label in seen:
            continue
        seen.add(label)
        stack.append((label, True))
        for s in reversed(func.blocks[label].succs):
            if s not in seen:
                stack.append((s, False))
    order.reverse()
    return order


# -- printing -----------------------------------------------------------------


def reg_name(func: Func, r: Reg) -> str:
    colour = func.colours.get(r)
    return f"%{r}" if colour is None else f"%{r}:{colour}"


def show_instr(func: Func, instr: Instr) -> str:
    def n(r: Reg) -> str:
        return reg_name(func, r)

    match instr:
        case Const(dst, value):
            return f"{n(dst)} = {value}"
        case StrConst(dst, symbol):
            return f"{n(dst)} = &{symbol}"
        case Move(dst, src):
            return f"{n(dst)} = {n(src)}"
        case Bin(dst, op, a, b):
            return f"{n(dst)} = {n(a)} {op} {n(b)}"
        case Cmp(dst, op, a, b):
            return f"{n(dst)} = {n(a)} {op} {n(b)}"
        case Load(dst, base, off):
            return f"{n(dst)} = [{n(base)} + {off}]"
        case Store(base, off, src):
            return f"[{n(base)} + {off}] = {n(src)}"
        case LoadSlot(dst, slot):
            return f"{n(dst)} = slot{slot}"
        case StoreSlot(slot, src):
            return f"slot{slot} = {n(src)}"
        case FrameAddr(dst):
            return f"{n(dst)} = frame"
        case Call(dst, callee, args):
            call = f"{callee}({', '.join(n(a) for a in args)})"
            return call if dst is None else f"{n(dst)} = {call}"
        case Phi(dst, args):
            parts = ", ".join(f"{p}: {n(r)}" for p, r in args.items())
            return f"{n(dst)} = phi [{parts}]"
        case Jmp(target):
            return f"jmp {target}"
        case CBr(cond, then, els):
            return f"br {n(cond)} ? {then} : {els}"
        case Ret(value):
            return "ret" if value is None else f"ret {n(value)}"
        case _:
            return "?"


def show_func(func: Func) -> str:
    out: list[str] = []
    params = ", ".join(reg_name(func, r) for r in func.params)
    out.append(f"fun {func.label}({params})  ; depth {func.depth}, {func.nslots} slots")
    for b in func.walk():
        preds = f"  ; preds: {', '.join(b.preds)}" if b.preds else ""
        out.append(f"{b.label}:{preds}")
        for phi in b.phis:
            out.append(f"    {show_instr(func, phi)}")
        for instr in b.instrs:
            out.append(f"    {show_instr(func, instr)}")
    return "\n".join(out)


def show_module(mod: Module) -> str:
    parts = [show_func(f) for f in mod.funcs]
    if mod.strings:
        lines = [f'{sym}: "{text}"' for sym, text in mod.strings.items()]
        parts.append("\n".join(lines))
    return "\n\n".join(parts) + "\n"
