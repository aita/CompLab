"""A tiny x86-64 JIT assembler experiment."""

from . import operands
from .aot import (ToolchainError, build_executable, build_object,
                  build_shared, gas_source, have_toolchain, load)
from .assembler import (Assembler, Label, ObjectCode, Reloc, RelocKind, Symbol,
                        TraceInsn, TraceLabel)
from .disasm import Insn, disasm, disassemble
from .operands import *  # noqa: F401,F403  (register constants + Reg/Xmm/Mem)
from .operands import Mem, Reg, Xmm
from .runtime import JITAllocator, Runtime, Span

__all__ = ["Assembler", "Label", "ObjectCode", "Reloc", "RelocKind", "Symbol",
           "TraceInsn", "TraceLabel",
           "Runtime", "JITAllocator", "Span", "Reg", "Xmm", "Mem",
           "disasm", "disassemble", "Insn",
           "gas_source", "ToolchainError", "have_toolchain",
           "load", "build_object", "build_shared", "build_executable"]
# Everything operands exports (Reg/Xmm/Mem, the size helpers, and every register
# constant) is re-exported from here too; `+=` on another module's __all__ is
# the one composition form type checkers understand.
__all__ += operands.__all__
