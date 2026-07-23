"""Compile the AST into bytecode.

Two entry points mirror the parser:

  compile_method(MethodNode, source)   -> CompiledMethod
  compile_doit(SequenceNode, source)   -> CompiledMethod   (a 0-arg "DoIt")

The control-flow selectors below are compiled inline into conditional jumps
when *all* of their block arguments are written as literal zero-argument
blocks. Otherwise the send is compiled normally and the blocks become real
closures (evaluated later via the ``value`` primitive).
"""

from __future__ import annotations

from st import ast
from st.bytecode import CompiledBlock, CompiledMethod, Instr, Op


class CompileError(Exception):
    pass


class _CodeGen:
    """Accumulates instructions and a literal pool for one method/block."""

    def __init__(self) -> None:
        self.code: list[Instr] = []
        self.literals: list[object] = []
        # temps discovered in inlined blocks get hoisted into the enclosing
        # method frame; collected here and merged into local_names.
        self.hoisted: list[str] = []

    def emit(self, op: Op, arg: object = None) -> int:
        self.code.append(Instr(op, arg))
        return len(self.code) - 1

    def literal(self, value: object) -> int:
        # Deduplicate immutable, hashable literals; append mutable ones (lists,
        # compiled blocks) as fresh entries so occurrences never share state.
        try:
            hash(value)
        except TypeError:
            self.literals.append(value)
            return len(self.literals) - 1
        for idx, existing in enumerate(self.literals):
            if type(existing) is type(value) and existing == value:
                return idx
        self.literals.append(value)
        return len(self.literals) - 1

    def here(self) -> int:
        return len(self.code)


# Selectors compiled inline (block args must be literal zero-arg blocks).
_COND = {"ifTrue:", "ifFalse:", "ifTrue:ifFalse:", "ifFalse:ifTrue:"}
_LOGIC = {"and:", "or:"}
_LOOP = {"whileTrue:", "whileFalse:", "whileTrue", "whileFalse", "repeat"}


