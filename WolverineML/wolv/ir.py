"""The three-address IR, and the control flow graph both IRs are written in.

There are two instruction sets in this compiler.  This module has the first:
three-address code over virtual registers, which is what lowering produces,
what `ssa.py` puts into SSA and what `opt.py` rewrites.  The second is in
`mach.py`, and instruction selection replaces the arithmetic of this one with
it.

What they share is everything else — the registers, the blocks, the graph, the
frame — so the passes that only care about the shape of a function (liveness,
dominance, both register allocators, the verifiers) work on either, and neither
has to know what the other's instructions mean.  That is what the methods on
`Instr` are for: an instruction says which register it writes and which it
reads, and nothing outside it has to match on what it is.

Nothing here is ARM-specific except that a register holds exactly one 64-bit
word, and the frame layout at the top, which the emitter and the nested
functions have to agree about.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from typing import Final

type Reg = int
type Name = Callable[[Reg], str]  # how a register is written in a dump
type Rewrite = Callable[[Reg], Reg]  # how a register is renamed

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


# -- what every instruction of either set can be asked -------------------------


@dataclass(slots=True)
class Instr:
    """The base of both instruction sets.

    A pass that walks a function asks these five questions and no others, which
    is why one liveness analysis and one register allocator serve both levels.
    """

    def defs(self) -> Reg | None:
        """The register it writes, if it writes one."""
        return None

    def uses(self) -> list[Reg]:
        """The registers it reads.  A phi's arguments are read on the edges,
        not here, so they are not among them."""
        return []

    def map_uses(self, f: Rewrite) -> None:
        """Rewrite the registers it reads, in place."""

    def set_def(self, r: Reg) -> None:
        raise AssertionError(f"{type(self).__name__} defines nothing")

    def has_effect(self) -> bool:
        """True when it has to be kept even if its result is dead."""
        return False

    def show(self, name: Name) -> str:
        return "?"


# -- the three-address instructions -------------------------------------------


@dataclass(slots=True)
class Const(Instr):
    dst: Reg
    value: int

    def defs(self) -> Reg | None:
        return self.dst

    def set_def(self, r: Reg) -> None:
        self.dst = r

    def show(self, name: Name) -> str:
        return f"{name(self.dst)} = {self.value}"


@dataclass(slots=True)
class StrConst(Instr):
    dst: Reg
    symbol: str

    def defs(self) -> Reg | None:
        return self.dst

    def set_def(self, r: Reg) -> None:
        self.dst = r

    def show(self, name: Name) -> str:
        return f"{name(self.dst)} = &{self.symbol}"


@dataclass(slots=True)
class Move(Instr):
    dst: Reg
    src: Reg

    def defs(self) -> Reg | None:
        return self.dst

    def uses(self) -> list[Reg]:
        return [self.src]

    def map_uses(self, f: Rewrite) -> None:
        self.src = f(self.src)

    def set_def(self, r: Reg) -> None:
        self.dst = r

    def show(self, name: Name) -> str:
        return f"{name(self.dst)} = {name(self.src)}"


@dataclass(slots=True)
class Bin(Instr):
    dst: Reg
    op: str
    lhs: Reg
    rhs: Reg

    def defs(self) -> Reg | None:
        return self.dst

    def uses(self) -> list[Reg]:
        return [self.lhs, self.rhs]

    def map_uses(self, f: Rewrite) -> None:
        self.lhs = f(self.lhs)
        self.rhs = f(self.rhs)

    def set_def(self, r: Reg) -> None:
        self.dst = r

    def show(self, name: Name) -> str:
        return f"{name(self.dst)} = {name(self.lhs)} {self.op} {name(self.rhs)}"


@dataclass(slots=True)
class Cmp(Instr):
    dst: Reg
    op: str
    lhs: Reg
    rhs: Reg

    def defs(self) -> Reg | None:
        return self.dst

    def uses(self) -> list[Reg]:
        return [self.lhs, self.rhs]

    def map_uses(self, f: Rewrite) -> None:
        self.lhs = f(self.lhs)
        self.rhs = f(self.rhs)

    def set_def(self, r: Reg) -> None:
        self.dst = r

    def show(self, name: Name) -> str:
        return f"{name(self.dst)} = {name(self.lhs)} {self.op} {name(self.rhs)}"


@dataclass(slots=True)
class Load(Instr):
    dst: Reg
    base: Reg
    offset: int

    def defs(self) -> Reg | None:
        return self.dst

    def uses(self) -> list[Reg]:
        return [self.base]

    def map_uses(self, f: Rewrite) -> None:
        self.base = f(self.base)

    def set_def(self, r: Reg) -> None:
        self.dst = r

    def show(self, name: Name) -> str:
        return f"{name(self.dst)} = [{name(self.base)} + {self.offset}]"


@dataclass(slots=True)
class Store(Instr):
    base: Reg
    offset: int
    src: Reg

    def uses(self) -> list[Reg]:
        return [self.base, self.src]

    def map_uses(self, f: Rewrite) -> None:
        self.base = f(self.base)
        self.src = f(self.src)

    def has_effect(self) -> bool:
        return True

    def show(self, name: Name) -> str:
        return f"[{name(self.base)} + {self.offset}] = {name(self.src)}"


# -- the frame, calls and joins, which both instruction sets keep --------------


@dataclass(slots=True)
class LoadSlot(Instr):
    """Read a frame slot of this function — an escaping variable, or a spill."""

    dst: Reg
    slot: int

    def defs(self) -> Reg | None:
        return self.dst

    def set_def(self, r: Reg) -> None:
        self.dst = r

    def show(self, name: Name) -> str:
        return f"{name(self.dst)} = slot{self.slot}"


@dataclass(slots=True)
class StoreSlot(Instr):
    slot: int
    src: Reg

    def uses(self) -> list[Reg]:
        return [self.src]

    def map_uses(self, f: Rewrite) -> None:
        self.src = f(self.src)

    def has_effect(self) -> bool:
        return True

    def show(self, name: Name) -> str:
        return f"slot{self.slot} = {name(self.src)}"


@dataclass(slots=True)
class FrameAddr(Instr):
    """The frame pointer itself, which is what a static link points at."""

    dst: Reg

    def defs(self) -> Reg | None:
        return self.dst

    def set_def(self, r: Reg) -> None:
        self.dst = r

    def show(self, name: Name) -> str:
        return f"{name(self.dst)} = frame"


@dataclass(slots=True)
class Call(Instr):
    dst: Reg | None
    callee: str
    args: list[Reg]

    def defs(self) -> Reg | None:
        return self.dst

    def uses(self) -> list[Reg]:
        return list(self.args)

    def map_uses(self, f: Rewrite) -> None:
        self.args = [f(a) for a in self.args]

    def set_def(self, r: Reg) -> None:
        self.dst = r

    def has_effect(self) -> bool:
        return True

    def show(self, name: Name) -> str:
        call = f"{self.callee}({', '.join(name(a) for a in self.args)})"
        return call if self.dst is None else f"{name(self.dst)} = {call}"


@dataclass(slots=True)
class Phi(Instr):
    dst: Reg
    args: dict[str, Reg]

    def defs(self) -> Reg | None:
        return self.dst

    def set_def(self, r: Reg) -> None:
        self.dst = r

    def show(self, name: Name) -> str:
        parts = ", ".join(f"{p}: {name(r)}" for p, r in self.args.items())
        return f"{name(self.dst)} = phi [{parts}]"


# -- control flow -------------------------------------------------------------


@dataclass(slots=True)
class Jmp(Instr):
    target: str

    def has_effect(self) -> bool:
        return True

    def show(self, name: Name) -> str:
        return f"jmp {self.target}"


@dataclass(slots=True)
class CBr(Instr):
    cond: Reg
    then: str
    els: str
    # After selection a branch may read the flags a comparison just set instead
    # of testing a register, and then it reads no register at all.
    code: str = ""

    def uses(self) -> list[Reg]:
        return [] if self.code else [self.cond]

    def map_uses(self, f: Rewrite) -> None:
        if not self.code:
            self.cond = f(self.cond)

    def has_effect(self) -> bool:
        return True

    def show(self, name: Name) -> str:
        test = f"{self.code}?" if self.code else f"{name(self.cond)} ?"
        return f"br {test} {self.then} : {self.els}"


@dataclass(slots=True)
class Ret(Instr):
    value: Reg | None

    def uses(self) -> list[Reg]:
        return [] if self.value is None else [self.value]

    def map_uses(self, f: Rewrite) -> None:
        if self.value is not None:
            self.value = f(self.value)

    def has_effect(self) -> bool:
        return True

    def show(self, name: Name) -> str:
        return "ret" if self.value is None else f"ret {name(self.value)}"


type Terminator = Jmp | CBr | Ret


# -- the graph ----------------------------------------------------------------


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


def naming(func: Func) -> Name:
    def name(r: Reg) -> str:
        return reg_name(func, r)

    return name


def show_instr(func: Func, instr: Instr) -> str:
    return instr.show(naming(func))


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
