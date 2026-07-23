# MinPython

A tiny subset of Python and a register bytecode VM for it, built as a target for
this repo's JIT experiments. Small enough to fit in a few files, but with the two
ingredients that make JIT compilation interesting: hot loops (`while`) and
data-dependent branches (`if`, short-circuit `and`/`or`).

## The language

    values      int, bool, str, list, None
    operators   + - * // % **,  & | ^ << >>,  unary - + ~ not,
                and / or (short-circuit),  == != < <= > >=  (incl. chains)
                +  also concatenates str / list;  x[i]  indexes str / list
    literals    integers, True/False, None, strings, [ ... ] lists
    statements  assignment, augmented assignment, expression-statement,
                if/elif/else, while, pass, break, continue,
                def, return, global
    calls       user-defined functions (recursion ok), builtins print() / len()

Deliberately absent: floats, dicts/sets/tuples, slicing, classes, closures over
locals, comprehensions, exceptions, imports. `/` raises on purpose.

`str` and `list` are **interpreter-only**: the JITs specialise on `int`, so a
trace guards int-ness (`str`/`list` operands abort the trace / deopt) and a
function that touches an object type stays interpreted. The int core is where
every value is a machine int (bool *is* an int) -- the invariant that keeps the
compilers tractable.

## Pieces

| file | what | role |
|------|------|------|
| `compile.py` + `bytecode.py` | AST → register bytecode | the JIT front end |
| `vm.py` | register bytecode VM | the JIT **substrate** |
| `_dispatch.pyx` | optional Cython port of the dispatch loop | ~8× faster baseline |
| `jit/` | LuaJIT-shaped tracing JIT over the VM | native code for hot **loops** |
| `jit/method.py` | method (function) JIT over the VM | native code for hot **functions** (recursion) |

The register VM is the ground truth; tests assert the VM's output against
hand-written expectations, and every JIT/backend is then checked against the VM
differentially. The register VM is also the thing the tracing JIT observes and
compiles.

> 詳しい設計解説（バイトコード / IR / 各アルゴリズム）は
> [`docs/jit.md`](../docs/jit.md)（日本語）にあります。

### Why a register VM (not a stack VM)

Every instruction names the registers it reads and writes, so `x = a + b` is one
`ADD dst, a, b`. Two payoffs for the JIT: a recorded trace of register ops maps
almost one-to-one onto the x86-64 integer instructions in this repo's
`jit.Assembler` (no stack shuffling to see through), and traces come out shorter
(no push/pop noise), so there's less to compile. Registers are a flat file per
function: locals low, temporaries above. Instructions are `(op, a, b, c)`
tuples -- a C-friendly shape for the planned Cythonisation of `vm.py`'s dispatch
loop.

## Run

```sh
uv run python -m minpython minpython/examples/collatz.mpy         # on the VM
uv run python -m minpython --jit  minpython/examples/collatz.mpy  # tracing JIT
uv run python -m minpython --dis  minpython/examples/collatz.mpy  # disassemble
uv run python -m minpython --loops minpython/examples/collatz.mpy # hot loops
uv run python -m minpython.examples.bench_jit                     # benchmark
```

```py
from minpython import VM, compile_module, disassemble
vm = VM()
vm.run("def sq(x):\n    return x * x\nprint(sq(9))")   # -> 81
print(disassemble(compile_module("...")))              # human-readable bytecode
```

## Tracing-JIT hooks (why the VM is shaped this way)

The back-edge of every `while` is an unconditional `JUMP` to a lower pc -- the
only place a loop is re-entered, so the natural profiling anchor. `vm.py`'s
dispatch loop does two things there:

- **Hotness.** `vm.loop_counts[(id(code), target_pc)]` counts how often each
  back-edge is taken. On collatz(1000) the inner loop shows ~60k vs ~1k for the
  outer: an obvious compile candidate.
