# WolverineML

A small ML-flavoured language, compiled to ARMv8 (AArch64), in Python. The
language is Tiger's — records, arrays, nested functions with static links,
loops with `break` — written the way SML writes things. The back end is the
point: the compiler builds SSA the textbook way, optimises there, and allocates
registers **on** SSA, colouring in dominance order instead of building an
interference graph.

```sml
type point = { x : int, y : int }

fun gcd (a : int, b : int) : int =
  if b = 0 then a else gcd (b, a mod b)

fun sumTo (n : int) : int =
  let var i = 0
      var total = 0
  in
    while i <= n do (total := total + i; i := i + 1);
    total
  end

val p = point { x = 3, y = 4 }
val () = print (intToString (gcd (84, 36)) ^ " " ^ intToString (sumTo (100)) ^ "\n")
```

```
$ uv run python -m wolv run examples/tour.wol
$ uv run python -m wolv build examples/queens.wol -o queens && qemu-aarch64 ./queens
```

## Build and run

```sh
uv sync
uv run pytest                     # 102 tests
uv run mypy                       # every module is strictly typed
uv run ruff check .

uv run python -m wolv run     prog.wol      # compile, link, and run it
uv run python -m wolv build   prog.wol -o prog
uv run python -m wolv check   prog.wol      # types only
uv run python -m wolv emit -s ssa prog.wol  # dump a stage
```

Assembling and linking is a cross `gcc` (`aarch64-linux-gnu-gcc`, or `$WOLV_CC`),
and running is `qemu-aarch64` unless the machine is already an ARM. Without
them everything up to `emit` still works, and the tests that need a toolchain
skip.

| flag | what it does |
| --- | --- |
| `--no-checks` | leave out the nil, bounds and divide-by-zero checks |
| `--no-opt` | skip the SSA optimiser |
| `--max-regs N` | pretend the machine has N registers, to make it spill |

## The language

Monomorphic, statically typed, and about the size of Tiger. The syntax is SML's
as far as it goes; where Tiger's semantics need something SML has no word for —
assignable variables, `for`, `break`, field assignment — it takes Tiger's.

**Types.** `int`, `string`, `bool`, `unit`, `t array`, and records declared by
name. Records are nominal: two record types with the same fields are different
types. `nil` belongs to every record type and to no other.

```sml
type point = { x : int, y : int }
type ints  = int array
type tree  = { key : int, left : tree, right : tree }   (* recursive *)
type a = b array and b = { next : a }                   (* mutually recursive *)
```

**Declarations.** `val` binds, `var` binds something assignable, `fun` declares
a function, and `and` joins a group that may recurse into itself. Declarations
appear at the top of the file or inside `let`, and a function declared inside
another may read the variables around it.

```sml
val answer = 42
var counter = 0
fun square (n : int) : int = n * n         (* a function returns its result type *)
fun greet (who : string) = print (who)     (* no result type means unit *)
fun even (n : int) : bool = if n = 0 then true else odd (n - 1)
and odd  (n : int) : bool = if n = 0 then false else even (n - 1)
```

A parameter is always annotated, and a `fun` without a result type is a
procedure returning `unit`. That is what makes recursion checkable with no
inference at all: every signature is known before any body is read.

**Expressions.**

| form | notes |
| --- | --- |
| `1`, `"text"`, `true`, `nil`, `()` | `~n` negates |
| `a + b`, `a mod b`, `a ^ b` | `/` and `mod` truncate towards zero |
| `a = b`, `a < b`, `a andalso b`, `not (a)` | strings compare by content, records by identity |
| `if c then a else b` | with no `else` the branch is `unit` |
| `while c do e`, `for i = a to b do e`, `break` | `for` binds an immutable `i` |
| `let ... in e1; e2 end`, `(e1; e2)` | a sequence is the value of its last expression |
| `point { x = 1, y = 2 }` | fields may be given in any order |
| `r.x`, `a[i]`, `x := e` | any of the three can be assigned to |
| `array (n, init)`, `length (a)` | the element type comes from `init` |

**The standard library** is `print`, `println`, `printInt`, `flush`, `getChar`,
`ord`, `chr`, `size`, `substring`, `concat`, `intToString`, `stringToInt`,
`not`, `exit`, `array`, `length`.

A string is a sequence of bytes, so `size` and `substring` count bytes: a
literal contributes the UTF-8 of the source text, and `\ddd` names one byte of
it directly.

A program is a sequence of declarations, run in order; there is no `main`.

## The pipeline

```
 .wol ──lex──▶ tokens ──parse──▶ tree ──check──▶ typed tree ──lower──▶ CFG
      ──ssa──▶ SSA ──opt──▶ SSA ──split──▶ ──regalloc──▶ coloured ──emit──▶ ARMv8
```

| module | what it does |
| --- | --- |
| `lexer.py` | one pass, no regexes; nested `(* *)`, `\ddd` escapes |
| `parser.py` | a Pratt parser: one precedence table, prefix forms take their tail at binding power 0 |
| `types.py`, `typecheck.py` | monomorphic checking, and escape analysis on the side |
| `ir.py` | a CFG of three-address code over virtual registers |
| `lower.py` | tree → CFG; decides which variables live in registers and which in the frame |
| `ssa.py` | dominators, dominance frontiers, phi placement, renaming, and a verifier |
| `opt.py` | constant folding, copy propagation, phi simplification, branch folding, dead code |
| `liveness.py` | liveness on SSA, where a phi reads its arguments on the edges |
| `regalloc.py` | colouring in dominance order, spilling, coalescing by biased colouring |
| `emit.py` | AAPCS64 assembly, frames, and the copies a phi turns into |
| `runtime/runtime.c` | allocation, strings, and the errors a check can raise |

