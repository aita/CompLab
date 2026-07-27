# Sable

A compiler from an ML-like language to RISC-V (RV64I/M), written in OCaml.
Register allocation is by graph colouring.

```
dune build          # build the compiler
dune test           # compile, link and run every example under qemu
./sable examples/tour.sbl
```

`./sable` builds the program, links it against `runtime/sable_runtime.c` with
`riscv64-linux-gnu-gcc`, and runs it under `qemu-riscv64`. `./sable -S` prints
the assembly instead.

```
sablec [options] <file.sbl>
  -o <file>          write the assembly here (default: stdout)
  -nregs <n>         allocate out of n registers only (10..25, default 25)
  -O <n>             run the optimizer n times (default 3)
  --dump-anf     print the A-normalized program
  --dump-closure     print the closure-converted program
  --dump-riscv          print the RISC-V code before register allocation
  --dump-regalloc    report rounds, coalesced moves and spills per function
```

`-nregs` shrinks the machine on purpose. Every test runs twice, with 25
registers and with 10, and the two runs must agree — which is how the spiller
gets tested.

Two longer write-ups, in Japanese:

- [doc/pipeline.md](doc/pipeline.md) — 1本のプログラムが全パスを通り抜けるまでを、
  実際のダンプで追ったもの
- [doc/regalloc.md](doc/regalloc.md) — レジスタ割り付けの詳説。干渉グラフの実例、
  合体・スピル・callee-saved の扱い

## The language

A small ML. Functions take all their arguments at once (no currying), and `type`
declarations come before the program body.

```
type tree = Leaf | Node of tree * int * tree

let rec insert t x =
  match t with
  | Leaf -> Node (Leaf, x, Leaf)
  | Node (l, v, r) ->
      if x < v then Node (insert l x, v, r)
      else if x > v then Node (l, v, insert r x)
      else t
in
let rec walk t =
  match t with
  | Leaf -> ()
  | Node (l, v, r) -> (walk l; print_int v; print_char 32; walk r)
in
walk (insert (insert Leaf 2) 1); print_newline ()
```

| | |
|---|---|
| types | `int`, `bool`, `unit`, `string`, `'a list`, tuples, arrays, functions, `type t = A \| B of int * t` |
| binding | `let`, `let rec ... and ...`, `let (a, b) = e`, `fun x y -> e` |
| control | `if`/`then`/`else` (the `else` may be left out when the branch is `unit`), `e1; e2`, `begin`/`end` |
| matching | `match e with p -> e \| ...`, over literals, wildcards, variables, tuples, lists and constructors, nested |
| operators | `+ - * / mod`, `= <> < <= > >=`, `&& \|\| not`, unary `-`, `::`, `^` |
| lists | `[]`, `x :: xs`, `[a; b; c]`, and the same in patterns |
| strings | `"text"` with `\n \t \r \\ \"`, `String.length s`, `s.[i]`, `s1 ^ s2`, `String.equal` |
| arrays | `Array.make n init`, `a.(i)`, `a.(i) <- e` |
| runtime | `print_int`, `print_char`, `print_string`, `print_newline`, `read_int` |

Type inference is Hindley–Milner with let-polymorphism, generalized by levels.
One compiled `length` serves `int list`, `string list` and `int list list`: every
value is one machine word, so a function that never looks inside its elements
does not care what they are, and no specialization is needed. Only syntactic
values are generalized — the usual value restriction, without which a
polymorphic value held in a mutable array would let a program store an integer
and read back a pointer.

`unit`, `bool` and `int` are all one machine word, so `=` is a single
instruction. It is restricted to those three types rather than silently
comparing addresses, and its operands are held back from generalization so that
they settle on a type that can be compared that way. `String.equal` compares
strings.

Pattern matching is checked for exhaustiveness and for unreachable cases, with a
witness:

```
Warning: this match is not exhaustive; no case matches (Blue, Dot)
Warning: this match case is unused: Blue
```

A non-exhaustive match that actually falls through aborts the program rather
than continuing with a wrong answer.

## The pipeline

