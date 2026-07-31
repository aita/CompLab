"""ARMv8 assembly, in AAPCS64.

The frame is the ordinary one.  `x29` points at the saved frame record, the
slots an escaping variable or a spill lives in are below it, the callee-saved
registers this function actually used are below those, and outgoing stack
arguments sit at the bottom, at `sp`, where the callee expects them.

    x29 -> | saved x29, x30 |
           | slot 0         |   x29 - 8      also where a static link points
           | slot 1         |   x29 - 16
           | ...            |
           | saved x19...   |
    sp  -> | outgoing args  |

Phis are resolved here rather than in the IR.  A phi is a copy on an edge, so
the copies go at the end of the predecessor, all at once: the values are read
before any is written, which is what `_sequentialize` arranges.  When the
copies form a cycle it borrows a register the function never used, and when
there is none it swaps the two ends with three `eor`s, so no register has to be
reserved for it.
"""

from __future__ import annotations

from dataclasses import dataclass

from wolv import ir
from wolv.machine import ARGUMENT_REGS, CALLER_SAVED, SCRATCH

CONDITIONS: dict[str, str] = {
    "=": "eq",
    "<>": "ne",
    "<": "lt",
    "<=": "le",
    ">": "gt",
    ">=": "ge",
    "u<": "lo",
    "u>=": "hs",
}

ARITHMETIC: dict[str, str] = {
    "+": "add",
    "-": "sub",
    "*": "mul",
    "/": "sdiv",
    "and": "and",
    "or": "orr",
    "xor": "eor",
    "shl": "lsl",
    "shr": "asr",
}

UNSCALED: dict[str, str] = {"ldr": "ldur", "str": "stur"}

# The one register kept back.  A frame big enough to put a slot out of reach of
# `ldur` is only discovered after allocation has added its spill slots, so the
# address has to be computed somewhere the allocator does not know about.
SPARE = SCRATCH[0]

# Nothing of ours is live at the top of the prologue except the incoming
# arguments, so a caller-saved register that is not one of them is free there.
PROLOGUE_TEMP = 9


@dataclass(slots=True)
class Frame:
    slots: int
    saved: list[int]
    stack_args: int
    size: int = 0

    def __post_init__(self) -> None:
        raw = ir.WORD * (self.slots + len(self.saved) + self.stack_args)
        self.size = (raw + 15) & ~15

    def slot_offset(self, slot: int) -> int:
        return ir.slot_offset(slot)

    def saved_offset(self, index: int) -> int:
        return -ir.WORD * (self.slots + index + 1)


def frame_of(func: ir.Func) -> Frame:
    stack_args = 0
    for block in func.walk():
        for instr in block.instrs:
            match instr:
                case ir.Call(_, _, args):
                    stack_args = max(stack_args, len(args) - len(ARGUMENT_REGS))
    return Frame(func.nslots, list(func.saved), max(stack_args, 0))