### Lowering never builds a phi

A variable assigned in two branches is simply written twice, to the same
register. Making one definition of that is SSA's job, not lowering's.

Lowering does decide where a variable lives. The checker marks a variable as
escaping when a more deeply nested function reads it; those get a frame slot
and are reached through `LoadSlot`/`StoreSlot`, or through a chain of static
links from inside. Everything else is a register, and the allocator's problem.

### SSA, the textbook way

Dominators by the iterative algorithm of Cooper, Harvey and Kennedy, dominance
frontiers from those, a phi wherever the frontier says — minimal SSA, not
pruned — and one walk of the dominator tree to rename. Phis that turned out to
be dead leave in the optimiser. A register that lowering wrote only once is
already in SSA and keeps its name.

```
$ uv run python -m wolv emit -s ra --no-checks loop.wol
fun wol_count(%0:0, %1:1)  ; depth 1, 0 slots
entry:
    %2:9 = 0
    %4:0 = 0
    jmp test1
test1:  ; preds: entry, body2
    %12:9 = phi [entry: %2:9, body2: %9:9]
    %13:0 = phi [entry: %4:0, body2: %7:0]
    %6:10 = %12:9 < %1:1
    br %6:10 ? body2 : done3
body2:  ; preds: test1
    %7:0 = %13:0 + %12:9
    %8:10 = 1
    %9:9 = %12:9 + %8:10
    jmp test1
done3:  ; preds: test1
    ret %13:0
```

`%12:9` is virtual register 12, coloured `x9`. Every argument of each phi ended
up the same colour as the phi itself, so both copies on the back edge cost
nothing; `%8`, a constant every reader can take as an immediate, is never
materialised at all; and the loop comes out as three instructions:

```
.Lwol_count_test1:
	cmp x9, x1
	b.ge .Lwol_count_done3
.Lwol_count_body2:
	add x0, x0, x9
	add x9, x9, #1
	b .Lwol_count_test1
```

### Register allocation on SSA

The interference graph of an SSA program is chordal, and a preorder walk of the
dominator tree is a perfect elimination order for it. So there is no graph, no
simplify/select stack, and no iteration: colouring a function is one walk in
dominance order, holding the set of values that are live and giving every
definition a colour none of them has. If no program point has more than `k`
values live, `k` registers always suffice.

Three things ride along on that walk:

* **Spilling.** When a definition finds no colour free, the value that is read
  least is given a frame slot — a store after its single definition, a reload
  in front of each use — and the walk starts again. The rewrite keeps the
  function in SSA, because every reload is a definition of its own. Reloads are
  never spilled again, so it terminates; if nothing else is left to spill, the
  instruction wants more registers at once than the machine has, and the
  compiler says so instead of looping.
* **Coalescing.** A definition prefers a colour already given to something it
  is copy-related to — a phi and its arguments — and, failing that, the colour
  that thing is itself going to ask for. That is what makes the copies on the
  edges disappear.
* **The calling convention.** A value that is live across a call may only take
  a callee-saved register, which is why nothing has to be saved around a `bl`.
  Argument and result positions are hints, so a value that is about to be
  argument 2 tends to be sitting in `x2` already.

`x0`–`x15` and `x19`–`x28` are allocatable, twenty-six registers. `x16` and
`x17` are the ABI's scratch, which the emitter keeps for parallel copies, large
immediates and long offsets. `--max-regs N` shrinks the machine, and the test
suite runs the whole example set at `N = 12` to exercise the spiller.

### Leaving SSA

Critical edges are split first — and so is any edge into a block that still has
a phi — so every phi becomes a parallel copy at the end of a block that ends in
a jump. The copies are then ordered so that nothing is overwritten before it is
read, with `x16` breaking a cycle when the copies form one.

### Frames and calls

```
    x29 -> | saved x29, x30 |
           | slot 0         |  x29 - 8    a nested function's static link
           | slot 1         |  x29 - 16   escaping variables, then spills
           | ...            |
           | saved x19...   |
    sp  -> | outgoing args  |
```

A function nested inside another takes its parent's frame pointer as a hidden
first argument and keeps it in slot 0, so a variable `k` levels out is `k`
loads away. A function nobody nests inside, and that never looks outward, keeps
no static link at all. The ninth argument and beyond are already in the frame
when the callee starts — they are read where the caller left them, and never
take a register at entry.

There is no garbage collector: allocation is a bump pointer, and memory is
never given back.

## Tests

```sh
uv run pytest
```

Unit tests for the lexer, the parser's precedence, the checker's errors and its
escape analysis. Structural tests for the middle: after construction and after
every optimisation, `ssa.verify` insists on one definition per register and
that each definition dominates its uses and reaches each phi through the right
edge; `regalloc.verify` insists that no two values live at the same point share
a colour. And end-to-end tests, which compile five programs to ARMv8, link them
against the runtime, run them under qemu, and compare the output — under five
configurations each, because `--no-opt`, `--no-checks` and a machine small
enough to spill all have to agree on the answer.

## What it does not do

No garbage collector, no first-class functions or closures (a function is not a
value, as in Tiger), no floating point, no modules, no polymorphism. The
optimiser is local: no loop-invariant hoisting, no common subexpression
elimination, no inlining. Integers are 64-bit and wrap.
