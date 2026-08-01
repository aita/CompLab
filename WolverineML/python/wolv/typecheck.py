"""The type checker, which also decides which variables escape.

Types are monomorphic and there is nothing to infer but the type of a `val`.
A `fun` without a result type is a procedure and returns `unit`, which is what
makes recursion checkable without inference: every function's signature is
known before any body is.

The pass has a second job.  A variable read from inside a function nested more
deeply than the one that binds it cannot live in a register, because the inner
function reaches it through a static link at run time.  Every lookup that
crosses a function boundary marks the variable as escaping, and the lowering
pass gives those a frame slot instead.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Final

from wolv import ast
from wolv.diag import Span, TypeCheckError
from wolv.types import (
    BOOL,
    INT,
    NIL,
    STRING,
    UNIT,
    ArrayT,
    FunSym,
    IntT,
    NilT,
    RecordT,
    StringT,
    Type,
    UnitT,
    VarSym,
    compatible,
)

BUILTIN_SIGS: Final[list[tuple[str, list[Type], Type, str]]] = [
    ("print", [STRING], UNIT, "wol_print"),
    ("println", [STRING], UNIT, "wol_println"),
    ("printInt", [INT], UNIT, "wol_print_int"),
    ("flush", [], UNIT, "wol_flush"),
    ("getChar", [], STRING, "wol_getchar"),
    ("ord", [STRING], INT, "wol_ord"),
    ("chr", [INT], STRING, "wol_chr"),
    ("size", [STRING], INT, "wol_size"),
    ("substring", [STRING, INT, INT], STRING, "wol_substring"),
    ("concat", [STRING, STRING], STRING, "wol_concat"),
    ("intToString", [INT], STRING, "wol_int_to_string"),
    ("stringToInt", [STRING], INT, "wol_string_to_int"),
    ("exit", [INT], UNIT, "wol_exit"),
]

ARITHMETIC: Final[frozenset[str]] = frozenset({"+", "-", "*", "/", "mod"})
ORDERINGS: Final[frozenset[str]] = frozenset({"<", "<=", ">", ">="})
EQUALITIES: Final[frozenset[str]] = frozenset({"=", "<>"})


@dataclass(slots=True)
class Scope:
    types: dict[str, Type]
    vals: dict[str, VarSym | FunSym]


class Checker:
    def __init__(self) -> None:
        self.scopes: list[Scope] = [self._prelude()]
        self.depth = 0
        self.loops = 0
        self.labels: dict[str, int] = {}

    def _prelude(self) -> Scope:
        types: dict[str, Type] = {
            "int": INT,
            "string": STRING,
            "bool": BOOL,
            "unit": UNIT,
        }
        vals: dict[str, VarSym | FunSym] = {}
        for name, params, result, symbol in BUILTIN_SIGS:
            vals[name] = FunSym(
                name=name,
                label=symbol,
                params=[VarSym(f"a{i}", t, False, 0) for i, t in enumerate(params)],
                result=result,
                depth=0,
                builtin=symbol,
            )
        for name in ("array", "length", "not"):
            vals[name] = FunSym(name, name, [], UNIT, 0, builtin=name)
        return Scope(types, vals)

    # -- scopes -----------------------------------------------------------

    def push(self) -> None:
        self.scopes.append(Scope({}, {}))

    def pop(self) -> None:
        self.scopes.pop()

    def bind_val(self, name: str, sym: VarSym | FunSym) -> None:
        self.scopes[-1].vals[name] = sym

    def bind_type(self, name: str, ty: Type) -> None:
        self.scopes[-1].types[name] = ty

    def lookup_val(self, name: str, span: Span) -> VarSym | FunSym:
        for scope in reversed(self.scopes):
            sym = scope.vals.get(name)
            if sym is not None:
                return sym
        raise TypeCheckError(span, f"`{name}` is not bound")

    def lookup_type(self, name: str, span: Span) -> Type:
        for scope in reversed(self.scopes):
            ty = scope.types.get(name)
            if ty is not None:
                return ty
        raise TypeCheckError(span, f"`{name}` is not a type")

    def unique_label(self, name: str) -> str:
        n = self.labels.get(name, 0)
        self.labels[name] = n + 1
        return f"wol_{name}" if n == 0 else f"wol_{name}.{n}"

    # -- programs ---------------------------------------------------------

    def program(self, prog: ast.Program) -> None:
        self.push()
        self.decls(prog.decls)
        self.pop()

    def decls(self, decls: list[ast.Decl]) -> None:
        i = 0
        while i < len(decls):
            decl = decls[i]
            match decl:
                case ast.TypeDecl():
                    self.type_decl(decl)
                case ast.ValDecl():
                    self.val_decl(decl)
                case ast.FunDecl():
                    self.fun_decl(decl)
                case _:
                    raise TypeCheckError(decl.span, "unknown declaration")
            i += 1

    def type_decl(self, decl: ast.TypeDecl) -> None:
        records: list[tuple[RecordT, ast.TyRecord]] = []
        for bind in decl.binds:
            if isinstance(bind.ty, ast.TyRecord):
                rec = RecordT(bind.name)
                self.bind_type(bind.name, rec)
                records.append((rec, bind.ty))
        for bind in decl.binds:
            if not isinstance(bind.ty, ast.TyRecord):
                self.bind_type(bind.name, self.resolve(bind.ty))
        for rec, syntax in records:
            seen: set[str] = set()
            for f in syntax.fields:
                if f.name in seen:
                    raise TypeCheckError(f.span, f"duplicate field `{f.name}`")
                seen.add(f.name)
                rec.fields.append((f.name, self.resolve(f.ty)))

    def resolve(self, ty: ast.TyExp) -> Type:
        match ty:
            case ast.TyName():
                return self.lookup_type(ty.name, ty.span)
            case ast.TyArray():
                return ArrayT(self.resolve(ty.elem))
            case ast.TyRecord():
                raise TypeCheckError(
                    ty.span, "a record type has to be given a name by `type`"
                )
            case _:
                raise TypeCheckError(ty.span, "unknown type")

    def val_decl(self, decl: ast.ValDecl) -> None:
        got = self.exp(decl.init)
        want = self.resolve(decl.ty) if decl.ty is not None else None
        if want is not None:
            self.unify(want, got, decl.init.span, "in this binding")
            got = want
        if decl.name is None:
            self.unify(UNIT, got, decl.init.span, "in `val () =`")
            return
        if isinstance(got, NilT):
            raise TypeCheckError(
                decl.span, f"`{decl.name}` needs a type annotation to hold `nil`"
            )
        sym = VarSym(decl.name, got, decl.mutable, self.depth)
        decl.sym = sym
        self.bind_val(decl.name, sym)

    def fun_decl(self, decl: ast.FunDecl) -> None:
        for bind in decl.binds:
            params: list[VarSym] = []
            seen: set[str] = set()
            for p in bind.params:
                if p.name in seen:
                    raise TypeCheckError(p.span, f"duplicate parameter `{p.name}`")
                seen.add(p.name)
                sym = VarSym(p.name, self.resolve(p.ty), False, self.depth + 1)
                p.sym = sym
                params.append(sym)
            result = self.resolve(bind.result) if bind.result is not None else UNIT
            fsym = FunSym(
                name=bind.name,
                label=self.unique_label(bind.name),
                params=params,
                result=result,
                depth=self.depth + 1,
            )
            bind.sym = fsym
            self.bind_val(bind.name, fsym)
        for bind in decl.binds:
            signature = bind.sym
            assert signature is not None
            self.depth += 1
            loops, self.loops = self.loops, 0
            self.push()
            for p in bind.params:
                assert p.sym is not None
                self.bind_val(p.name, p.sym)
            got = self.exp(bind.body)
            self.unify(
                signature.result,
                got,
                bind.body.span,
                f"in the body of `{bind.name}`",
            )
            self.pop()
            self.loops = loops
            self.depth -= 1

    # -- expressions ------------------------------------------------------

    def unify(self, want: Type, got: Type, span: Span, where: str) -> None:
        if not compatible(want, got):
            raise TypeCheckError(span, f"expected `{want}`, found `{got}` {where}")

    def exp(self, e: ast.Exp) -> Type:
        ty = self._exp(e)
        e.ty = ty
        return ty

    def _exp(self, e: ast.Exp) -> Type:
        match e:
            case ast.IntLit():
                return INT
            case ast.StrLit():
                return STRING
            case ast.BoolLit():
                return BOOL
            case ast.NilLit():
                return NIL
            case ast.UnitLit():
                return UNIT
            case ast.Var():
                return self.var(e)
            case ast.Call():
                return self.call(e)
            case ast.RecordLit():
                return self.record_lit(e)
            case ast.Index():
                return self.index(e)
            case ast.Field():
                return self.field(e)
            case ast.Neg():
                self.unify(INT, self.exp(e.operand), e.span, "in a negation")
                return INT
            case ast.Bin():
                return self.binop(e)
            case ast.Logic():
                self.unify(BOOL, self.exp(e.lhs), e.lhs.span, f"on the left of `{e.op}`")
                self.unify(
                    BOOL, self.exp(e.rhs), e.rhs.span, f"on the right of `{e.op}`"
                )
                return BOOL
            case ast.Assign():
                return self.assign(e)
            case ast.If():
                return self.if_exp(e)
            case ast.While():
                self.unify(BOOL, self.exp(e.cond), e.cond.span, "as a `while` condition")
                self.loops += 1
                self.unify(UNIT, self.exp(e.body), e.body.span, "in a `while` body")
                self.loops -= 1
                return UNIT
            case ast.For():
                return self.for_exp(e)
            case ast.Break():
                if self.loops == 0:
                    raise TypeCheckError(e.span, "`break` is outside any loop")
                return UNIT
            case ast.Seq():
                ty: Type = UNIT
                for item in e.items:
                    ty = self.exp(item)
                return ty
            case ast.Let():
                self.push()
                self.decls(e.decls)
                ty = self.exp(e.body)
                self.pop()
                return ty
            case _:
                raise TypeCheckError(e.span, "unknown expression")

    def var(self, e: ast.Var) -> Type:
        sym = self.lookup_val(e.name, e.span)
        if isinstance(sym, FunSym):
            raise TypeCheckError(
                e.span, f"`{e.name}` is a function, and functions are not values"
            )
        if sym.depth < self.depth:
            sym.escapes = True
        e.sym = sym
        return sym.ty

    def call(self, e: ast.Call) -> Type:
        sym = self.lookup_val(e.name, e.span)
        if isinstance(sym, VarSym):
            raise TypeCheckError(e.span, f"`{e.name}` is a variable, not a function")
        e.sym = sym
        match sym.builtin:
            case "array":
                return self.array_call(e)
            case "length":
                return self.length_call(e)
            case "not":
                self.arity(e, 1)
                self.unify(BOOL, self.exp(e.args[0]), e.span, "in a call to `not`")
                return BOOL
        self.arity(e, len(sym.params))
        for arg, param in zip(e.args, sym.params, strict=True):
            self.unify(
                param.ty, self.exp(arg), arg.span, f"in a call to `{e.name}`"
            )
        return sym.result

    def arity(self, e: ast.Call, want: int) -> None:
        if len(e.args) != want:
            plural = "" if want == 1 else "s"
            raise TypeCheckError(
                e.span,
                f"`{e.name}` takes {want} argument{plural}, given {len(e.args)}",
            )

    def array_call(self, e: ast.Call) -> Type:
        self.arity(e, 2)
        self.unify(INT, self.exp(e.args[0]), e.args[0].span, "as an array length")
        elem = self.exp(e.args[1])
        if isinstance(elem, NilT):
            raise TypeCheckError(
                e.args[1].span, "`array` cannot tell which record `nil` stands for"
            )
        return ArrayT(elem)

    def length_call(self, e: ast.Call) -> Type:
        self.arity(e, 1)
        arg = self.exp(e.args[0])
        if not isinstance(arg, ArrayT):
            raise TypeCheckError(
                e.args[0].span, f"`length` wants an array, found `{arg}`"
            )
        return INT

    def record_lit(self, e: ast.RecordLit) -> Type:
        rec = self.lookup_type(e.tyname, e.span)
        if not isinstance(rec, RecordT):
            raise TypeCheckError(e.span, f"`{e.tyname}` is not a record type")
        given: dict[str, ast.FieldInit] = {}
        for f in e.fields:
            if f.name in given:
                raise TypeCheckError(f.span, f"field `{f.name}` is given twice")
            if rec.index(f.name) < 0:
                raise TypeCheckError(f.span, f"`{rec.name}` has no field `{f.name}`")
            given[f.name] = f
        ordered: list[ast.FieldInit] = []
        for name, ty in rec.fields:
            init = given.get(name)
            if init is None:
                raise TypeCheckError(e.span, f"field `{name}` is missing")
            self.unify(ty, self.exp(init.value), init.span, f"in field `{name}`")
            ordered.append(init)
        e.fields = ordered
        return rec

    def index(self, e: ast.Index) -> Type:
        arr = self.exp(e.array)
        if not isinstance(arr, ArrayT):
            raise TypeCheckError(e.span, f"`{arr}` is not an array")
        self.unify(INT, self.exp(e.index), e.index.span, "as an array index")
        return arr.elem

    def field(self, e: ast.Field) -> Type:
        rec = self.exp(e.record)
        if not isinstance(rec, RecordT):
            raise TypeCheckError(e.span, f"`{rec}` is not a record")
        ty = rec.field_type(e.name)
        if ty is None:
            raise TypeCheckError(e.span, f"`{rec.name}` has no field `{e.name}`")
        e.offset = rec.index(e.name)
        return ty

    def binop(self, e: ast.Bin) -> Type:
        lhs = self.exp(e.lhs)
        rhs = self.exp(e.rhs)
        if e.op in ARITHMETIC:
            self.unify(INT, lhs, e.lhs.span, f"on the left of `{e.op}`")
            self.unify(INT, rhs, e.rhs.span, f"on the right of `{e.op}`")
            return INT
        if e.op == "^":
            self.unify(STRING, lhs, e.lhs.span, "on the left of `^`")
            self.unify(STRING, rhs, e.rhs.span, "on the right of `^`")
            return STRING
        if e.op in ORDERINGS:
            match lhs:
                case IntT() | StringT():
                    self.unify(lhs, rhs, e.rhs.span, f"on the right of `{e.op}`")
                    return BOOL
                case _:
                    raise TypeCheckError(
                        e.span, f"`{e.op}` compares int or string, not `{lhs}`"
                    )
        if e.op in EQUALITIES:
            if isinstance(lhs, UnitT) or isinstance(rhs, UnitT):
                raise TypeCheckError(e.span, f"`{e.op}` cannot compare `unit`")
            if not compatible(lhs, rhs):
                raise TypeCheckError(
                    e.span, f"`{e.op}` compares `{lhs}` with `{rhs}`"
                )
            return BOOL
        raise TypeCheckError(e.span, f"unknown operator `{e.op}`")

    def assign(self, e: ast.Assign) -> Type:
        target = self.exp(e.target)
        match e.target:
            case ast.Var(sym=sym) if sym is not None and not sym.mutable:
                raise TypeCheckError(
                    e.span, f"`{sym.name}` is a `val`, so it cannot be assigned"
                )
            case _:
                pass
        self.unify(target, self.exp(e.value), e.value.span, "in an assignment")
        return UNIT

    def if_exp(self, e: ast.If) -> Type:
        self.unify(BOOL, self.exp(e.cond), e.cond.span, "as an `if` condition")
        then = self.exp(e.then)
        if e.els is None:
            self.unify(UNIT, then, e.then.span, "in an `if` with no `else`")
            return UNIT
        els = self.exp(e.els)
        if not compatible(then, els):
            raise TypeCheckError(
                e.span, f"the branches differ: `{then}` and `{els}`"
            )
        return els if isinstance(then, NilT) else then

    def for_exp(self, e: ast.For) -> Type:
        self.unify(INT, self.exp(e.lo), e.lo.span, "as a `for` bound")
        self.unify(INT, self.exp(e.hi), e.hi.span, "as a `for` bound")
        sym = VarSym(e.name, INT, False, self.depth)
        e.sym = sym
        self.push()
        self.bind_val(e.name, sym)
        self.loops += 1
        self.unify(UNIT, self.exp(e.body), e.body.span, "in a `for` body")
        self.loops -= 1
        self.pop()
        return UNIT


def check(prog: ast.Program) -> None:
    """Type the program in place: every node comes back with its `ty` filled in."""
    Checker().program(prog)
