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

A phi that reaches here — which is the ones the dominance-order allocator
coloured, the other allocator having left SSA already — is a copy on an edge,
so the copies go at the end of the predecessor, all at once: the values are read
before any is written, which is what `_sequentialize` arranges.  When the
copies form a cycle it borrows a register the function never used, and when
there is none it swaps the two ends with three `eor`s, so no register has to be
reserved for it.
"""

from __future__ import annotations

from dataclasses import dataclass

from wolv import copies, ir, mach
from wolv.registers import ARGUMENT_REGS, CALLER_SAVED, SCRATCH

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
        self.read_somewhere = _registers_read(func)
        self.taken = set(func.colours.values())

    # -- helpers ----------------------------------------------------------

    def line(self, text: str) -> None:
        self.out.append(f"\t{text}")

    def label(self, text: str) -> None:
        self.out.append(f"{text}:")

    def colour(self, reg: ir.Reg) -> int:
        colour = self.func.colours.get(reg)
        assert colour is not None, f"%{reg} was never coloured"
        return colour

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
        for instr in block.instrs[:-1]:
            self.instruction(instr)
        self.terminator(block, nxt)

    def terminator(self, block: ir.Block, nxt: str | None) -> None:
        match block.terminator:
            case ir.Jmp(target):
                self.edge(block.label, target)
                if target != nxt:
                    self.line(f"b .L{self.func.label}_{target}")
            case ir.CBr(cond, then, els, code):
                assert not self.func.blocks[then].phis
                assert not self.func.blocks[els].phis
                then_label = f".L{self.func.label}_{then}"
                else_label = f".L{self.func.label}_{els}"
                if code:
                    if then == nxt:
                        self.line(f"b.{mach.OPPOSITE[code]} {else_label}")
                    else:
                        self.line(f"b.{code} {then_label}")
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
        for step in copies.sequentialize(moves, self.borrowed(moves)):
            match step:
                case copies.Mov(dst, src):
                    self.mov(dst, src)
                case copies.Swap(a, b):
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
            case mach.Mach():
                self.machine(instr)
            case ir.Move(dst, src):
                self.mov(self.colour(dst), self.colour(src))
            case ir.LoadSlot(dst, slot):
                self.access("ldr", self.colour(dst), 29, ir.slot_offset(slot))
            case ir.StoreSlot(slot, src):
                self.access("str", self.colour(src), 29, ir.slot_offset(slot))
            case ir.FrameAddr(dst):
                self.mov(self.colour(dst), 29)
            case ir.Call(dst, callee, args):
                self.call(dst, callee, args)
            case _:
                raise AssertionError(f"cannot emit {instr}")

    def machine(self, instr: mach.Mach) -> None:
        """Write down one selected instruction, or the sequence it stands for."""
        srcs = [self.colour(s) for s in instr.srcs]
        match instr.form:
            case "const":
                assert instr.dst is not None
                self.immediate(self.colour(instr.dst), instr.imm)
            case "adr":
                assert instr.dst is not None
                d = self.colour(instr.dst)
                self.line(f"adrp x{d}, {instr.symbol}")
                self.line(f"add x{d}, x{d}, :lo12:{instr.symbol}")
            case "ldr":
                assert instr.dst is not None
                self.access("ldr", self.colour(instr.dst), srcs[0], instr.imm)
            case "str":
                self.access("str", srcs[1], srcs[0], instr.imm)
            case _:
                names = {f"s{i}": f"x{c}" for i, c in enumerate(srcs)}
                if instr.dst is not None:
                    names["d"] = f"x{self.colour(instr.dst)}"
                self.line(
                    mach.FORMS[instr.form].format(
                        **names, imm=instr.imm, sym=instr.symbol
                    )
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


def _registers_read(func: ir.Func) -> set[ir.Reg]:
    read: set[ir.Reg] = set()
    for block in func.walk():
        for phi in block.phis:
            read.update(phi.args.values())
        for instr in block.instrs:
            read.update(instr.uses())
    return read


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