class FuncEmitter:
    def __init__(self, func: ir.Func) -> None:
        self.func = func
        self.frame = frame_of(func)
        self.out: list[str] = []
        self.epilogue = f".Lepi_{func.label}"
        reads = _read_counts(func)
        self.uses_once = {r for r, n in reads.items() if n == 1}
        self.read_somewhere = set(reads)
        self.taken = set(func.colours.values())
        self.constants, self.immediate_only = _inlineable_constants(func)

    # -- helpers ----------------------------------------------------------

    def line(self, text: str) -> None:
        self.out.append(f"\t{text}")

    def label(self, text: str) -> None:
        self.out.append(f"{text}:")

    def colour(self, reg: ir.Reg) -> int:
        colour = self.func.colours.get(reg)
        assert colour is not None, f"%{reg} was never coloured"
        return colour

    def operand(self, reg: ir.Reg) -> str:
        """A register, or the constant it holds if the instruction can take one."""
        if reg in self.immediate_only:
            return f"#{self.constants[reg]}"
        return f"x{self.colour(reg)}"

    def mov(self, dst: int, src: int) -> None:
        if dst != src:
            self.line(f"mov x{dst}, x{src}")

    def immediate(self, dst: int, value: int) -> None:
        word = value & ((1 << 64) - 1)
        if word == 0:
            self.line(f"mov x{dst}, #0")
            return
        chunks = [(word >> shift) & 0xFFFF for shift in (0, 16, 32, 48)]
        first = True
        for i, chunk in enumerate(chunks):
            if chunk == 0:
                continue
            shift = f", lsl #{i * 16}" if i else ""
            self.line(f"{'movz' if first else 'movk'} x{dst}, #{chunk}{shift}")
            first = False

    def access(self, op: str, reg: int, base: int, offset: int) -> None:
        """`ldr`/`str`, in whichever addressing mode reaches this far."""
        where = "sp" if base == 31 else f"x{base}"
        if 0 <= offset <= 32760 and offset % ir.WORD == 0:
            self.line(f"{op} x{reg}, [{where}, #{offset}]")
        elif -256 <= offset <= 255:
            self.line(f"{UNSCALED[op]} x{reg}, [{where}, #{offset}]")
        else:
            self.immediate(SPARE, offset)
            self.line(f"{op} x{reg}, [{where}, x{SPARE}]")

    # -- whole functions --------------------------------------------------

    def emit(self) -> list[str]:
        self.out.append(f"\t.globl {self.func.label}")
        self.out.append(f"\t.type {self.func.label}, %function")
        self.label(self.func.label)
        self.prologue()
        order = self.func.order
        for i, name in enumerate(order):
            self.label(f".L{self.func.label}_{name}")
            nxt = order[i + 1] if i + 1 < len(order) else None
            self.block(self.func.blocks[name], nxt)
        self.label(self.epilogue)
        self.restore()
        self.line("mov sp, x29")
        self.line("ldp x29, x30, [sp], #16")
        self.line("ret")
        self.out.append(f"\t.size {self.func.label}, .-{self.func.label}")
        return self.out

    def prologue(self) -> None:
        self.line("stp x29, x30, [sp, #-16]!")
        self.line("mov x29, sp")
        if self.frame.size:
            if self.frame.size <= 4095:
                self.line(f"sub sp, sp, #{self.frame.size}")
            else:
                self.immediate(PROLOGUE_TEMP, self.frame.size)
                self.line(f"sub sp, sp, x{PROLOGUE_TEMP}")
        for i, reg in enumerate(self.frame.saved):
            self.access("str", reg, 29, self.frame.saved_offset(i))
        self.copies(
            [
                (self.colour(p), ARGUMENT_REGS[i])
                for i, p in enumerate(self.func.params)
                if p in self.read_somewhere
            ]
        )

    def restore(self) -> None:
        for i, reg in enumerate(self.frame.saved):
            self.access("ldr", reg, 29, self.frame.saved_offset(i))

    def block(self, block: ir.Block, nxt: str | None) -> None:
        pending_condition: str | None = None
        body = block.instrs[:-1]
        fused = -1
        for i, instr in enumerate(body):
            if i == fused:
                continue
            if self._compares_for(instr, i, body, block):
                assert isinstance(instr, ir.Cmp)
                self.line(f"cmp x{self.colour(instr.lhs)}, {self.operand(instr.rhs)}")
                pending_condition = CONDITIONS[instr.op]
                continue
            difference = self._subtracts_from(instr, i, body)
            if difference is not None:
                assert isinstance(instr, ir.Bin)
                self.multiply_subtract(instr, difference)
                fused = i + 1
                continue
            self.instruction(instr)
        self.terminator(block, nxt, pending_condition)

    def _compares_for(
        self, instr: ir.Instr, i: int, body: list[ir.Instr], block: ir.Block
    ) -> bool:
        """A comparison read only by the branch right after it sets the flags."""
        return (
            isinstance(instr, ir.Cmp)
            and i == len(body) - 1
            and isinstance(block.terminator, ir.CBr)
            and block.terminator.cond == instr.dst
            and instr.dst in self.uses_once
        )

    def _subtracts_from(
        self, instr: ir.Instr, i: int, body: list[ir.Instr]
    ) -> ir.Bin | None:
        """A product read only by the subtraction right after it becomes `msub`."""
        if not isinstance(instr, ir.Bin) or instr.op != "*":
            return None
        if instr.dst not in self.uses_once or i + 1 >= len(body):
            return None
        nxt = body[i + 1]
        if not isinstance(nxt, ir.Bin) or nxt.op != "-":
            return None
        if nxt.rhs != instr.dst or nxt.lhs == instr.dst:
            return None
        if instr.rhs in self.immediate_only or nxt.rhs in self.immediate_only:
            return None
        return nxt

    def terminator(
        self, block: ir.Block, nxt: str | None, condition: str | None
    ) -> None:
        match block.terminator:
            case ir.Jmp(target):
                self.edge(block.label, target)
                if target != nxt:
                    self.line(f"b .L{self.func.label}_{target}")
            case ir.CBr(cond, then, els):
                assert not self.func.blocks[then].phis
                assert not self.func.blocks[els].phis
                then_label = f".L{self.func.label}_{then}"
                else_label = f".L{self.func.label}_{els}"
                if condition is not None:
                    if then == nxt:
                        self.line(f"b.{_invert(condition)} {else_label}")
                    else:
                        self.line(f"b.{condition} {then_label}")
                        if els != nxt:
                            self.line(f"b {else_label}")
                elif then == nxt:
                    self.line(f"cbz x{self.colour(cond)}, {else_label}")
                else:
                    self.line(f"cbnz x{self.colour(cond)}, {then_label}")
                    if els != nxt:
                        self.line(f"b {else_label}")
            case ir.Ret(value):
                if value is not None:
                    self.mov(ARGUMENT_REGS[0], self.colour(value))
                if nxt is not None:  # the epilogue follows the last block
                    self.line(f"b {self.epilogue}")

    def edge(self, source: str, target: str) -> None:
        """The copies a phi stands for, made real on this edge."""
        phis = self.func.blocks[target].phis
        if not phis:
            return
        self.copies(
            [(self.colour(phi.dst), self.colour(phi.args[source])) for phi in phis]
        )

    def copies(self, moves: list[tuple[int, int]]) -> None:
        for step in _sequentialize(moves, self.borrowed(moves)):
            match step:
                case _Mov(dst, src):
                    self.mov(dst, src)
                case _Swap(a, b):
                    self.line(f"eor x{a}, x{a}, x{b}")
                    self.line(f"eor x{b}, x{a}, x{b}")
                    self.line(f"eor x{a}, x{a}, x{b}")

    def borrowed(self, moves: list[tuple[int, int]]) -> int | None:
        """A register free to clobber here, if the function left one over.

        A caller-saved register this function never gave to a value holds
        nothing of ours anywhere, and one that this copy neither reads nor
        writes holds nothing of the copy's either.  With no such register the
        copies swap instead, which needs no scratch at all.
        """
        touched = {r for pair in moves for r in pair}
        for reg in CALLER_SAVED:
            if reg not in self.taken and reg not in touched:
                return reg
        return None

    # -- one instruction --------------------------------------------------

    def instruction(self, instr: ir.Instr) -> None:
        match instr:
            case ir.Const(dst, value):
                if dst not in self.immediate_only:
                    self.immediate(self.colour(dst), value)
            case ir.StrConst(dst, symbol):
                d = self.colour(dst)
                self.line(f"adrp x{d}, {symbol}")
                self.line(f"add x{d}, x{d}, :lo12:{symbol}")
            case ir.Move(dst, src):
                self.mov(self.colour(dst), self.colour(src))
            case ir.Bin(dst, op, lhs, rhs):
                self.arithmetic(op, self.colour(dst), self.colour(lhs), rhs)
            case ir.Cmp(dst, op, lhs, rhs):
                self.line(f"cmp x{self.colour(lhs)}, {self.operand(rhs)}")
                self.line(f"cset x{self.colour(dst)}, {CONDITIONS[op]}")
            case ir.Load(dst, base, offset):
                self.access("ldr", self.colour(dst), self.colour(base), offset)
            case ir.Store(base, offset, src):
                self.access("str", self.colour(src), self.colour(base), offset)
            case ir.LoadSlot(dst, slot):
                self.access("ldr", self.colour(dst), 29, self.frame.slot_offset(slot))
            case ir.StoreSlot(slot, src):
                self.access("str", self.colour(src), 29, self.frame.slot_offset(slot))
            case ir.FrameAddr(dst):
                self.mov(self.colour(dst), 29)
            case ir.Call(dst, callee, args):
                self.call(dst, callee, args)
            case _:
                raise AssertionError(f"cannot emit {instr}")

    def arithmetic(self, op: str, dst: int, lhs: int, rhs: ir.Reg) -> None:
        self.line(f"{ARITHMETIC[op]} x{dst}, x{lhs}, {self.operand(rhs)}")

    def multiply_subtract(self, product: ir.Bin, difference: ir.Bin) -> None:
        """`a - x * y` in one instruction, which is how a remainder ends up."""
        self.line(
            f"msub x{self.colour(difference.dst)}, x{self.colour(product.lhs)}, "
            f"x{self.colour(product.rhs)}, x{self.colour(difference.lhs)}"
        )

    def call(self, dst: ir.Reg | None, callee: str, args: list[ir.Reg]) -> None:
        in_registers = [
            (ARGUMENT_REGS[i], self.colour(a))
            for i, a in enumerate(args[: len(ARGUMENT_REGS)])
        ]
        for i, a in enumerate(args[len(ARGUMENT_REGS) :]):
            self.access("str", self.colour(a), 31, ir.WORD * i)
        self.copies(in_registers)
        self.line(f"bl {callee}")
        if dst is not None:
            self.mov(self.colour(dst), ARGUMENT_REGS[0])


