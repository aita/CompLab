"""The bytecode virtual machine.

A recursive stack machine: each activation (:class:`Frame`) runs a dispatch
loop over its method's bytecode; a message send that resolves to compiled code
recurses into a fresh activation. Blocks are real closures that capture their
defining environment and home activation, so a ``^`` inside a block performs a
non-local return from the home method (implemented with :class:`NonLocalReturn`).
"""

from __future__ import annotations

import sys
from typing import Any, Callable

from st.bytecode import CompiledBlock, CompiledMethod, Instr, Op
from st.objects import (
    STBlock,
    STChar,
    STClass,
    STError,
    STObject,
    STSymbol,
    PrimitiveMethod,
    nil,
)


class NonLocalReturn(Exception):
    """Carries a ``^`` value out of a block up to its home activation."""

    def __init__(self, home: "Frame", value: Any):
        super().__init__("non-local return")
        self.home = home
        self.value = value


class Environment:
    """A lexical scope: a name→value map with a link to the enclosing scope."""

    __slots__ = ("vars", "parent")

    def __init__(self, parent: "Environment | None" = None):
        self.vars: dict[str, Any] = {}
        self.parent = parent

    def find(self, name: str) -> "Environment | None":
        env: Environment | None = self
        while env is not None:
            if name in env.vars:
                return env
            env = env.parent
        return None


