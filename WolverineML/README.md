# WolverineML

A small ML-flavoured language, compiled to ARMv8 (AArch64), in Python. The
language is Tiger's — records, arrays, nested functions with static links,
loops with `break` — written the way SML writes things. The back end is the
point: the compiler builds SSA the textbook way, optimises there, chooses
instructions by covering a **DAG** of each block with the things ARM can do in
one, and then allocates registers **two different ways** over the same IR, so
that the two can be held next to each other — by colouring the SSA itself in
dominance order, and by leaving SSA first and colouring the interference graph
with iterated coalescing.

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
$ cd python
$ uv run python -m wolv run examples/tour.wol
$ uv run python -m wolv build examples/queens.wol -o queens && qemu-aarch64 ./queens
```

The book is in [`doc/`](doc/index.md), a chapter per pass, in Japanese, with
every dump in it taken from an actual run. Two to start with:
[パイプライン](doc/00-pipeline.md) と
[レジスタ割り当て(1) 支配木彩色](doc/07-chordal.md)。

The grammar on its own, apart from the book, is
[`spec/grammar.md`](spec/grammar.md): the tokens and an EBNF, and the same
thing again as LALR(1) productions with a precedence table, so that a parser
can be written from it with yacc, bison, menhir or ocamlyacc rather than by
hand.

## The compilers

[`python/`](python) holds the one this file describes, and the one the book is
written about: both allocators are here, and so is everything the chapters dump.

[`kotlin/`](kotlin), [`go/`](go), [`ocaml/`](ocaml), [`typescript/`](typescript),
[`haxe/`](haxe), [`racket/`](racket), [`ruby/`](ruby), [`haskell/`](haskell),
[`lisp/`](lisp), [`prolog/`](prolog), [`guile/`](guile) and
[`clojure/`](clojure) hold the same compiler written again, each described in a
README of its own. They carry one allocator — the graph — because the
comparison the other one exists for is made in the Python tree. Every other
stage is the same pass over the same shapes, and for every example and test
program in every configuration, every stage dumps the same bytes out of any of
the thirteen, the assembly included.

None of the twelve is a transliteration. Each says the same thing the way its
own language says things — a sealed hierarchy and one exhaustive `when` per
question in Kotlin, variants with mutable inline records in OCaml, a flat
package and a type switch in Go, a discriminated union in TypeScript, an
immutable `enum` and pure rewriting in Haxe, immutable structs and prefixed
modules in Racket, `Data` for an instruction and `Struct` for the tree in Ruby,
in Haskell a checker that answers with a second tree because it cannot write on
the first, in Common Lisp two macros, one that writes the instruction protocol
and one that writes a pass over the tree from a table of clauses, in Prolog
three grammars, a syntax tree whose type fields are logic variables the checker
binds, and case analysis that lives in the clause heads, in Guile a GOOPS class
per node and a generic function per question, so the answer lives next to the
thing it is about, and in Clojure nothing declared at all — an instruction is a
map with an `:op`, the passes are multimethods over it, and every pass is
`func -> func` over a persistent graph — and the READMEs are largely about where
those choices led.

`compare.sh` is what checks that claim: `./compare.sh lisp/bin/wolv` runs the
ten stages over ten programs in four configurations and diffs every one of the
400 dumps against `python --regalloc graph`.

| | allocators | how it is built |
| --- | --- | --- |
| [`python/`](python) | both | `uv run pytest` |
| [`kotlin/`](kotlin) | graph | `./gradlew test` |
| [`go/`](go) | graph | `go test ./...` |
| [`ocaml/`](ocaml) | graph | `dune test` |
| [`typescript/`](typescript) | graph | `npm test` |
| [`haxe/`](haxe) | graph | `haxe test.hxml && neko bin/test.n` |
| [`racket/`](racket) | graph | `raco test test/` |
| [`ruby/`](ruby) | graph | `rake` |
| [`haskell/`](haskell) | graph | `cabal test` |
| [`lisp/`](lisp) | graph | `./run-tests.sh` |
| [`prolog/`](prolog) | graph | `./run-tests.sh` |
| [`guile/`](guile) | graph | `./run-tests.sh` |
| [`clojure/`](clojure) | graph | `./run-tests.sh` |

## Build and run

```sh
cd python
uv sync
uv run pytest                     # 183 tests
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
      ──ssa──▶ SSA ──opt──▶ SSA ──split──▶ ──select──▶ machine IR
                                                  │
                                                  ├─ out of SSA, for the graph
                                                  ▼
                                    ──regalloc──▶ coloured ──emit──▶ ARMv8
