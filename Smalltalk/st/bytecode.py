"""Bytecode instruction set and compiled-code containers.

The VM is a simple stack machine. Each :class:`CompiledMethod` / block carries
a flat list of :class:`Instr` (opcode + optional argument), a literal pool, and
the names of the locals that live in its activation frame.

Control flow (``ifTrue:``/``whileTrue:``/``and:``/``or:`` with literal-block
arguments) is compiled inline into jumps; everything else is a real message
send, so blocks used elsewhere become genuine closures invoked via ``value``.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum, auto
from typing import Any


class Op(IntEnum):
    PUSH_LITERAL = auto()  # arg: index into literals
    PUSH_SELF = auto()
    PUSH_NIL = auto()
    PUSH_TRUE = auto()
    PUSH_FALSE = auto()
    PUSH_CONTEXT = auto()  # push the current activation (thisContext)
    PUSH_VAR = auto()  # arg: variable name (str)
    STORE_VAR = auto()  # arg: variable name; peeks TOS (assignment is an expr)
    POP = auto()
    DUP = auto()
    SEND = auto()  # arg: (selector, argc)
    SEND_SUPER = auto()  # arg: (selector, argc)
    PUSH_BLOCK = auto()  # arg: index into literals holding a CompiledBlock
    MAKE_ARRAY = auto()  # arg: count; pops that many, pushes an Array (list)
    JUMP = auto()  # arg: absolute instruction index
    JUMP_TRUE = auto()  # pops TOS; jumps if true (else must be false)
    JUMP_FALSE = auto()  # pops TOS; jumps if false (else must be true)
    RETURN = auto()  # method return (^expr); non-local from within a block
    BLOCK_RETURN = auto()  # normal end of a block: return TOS to its caller


@dataclass
class Instr:
    op: Op
    arg: Any = None

    def __repr__(self) -> str:
        if self.arg is None:
            return self.op.name
        return f"{self.op.name} {self.arg!r}"


@dataclass
class CompiledBlock:
    """A block ``[:a | ...]`` compiled to its own code with its own locals."""

    params: list[str]
    local_names: list[str]  # params + temps, seeded into the block frame
    code: list[Instr] = field(default_factory=list)
    literals: list[Any] = field(default_factory=list)

    @property
    def num_args(self) -> int:
        return len(self.params)


@dataclass
class CompiledMethod:
    """A method compiled to bytecode."""

    selector: str
    params: list[str]
    local_names: list[str]  # params + temps living in the method frame
    code: list[Instr] = field(default_factory=list)
    literals: list[Any] = field(default_factory=list)
    source: str = ""
    defined_in: Any = None  # STClass the method is installed in (for super)

    @property
    def num_args(self) -> int:
        return len(self.params)

    def __repr__(self) -> str:
        return f"<compiled {self.selector}>"


def disassemble(cm: CompiledMethod | CompiledBlock) -> str:
    """Human-readable listing, used by the IDE and tests."""
    lines: list[str] = []
    for i, ins in enumerate(cm.code):
        arg = ""
        if ins.op in (Op.PUSH_LITERAL, Op.PUSH_BLOCK) and isinstance(ins.arg, int):
            lit = cm.literals[ins.arg]
            arg = f"{ins.arg} ({lit!r})"
        elif ins.arg is not None:
            arg = repr(ins.arg)
        lines.append(f"{i:3d}  {ins.op.name:<12} {arg}")
    return "\n".join(lines)
