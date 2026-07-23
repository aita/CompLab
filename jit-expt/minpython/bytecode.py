"""Bytecode for the MinPython register VM.

A register machine (Lua-style), not a stack machine: every instruction names
the registers it reads and writes, so `x = a + b` is one instruction
`ADD dst, a, b` rather than load/load/add/store. Two reasons, both about the
tracing JIT this feeds:

  * A recorded trace of register ops maps almost one-to-one onto the x86-64
    integer instructions in this repo's `jit.Assembler` -- `ADD r0, r1, r2`
    is `mov/add` on three machine registers, no stack shuffling to see through.
  * Traces come out shorter (no push/pop noise), so there is less to compile.

Each function compiles to a `CodeObject`: a flat register file (locals in the
low registers, temporaries above them), a constant pool, a pool of global names
it refers to, and the instruction array. Instructions are 4-tuples
`(op, a, b, c)`; unused operands are 0. That shape is deliberately C-friendly --
the plan is to Cythonise the VM's dispatch loop later, at which point these
become rows of a typed int array with no reshaping.

This module is pure data + a disassembler; execution lives in `vm.py` and
generation in `compile.py`.
"""

from __future__ import annotations

import ast
import enum
import operator
from typing import Any, Callable, NamedTuple

# A MinPython runtime value: int/bool (the JIT-able numeric core), plus str,
# list, and None. The JITs specialise on int and stay away from the object types
# (str/list ops are interpreted; a trace guards int-ness and deopts otherwise).
Value = int | bool | str | list | None


class MinPythonError(Exception):
    """A program-level error: an unsupported construct, an unbound name, a call
    to something that is not a function, etc. Distinct from a bug in the VM
    itself, which is an ordinary Python exception."""


class Op(enum.IntEnum):
    """The opcodes. Operand meaning is per-op; see `_FORMAT` for the layout and
    the disassembler for the human-readable rendering.

    Arithmetic/compare ops are one opcode *per operator* (ADD, SUB, ... rather
    than a single BINARY_OP with an operator operand). That keeps the operand
    slots as pure register indices and turns the VM's dispatch into a flat
    switch on the opcode -- the form a C compiler, and later Cython, turns into
    a jump table."""

    # value movement:  dst <- ...
    LOAD_CONST = 1      # a=dst, b=const-pool index
    LOAD_GLOBAL = 2     # a=dst, b=name-pool index
    STORE_GLOBAL = 3    # a=name-pool index, b=src
    MOVE = 4            # a=dst, b=src
    MAKE_FUNCTION = 5   # a=dst, b=const index holding the child CodeObject

    # binary arithmetic:  dst <- b <op> c
    ADD = 10
    SUB = 11
    MUL = 12
    FLOORDIV = 13
    MOD = 14
    POW = 15
    BIT_AND = 16
    BIT_OR = 17
    BIT_XOR = 18
    LSHIFT = 19
    RSHIFT = 20

    # unary:  dst <- <op> b
    NEG = 30
    POS = 31
    INVERT = 32
    NOT = 33

    # comparison:  dst <- (b <cmp> c)  -> bool
    EQ = 40
    NE = 41
    LT = 42
    LE = 43
    GT = 44
    GE = 45

    # control flow
    JUMP = 50               # a=target pc
    JUMP_IF_FALSE = 51      # a=cond reg, b=target pc
    JUMP_IF_TRUE = 52       # a=cond reg, b=target pc

    # calls / builtins
    CALL = 60           # a=dst, b=func reg, c=argc  (args in func+1 .. func+argc)
    RETURN = 61         # a=src
    PRINT = 62          # a=arg base, b=argc

    # object types (str / list) -- always interpreted, never JIT-compiled
    MAKE_LIST = 63     # a=dst, b=base, c=count  (regs[a] = regs[b .. b+count])
    SUBSCR = 64         # a=dst, b=obj, c=idx     (regs[a] = regs[b][regs[c]])
    LEN = 65            # a=dst, b=src            (regs[a] = len(regs[b]))


class Instr(NamedTuple):
    """One instruction: an opcode and up to three operands (0 when unused)."""
    op: Op
    a: int = 0
    b: int = 0
    c: int = 0


class CodeObject:
    """A compiled function (or the module top level, name '<module>').

    Registers 0..n_params-1 hold the parameters on entry; 0..n_locals-1 are the
    named locals; n_locals..n_regs-1 are scratch temporaries. `consts` and
    `names` are the pools indexed by LOAD_CONST / LOAD_GLOBAL etc."""

    __slots__ = ("name", "params", "n_locals", "n_regs", "consts", "names",
                 "code", "local_names", "_cy_cache")

    def __init__(self, name: str, params: list[str], n_locals: int,
                 n_regs: int, consts: list[Value | CodeObject],
                 names: list[str], code: list[Instr], local_names: list[str]):
        self.name = name
        self.params = params
        self.n_locals = n_locals
        self.n_regs = n_regs
        self.consts = consts
        self.names = names
        self.code = code
        self.local_names = local_names
        self._cy_cache = None   # populated by the optional Cython dispatcher

    def __repr__(self) -> str:
        return (f"<CodeObject {self.name}({', '.join(self.params)}) "
                f"{len(self.code)} insns, {self.n_regs} regs>")