| pass | file | what it does |
|---|---|---|
| lexing, parsing | `lexer.mll`, `parser.mly` | ocamllex and menhir |
| type inference | `typing.ml` | destructive unification, occurs check |
| match checking | `match_check.ml` | usefulness: exhaustiveness and redundancy |
| match compilation | `match_compile.ml` | `match` into a decision tree |
| A-normalization (ANF) | `anf.ml` | name every intermediate result |
| α-conversion | `alpha.ml` | make every binder unique |
| optimization | `optim.ml` | let-flattening, copy and constant propagation, dead-let elimination |
| closure conversion | `closure.ml` | lift functions to the top level |
| instruction selection | `selection.ml` | RISC-V CFG over unlimited virtual registers |
| liveness | `liveness.ml` | backwards dataflow; also dead-code elimination |
| **register allocation** | **`regalloc.ml`** | **graph colouring with iterated coalescing** |
| peephole | `peephole.ml` | local rewrites once registers are assigned |
| assembly | `emit.ml` | frame layout and instruction printing |

The last five rows sit on `riscv.ml`, which holds the instruction and
control-flow types, the register file and the calling convention. It is
deliberately not called `ir.ml`: it knows exactly one target, down to which
operations take a 12-bit immediate. `liveness.ml` and `regalloc.ml` are the
parts that do not — they use only uses, definitions, successors and register
substitution, so retargeting would mean rewriting `riscv.ml`, `emit.ml` and the
instruction-selection half of `selection.ml`, and leaving the allocator alone.

### Representation

Everything is a 64-bit word. Tuples and constructor arguments are heap blocks; a
datatype block keeps its tag in word 0, so `Node (l, v, r)` is `[1 | l | v | r]`
and `Leaf` is the address of a read-only `[0]` emitted once into `.rodata`.
Lists are built in but represented no differently: `[]` is a shared `[0]` and
`x :: xs` is `[1 | x | xs]`. Keeping constant constructors boxed costs an
indirection and buys a back end that never has to ask whether a word is a
pointer — which is also what makes polymorphism free.

A string is `[length | bytes...]`, packed, immutable, and literals with the same
text share one block. `s.[i]` is the only place the compiler emits a byte-sized
load; everything else moves whole words.

A closure is `[code pointer | captured values...]`. A function that captures
nothing is called directly and has no runtime representation at all; closure
conversion decides which is which by optimistically assuming a whole `let rec`
group is directly callable and checking afterwards whether anything is still
free.

The heap is a bump allocator in the runtime and nothing is freed. A collector
would need the compiler to describe where the pointers are, which is a different
project.

### Calling convention

The standard RISC-V one, plus one addition: `t6` carries the closure into a call
through a closure, and `t5` is reserved for the emitter, which needs a register
to materialize offsets that do not fit in a 12-bit immediate. That leaves 25
registers for the allocator — `a0`–`a7`, `t0`–`t4`, `s0`–`s11`.

Tail calls are real: the frame is torn down and the call becomes a jump, so a
loop written as tail recursion costs no stack.

## Register allocation

This is the part the rest of the compiler exists to feed.

Instruction selection emits code in which every value has its own virtual
register, and hands the allocator a graph whose nodes are registers and whose
edges join values that are live at the same time. The 25 machine registers are
pre-coloured nodes of infinite degree. Then, following Appel's formulation of
Chaitin–Briggs with iterated coalescing:

- **simplify** — remove a node with fewer than K neighbours and push it on a
  stack. Kempe's observation is that such a node can always be coloured later,
  whatever happens to the rest of the graph.
- **coalesce** — merge the two ends of a `mv` when Briggs' or George's test
  proves the merge cannot make the graph harder to colour. The move then
  disappears.
- **freeze** — when nothing can be simplified or safely coalesced, give up on
  some move so that its nodes become ordinary again.
- **spill** — when everything left has K or more neighbours, guess that the
  value used least and interfering most will not get a register.
- **select** — pop the stack and hand out colours. A node that finds none was a
  bad guess: it gets a stack slot, the program is rewritten to load and store it
  around each use, and the whole thing runs again.

Two things fall out of this that are worth pointing at.

**The calling convention is just edges.** A call defines every caller-saved
register, so anything live across it interferes with all of them and is pushed
into a callee-saved register or onto the stack — without a single special case
in the allocator.

