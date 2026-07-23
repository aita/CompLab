"""The MinPython register VM: a flat dispatch loop over `CodeObject` bytecode.

One `run_frame` call executes one function activation. Registers are a plain
Python list; a `CALL` recurses into another `run_frame`, so the host Python
stack is the call stack (fine for this experiment -- loops, not deep recursion,
are what the JIT cares about). Every instruction either advances `pc` by one or
jumps; there is no hidden control flow, which is exactly what makes a trace of
this loop straightforward to record and later compile.

Tracing hooks. The back-edge of every `while` is an unconditional `JUMP` to a
lower pc. Those are the only places a loop can be entered repeatedly, so they
are the anchors a tracing JIT profiles:

  * `loop_counts[(id(code), target)]` counts how often each back-edge is taken.
  * `on_backedge(code, target, regs, globals)`, if set, is called there -- the
    hook a tracer overrides to threshold on the count, begin recording, or
    dispatch into already-compiled native code. It returns a pc to resume the
    interpreter at (after updating `regs` in place), or None to keep going.

The base VM only counts; it never changes behaviour. This keeps a clean split:
this file is the reference interpreter and the fallback target; the JIT is a
layer on top that reads these signals.

Public API:
    VM().run(source) -> globals dict
    VM().run_code(code_object) -> return value
"""

from __future__ import annotations

from typing import Callable

from .bytecode import (BIN_FN, CMP_FN, UNARY_FN, CodeObject, MinPythonError,
                       Op, Value)
from .compile import compile_module


def _repr(value: Value) -> str:
    """Render a value the way print() should: bools as True/False (bool is int,
    so guard it first), everything else via str()."""
    if isinstance(value, bool):
        return "True" if value else "False"
    return str(value)


class Function:
    """A runtime function value: a CodeObject plus the module globals it was
    defined against (so it can reach other globals and recurse)."""
    __slots__ = ("code", "globals")

    def __init__(self, code: CodeObject, globals_: dict[str, Value]):
        self.code = code
        self.globals = globals_

    def __repr__(self) -> str:
        return f"<minpython function {self.code.name}>"


# Back-edge hook: (code, target_pc, regs, globals) -> resume-pc | None.
# Returning an int redirects the interpreter to that pc (having mutated `regs`
# in place); None means "keep interpreting normally from the back-edge target".
BackedgeHook = Callable[[CodeObject, int, list, dict], int | None]

# Call hook: (callee, regs, arg_base, argc) -> (handled, value). See VM.on_call.
CallHook = Callable[[object, list, int, int], tuple[bool, Value]]


