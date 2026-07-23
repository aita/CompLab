"""AST -> bytecode compiler for MinPython.

Lowers the MinPython subset to `CodeObject`s for the register VM: each AST node
emits instructions that compute its value at run time, and the compiler hands
out registers to hold intermediate results.

Register allocation is deliberately simple. A function's named locals
(parameters plus every name it assigns, minus `global` declarations) get stable
low registers 0..n_locals-1. Everything above that is a temporary stack: an
expression pushes its result onto the next free temp and operators pop their
operands, so `n_regs` is just the high-water mark. No liveness analysis, no
reuse beyond the stack discipline -- correctness first; the trace compiler is
where cleverness will pay off.

Public API:
    compile_module(source) -> CodeObject     # the '<module>' top level
"""

from __future__ import annotations

import ast

from .bytecode import (AST_BINOP, AST_CMP, AST_UNARY, CodeObject, Instr,
                       MinPythonError, Op, Value)


class _Label:
    """A jump target, resolved to a code offset in a fixup pass once the
    instruction it points at has been emitted."""
    __slots__ = ("pos",)

    def __init__(self) -> None:
        self.pos = -1


def _assigned_names(body: list[ast.stmt]) -> list[str]:
    """Names a function binds -> its locals. Walks the body but not into nested
    function bodies (which introduce their own scope). Order is first-appearance
    so register numbers are stable and readable."""
    found: list[str] = []
    seen: set[str] = set()

    def add(name: str) -> None:
        if name not in seen:
            seen.add(name)
            found.append(name)

    def visit(node: ast.AST) -> None:
        match node:
            case ast.FunctionDef():
                add(node.name)  # the def binds its own name, but don't recurse
                return
            case ast.Name(ctx=ast.Store(), id=name):
                add(name)
            case ast.AugAssign(target=ast.Name(id=name)):
                add(name)
            case ast.AnnAssign(target=ast.Name(id=name)):
                add(name)
        for child in ast.iter_child_nodes(node):
            visit(child)

    for stmt in body:
        visit(stmt)
    return found