- **A hook.** `vm.on_backedge = fn` calls `fn(code, target, regs, globals)` at
  each back-edge. The base VM only counts; a tracer overrides this to threshold
  on the count, record a linear trace of the ops the body runs (a guard per
  branch taken), compile it via `jit.Assembler` → `jit.Runtime`, and on later
  entries dispatch straight into the native code -- returning a value to resume
  the frame with, or `None` to keep interpreting. `test_vm.py` exercises the
  resume path with a stub hook.

## The tracing JIT (`jit/`)

A LuaJIT-shaped tracing JIT is attached through exactly the `on_backedge` seam
above:

```py
from minpython import VM
from minpython.jit import TracingJIT
vm = VM()
jit = TracingJIT(vm, threshold=50)
vm.run(source)
print(jit.stats())   # {'compiled': .., 'aborted': .., 'trace_runs': ..}
```

The whole tracing JIT lives in one module, `jit/tracing.py`, as a pipeline
(data flows top to bottom):

| section of `jit/tracing.py` | what |
|------|------|
| IR | linear **SSA** trace IR: integer value ops, guards, snapshots |
| recorder (`record`) | run one loop iteration, emit IR + a guard per branch |
| codegen (`compile_trace`) | lower the IR to x86-64 via `jit.Assembler` / `jit.Runtime`, allocating registers with `jit/regalloc.py`'s shared `linear_scan` |
| driver (`TracingJIT`) | hot counters, trace cache, blacklist, side traces, dispatch |

(`jit/regalloc.py` is the linear-scan core shared with the method JIT; each
builds its own live intervals and calls `linear_scan`.)

The state machine per back-edge: cold → (hits ≥ threshold) → **record** →
compile+cache+run, or **abort** → blacklist and keep interpreting. A cached
trace loops in native code until a **guard** fails, at which point its
**snapshot** restores the VM's local registers and the JIT returns the pc to
resume the interpreter at. Every value in a trace is a 64-bit int, so guards are
control-flow guards (which branch was taken), not type guards -- a simplification
MinPython's int-only design buys us over LuaJIT.

Correctness is independent of the JIT: anything it can't compile (calls,
globals, `//`/`%`/`**`, nested loops) aborts the trace and stays interpreted, so
results always equal the pure VM's. `tests/test_trace.py` checks this
differentially.

Speed today (`bench_jit`, vs the pure-Python VM): straight-line loops ~**2000-2600x**;
collatz ~**5.5x** (its parity flips now stay in native code via linked side
traces; the residual cost is the Python-level chain between them). The optional
Cython dispatch loop (`VM(cython=True)`) is a ~**8x** faster interpreter baseline
on its own.

### Register allocation

`regalloc.py` is textbook linear scan over the trace's SSA values. A trace is a
loop, so anything that must survive between iterations -- a live-in phi, a
loop-carried result, a value some guard's snapshot needs -- gets the interval
`[0, N]` and stays in a register (or spill slot) for the whole loop; short-lived
intermediates free their register at last use. Under pressure the
furthest-last-use value spills to a buffer slot, which codegen reads straight out
of memory (x86 allows one memory operand). Constants are rematerialised as
immediates, so they cost no register. The buffer is now touched only at the
prologue (load live-ins) and at guard exits (write the snapshot) -- values live
in registers across the loop, which is where the ~2x over the memory-form
version came from.

Codegen quality: the two-address peephole computes in place when the
destination reuses an operand's register, and back-edge phi moves are a register
parallel-move (buffer-staged only for genuine swap cycles). **LICM** (`tracing.py`'s
`loop_invariants`) hoists invariant value ops to a preheader that runs once.
**Side traces** (`jit/tracing.py`): a hot guard exit gets its own trace recorded
from the exit to the loop header and linked in, so data-dependent branches stay
in native code across the flip.

Remaining ideas: native trace-to-trace linking (patch the parent exit stub to
`jmp` the side trace, removing the Python chain hop); trace trees / more of a
side-trace fabric; and giving the Cython dispatch `cdef long` registers (which
would also make the interpreter's overflow behaviour match the JIT's fixed
64-bit registers -- today both keep Python bignum semantics).

## The method JIT (`jit/method.py`)