class Compiler:
    def __init__(self) -> None:
        self.g = _CodeGen()

    # --- public API ---

    def compile_method(self, node: ast.MethodNode, source: str = "") -> CompiledMethod:
        self.g = _CodeGen()
        self._sequence_value(node.body, is_method_body=True)
        # implicit ^self
        self.g.emit(Op.PUSH_SELF)
        self.g.emit(Op.RETURN)
        locals_ = list(node.params) + list(node.body.temps) + self.g.hoisted
        return CompiledMethod(
            selector=node.selector,
            params=list(node.params),
            local_names=_dedup(locals_),
            code=self.g.code,
            literals=self.g.literals,
            source=source,
        )

    def compile_doit(self, seq: ast.SequenceNode, source: str = "") -> CompiledMethod:
        self.g = _CodeGen()
        self._sequence_value(seq, is_method_body=True)
        # A DoIt yields the value of its last statement (already on the stack);
        # if there were no statements, yield nil.
        if not seq.statements:
            self.g.emit(Op.PUSH_NIL)
        self.g.emit(Op.RETURN)
        locals_ = list(seq.temps) + self.g.hoisted
        return CompiledMethod(
            selector="DoIt",
            params=[],
            local_names=_dedup(locals_),
            code=self.g.code,
            literals=self.g.literals,
            source=source,
        )

    # --- statement sequences ---

    def _sequence_value(self, seq: ast.SequenceNode, *, is_method_body: bool) -> None:
        """Compile a statement sequence leaving the value of its last
        expression on the stack (for method/block bodies). A ``^`` return in
        the middle emits RETURN and stops."""
        stmts = seq.statements
        if not stmts:
            if not is_method_body:
                self.g.emit(Op.PUSH_NIL)
            return
        for i, stmt in enumerate(stmts):
            last = i == len(stmts) - 1
            if isinstance(stmt, ast.ReturnNode):
                self._expr(stmt.value)
                self.g.emit(Op.RETURN)
                return
            self._expr(stmt)
            if not last:
                self.g.emit(Op.POP)

    def _sequence_effect(self, seq: ast.SequenceNode) -> None:
        """Compile a sequence for its side effects, leaving nothing extra
        (used for inlined loop bodies)."""
        self._sequence_value(seq, is_method_body=False)
        self.g.emit(Op.POP)

    # --- expressions ---

    def _expr(self, node: ast.ExprNode) -> None:
        match node:
            case ast.LiteralNode(value=value):
                self._literal(value)
            case ast.VariableNode(name=name):
                self._variable(name)
            case ast.AssignmentNode(name=name, value=value):
                self._expr(value)
                self.g.emit(Op.STORE_VAR, name)
            case ast.MessageNode():
                self._message(node)
            case ast.CascadeNode():
                self._cascade(node)
            case ast.BlockNode():
                self._block_literal(node)
            case ast.ReturnNode(value=value):
                self._expr(value)
                self.g.emit(Op.RETURN)
            case _:  # pragma: no cover
                raise CompileError(f"cannot compile node {node!r}")

    def _literal(self, value: object) -> None:
        from st.objects import nil

        match value:
            case True:
                self.g.emit(Op.PUSH_TRUE)
            case False:
                self.g.emit(Op.PUSH_FALSE)
            case _ if value is nil:
                self.g.emit(Op.PUSH_NIL)
            case _:
                self.g.emit(Op.PUSH_LITERAL, self.g.literal(value))

    def _variable(self, name: str) -> None:
        match name:
            case "self" | "super":
                self.g.emit(Op.PUSH_SELF)
            case "thisContext":
                self.g.emit(Op.PUSH_CONTEXT)
            case _:
                self.g.emit(Op.PUSH_VAR, name)

    def _cascade(self, node: ast.CascadeNode) -> None:
        self._expr(node.receiver)
        for i, msg in enumerate(node.messages):
            last = i == len(node.messages) - 1
            if not last:
                self.g.emit(Op.DUP)
            for arg in msg.args:
                self._expr(arg)
            self.g.emit(Op.SEND, (msg.selector, len(msg.args)))
            if not last:
                self.g.emit(Op.POP)  # discard result, keep receiver for next

    # --- message sends, with inlining of control flow ---

    def _message(self, node: ast.MessageNode) -> None:
        sel = node.selector

        if sel == "__brace__":  # dynamic array {a. b. c}
            for el in node.args:
                self._expr(el)
            self.g.emit(Op.MAKE_ARRAY, len(node.args))
            return

        if self._try_inline(node):
            return

        # super send?
        if isinstance(node.receiver, ast.VariableNode) and node.receiver.name == "super":
            self.g.emit(Op.PUSH_SELF)
            for arg in node.args:
                self._expr(arg)
            self.g.emit(Op.SEND_SUPER, (sel, len(node.args)))
            return

        self._expr(node.receiver)
        for arg in node.args:
            self._expr(arg)
        self.g.emit(Op.SEND, (sel, len(node.args)))

    def _try_inline(self, node: ast.MessageNode) -> bool:
        sel = node.selector
        if sel in _COND:
            return self._inline_cond(node)
        if sel in _LOGIC:
            return self._inline_logic(node)
        if sel in _LOOP:
            return self._inline_loop(node)
        return False

    def _zero_arg_block(self, node: ast.ExprNode) -> ast.BlockNode | None:
        if isinstance(node, ast.BlockNode) and not node.params:
            return node
        return None

    def _inline_block_body(self, block: ast.BlockNode) -> None:
        # temps declared in an inlined block are hoisted into the method frame
        self.g.hoisted.extend(block.temps)
        self._sequence_value(block.body, is_method_body=False)

    def _inline_cond(self, node: ast.MessageNode) -> bool:
        sel = node.selector
        blocks = [self._zero_arg_block(a) for a in node.args]
        if any(b is None for b in blocks):
            return False
        g = self.g
        # Normalise to (true_block, false_block or None)
        if sel == "ifTrue:":
            true_b, false_b, negate = blocks[0], None, False
        elif sel == "ifFalse:":
            true_b, false_b, negate = None, blocks[0], False
        elif sel == "ifTrue:ifFalse:":
            true_b, false_b, negate = blocks[0], blocks[1], False
        else:  # ifFalse:ifTrue:
            true_b, false_b, negate = blocks[1], blocks[0], False

        self._expr(node.receiver)
        j_false = g.emit(Op.JUMP_FALSE, None)
        # true branch
        if true_b is not None:
            self._inline_block_body(true_b)
        else:
            g.emit(Op.PUSH_NIL)
        j_end = g.emit(Op.JUMP, None)
        g.code[j_false].arg = g.here()
        # false branch
        if false_b is not None:
            self._inline_block_body(false_b)
        else:
            g.emit(Op.PUSH_NIL)
        g.code[j_end].arg = g.here()
        _ = negate
        return True

    def _inline_logic(self, node: ast.MessageNode) -> bool:
        arg_block = self._zero_arg_block(node.args[0])
        if arg_block is None:
            return False
        g = self.g
        self._expr(node.receiver)
        if node.selector == "and:":
            j = g.emit(Op.JUMP_FALSE, None)  # pops receiver
            self._inline_block_body(arg_block)
            j_end = g.emit(Op.JUMP, None)
            g.code[j].arg = g.here()
            g.emit(Op.PUSH_FALSE)
            g.code[j_end].arg = g.here()
        else:  # or:
            j = g.emit(Op.JUMP_TRUE, None)
            self._inline_block_body(arg_block)
            j_end = g.emit(Op.JUMP, None)
            g.code[j].arg = g.here()
            g.emit(Op.PUSH_TRUE)
            g.code[j_end].arg = g.here()
        return True

    def _inline_loop(self, node: ast.MessageNode) -> bool:
        sel = node.selector
        g = self.g
        cond_block = self._zero_arg_block(node.receiver)

        if sel == "repeat":
            body = self._zero_arg_block(node.receiver)
            if body is None:
                return False
            start = g.here()
            self._sequence_effect(body.body)
            j = g.emit(Op.JUMP, None)
            g.code[j].arg = start
            g.emit(Op.PUSH_NIL)  # unreachable, keeps the stack model consistent
            return True

        if sel in ("whileTrue", "whileFalse"):
            if cond_block is None:
                return False
            start = g.here()
            self._sequence_value(cond_block.body, is_method_body=False)
            jexit = g.emit(
                Op.JUMP_FALSE if sel == "whileTrue" else Op.JUMP_TRUE, None
            )
            j = g.emit(Op.JUMP, None)
            g.code[j].arg = start
            g.code[jexit].arg = g.here()
            g.emit(Op.PUSH_NIL)
            return True

        # whileTrue:/whileFalse:
        body_block = self._zero_arg_block(node.args[0])
        if cond_block is None or body_block is None:
            return False
        start = g.here()
        self._sequence_value(cond_block.body, is_method_body=False)
        jexit = g.emit(Op.JUMP_FALSE if sel == "whileTrue:" else Op.JUMP_TRUE, None)
        self._sequence_effect(body_block.body)
        j = g.emit(Op.JUMP, None)
        g.code[j].arg = start
        g.code[jexit].arg = g.here()
        g.emit(Op.PUSH_NIL)
        return True

    # --- non-inlined blocks become closures ---

    def _block_literal(self, node: ast.BlockNode) -> None:
        sub = Compiler()
        sub.g = _CodeGen()
        sub._sequence_value(node.body, is_method_body=False)
        sub.g.emit(Op.BLOCK_RETURN)
        block = CompiledBlock(
            params=list(node.params),
            local_names=_dedup(list(node.params) + list(node.temps) + sub.g.hoisted),
            code=sub.g.code,
            literals=sub.g.literals,
        )
        self.g.emit(Op.PUSH_BLOCK, self.g.literal(block))


def _dedup(names: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for n in names:
        if n not in seen:
            seen.add(n)
            out.append(n)
    return out


def compile_method(node: ast.MethodNode, source: str = "") -> CompiledMethod:
    return Compiler().compile_method(node, source)


def compile_doit(seq: ast.SequenceNode, source: str = "") -> CompiledMethod:
    return Compiler().compile_doit(seq, source)