class VM:
    """A MinPython bytecode VM instance; one holds one module's globals."""

    def __init__(self, *, profile: bool = True, cython: bool = False):
        self.globals: dict[str, Value] = {}
        self.profile = profile
        self.loop_counts: dict[tuple[int, int], int] = {}
        self.on_backedge: BackedgeHook | None = None
        # Optional method-JIT hook: (callee, regs, arg_base, argc) -> (handled,
        # value). If it returns handled=True it ran native code for the whole
        # call and `value` is the result; otherwise the VM interprets normally.
        self.on_call: CallHook | None = None
        self._output: list[str] = []

        # The dispatch loop: the optional compiled Cython one, or the pure
        # Python method below. Both obey the same contract, so the JIT and the
        # tests see no difference beyond speed.
        self._dispatch = self.run_frame
        self.using_cython = False
        if cython:
            from ._cydispatch import load
            cy = load()
            if cy is not None:
                self._dispatch = lambda code, regs, glb: cy(self, code, regs,
                                                            glb)
                self.using_cython = True

    # -- entry points --------------------------------------------------------

    def run(self, source: str) -> dict[str, Value]:
        """Compile and execute `source` as a module; return its globals."""
        self.run_code(compile_module(source))
        return self.globals

    def run_code(self, code: CodeObject, args: list[Value] | None = None
                 ) -> Value:
        """Execute a CodeObject as the module top level (its registers share
        nothing with any caller). `args` seeds the parameter registers."""
        regs: list[Value] = [None] * code.n_regs
        if args:
            regs[:len(args)] = args
        return self._dispatch(code, regs, self.globals)

    # -- the dispatch loop ---------------------------------------------------

    def run_frame(self, code: CodeObject, regs: list, glb: dict) -> Value:
        """Run one activation of `code` with register file `regs`."""
        insns = code.code
        consts = code.consts
        names = code.names
        pc = 0
        while True:
            ins = insns[pc]
            op = ins.op
            a = ins.a
            b = ins.b

            if op == Op.LOAD_CONST:
                regs[a] = consts[b]
            elif op == Op.MOVE:
                regs[a] = regs[b]
            elif op == Op.LOAD_GLOBAL:
                name = names[b]
                if name in glb:
                    regs[a] = glb[name]
                else:
                    raise MinPythonError(f"name '{name}' is not defined")
            elif op == Op.STORE_GLOBAL:
                glb[names[a]] = regs[b]
            elif op in BIN_FN:
                regs[a] = BIN_FN[op](regs[b], regs[ins.c])
            elif op in CMP_FN:
                regs[a] = CMP_FN[op](regs[b], regs[ins.c])
            elif op in UNARY_FN:
                regs[a] = UNARY_FN[op](regs[b])

            elif op == Op.JUMP:
                # a back-edge (target below here) is a loop iteration
                if a <= pc:
                    if self.profile:
                        key = (id(code), a)
                        self.loop_counts[key] = self.loop_counts.get(key, 0) + 1
                    if self.on_backedge is not None:
                        # The hook may run compiled native code for this loop
                        # and hand control back at a different pc (a guard exit),
                        # with `regs` already updated in place. It returns that
                        # resume pc, or None to keep interpreting from here.
                        resume = self.on_backedge(code, a, regs, glb)
                        if resume is not None:
                            pc = resume
                            continue
                pc = a
                continue
            elif op == Op.JUMP_IF_FALSE:
                if not regs[a]:
                    pc = b
                    continue
            elif op == Op.JUMP_IF_TRUE:
                if regs[a]:
                    pc = b
                    continue

            elif op == Op.CALL:
                regs[a] = self._call(regs[b], regs, b + 1, ins.c)
            elif op == Op.PRINT:
                self._print(regs, a, b)
            elif op == Op.RETURN:
                return regs[a]
            elif op == Op.MAKE_FUNCTION:
                child = consts[b]
                assert isinstance(child, CodeObject)
                regs[a] = Function(child, glb)
            elif op == Op.MAKE_LIST:
                regs[a] = regs[b:b + ins.c]
            elif op == Op.SUBSCR:
                regs[a] = regs[b][regs[ins.c]]
            elif op == Op.LEN:
                regs[a] = len(regs[b])
            else:
                raise MinPythonError(f"unknown opcode: {op!r}")

            pc += 1

    # -- helpers -------------------------------------------------------------

    def _call(self, callee: Value, regs: list, arg_base: int,
              argc: int) -> Value:
        if not isinstance(callee, Function):
            raise MinPythonError(f"{callee!r} is not callable")
        code = callee.code
        if argc != len(code.params):
            raise MinPythonError(
                f"{code.name}() takes {len(code.params)} argument(s) "
                f"but {argc} were given")
        if self.on_call is not None:
            handled, value = self.on_call(callee, regs, arg_base, argc)
            if handled:
                return value
        frame: list[Value] = [None] * code.n_regs
        frame[:argc] = regs[arg_base:arg_base + argc]
        return self._dispatch(code, frame, callee.globals)

    def _make_function(self, code: CodeObject, glb: dict) -> Function:
        """Build a runtime Function (used by the MAKE_FUNCTION opcode; also the
        Cython dispatcher's hook, to avoid importing Function into the .pyx)."""
        return Function(code, glb)

    def _print(self, regs: list, base: int, argc: int) -> None:
        line = " ".join(_repr(regs[base + i]) for i in range(argc))
        self._output.append(line)
        print(line)

    @property
    def output(self) -> str:
        return "\n".join(self._output)