```

| module | what it does |
| --- | --- |
| `lexer.py` | one pass, no regexes; nested `(* *)`, `\ddd` escapes |
| `parser.py` | a Pratt parser: one precedence table, prefix forms take their tail at binding power 0 |
| `types.py`, `typecheck.py` | monomorphic checking, and escape analysis on the side |
| `ir.py` | the three-address IR, and the graph and frame both IRs are written in |
| `lower.py` | tree → CFG; decides which variables live in registers and which in the frame |
| `ssa.py` | dominators, dominance frontiers, phi placement, renaming, and a verifier |
| `opt.py` | constant folding, copy propagation, phi simplification, branch folding, dead code |
| `liveness.py` | liveness on SSA, where a phi reads its arguments on the edges |
| `mach.py` | the machine IR: one instruction, a table of forms, and what may no longer appear |
| `dag.py` | one block as a graph of expressions, and which nodes may be folded |
| `select.py` | covering that graph with instructions: `madd`, shifted operands, addressing modes |
| `outofssa.py` | phis become copies in the predecessors, for the allocator that wants that |
| `registers.py` | the register file, and which registers a call may clobber |
| `allocator/chordal.py` | colouring the SSA in dominance order, no graph |
| `allocator/graph.py` | Chaitin's algorithm with iterated coalescing |
| `allocator/spill.py` | the rewrite both of them spill with, and what a spill costs |
| `allocator/hints.py` | which colour a value would like, which both of them ask |
| `copies.py` | putting a permutation of registers into a sequence of instructions |
| `emit.py` | frames, the copies a phi turns into, and one line per instruction |
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
    %2:9 = const #0
    %4:0 = const #0
    jmp test1
test1:  ; preds: entry, body2
    %12:9 = phi [entry: %2:9, body2: %9:9]
    %13:0 = phi [entry: %4:0, body2: %7:0]
    cmp %12:9, %1:1
    br lt? body2 : done3
body2:  ; preds: test1
    %7:0 = add %13:0, %12:9
    %9:9 = addi %12:9, #1
    jmp test1
done3:  ; preds: test1
    ret %13:0
```

`%12:9` is virtual register 12, coloured `x9`. Every argument of each phi ended
up the same colour as the phi itself, so both copies on the back edge cost
nothing; the comparison sets the flags the branch reads, so it needs no
register; the 1 became an immediate rather than a value; and the loop comes out
as three instructions:

```
.Lwol_count_test1:
	cmp x9, x1
	b.ge .Lwol_count_done3
.Lwol_count_body2:
	add x0, x0, x9
	add x9, x9, #1
	b .Lwol_count_test1
```

### The machine IR, chosen off a DAG

An instruction is chosen where the whole expression is visible, not by looking
at the line before. Each block is read into a graph — a node per instruction,
an edge per operand — and the selector covers that graph with the things this
machine can do in one instruction:

    a + b * c            madd
    a - b * c            msub
    a + (b << k)         add with a shifted operand
    a * 8                lsl
    a + 4095             add with an immediate
    [a + 24]             a load with a displacement
    a < b, then branch   cmp, and a branch on the flags it set

