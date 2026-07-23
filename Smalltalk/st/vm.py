"""The bytecode virtual machine.

A recursive stack machine: each activation (:class:`Frame`) runs a dispatch
loop over its method's bytecode; a message send that resolves to compiled code
recurses into a fresh activation. Blocks are real closures that capture their
defining environment and home activation, so a ``^`` inside a block performs a
non-local return from the home method (implemented with :class:`NonLocalReturn`).
"""

from __future__ import annotations

import operator
import sys
from typing import Any, Callable

from st.bytecode import CompiledBlock, CompiledMethod, Op
from st.objects import (
    PrimitiveMethod,
    STBlock,
    STChar,
    STClass,
    STError,
    STObject,
    STSymbol,
    nil,
)

# Special binary selectors that, for SmallInteger/Float operands, are executed
# inline in the dispatch loop (bypassing lookup + the arithmetic primitives).
# Disabled per-VM if a user overrides one of them on a numeric class.
_ARITH: dict[str, Callable[[Any, Any], Any]] = {
    "+": operator.add,
    "-": operator.sub,
    "*": operator.mul,
    "<": operator.lt,
    ">": operator.gt,
    "<=": operator.le,
    ">=": operator.ge,
    "=": operator.eq,
}
ARITHMETIC_SELECTORS = frozenset(_ARITH)


class NonLocalReturn(Exception):
    """Carries a ``^`` value out of a block up to its home activation."""

    def __init__(self, home: "Frame", value: Any):
        super().__init__("non-local return")
        self.home = home
        self.value = value


class Frame:
    """A single method or block activation.

    Locals (arguments + temporaries) live in a flat ``locals`` list addressed
    by slot index; ``outer`` links to the lexically enclosing activation so a
    block can reach its captured variables. Frames are reified: they are the
    Smalltalk ``MethodContext`` / ``BlockContext`` objects, and ``sender``
    links each activation to its caller, so the VM's ``active_context`` chain
    *is* the call stack (walkable from Smalltalk via ``thisContext``).
    """

    __slots__ = (
        "receiver",
        "method",
        "locals",
        "outer",
        "stack",
        "ip",
        "is_block",
        "home",
        "sender",
        "st_class",
    )

    def __init__(
        self,
        receiver: Any,
        method: CompiledMethod | CompiledBlock,
        locals_: list[Any],
        *,
        outer: "Frame | None",
        is_block: bool,
        home: "Frame | None",
        sender: "Frame | None" = None,
        st_class: STClass | None = None,
    ):
        self.receiver = receiver
        self.method = method
        self.locals = locals_
        self.outer = outer
        self.stack: list[Any] = []
        self.ip = 0
        self.is_block = is_block
        self.home = home
        self.sender = sender
        self.st_class = st_class


