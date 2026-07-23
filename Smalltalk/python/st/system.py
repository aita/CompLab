"""High-level facade: parse → compile → run, plus class/method definition.

This is the object the REPL and the IDE talk to. A single :class:`Smalltalk`
owns one :class:`~st.vm.VM` with the kernel installed.
"""

from __future__ import annotations

from typing import Any

from st import parser
from st.bytecode import CompiledMethod
from st.compiler import compile_doit, compile_method
from st.kernel import build_kernel, py_print
from st.objects import STClass, nil
from st.vm import VM


class Smalltalk:
    def __init__(self) -> None:
        self.vm = VM()
        build_kernel(self.vm)

    # --- evaluation ---

    def compile_doit(self, source: str) -> CompiledMethod:
        seq = parser.parse_sequence(source)
        return compile_doit(seq, source)

    def eval(self, source: str, receiver: Any = nil) -> Any:
        method = self.compile_doit(source)
        return self.vm.activate(method, receiver, [])

    def eval_to_string(self, source: str, receiver: Any = nil) -> str:
        value = self.eval(source, receiver)
        return str(self.vm.send(value, "printString", []))

    def print_string(self, value: Any) -> str:
        return str(self.vm.send(value, "printString", []))

    # --- class / method definition ---

    def define_class(
        self,
        name: str,
        superclass: str = "Object",
        instance_vars: list[str] | None = None,
    ) -> STClass:
        sup = self.vm.classes.get(superclass)
        if sup is None:
            raise ValueError(f"unknown superclass {superclass!r}")
        existing = self.vm.classes.get(name)
        if existing is not None:
            existing.superclass = sup
            existing.instance_variables = list(instance_vars or [])
            self.vm.flush_method_caches()
            return existing
        cls = STClass(
            name=name,
            superclass=sup,
            instance_variables=list(instance_vars or []),
        )
        self.vm.register_class(cls)
        return cls

    def define_method(
        self, class_name: str, source: str, class_side: bool = False
    ) -> CompiledMethod:
        cls = self.vm.classes.get(class_name)
        if cls is None:
            raise ValueError(f"unknown class {class_name!r}")
        node = parser.parse_method(source)
        method = compile_method(node, source)
        method.defined_in = cls
        if class_side:
            cls.class_methods[method.selector] = method
        else:
            cls.methods[method.selector] = method
            self.vm.note_override(cls, method.selector)
        self.vm.flush_method_caches()
        return method

    # --- convenience ---

    def classes(self) -> list[STClass]:
        return list(self.vm.classes.values())

    def describe(self, value: Any) -> str:
        return py_print(self.vm, value)