# --- operator tables the VM executes ---------------------------------------

BIN_FN: dict[Op, Callable[[Any, Any], Any]] = {
    Op.ADD: operator.add, Op.SUB: operator.sub, Op.MUL: operator.mul,
    Op.FLOORDIV: operator.floordiv, Op.MOD: operator.mod, Op.POW: operator.pow,
    Op.BIT_AND: operator.and_, Op.BIT_OR: operator.or_, Op.BIT_XOR: operator.xor,
    Op.LSHIFT: operator.lshift, Op.RSHIFT: operator.rshift,
}

UNARY_FN: dict[Op, Callable[[Any], Any]] = {
    Op.NEG: operator.neg, Op.POS: operator.pos,
    Op.INVERT: operator.invert, Op.NOT: operator.not_,
}

CMP_FN: dict[Op, Callable[[Any, Any], Any]] = {
    Op.EQ: operator.eq, Op.NE: operator.ne, Op.LT: operator.lt,
    Op.LE: operator.le, Op.GT: operator.gt, Op.GE: operator.ge,
}

# --- AST operator -> opcode (used by the compiler) --------------------------

AST_BINOP: dict[type[ast.operator], Op] = {
    ast.Add: Op.ADD, ast.Sub: Op.SUB, ast.Mult: Op.MUL,
    ast.FloorDiv: Op.FLOORDIV, ast.Mod: Op.MOD, ast.Pow: Op.POW,
    ast.BitAnd: Op.BIT_AND, ast.BitOr: Op.BIT_OR, ast.BitXor: Op.BIT_XOR,
    ast.LShift: Op.LSHIFT, ast.RShift: Op.RSHIFT,
}

AST_UNARY: dict[type[ast.unaryop], Op] = {
    ast.UAdd: Op.POS, ast.USub: Op.NEG, ast.Invert: Op.INVERT, ast.Not: Op.NOT,
}

AST_CMP: dict[type[ast.cmpop], Op] = {
    ast.Eq: Op.EQ, ast.NotEq: Op.NE, ast.Lt: Op.LT,
    ast.LtE: Op.LE, ast.Gt: Op.GT, ast.GtE: Op.GE,
}


# --- disassembly ------------------------------------------------------------
#
# How each opcode's operands are rendered. 'r'=register, 'k'=const index,
# 'n'=name index, 'L'=jump target (code offset). Purely for humans / debugging /
# the --dis CLI flag; the VM never looks at this.

_FORMAT: dict[Op, str] = {
    Op.LOAD_CONST: "rk", Op.LOAD_GLOBAL: "rn", Op.STORE_GLOBAL: "nr",
    Op.MOVE: "rr", Op.MAKE_FUNCTION: "rk",
    Op.JUMP: "L", Op.JUMP_IF_FALSE: "rL", Op.JUMP_IF_TRUE: "rL",
    Op.CALL: "rri", Op.RETURN: "r", Op.PRINT: "ri",
    Op.MAKE_LIST: "rri", Op.SUBSCR: "rrr", Op.LEN: "rr",
}
# every arithmetic/compare op is dst, lhs, rhs
_FORMAT |= {op: "rrr" for op in BIN_FN}
_FORMAT |= {op: "rrr" for op in CMP_FN}
_FORMAT |= {op: "rr" for op in UNARY_FN}  # dst, src


def disassemble(code: CodeObject, *, recurse: bool = True) -> str:
    """Render a CodeObject as human-readable assembly text. With `recurse`
    (the default), nested function CodeObjects are appended after it."""
    lines = [f"{code.name}({', '.join(code.params)})  "
             f"[{code.n_locals} locals, {code.n_regs} regs]"]
    nested: list[CodeObject] = []
    for pc, ins in enumerate(code.code):
        fmt = _FORMAT.get(ins.op, "rrr")
        parts = []
        for spec, val in zip(fmt, (ins.a, ins.b, ins.c)):
            match spec:
                case "r":
                    name = (code.local_names[val]
                            if val < len(code.local_names) else None)
                    parts.append(f"r{val}({name})" if name else f"r{val}")
                case "k":
                    k = code.consts[val]
                    parts.append(f"<code {k.name}>" if isinstance(k, CodeObject)
                                 else f"={k!r}")
                    if isinstance(k, CodeObject):
                        nested.append(k)
                case "n":
                    parts.append(f"g:{code.names[val]}")
                case "L":
                    parts.append(f"->{val}")
                case "i":
                    parts.append(str(val))
        lines.append(f"  {pc:>4}  {ins.op.name:<14} {', '.join(parts)}")
    text = "\n".join(lines)
    if recurse:
        for child in nested:
            text += "\n\n" + disassemble(child, recurse=True)
    return text
