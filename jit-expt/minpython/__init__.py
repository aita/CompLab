"""MinPython: a tiny Python subset built as a target for this repo's JIT
experiments.

`compile_module` lowers source to register bytecode; `VM` runs it (see
`minpython.jit` for the tracing / method / tiered JITs over it); `disassemble`
renders the bytecode."""

from .bytecode import (CodeObject, Instr, MinPythonError, Op, Value,
                       disassemble)
from .compile import compile_module
from .vm import VM

__all__ = ["VM", "compile_module", "disassemble", "CodeObject", "Instr", "Op",
           "MinPythonError", "Value"]