def _invert(condition: str) -> str:
    pairs = {
        "eq": "ne",
        "ne": "eq",
        "lt": "ge",
        "ge": "lt",
        "gt": "le",
        "le": "gt",
        "lo": "hs",
        "hs": "lo",
    }
    return pairs[condition]


def _takes_an_immediate(instr: ir.Instr, reg: ir.Reg, value: int) -> bool:
    """Whether this instruction can read `reg`'s constant as an immediate."""
    match instr:
        case ir.Bin(_, op, lhs, rhs) if rhs == reg and lhs != reg:
            if op in ("+", "-"):
                return 0 <= value <= 4095
            if op in ("shl", "shr"):
                return 0 <= value < 64
            return False
        case ir.Cmp(_, _, lhs, rhs) if rhs == reg and lhs != reg:
            return 0 <= value <= 4095
        case _:
            return False


def _inlineable_constants(func: ir.Func) -> tuple[dict[ir.Reg, int], set[ir.Reg]]:
    """Constants every reader can take as an immediate need never be materialised."""
    constants: dict[ir.Reg, int] = {}
    for block in func.walk():
        for instr in block.instrs:
            match instr:
                case ir.Const(dst, value):
                    constants[dst] = value
    inline = set(constants)
    for block in func.walk():
        for phi in block.phis:
            inline -= set(phi.args.values())
        for instr in block.instrs:
            for r in ir.uses(instr):
                if r in constants and not _takes_an_immediate(instr, r, constants[r]):
                    inline.discard(r)
    return constants, inline


