"""The MinPython JITs: native-code backends over the register VM.

Two complementary compilers, each hanging off its own VM hook:

  * `TracingJIT` -- a LuaJIT-shaped *tracing* JIT for hot `while` loops. Records
    a linear trace of a hot loop iteration (guarding every branch), compiles it
    to x86-64, and links side traces for hot guard exits. Fires on back-edges.

  * `MethodJIT` -- a *method* JIT for hot (non-loop) functions, recursion
    included -- the case tracing can't reach. Compiles a whole function's
    control-flow graph with linear-scan register allocation. Fires on calls.

The tracing-JIT internals (in data-flow order): `ir` (SSA trace IR) ->
`recorder` (record a hot iteration) -> `regalloc` (linear scan) -> `codegen`
(lower to x86-64) -> `tracing` (the driver). The method JIT is self-contained in
`method`. Both lower through this repo's top-level `jit` assembler package.

    from minpython import VM
    from minpython.jit import TracingJIT, MethodJIT
    vm = VM()
    TracingJIT(vm, threshold=50)     # hot loops -> native
    MethodJIT(vm, threshold=10)      # hot functions -> native
    vm.run(source)
"""

from .method import MethodJIT
from .tiered import TieredJIT
from .tracing import TracingJIT

__all__ = ["TracingJIT", "MethodJIT", "TieredJIT"]