```
$ uv run python -m wolv emit -s dag --no-checks loop.wol
body2:
    0*  %7 = %13 + %12                         reads [-, -]  users 0
    1   %8 = 1                                 reads []  users 1
    2*  %9 = %12 + %8                          reads [-, 1]  users 0
    3!  jmp test1                              reads []  users 0
```

`*` is a value the block does not keep to itself and `!` is one that has to
happen whether or not anything reads it; `reads` names the nodes an operand
comes from, and `-` is a value from somewhere else. So node 1 has one reader
and node 2 is the only one — which is what lets the 1 disappear into an `addi`.

The two instruction sets are two modules. `ir.py` has the three-address one —
what lowering writes, what SSA construction renames, what the optimiser
rewrites — and `mach.py` has the machine one. What they share is everything
that is not an instruction: the registers, the blocks, the graph, the frame.
Each instruction answers for itself which register it writes and which it
reads, so liveness, both allocators and the verifiers work on either level
without knowing what an `madd` is, and the program is still in SSA after
selection — a tile defines one new register. `mach.verify` says what may no
longer appear once selection has run, so an abstract instruction that survived
is caught there rather than in the emitter. `wolv emit -s mach` shows the
result.

The rule about folding is the whole of the difficulty. A node with one reader
*can* be computed where it is read rather than where it was written — but only
if the reader's instruction actually swallows it. Deferring one on the chance
that it will be swallowed is how `a + b + c + d + ...` ends up computed on its
last line, with every term alive until then: measured, that cost a 40-term sum
about fifty instructions of spilling. So the selector plans first, asking of
each node whether its reader has a tile with room for it, and everything else
is computed where it was written. Constants are the exception in the other
direction: repeating one is free, so any number of readers may take it as an
immediate, and it becomes an instruction only if somebody needs it in a
register.

Selection is worth about 2% of the code, and the same in both allocators:

| | instructions |
| --- | --- |
| before, with peepholes in the emitter | 3288 |
| after, chosen off the DAG | 3225 |

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

The two are worth comparing:

| | instructions | `mov`s |
| --- | --- | --- |
| `chordal`, over the examples and test programs | 3275 | 425 |
| `graph` | 3249 | 399 |

`graph` is ahead on every program and further ahead on the big ones (`queens`
348 → 341, `sort` 534 → 528), and what it is ahead by is copies: 26 of the 26
instructions between them are `mov`s that coalescing removed and biased
colouring could not. That it is ahead *at all* is the interesting part, because
leaving SSA makes copies that were never there before and coalescing has to
earn them back first — it earns back 96–100% of them, and of the 30 that
leaving SSA adds to `tour`, one survives.

What neither can touch is the ABI copies, which the emitter makes on its own at
a call, where no allocator can see them.

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
that names it. `allocator.verify` insists that no two values holding different
things at once share a colour, and every test that says so runs against both
allocators.

"Different things" is the load-bearing half. Both ends of a copy are live after
it and hold the same value, which is exactly what coalescing gives them one
register for, so the check is made where the interference graph draws an edge —
at each definition — and not over a whole live set. Reading the set instead
rejects `queens` under `--no-opt`, where `%156` and `%157` are a copy apart and
both in `x19`.

And end-to-end tests, which compile seven programs to ARMv8, link them against
the runtime, run them under qemu, and compare the output — under eight
configurations each, because `--no-opt`, `--no-checks`, a machine small enough
to spill, and both allocators all have to agree on the answer.

Agreeing with each other is not the same as being right, though, so the last
lot generate a program at random, work out in Python what it should print, and
then compile it: expressions over the arithmetic this language has, and
programs of assignments, loops and branches over an array. Those found nothing,
which is the point of writing them down — but the harness that runs them
against thousands of programs at a time did find that two of the selector's
tiles could never be reached, and they are gone.

## What it does not do

No garbage collector, no first-class functions or closures (a function is not a
value, as in Tiger), no floating point, no modules, no polymorphism. The
optimiser is local: no loop-invariant hoisting, no common subexpression
elimination, no inlining. Integers are 64-bit and wrap.