def _read_counts(func: ir.Func) -> dict[ir.Reg, int]:
    counts: dict[ir.Reg, int] = {}
    for block in func.walk():
        for phi in block.phis:
            for arg in phi.args.values():
                counts[arg] = counts.get(arg, 0) + 1
        for instr in block.instrs:
            for r in ir.uses(instr):
                counts[r] = counts.get(r, 0) + 1
    return counts


@dataclass(frozen=True, slots=True)
class _Mov:
    dst: int
    src: int


@dataclass(frozen=True, slots=True)
class _Swap:
    a: int
    b: int


type _Step = _Mov | _Swap


def _sequentialize(
    moves: list[tuple[int, int]], borrowed: int | None
) -> list[_Step]:
    """Order a parallel copy so that no move overwrites a value still to be read.

    Moves whose destination nobody else reads can go first; when only cycles
    are left, one register has to be got out of the way.  A borrowed register
    does that in one move, and without one the two ends swap, which costs three
    `eor`s and no register at all.
    """
    real = [(dst, src) for dst, src in moves if dst != src]
    pending = dict(real)
    assert len(pending) == len(real), "a parallel copy writes a register twice"
    done: list[_Step] = []
    while pending:
        sources = set(pending.values())
        ready = [dst for dst in pending if dst not in sources]
        if ready:
            for dst in ready:
                done.append(_Mov(dst, pending.pop(dst)))
            continue
        stuck = next(iter(pending))
        if borrowed is not None:
            done.append(_Mov(borrowed, stuck))
            _reads_elsewhere_now(pending, stuck, borrowed)
            continue
        # Swapping satisfies `stuck` outright and leaves its old value where
        # the other end was, so everything still to read it reads there.
        other = pending.pop(stuck)
        done.append(_Swap(stuck, other))
        _reads_elsewhere_now(pending, stuck, other)
    return done


def _reads_elsewhere_now(pending: dict[int, int], was: int, now: int) -> None:
    """The value that was in `was` is in `now`; whoever wanted it looks there."""
    for dst, src in list(pending.items()):
        if src == was:
            if dst == now:
                del pending[dst]  # the swap already put it where it belongs
            else:
                pending[dst] = now


# -- modules ------------------------------------------------------------------


def escape(text: str) -> str:
    """One character of a literal is one byte; write the ones `.ascii` cannot."""
    out: list[str] = []
    for ch in text.encode("latin-1"):
        if ch == 0x22:
            out.append('\\"')
        elif ch == 0x5C:
            out.append("\\\\")
        elif 0x20 <= ch < 0x7F:
            out.append(chr(ch))
        else:
            out.append(f"\\{ch:03o}")
    return "".join(out)


def emit_module(mod: ir.Module) -> str:
    out: list[str] = ["\t.text"]
    for func in mod.funcs:
        out.extend(FuncEmitter(func).emit())
        out.append("")
    if mod.strings:
        out.append("\t.section .rodata")
        for symbol, text in mod.strings.items():
            out.append("\t.p2align 3")
            out.append(f"{symbol}:")
            out.append(f"\t.quad {len(text)}")
            out.append(f'\t.ascii "{escape(text)}"')
            out.append("\t.byte 0")
    out.append('\t.section .note.GNU-stack,"",%progbits')
    return "\n".join(out) + "\n"
