# WolverineML

A small ML-flavoured language, compiled to ARMv8 (AArch64), in Python. The
language is Tiger's — records, arrays, nested functions with static links,
loops with `break` — written the way SML writes things. The back end is the
point: the compiler builds SSA the textbook way, optimises there, and then
allocates registers **two different ways**, over the same IR, so that the two
can be held next to each other — by colouring the SSA itself in dominance
order, and by leaving SSA first and colouring the interference graph with
iterated coalescing.

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
uv run pytest                     # 144 tests
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
| `--regalloc chordal\|graph` | which allocator; `chordal` is the default |
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
                                             │
                          out of SSA first, if the allocator wants a graph
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
| `outofssa.py` | phis become copies in the predecessors, for the allocator that wants that |
| `machine.py` | the register file, and which registers a call may clobber |
| `allocator/chordal.py` | colouring the SSA in dominance order, no graph |
| `allocator/graph.py` | Chaitin's algorithm with iterated coalescing |
| `allocator/spill.py` | the rewrite both of them spill with, and what a spill costs |
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

Why the graph is chordal is one theorem away. In SSA a value's definition
dominates its whole live range, so a live range is a subtree of the dominator
tree — and by Gavril's theorem a graph is chordal exactly when it is the
intersection graph of subtrees of a tree. That is the only thing SSA is doing
here: `x := a` in one branch and `x := b` in the other is a live range that is
not a subtree, and a phi is what cuts it into two that are. The allocator is
Hack, Grund and Goos (CC 2006); Pereira and Palsberg (APLAS 2005) reached the
same graphs and coloured them with an explicit chordal colouring instead.
Linear scan is the same idea one level down: flatten the tree into a line, and
subtrees become intervals.

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
  edges disappear. It is also the weak point: a graph-colouring allocator can
  *merge* two nodes and re-test, which is what iterated coalescing does with
  Briggs' and George's tests, and merging two values is precisely what SSA does
  not allow. Coalescing by recolouring (Hack and Goos, PLDI 2008) is the answer
  to that, and it is not implemented here — the other allocator is.
* **The calling convention.** A value that is live across a call may only take
  a callee-saved register, which is why nothing has to be saved around a `bl`.
  Argument and result positions are hints, so a value that is about to be
  argument 2 tends to be sitting in `x2` already.

`x0`–`x16` and `x19`–`x28` are allocatable, twenty-seven registers. Only `x17`
is held back, and only for one thing: a frame big enough to put a slot out of
reach of `ldur` is not known until allocation has added its spill slots, so
that address has to be computed somewhere the allocator was never told about.
Everything else that used to want a scratch register was given a way not to —
a remainder is spelled out in the IR, where its quotient is a value like any
other, and the prologue borrows a caller-saved register that nothing is live
in yet. `--max-regs N` shrinks the machine, and the test suite runs the whole
example set at `N = 12` to exercise the spiller.

### The other one: graph colouring, `--regalloc graph`

Chaitin's algorithm, with the iterated coalescing of George and Appel (1996).
The interference graph is built for real this time; a node with fewer than `K`
neighbours is removed and pushed on a stack, because Kempe says it can always
be coloured later; when nothing is trivially removable one node is pushed
optimistically, and if the guess was wrong that value is rewritten into memory
and the whole thing runs again.

For this allocator the phis have to go first, so `outofssa.py` turns each one
into copies at the ends of its predecessors. That is not a cost to be sorry
about — it is the point. Copies are what coalescing eats: merging the two ends
of one removes it, and a merge only happens when Briggs' test proves it cannot
make the graph uncolourable. Because merging raises degrees and simplifying
lowers them, each making the other possible, the two run interleaved, with
freezing as the way out.

This machine has no fixed registers to colour against — the ABI is handled by
the emitter — so the call convention rides along as a set of colours a node may
not take, and a node with `f` of those and `d` neighbours needs `d + f < K`.
That sum stands in for the degree in every test.

The two are worth comparing, and the answer is that they are level:

| | instructions | `mov`s |
| --- | --- | --- |
| `chordal`, over the examples and test programs | 3288 | 421 |
| `graph` | 3286 | 420 |

`graph` is ahead on the bigger programs (`queens` 359 → 352, `sort` 546 → 540)
and behind on the small ones, and the reason for both is the same: leaving SSA
made copies that were never there before, and coalescing has to earn them back.
It earns back 96–100% of them — of the 30 copies that leaving SSA adds to
`tour`, one survives. What is left in the output of *either* allocator is
almost entirely the ABI copies, and those are made by the emitter, where no
allocator can see them.

### Leaving SSA, for the allocator that stays in it

Critical edges are split first — and so is any edge into a block that still has
a phi — so every phi becomes a parallel copy at the end of a block that ends in
a jump. The copies are then ordered so that nothing is overwritten before it is
read. When they form a cycle the ordering borrows a register the function never
used, and when the function used them all the two ends swap with three `eor`s,
which needs no register at all.

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
escape analysis, and for the ordering of a parallel copy — which is checked by
running the ordering on a register file and insisting the permutation came out
right, a test that caught a swap the ordering was doing twice.

Structural tests for the middle. After construction and after every
optimisation, `ssa.verify` insists on one definition per register, that each
definition dominates its uses, and that it reaches each phi through the edge
that names it. `allocator.verify` insists that no two values live at the same
point share a colour, and every test that says so runs against both allocators.

And end-to-end tests, which compile six programs to ARMv8, link them against
the runtime, run them under qemu, and compare the output — under eight
configurations each, because `--no-opt`, `--no-checks`, a machine small enough
to spill, and both allocators all have to agree on the answer.

## What it does not do

No garbage collector, no first-class functions or closures (a function is not a
value, as in Tiger), no floating point, no modules, no polymorphism. The
optimiser is local: no loop-invariant hoisting, no common subexpression
elimination, no inlining. Integers are 64-bit and wrap.
