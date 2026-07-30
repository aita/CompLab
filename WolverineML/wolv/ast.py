"""The syntax tree.

The tree the parser builds is untyped; the checker fills in the `ty` and `sym`
fields as it goes, and everything after it reads them.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from wolv.diag import Span
from wolv.types import FunSym, Type, VarSym

# -- types as they are written ------------------------------------------------


@dataclass(slots=True)
class TyExp:
    span: Span


@dataclass(slots=True)
class TyName(TyExp):
    name: str


@dataclass(slots=True)
class TyArray(TyExp):
    elem: TyExp


@dataclass(slots=True)
class TyField:
    name: str
    ty: TyExp
    span: Span


@dataclass(slots=True)
class TyRecord(TyExp):
    fields: list[TyField]


# -- expressions --------------------------------------------------------------


@dataclass(slots=True)
class Exp:
    span: Span
    ty: Type | None = field(default=None, kw_only=True)


@dataclass(slots=True)
class IntLit(Exp):
    value: int


@dataclass(slots=True)
class StrLit(Exp):
    value: str


@dataclass(slots=True)
class BoolLit(Exp):
    value: bool


@dataclass(slots=True)
class NilLit(Exp):
    pass


@dataclass(slots=True)
class UnitLit(Exp):
    pass


@dataclass(slots=True)
class Var(Exp):
    name: str
    sym: VarSym | None = field(default=None, kw_only=True)


@dataclass(slots=True)
class Call(Exp):
    name: str
    args: list[Exp]
    sym: FunSym | None = field(default=None, kw_only=True)


@dataclass(slots=True)
class FieldInit:
    name: str
    value: Exp
    span: Span


@dataclass(slots=True)
class RecordLit(Exp):
    tyname: str
    fields: list[FieldInit]


@dataclass(slots=True)
class Index(Exp):
    array: Exp
    index: Exp


@dataclass(slots=True)
class Field(Exp):
    record: Exp
    name: str
    offset: int = field(default=-1, kw_only=True)


@dataclass(slots=True)
class Neg(Exp):
    operand: Exp


@dataclass(slots=True)
class Bin(Exp):
    op: str
    lhs: Exp
    rhs: Exp


@dataclass(slots=True)
class Logic(Exp):
    """`andalso` and `orelse`, which are control flow, not operators."""

    op: str
    lhs: Exp
    rhs: Exp


@dataclass(slots=True)
class Assign(Exp):
    target: Exp
    value: Exp


@dataclass(slots=True)
class If(Exp):
    cond: Exp
    then: Exp
    els: Exp | None


@dataclass(slots=True)
class While(Exp):
    cond: Exp
    body: Exp


@dataclass(slots=True)
class For(Exp):
    name: str
    lo: Exp
    hi: Exp
    body: Exp
    sym: VarSym | None = field(default=None, kw_only=True)


@dataclass(slots=True)
class Break(Exp):
    pass


@dataclass(slots=True)
class Seq(Exp):
    items: list[Exp]


@dataclass(slots=True)
class Let(Exp):
    decls: list[Decl]
    body: Exp


# -- declarations -------------------------------------------------------------


@dataclass(slots=True)
class Decl:
    span: Span


@dataclass(slots=True)
class TypeBind:
    name: str
    ty: TyExp
    span: Span


@dataclass(slots=True)
class TypeDecl(Decl):
    binds: list[TypeBind]


@dataclass(slots=True)
class ValDecl(Decl):
    name: str | None
    ty: TyExp | None
    init: Exp
    mutable: bool
    sym: VarSym | None = field(default=None, kw_only=True)


@dataclass(slots=True)
class Param:
    name: str
    ty: TyExp
    span: Span
    sym: VarSym | None = field(default=None, kw_only=True)


@dataclass(slots=True)
class FunBind:
    name: str
    params: list[Param]
    result: TyExp | None
    body: Exp
    span: Span
    sym: FunSym | None = field(default=None, kw_only=True)


@dataclass(slots=True)
class FunDecl(Decl):
    binds: list[FunBind]


@dataclass(slots=True)
class Program:
    decls: list[Decl]