class Frame:
    """A single method or block activation.

    Frames are reified: they are the Smalltalk ``MethodContext`` /
    ``BlockContext`` objects. ``sender`` links each activation to the one that
    invoked it, so the VM's ``active_context`` chain *is* the call stack and is
    walkable from Smalltalk via ``thisContext``.
    """

    __slots__ = (
        "receiver",
        "method",
        "env",
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
        env: Environment,
        *,
        is_block: bool,
        home: "Frame | None",
        sender: "Frame | None" = None,
        st_class: STClass | None = None,
    ):
        self.receiver = receiver
        self.method = method
        self.env = env
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
        # Where Transcript output goes; the IDE overrides this to capture it.
        # Resolve sys.stdout lazily so test capture / redirection still works.
        self.output: Callable[[str], None] = lambda s: sys.stdout.write(s)

    # --- class registry ---

    def register_class(self, cls: STClass) -> None:
        self.classes[cls.name] = cls
        self.globals[cls.name] = cls

    def class_of(self, value: Any) -> STClass:
        c = self.classes
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

    def send(
        self,
        receiver: Any,
        selector: str,
        args: list[Any],
        super_start: STClass | None = None,
    ) -> Any:
        if super_start is not None:
            method = super_start.lookup(selector)
        elif isinstance(receiver, STClass):
            method = receiver.lookup_class_method(selector)
            if method is None:
                # a class also understands generic instance messages of Class
                method = self.classes["Class"].lookup(selector)
        else:
            method = self.class_of(receiver).lookup(selector)

        if method is None:
            return self.does_not_understand(receiver, selector, args)
        if isinstance(method, PrimitiveMethod):
            return method.fn(self, receiver, args)
        return self.activate(method, receiver, args)

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

    def activate(
        self, method: CompiledMethod, receiver: Any, args: list[Any]
    ) -> Any:
        if len(args) != method.num_args:
            raise STError(
                f"#{method.selector} expects {method.num_args} args, "
                f"got {len(args)}"
            )
        env = Environment()
        for name in method.local_names:
            env.vars[name] = nil
        for name, value in zip(method.params, args):
            env.vars[name] = value
        frame = Frame(
            receiver,
            method,
            env,
            is_block=False,
            home=None,
            sender=self.active_context,
            st_class=self.classes.get("MethodContext"),
        )
        self.active_context = frame
        try:
            return self.interpret(frame)
        except NonLocalReturn as nlr:
            if nlr.home is frame:
                return nlr.value
            raise
        finally:
            self.active_context = frame.sender

    def run_block(self, block: STBlock, args: list[Any]) -> Any:
        tmpl: CompiledBlock = block.node
        if len(args) != tmpl.num_args:
            raise STError(
                f"block expects {tmpl.num_args} args, got {len(args)}"
            )
        env = Environment(block.home_env)
        for name in tmpl.local_names:
            env.vars[name] = nil
        for name, value in zip(tmpl.params, args):
            env.vars[name] = value
        home: Frame | None = block.home_context
        receiver = home.receiver if home is not None else nil
        frame = Frame(
            receiver,
            tmpl,
            env,
            is_block=True,
            home=home,
            sender=self.active_context,
            st_class=self.classes.get("BlockContext"),
        )
        self.active_context = frame
        try:
            return self.interpret(frame)
        finally:
            self.active_context = frame.sender

    # --- variable access ---

    def _read_var(self, frame: Frame, name: str) -> Any:
        env = frame.env.find(name)
        if env is not None:
            return env.vars[name]
        recv = frame.receiver
        if isinstance(recv, STObject) and name in recv.st_class.all_instance_variables():
            return recv.ivars.get(name, nil)
        if name in self.globals:
            return self.globals[name]
        raise STError(f"undeclared variable {name!r}")

    def _write_var(self, frame: Frame, name: str, value: Any) -> None:
        env = frame.env.find(name)
        if env is not None:
            env.vars[name] = value
            return
        recv = frame.receiver
        if isinstance(recv, STObject) and name in recv.st_class.all_instance_variables():
            recv.ivars[name] = value
            return
        # auto-declare into the global/workspace namespace
        self.globals[name] = value

    # --- the dispatch loop ---

    def interpret(self, frame: Frame) -> Any:
        code: list[Instr] = frame.method.code
        literals = frame.method.literals
        stack = frame.stack
        while True:
            ins = code[frame.ip]
            frame.ip += 1

            match ins.op:
                case Op.PUSH_LITERAL:
                    stack.append(literals[ins.arg])
                case Op.PUSH_SELF:
                    stack.append(frame.receiver)
                case Op.PUSH_CONTEXT:
                    stack.append(frame)
                case Op.PUSH_NIL:
                    stack.append(nil)
                case Op.PUSH_TRUE:
                    stack.append(True)
                case Op.PUSH_FALSE:
                    stack.append(False)
                case Op.PUSH_VAR:
                    stack.append(self._read_var(frame, ins.arg))
                case Op.STORE_VAR:
                    self._write_var(frame, ins.arg, stack[-1])
                case Op.POP:
                    stack.pop()
                case Op.DUP:
                    stack.append(stack[-1])
                case Op.SEND:
                    selector, argc = ins.arg
                    args = stack[len(stack) - argc :]
                    del stack[len(stack) - argc :]
                    receiver = stack.pop()
                    stack.append(self.send(receiver, selector, args))
                case Op.SEND_SUPER:
                    selector, argc = ins.arg
                    args = stack[len(stack) - argc :]
                    del stack[len(stack) - argc :]
                    receiver = stack.pop()
                    defined_in = frame.method.defined_in
                    start = defined_in.superclass if defined_in is not None else None
                    stack.append(
                        self.send(receiver, selector, args, super_start=start)
                    )
                case Op.PUSH_BLOCK:
                    tmpl = literals[ins.arg]
                    home = frame if not frame.is_block else frame.home
                    stack.append(STBlock(tmpl, frame.env, home))
                case Op.MAKE_ARRAY:
                    n = ins.arg
                    items = stack[len(stack) - n :]
                    del stack[len(stack) - n :]
                    stack.append(list(items))
                case Op.JUMP:
                    frame.ip = ins.arg
                case Op.JUMP_TRUE:
                    match stack.pop():
                        case True:
                            frame.ip = ins.arg
                        case False:
                            pass
                        case _:
                            raise STError("condition must be a Boolean")
                case Op.JUMP_FALSE:
                    match stack.pop():
                        case False:
                            frame.ip = ins.arg
                        case True:
                            pass
                        case _:
                            raise STError("condition must be a Boolean")
                case Op.RETURN:
                    value = stack.pop()
                    if not frame.is_block:
                        return value
                    if frame.home is None:
                        raise STError("non-local return with no home context")
                    raise NonLocalReturn(frame.home, value)
                case Op.BLOCK_RETURN:
                    return stack.pop()
                case _:  # pragma: no cover
                    raise STError(f"unknown opcode {ins.op!r}")