class VM:
    def __init__(self) -> None:
        self.classes: dict[str, STClass] = {}
        self.globals: dict[str, Any] = {}
        # The currently executing activation; the top of the reified call
        # stack. thisContext reads it and sender links walk it.
        self.active_context: Frame | None = None
        # Inline integer/float arithmetic in the loop; switched off if a user
        # overrides an arithmetic selector on a numeric class.
        self.optimize_arithmetic = True
        # Where Transcript output goes; the IDE overrides this to capture it.
        # Resolve sys.stdout lazily so test capture / redirection still works.
        self.output: Callable[[str], None] = lambda s: sys.stdout.write(s)

    # --- class registry ---

    def register_class(self, cls: STClass) -> None:
        self.classes[cls.name] = cls
        self.globals[cls.name] = cls
        self.flush_method_caches()

    def flush_method_caches(self) -> None:
        """Invalidate every class's method/layout caches. Call after any change
        to the class hierarchy or method dictionaries."""
        for cls in self.classes.values():
            cls.method_cache.clear()
            cls.class_method_cache.clear()
            cls._ivars_cache = None

    def note_override(self, cls: STClass, selector: str) -> None:
        """Disable inline arithmetic if an instance-side arithmetic selector is
        overridden on a class that SmallInteger or Float inherits from."""
        if selector not in ARITHMETIC_SELECTORS:
            return
        for name in ("SmallInteger", "Float"):
            num = self.classes.get(name)
            if num is not None and num.is_kind_of(cls):
                self.optimize_arithmetic = False
                return

    def class_of(self, value: Any) -> STClass:
        c = self.classes
        # fast path for the hottest exact types (bool/STSymbol/_Nil are
        # distinct types, so `is int`/`is str` never misclassify them)
        t = type(value)
        if t is STObject:
            return value.st_class
        if t is int:
            return c["SmallInteger"]
        if t is str:
            return c["String"]
        match value:
            case _ if value is nil:
                return c["UndefinedObject"]
            case True:
                return c["True"]
            case False:
                return c["False"]
            case STSymbol():  # before str: STSymbol is a str subclass
                return c["Symbol"]
            case str():
                return c["String"]
            case STChar():
                return c["Character"]
            case bool():  # unreachable (True/False handled above), kept explicit
                return c["Boolean"]
            case int():  # after bool: bool is an int subclass
                return c["SmallInteger"]
            case float():
                return c["Float"]
            case list():
                return c["Array"]
            case STBlock():
                return c["BlockClosure"]
            case STClass():
                return c["Class"]
            case Frame():
                return value.st_class or c["Context"]
            case STObject():
                return value.st_class
            case _:
                raise STError(
                    f"no Smalltalk class for host value {value!r}"
                )

    # --- message send ---

    def _lookup(
        self, receiver: Any, selector: str, super_start: STClass | None
    ) -> Any:
        if super_start is not None:
            return super_start.lookup(selector)
        if isinstance(receiver, STClass):
            method = receiver.lookup_class_method(selector)
            if method is None:
                # a class also understands generic instance messages of Class
                method = self.classes["Class"].lookup(selector)
            return method
        return self.class_of(receiver).lookup(selector)

    def send(
        self,
        receiver: Any,
        selector: str,
        args: list[Any],
        super_start: STClass | None = None,
    ) -> Any:
        """Synchronous send used from Python (primitives, the REPL, the IDE).

        A primitive runs in place; a compiled method starts a fresh driver
        (:meth:`_run`) whose frame's sender is the current activation, so the
        reified call stack stays continuous across the Python/Smalltalk border.
        """
        method = self._lookup(receiver, selector, super_start)
        if method is None:
            return self.does_not_understand(receiver, selector, args)
        if isinstance(method, PrimitiveMethod):
            return method.fn(self, receiver, args)
        return self._run(self._method_frame(method, receiver, args))

    def does_not_understand(
        self, receiver: Any, selector: str, args: list[Any]
    ) -> Any:
        cls = (
            receiver.name + " class"
            if isinstance(receiver, STClass)
            else self.class_of(receiver).name
        )
        raise STError(
            f"{cls} does not understand #{selector}", receiver=receiver
        )

    # --- activation ---

    def _method_frame(
        self, method: CompiledMethod, receiver: Any, args: list[Any]
    ) -> Frame:
        if len(args) != method.num_args:
            raise STError(
                f"#{method.selector} expects {method.num_args} args, "
                f"got {len(args)}"
            )
        locals_ = [nil] * len(method.local_names)
        locals_[: len(args)] = args  # arguments occupy the first slots
        return Frame(
            receiver,
            method,
            locals_,
            outer=None,
            is_block=False,
            home=None,
            sender=self.active_context,
            st_class=self.classes.get("MethodContext"),
        )

    def _block_frame(self, block: STBlock, args: list[Any]) -> Frame:
        tmpl: CompiledBlock = block.node
        if len(args) != tmpl.num_args:
            raise STError(
                f"block expects {tmpl.num_args} args, got {len(args)}"
            )
        locals_ = [nil] * len(tmpl.local_names)
        locals_[: len(args)] = args  # block arguments occupy the first slots
        home: Frame | None = block.home_context
        receiver = home.receiver if home is not None else nil
        return Frame(
            receiver,
            tmpl,
            locals_,
            outer=block.outer,
            is_block=True,
            home=home,
            sender=self.active_context,
            st_class=self.classes.get("BlockContext"),
        )

    def activate(
        self, method: CompiledMethod, receiver: Any, args: list[Any]
    ) -> Any:
        """Top-level entry (the REPL / IDE / ``system.eval``)."""
        return self._run(self._method_frame(method, receiver, args))

    def run_block(self, block: STBlock, args: list[Any]) -> Any:
        return self._run(self._block_frame(block, args))

    # --- the non-recursive driver ---

    def _run(self, root: Frame) -> Any:
        """Drive execution until ``root`` returns.

        Method-to-method sends push a new activation and keep looping (no host
        recursion), so a deep chain of Smalltalk sends costs heap, not Python
        stack. Only a primitive that re-enters the VM (``value``, ``do:`` …)
        nests another ``_run``. ``^`` from a block surfaces as
        :class:`NonLocalReturn` and is resolved by whichever ``_run`` owns the
        home activation.
        """
        boundary = root.sender
        self.active_context = root
        while True:
            try:
                return self._loop(boundary)
            except NonLocalReturn as nlr:
                if self._manages(nlr.home, boundary):
                    target = nlr.home.sender
                    if target is boundary:
                        self.active_context = target
                        return nlr.value
                    target.stack.append(nlr.value)
                    self.active_context = target
                    continue  # resume executing the home's sender
                if boundary is None:
                    raise STError("non-local return from a dead context") from None
                raise

    def _manages(self, home: Frame, boundary: Frame | None) -> bool:
        """Is ``home`` one of the activations this ``_run`` owns (i.e. above
        ``boundary`` in the current sender chain)?"""
        ctx: Frame | None = self.active_context
        while ctx is not None and ctx is not boundary:
            if ctx is home:
                return True
            ctx = ctx.sender
        return False

    # --- instance-variable / global access (locals are addressed by slot) ---

    def _read_var(self, frame: Frame, name: str) -> Any:
        recv = frame.receiver
        if type(recv) is STObject and name in recv.st_class.all_instance_variables():
            return recv.ivars.get(name, nil)
        if name in self.globals:
            return self.globals[name]
        raise STError(f"undeclared variable {name!r}")

    def _write_var(self, frame: Frame, name: str, value: Any) -> None:
        recv = frame.receiver
        if type(recv) is STObject and name in recv.st_class.all_instance_variables():
            recv.ivars[name] = value
            return
        # auto-declare into the global/workspace namespace
        self.globals[name] = value

    # --- the dispatch loop ---

    def _loop(self, boundary: Frame | None) -> Any:
        """Execute instructions until an activation whose sender is
        ``boundary`` returns; then hand that return value back to :meth:`_run`.

        ``ctx`` is the current activation. A compiled send swaps ``ctx`` to the
        callee (rebinding the hot locals ``code``/``literals``/``stack``); a
        return swaps it back to the sender. No Python recursion is involved for
        Smalltalk-to-Smalltalk sends.
        """
        ctx = self.active_context
        assert ctx is not None
        code = ctx.method.code
        literals = ctx.method.literals
        stack = ctx.stack
        while True:
            ins = code[ctx.ip]
            ctx.ip += 1

            # Cases are ordered hottest-first: `match` on an enum value compiles
            # to sequential comparisons in CPython, so the common opcodes (send,
            # local access, return, literal push, branch) are checked first.
            match ins.op:
                case Op.SEND | Op.SEND_SUPER:
                    selector, argc = ins.arg
                    n = len(stack) - argc
                    args = stack[n:]
                    del stack[n:]
                    receiver = stack.pop()
                    if ins.op is Op.SEND_SUPER:
                        defined_in = ctx.method.defined_in
                        start = (
                            defined_in.superclass
                            if defined_in is not None
                            else None
                        )
                        method = self._lookup(receiver, selector, start)
                    else:
                        # inline fast path for numeric binary operators
                        if argc == 1 and self.optimize_arithmetic:
                            fast = _ARITH.get(selector)
                            if fast is not None:
                                rt = type(receiver)
                                if rt is int or rt is float:
                                    at = type(args[0])
                                    if at is int or at is float:
                                        stack.append(fast(receiver, args[0]))
                                        continue
                        method = self._lookup(receiver, selector, None)
                    if method is None:
                        self.does_not_understand(receiver, selector, args)
                    if isinstance(method, PrimitiveMethod):
                        stack.append(method.fn(self, receiver, args))
                    else:
                        ctx = self._method_frame(method, receiver, args)
                        self.active_context = ctx
                        code = ctx.method.code
                        literals = ctx.method.literals
                        stack = ctx.stack
                case Op.PUSH_LOCAL:
                    stack.append(ctx.locals[ins.arg])
                case Op.RETURN | Op.BLOCK_RETURN:
                    value = stack.pop()
                    if ins.op is Op.RETURN and ctx.is_block:
                        if ctx.home is None:
                            raise STError("non-local return with no home context")
                        raise NonLocalReturn(ctx.home, value)
                    sender = ctx.sender
                    self.active_context = sender
                    if sender is boundary:
                        return value
                    assert sender is not None
                    sender.stack.append(value)
                    ctx = sender
                    code = ctx.method.code
                    literals = ctx.method.literals
                    stack = ctx.stack
                case Op.PUSH_LITERAL:
                    stack.append(literals[ins.arg])
                case Op.STORE_LOCAL:
                    ctx.locals[ins.arg] = stack[-1]
                case Op.JUMP_FALSE:
                    match stack.pop():
                        case False:
                            ctx.ip = ins.arg
                        case True:
                            pass
                        case _:
                            raise STError("condition must be a Boolean")
                case Op.POP:
                    stack.pop()
                case Op.JUMP:
                    ctx.ip = ins.arg
                case Op.PUSH_SELF:
                    stack.append(ctx.receiver)
                case Op.DUP:
                    stack.append(stack[-1])
                case Op.PUSH_BLOCK:
                    tmpl = literals[ins.arg]
                    home = ctx if not ctx.is_block else ctx.home
                    stack.append(STBlock(tmpl, ctx, home))
                case Op.PUSH_OUTER:
                    depth, index = ins.arg
                    f = ctx.outer
                    for _ in range(depth - 1):
                        f = f.outer
                    stack.append(f.locals[index])
                case Op.STORE_OUTER:
                    depth, index = ins.arg
                    f = ctx.outer
                    for _ in range(depth - 1):
                        f = f.outer
                    f.locals[index] = stack[-1]
                case Op.PUSH_NIL:
                    stack.append(nil)
                case Op.PUSH_TRUE:
                    stack.append(True)
                case Op.PUSH_FALSE:
                    stack.append(False)
                case Op.PUSH_CONTEXT:
                    stack.append(ctx)
                case Op.PUSH_VAR:
                    stack.append(self._read_var(ctx, ins.arg))
                case Op.STORE_VAR:
                    self._write_var(ctx, ins.arg, stack[-1])
                case Op.MAKE_ARRAY:
                    n = len(stack) - ins.arg
                    items = stack[n:]
                    del stack[n:]
                    stack.append(list(items))
                case Op.JUMP_TRUE:
                    match stack.pop():
                        case True:
                            ctx.ip = ins.arg
                        case False:
                            pass
                        case _:
                            raise STError("condition must be a Boolean")
                case _:  # pragma: no cover
                    raise STError(f"unknown opcode {ins.op!r}")
