"""An indented dump of the typed syntax tree, for `wolv emit ast`."""

from __future__ import annotations

from wolv import ast


def show_program(prog: ast.Program) -> str:
    lines: list[str] = []
    for decl in prog.decls:
        _decl(decl, 0, lines)
    return "\n".join(lines) + "\n"


def _put(lines: list[str], depth: int, text: str) -> None:
    lines.append("  " * depth + text)


def _ty(e: ast.Exp) -> str:
    return "" if e.ty is None else f" : {e.ty}"


def _decl(decl: ast.Decl, depth: int, lines: list[str]) -> None:
    match decl:
        case ast.TypeDecl(_, types):
            for t in types:
                _put(lines, depth, f"type {t.name}")
        case ast.ValDecl(_, name, _, init, mutable):
            keyword = "var" if mutable else "val"
            sym = decl.sym
            home = " (escapes)" if sym is not None and sym.escapes else ""
            _put(lines, depth, f"{keyword} {name or '()'}{home}")
            _exp(init, depth + 1, lines)
        case ast.FunDecl(_, funs):
            for f in funs:
                params = ", ".join(
                    f"{p.name}{' (escapes)' if p.sym and p.sym.escapes else ''}"
                    for p in f.params
                )
                result = f.sym.result if f.sym is not None else "?"
                _put(lines, depth, f"fun {f.name}({params}) : {result}")
                _exp(f.body, depth + 1, lines)


def _exp(e: ast.Exp, depth: int, lines: list[str]) -> None:
    match e:
        case ast.IntLit(_, value):
            _put(lines, depth, f"int {value}")
        case ast.StrLit(_, value):
            _put(lines, depth, f"string {value!r}")
        case ast.BoolLit(_, value):
            _put(lines, depth, f"bool {'true' if value else 'false'}")
        case ast.NilLit():
            _put(lines, depth, "nil")
        case ast.UnitLit():
            _put(lines, depth, "()")
        case ast.Var(_, name):
            _put(lines, depth, f"var {name}{_ty(e)}")
        case ast.Call(_, name, args):
            _put(lines, depth, f"call {name}{_ty(e)}")
            for a in args:
                _exp(a, depth + 1, lines)
        case ast.RecordLit(_, tyname, fields):
            _put(lines, depth, f"record {tyname}{_ty(e)}")
            for f in fields:
                _put(lines, depth + 1, f"{f.name} =")
                _exp(f.value, depth + 2, lines)
        case ast.Index(_, array, index):
            _put(lines, depth, f"index{_ty(e)}")
            _exp(array, depth + 1, lines)
            _exp(index, depth + 1, lines)
        case ast.Field(_, record, name):
            _put(lines, depth, f"field .{name}{_ty(e)}")
            _exp(record, depth + 1, lines)
        case ast.Neg(_, operand):
            _put(lines, depth, "neg")
            _exp(operand, depth + 1, lines)
        case ast.Bin(_, op, lhs, rhs) | ast.Logic(_, op, lhs, rhs):
            _put(lines, depth, f"{op}{_ty(e)}")
            _exp(lhs, depth + 1, lines)
            _exp(rhs, depth + 1, lines)
        case ast.Assign(_, target, value):
            _put(lines, depth, ":=")
            _exp(target, depth + 1, lines)
            _exp(value, depth + 1, lines)
        case ast.If(_, cond, then, els):
            _put(lines, depth, f"if{_ty(e)}")
            _exp(cond, depth + 1, lines)
            _exp(then, depth + 1, lines)
            if els is not None:
                _exp(els, depth + 1, lines)
        case ast.While(_, cond, body):
            _put(lines, depth, "while")
            _exp(cond, depth + 1, lines)
            _exp(body, depth + 1, lines)
        case ast.For(_, name, lo, hi, body):
            escapes = e.sym is not None and e.sym.escapes
            _put(lines, depth, f"for {name}{' (escapes)' if escapes else ''}")
            _exp(lo, depth + 1, lines)
            _exp(hi, depth + 1, lines)
            _exp(body, depth + 1, lines)
        case ast.Break():
            _put(lines, depth, "break")
        case ast.Seq(_, items):
            _put(lines, depth, f"seq{_ty(e)}")
            for item in items:
                _exp(item, depth + 1, lines)
        case ast.Let(_, decls, body):
            _put(lines, depth, f"let{_ty(e)}")
            for d in decls:
                _decl(d, depth + 1, lines)
            _put(lines, depth, "in")
            _exp(body, depth + 1, lines)
        case _:
            _put(lines, depth, "?")