The tracing JIT only fires on hot `while` back-edges, so a function with no loop
-- above all a recursive one like `fib_rec` -- never gets native code. The
**method JIT** fills that gap: when a function is *called* often enough it
compiles the whole function, both arms of every branch, to machine code, with
recursion becoming native `call`s.

```py
from minpython import VM
from minpython.jit import MethodJIT
vm = VM()
mj = MethodJIT(vm, threshold=10)      # installs vm.on_call
vm.run(source)
```

It hangs off a second VM seam, `on_call` (in `_call`): `(callee, regs,
arg_base, argc) -> (handled, value)`. Like the traces it is int-specialised,
with an entry type-guard (the arguments must be ints) at the interpreter →
native boundary; inside, every value is an int so no further guards are needed.
`fib(33)` runs ~**1000×** the pure VM.

Register allocation is textbook linear scan again, but over the *function's VM
registers* across its control-flow graph (backward-dataflow liveness; the
function is loop-free -- loops are the tracing JIT's job -- so it is a DAG that
converges in a couple of passes). Two things make it simple:

- **The pool is callee-saved** (RBX, R12–R15). A value in one survives the
  native `call` a recursive function makes, so there is no save/restore dance
  around call sites -- just push them once in the prologue. Spill to the stack
  frame under pressure.
- **One machine location per VM register** for the whole function, so branch
  joins need no phi moves -- the value is in the same place on every path.

v1 stays inside the int subset and aborts (leaving the function to the
interpreter) on: loops, globals/print, `//`/`%`/`**`, any call that isn't direct
self-recursion, or more than six parameters. Mutual recursion and calls to other
compiled functions -- a compiled-function registry with direct native links --
are the natural next step.

## Baseline (stencil) JIT + tiering + background compilation (`jit/stencil.py`, `tiered.py`)

The method JIT is the *optimizing* tier. Below it sit two **baseline** compilers
that build code by stitching pre-built per-opcode machine-code *stencils* and
*patching* in the actual operands, so compilation is little more than `memcpy` +
a few field writes. (This stitch-and-patch technique is "copy-and-patch" in the
literature -- what CPython 3.13's JIT does.)

- **`stencil.py`** compiles its stencils from C, the robust way: each value op is
  a **C template**, compiled once by the C compiler; its machine code and its
  **relocations** are read straight out of the object file (a small ELF64
  parser), and the relocations *are* the hole descriptors -- no fragile scanning.
  The frame pointer is pinned to `rbx` (callee-saved, survives recursive calls)
  via a GCC global register variable, so `A = B + C` compiles to
  `mov/add [rbx+disp32]` with an `R_X86_64_32S` relocation on each disp -- that
  disp32 is the hole, patched with the real slot offset. (Clang rejects the
  rbx-global-register trick, so this path needs GCC/`cc`; CPython instead threads
  the frame through tail-call arguments, which needs Clang's `musttail`.)
- **`patch.py`** is the toolchain-free sibling: it hand-assembles each stencil
  with recognisable *sentinel* operands and scans the bytes to find the holes.
  It is the fallback tier-1 when no C compiler is available.

**`TieredJIT`** ties it together and adds **background compilation**:

```py
from minpython.jit import TieredJIT
TieredJIT(vm, tier1_threshold=10, tier2_threshold=500, background=True)
```

tier 1 = baseline stencils (fast to compile), tier 2 = register allocation (fast to
run), and both are compiled on a **worker thread**: on hotness the driver submits
a compile job and *keeps interpreting*, installing the native code under a lock
when it's ready. On free-threaded 3.14 that compile runs in parallel with the
interpreter. Measured trade-off (tiny fib): baseline stencils compile ~1.5× faster,
register allocation runs ~1.2× faster -- the gap widens with function size.

(Footgun worth knowing: a compiled function's code lives in the `Runtime`'s
executable pages, so the `Runtime` must outlive the callable -- the drivers hold
`self.rt`; a throwaway `Runtime()` gets collected and its pages unmapped.)