class _Compiler:
    """Compiles one code unit (a function body, or the module top level).

    `is_module`: at module level there are no locals -- every name is a global,
    so loads/stores go through the globals pool rather than registers."""

    def __init__(self, name: str, params: list[str], body: list[ast.stmt],
                 *, is_module: bool):
        self.name = name
        self.params = params
        self.body = body
        self.is_module = is_module

        self.declared_global: set[str] = set()
        for stmt in body:  # a top-level `global` in this unit
            if isinstance(stmt, ast.Global):
                self.declared_global.update(stmt.names)

        if is_module:
            self.locals: list[str] = []
        else:
            names = list(params)
            for n in _assigned_names(body):
                if n not in names and n not in self.declared_global:
                    names.append(n)
            self.locals = names
        self.local_index = {n: i for i, n in enumerate(self.locals)}

        self.consts: list[Value | CodeObject] = []
        self.names: list[str] = []          # global-name pool
        self.code: list[Instr] = []
        self.fixups: list[tuple[int, str, _Label]] = []  # (pc, field, label)

        self.n_locals = len(self.locals)
        self.top = self.n_locals            # next free temp register
        self.n_regs = self.n_locals
        self.loops: list[tuple[_Label, _Label]] = []  # (continue, break) targets

    # -- register / pool helpers --------------------------------------------

    def _push(self) -> int:
        r = self.top
        self.top += 1
        self.n_regs = max(self.n_regs, self.top)
        return r

    def _const(self, value: Value | CodeObject) -> int:
        # dedup by identity+equality for scalars; CodeObjects are always fresh
        for i, existing in enumerate(self.consts):
            if type(existing) is type(value) and existing == value \
                    and not isinstance(existing, CodeObject):
                return i
        self.consts.append(value)
        return len(self.consts) - 1

    def _name(self, name: str) -> int:
        if name in self.names:
            return self.names.index(name)
        self.names.append(name)
        return len(self.names) - 1

    # -- emission -----------------------------------------------------------

    def _emit(self, op: Op, a: int = 0, b: int = 0, c: int = 0) -> int:
        self.code.append(Instr(op, a, b, c))
        return len(self.code) - 1

    def _emit_jump(self, op: Op, target: _Label, cond: int = 0) -> None:
        # JUMP stores the target in operand a; conditional jumps in operand b.
        pc = self._emit(op, cond, 0) if op != Op.JUMP else self._emit(op, 0)
        field = "a" if op == Op.JUMP else "b"
        self.fixups.append((pc, field, target))

    def _label(self) -> _Label:
        return _Label()

    def _bind(self, label: _Label) -> None:
        label.pos = len(self.code)

    def _resolve(self) -> None:
        for pc, field, label in self.fixups:
            if label.pos < 0:
                raise MinPythonError("internal: unbound jump label")
            ins = self.code[pc]
            self.code[pc] = ins._replace(**{field: label.pos})

    # -- name access --------------------------------------------------------

    def _is_local(self, name: str) -> bool:
        return name in self.local_index and name not in self.declared_global

    def _load_name(self, name: str, into: int | None = None) -> int:
        """Return a register holding `name`. Locals are already in a register
        (returned directly unless `into` forces a copy); globals are loaded."""
        if self._is_local(name):
            reg = self.local_index[name]
            if into is not None and into != reg:
                self._emit(Op.MOVE, into, reg)
                return into
            return reg
        dst = into if into is not None else self._push()
        self._emit(Op.LOAD_GLOBAL, dst, self._name(name))
        return dst

    def _store_name(self, name: str, src: int) -> None:
        if self._is_local(name):
            dst = self.local_index[name]
            if dst != src:
                self._emit(Op.MOVE, dst, src)
        else:
            self._emit(Op.STORE_GLOBAL, self._name(name), src)

    # -- expressions --------------------------------------------------------

    def _expr(self, node: ast.expr) -> int:
        """Compile `node`; return the register holding its value."""
        match node:
            case ast.Constant(value=value):
                _check_literal(value)
                dst = self._push()
                self._emit(Op.LOAD_CONST, dst, self._const(value))
                return dst

            case ast.Name(id=name):
                return self._load_name(name)

            case ast.List(elts=elts):
                # [e0, e1, ...] -> build a list from a contiguous reg window
                base = self.top
                for elt in elts:
                    self._into(elt, self._push())
                self.top = base
                dst = self._push()
                self._emit(Op.MAKE_LIST, dst, base, len(elts))
                return dst

            case ast.Subscript(value=value, slice=index, ctx=ast.Load()):
                if isinstance(index, ast.Slice):
                    raise MinPythonError("slices are not supported")
                mark = self.top
                obj = self._expr(value)
                idx = self._expr(index)
                self.top = mark
                dst = self._push()
                self._emit(Op.SUBSCR, dst, obj, idx)
                return dst

            case ast.BinOp(left=left, op=op, right=right):
                opcode = AST_BINOP.get(type(op))
                if opcode is None:
                    if isinstance(op, ast.Div):
                        raise MinPythonError(
                            "'/' is not supported (it yields a float); use '//'")
                    raise MinPythonError(
                        f"unsupported binary operator: {type(op).__name__}")
                mark = self.top
                lhs = self._expr(left)
                rhs = self._expr(right)
                self.top = mark
                dst = self._push()
                self._emit(opcode, dst, lhs, rhs)
                return dst

            case ast.UnaryOp(op=op, operand=operand):
                opcode = AST_UNARY.get(type(op))
                if opcode is None:
                    raise MinPythonError(
                        f"unsupported unary operator: {type(op).__name__}")
                mark = self.top
                src = self._expr(operand)
                self.top = mark
                dst = self._push()
                self._emit(opcode, dst, src)
                return dst

            case ast.BoolOp():
                return self._boolop(node)

            case ast.Compare():
                return self._compare(node)

            case ast.IfExp(test=test, body=body, orelse=orelse):
                dst = self._push()
                self._into(body, dst, guard=test, orelse=orelse)
                return dst

            case ast.Call():
                return self._call(node)

            case _:
                raise MinPythonError(
                    f"unsupported expression: {type(node).__name__}")

    def _into(self, node: ast.expr, dst: int, *,
              guard: ast.expr | None = None,
              orelse: ast.expr | None = None) -> None:
        """Compile so the result lands in register `dst` (already reserved).

        With `guard`/`orelse` set this compiles a conditional expression
        `node if guard else orelse` into dst."""
        if guard is not None:
            assert orelse is not None
            end = self._label()
            other = self._label()
            self._branch_if_false(guard, other)
            self._into(node, dst)
            self._emit_jump(Op.JUMP, end)
            self._bind(other)
            self._into(orelse, dst)
            self._bind(end)
            return
        mark = self.top
        r = self._expr(node)
        self.top = mark
        if r != dst:
            self._emit(Op.MOVE, dst, r)

    def _boolop(self, node: ast.BoolOp) -> int:
        # Short-circuit; the result is the last operand evaluated, kept in one
        # register. `and` bails on the first falsy operand, `or` on the first
        # truthy one.
        short = Op.JUMP_IF_FALSE if isinstance(node.op, ast.And) \
            else Op.JUMP_IF_TRUE
        dst = self._push()
        end = self._label()
        for i, value in enumerate(node.values):
            self._into(value, dst)
            if i != len(node.values) - 1:
                self._emit_jump(short, end, cond=dst)
        self._bind(end)
        return dst

    def _compare(self, node: ast.Compare) -> int:
        # Chained: a < b < c evaluates each operand once and short-circuits to
        # a False result on the first failing link.
        dst = self._push()
        mark = self.top  # temps for the operands live above dst
        end = self._label()
        cur = self._expr(node.left)
        for i, (op, comp) in enumerate(zip(node.ops, node.comparators)):
            opcode = AST_CMP.get(type(op))
            if opcode is None:
                raise MinPythonError(
                    f"unsupported comparison: {type(op).__name__}")
            nxt = self._expr(comp)
            self._emit(opcode, dst, cur, nxt)  # dst = cur <cmp> nxt
            if i != len(node.ops) - 1:
                self._emit_jump(Op.JUMP_IF_FALSE, end, cond=dst)
            cur = nxt
        self.top = mark  # dst stays reserved (it is below mark)
        self._bind(end)
        return dst

    def _branch_if_false(self, test: ast.expr, target: _Label) -> None:
        mark = self.top
        cond = self._expr(test)
        self.top = mark
        self._emit_jump(Op.JUMP_IF_FALSE, target, cond=cond)

    def _call(self, node: ast.Call) -> int:
        if node.keywords:
            raise MinPythonError("keyword arguments are not supported")
        if not isinstance(node.func, ast.Name):
            raise MinPythonError("only calls to named functions are supported")
        name = node.func.id

        if name == "print":
            base = self.top
            for arg in node.args:
                areg = self._push()
                self._into(arg, areg)
            self.top = base
            self._emit(Op.PRINT, base, len(node.args))
            dst = self._push()
            self._emit(Op.LOAD_CONST, dst, self._const(None))  # print -> None
            return dst

        if name == "len":
            if len(node.args) != 1:
                raise MinPythonError("len() takes exactly one argument")
            mark = self.top
            src = self._expr(node.args[0])
            self.top = mark
            dst = self._push()
            self._emit(Op.LEN, dst, src)
            return dst

        # user function: [func][arg0][arg1]... in a contiguous window
        base = self.top
        freg = self._push()
        self._load_name(name, into=freg)
        for arg in node.args:
            areg = self._push()
            self._into(arg, areg)
        self.top = base
        dst = self._push()
        self._emit(Op.CALL, dst, freg, len(node.args))
        return dst

    # -- statements ---------------------------------------------------------

    def _stmt(self, node: ast.stmt) -> None:
        mark = self.top
        match node:
            case ast.FunctionDef():
                self._function_def(node)

            case ast.Return(value=value):
                if value is None:
                    r = self._push()
                    self._emit(Op.LOAD_CONST, r, self._const(None))
                else:
                    r = self._expr(value)
                self._emit(Op.RETURN, r)

            case ast.Assign(targets=targets, value=value):
                src = self._expr(value)
                for target in targets:
                    if not isinstance(target, ast.Name):
                        raise MinPythonError(
                            "only simple name assignment targets are supported")
                    self._store_name(target.id, src)

            case ast.AugAssign(target=target, op=op, value=value):
                if not isinstance(target, ast.Name):
                    raise MinPythonError(
                        "augmented assignment target must be a name")
                opcode = AST_BINOP.get(type(op))
                if opcode is None:
                    raise MinPythonError(
                        f"unsupported operator in augmented assignment: "
                        f"{type(op).__name__}")
                cur = self._load_name(target.id)
                delta = self._expr(value)
                dst = self._push()
                self._emit(opcode, dst, cur, delta)
                self._store_name(target.id, dst)

            case ast.AnnAssign(target=ast.Name(id=name), value=value):
                if value is not None:
                    src = self._expr(value)
                    self._store_name(name, src)

            case ast.Expr(value=value):
                self._expr(value)  # for side effects; result discarded

            case ast.If(test=test, body=body, orelse=orelse):
                self._if(test, body, orelse)

            case ast.While(test=test, body=body, orelse=orelse):
                if orelse:
                    raise MinPythonError("while/else is not supported")
                self._while(test, body)

            case ast.Break():
                if not self.loops:
                    raise MinPythonError("'break' outside loop")
                self._emit_jump(Op.JUMP, self.loops[-1][1])

            case ast.Continue():
                if not self.loops:
                    raise MinPythonError("'continue' outside loop")
                self._emit_jump(Op.JUMP, self.loops[-1][0])

            case ast.Pass():
                pass

            case ast.Global():
                pass  # already collected into declared_global

            case _:
                raise MinPythonError(
                    f"unsupported statement: {type(node).__name__}")
        self.top = mark  # statements leave no temporaries live

    def _if(self, test: ast.expr, body: list[ast.stmt],
            orelse: list[ast.stmt]) -> None:
        else_label = self._label()
        self._branch_if_false(test, else_label)
        for stmt in body:
            self._stmt(stmt)
        if orelse:
            end = self._label()
            self._emit_jump(Op.JUMP, end)
            self._bind(else_label)
            for stmt in orelse:
                self._stmt(stmt)
            self._bind(end)
        else:
            self._bind(else_label)

    def _while(self, test: ast.expr, body: list[ast.stmt]) -> None:
        top = self._label()
        end = self._label()
        self._bind(top)
        self._branch_if_false(test, end)
        self.loops.append((top, end))
        for stmt in body:
            self._stmt(stmt)
        self.loops.pop()
        self._emit_jump(Op.JUMP, top)   # the back-edge: hot-loop anchor
        self._bind(end)

    def _function_def(self, node: ast.FunctionDef) -> None:
        args = node.args
        if (args.vararg or args.kwarg or args.kwonlyargs or args.defaults
                or args.posonlyargs):
            raise MinPythonError(
                f"function '{node.name}': only plain positional parameters "
                "are supported")
        params = [a.arg for a in args.args]
        child = _compile_unit(node.name, params, node.body, is_module=False)
        dst = self._push()
        self._emit(Op.MAKE_FUNCTION, dst, self._const(child))
        self._store_name(node.name, dst)

    # -- driver -------------------------------------------------------------

    def compile(self) -> CodeObject:
        for stmt in self.body:
            self._stmt(stmt)
        # functions/modules fall off the end returning None
        r = self._push()
        self._emit(Op.LOAD_CONST, r, self._const(None))
        self._emit(Op.RETURN, r)
        self._resolve()
        return CodeObject(self.name, self.params, self.n_locals, self.n_regs,
                          self.consts, self.names, self.code, self.locals)


def _compile_unit(name: str, params: list[str], body: list[ast.stmt],
                  *, is_module: bool) -> CodeObject:
    return _Compiler(name, params, body, is_module=is_module).compile()


def _check_literal(value: object) -> None:
    if (isinstance(value, (bool, int, str)) or value is None):
        return
    raise MinPythonError(
        f"unsupported literal: {value!r} ({type(value).__name__})")


def compile_module(source: str) -> CodeObject:
    """Parse `source` and compile its top level to a '<module>' CodeObject."""
    tree = ast.parse(source)
    return _compile_unit("<module>", [], tree.body, is_module=True)