**Saving callee-saved registers is just spilling.** `selection.ml` copies every
callee-saved register into a virtual register on entry and copies it back before
each return. If the function does not need that register, coalescing merges the
two ends and both moves vanish. If it does, the virtual gets spilled — and the
spill *is* the save/restore. A leaf function pays nothing; a function that uses
five saved registers saves exactly five.

Here is `fib` before allocation (`--dump-riscv`), 22 virtual registers and 12
callee-saved copies:

```
function sable_fib (22 registers, 0 spill slots)
  sable_fib:
    mv v0, s0
    ...                       (one for each callee-saved register)
    mv v11, s11
    mv v12, a0
    li v13, 2
    bge v12, v13, .Lthen else .Lelse
  .Lthen:
    addi v15, v12, -1
    mv a0, v15
    call sable_fib(a0)
    mv v16, a0
    addi v18, v12, -2
    mv a0, v18
    call sable_fib(a0)
    mv v19, a0
    add v20, v16, v19
    mv a0, v20
    mv s0, v0
    ...
    ret a0
```

and after:

```
sable_fib:
	addi sp, sp, -32
	sd ra, 24(sp)
	sd s0, 0(sp)          # v0 spilled: this is the save of s0
	mv s0, a0             # n lives across two calls, so it needs a saved register
	li t0, 2
	blt s0, t0, .Lelse
.Lthen:
	addi a0, s0, -1
	call sable_fib
	sd a0, 8(sp)          # fib(n-1) is live across the second call
	addi a0, s0, -2
	call sable_fib
	ld t0, 8(sp)
	add a0, t0, a0
	ld s0, 0(sp)
	ld ra, 24(sp)
	addi sp, sp, 32
	ret
```

Eleven of the twelve callee-saved copies coalesced away, along with every
argument and result move; the one that survived became the two instructions that
save and restore `s0`. Two values ended up in memory: `v0`, which is the saved
`s0`, and the result of `fib (n-1)`, which is live across the second call. For a
function that needs nothing, the whole thing collapses:

```
$ echo 'let rec f x = x + 1 in print_int (f 1)' > add.sbl && ./sable -S add.sbl
sable_f_4:
	addi a0, a0, 1
	ret
```

(Labels carry the numeric suffix α-conversion gave the name, so that two `f`s in
different scopes do not collide. The listings above drop it for readability.)

`--dump-regalloc` reports what happened:

```
$ ./sable --dump-regalloc examples/pressure.sbl
sable_blend:      1 round(s), 27/27 moves coalesced, 0 spill slot(s)
sable_pressure:   2 round(s), 46/75 moves coalesced, 16 spill slot(s) [spilled ...]
sable_accumulate: 2 round(s), 42/44 moves coalesced, 2 spill slot(s) [spilled ...]
sable_main:       1 round(s), 26/26 moves coalesced, 0 spill slot(s)
```

`examples/pressure.sbl` is written to make this happen: sixteen values, all live
across the same sixteen calls. Run it with `-nregs 10` and the spill count goes
up while the answer does not change.

One simplification is worth stating because it would not survive contact with a
bigger language: the control-flow graph of a Sable function is acyclic, since a
loop in the source is a recursive call and a call leaves the function. So the
liveness fixed point converges in one backwards pass, and the spill-cost
heuristic needs no loop-nesting estimate — every basic block genuinely weighs
the same.

## Limitations

Deliberate, and each one is a place the project could go next.

- No garbage collector; the heap is a bump allocator.
- No polymorphic comparison: `=` works on `int`, `bool` and `unit` only.
- Strings are immutable and there is no `String.sub` or `String.make`; the
  runtime offers length, indexing, concatenation and equality.
- Functions are uncurried and take at most eight arguments (they arrive in
  `a0`–`a7`); more should be a tuple.
- Mutually recursive functions may not capture their environment. A
  self-recursive one may, through its own closure; a cyclic group of closures
  would need allocate-then-patch, which is not implemented. The compiler says so
  rather than miscompiling.
- No bounds checking on arrays, and integer division by zero follows the
  hardware rather than raising.
- No inlining, and no instruction scheduling.
- Type errors do not carry source positions; syntax errors do.

## Layout

```
src/          the compiler
runtime/      sable_runtime.c: entry point, heap, primitives
examples/     programs, all run by the test suite
tests/        golden tests, including the compile-error messages
sable         compile + link + run under qemu
```
