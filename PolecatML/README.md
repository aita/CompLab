# PolecatML

A small strict ML, compiled to a stack machine: Hindley-Milner inference,
first-class closures, proper tail calls, and a verifier that checks the compiled
code before the machine will run it.

```sml
fun fact (n) = if n <= 1 then 1 else n * fact (n - 1)

fun adder (k) = fn (n) => n + k

fun countdown (n, acc) = if n = 0 then acc else countdown (n - 1, acc + 1)

val chosen = fact (20)
val added = adder (10) (5)
val counted = countdown (1000000, 0)
```

A program has no output of its own.  It evaluates to everything it bound, and
running it prints that against the types that were inferred for it:

```
val fact : int -> int = fn
val adder : int -> int -> int = fn
val countdown : (int, int) -> int = fn
val chosen : int = 2432902008176640000
val added : int = 15
val counted : int = 1000000
```

```sh
dune build
dune test                                    # 104 checks: goldens, units, and the three back ends against each other
dune exec bin/main.exe -- run examples/tour.pol
dune exec bin/main.exe -- run --stats examples/collatz.pol
dune exec bin/main.exe -- emit -s code tests/programs/machine.pol
echo 'val x = 6 * 7' | dune exec bin/main.exe -- run
```

`run` takes `--interp` to use the evaluator over the core tree instead of the
machine, `--anf` to use the one over A-normal form, `--trace` to print every
instruction as it is executed, `--stats` to say how many instructions ran and how
deep the frame stack got, and `--no-verify` to skip the verifier.
`emit -s <stage>` prints one stage: `tokens`, `types`, `core`, `anf`, `resolved`
or `code`.

## The pipeline

```
source
  |   one scanning pass, then recursive descent
surface tree
  |   Hindley-Milner with levels          types, and every top-level name
  |   desugaring                          sugar and patterns gone, names unique
core tree
  |   lexical addressing =                names become slot numbers and
  |   closure conversion                  capture vectors; functions come apart
resolved core
  |   code generation                     one instruction array per function
machine code
  |   verification                        heights, indices, targets, arities
  |   execution
value
```

There is no A-normal form on the way in, and no basic-block graph: the code
generator walks the resolved tree once and the operand stack does what an
intermediate name would have done.  There *is* an A-normal form off to the side,
with an interpreter of its own — `emit -s anf`, `run --anf` — because naming
those intermediates is the other way of saying what the operand stack says, and
having both makes the comparison concrete.

## The machine

Four things describe its state, and nothing keeps a second copy of any of them:

| | |
|---|---|
| operand stack | the temporaries of the expression being evaluated |
| frame locals and closure captures | the arguments and bindings of the call in progress |
| a function's code, and a program counter into it | what to do next |
| frame stack | the calls that are waiting |

That is CEK's control, environment and continuation, with the values a CEK
machine carries inside a redex put on a stack of their own, and with the part of
the continuation that is statically known compiled into the instruction stream.
What is left on the frame stack is only what a call needs: nothing pushes a
frame except a call, and nothing pops one except a return.

The instruction set is small enough to list:

```
Const  ConstUnit  ConstBool                    constants, from a per-function pool
LoadLocal  InitLocal  StoreLocal  LoadCapture  the environment
Pop  Dup                                       the operand stack
AddI64 SubI64 MulI64 DivI64 ModI64 NegI64      arithmetic, wrapping, 64-bit
EqI64 NeI64 LtI64 LeI64 GtI64 GeI64            comparison, signed
MakeTuple  TupleGet                            the only aggregate
MakeClosure                                    a function id and where to fetch each capture
Jump  JumpIfFalse                              control flow
Call  CallStatic  ReturnCall  ReturnCallStatic calls
Return                                         and returns
Trap                                           a failure the compiler put there
```

Instructions are OCaml constructors rather than bytes.  Encoding them would be a
separate and mechanical step, and it would only make the machine harder to read;
what matters is that the set is fixed, that every instruction has one effect on
the stack, and that a verifier can check a program against both.

## The five things worth reading the source for

**`ReturnCall` is its own instruction.**  Tail position is a property of where an
expression sits, and the compiler is the only thing that knows it — so it says
so, rather than leaving the machine to notice a `Return` after a `Call` and
optimise it.  `Call` pushes a frame; `ReturnCall` replaces the top one.  A
million iterations of a tail recursive loop therefore run with two frames on the
stack, which is what `--stats` reports, and the test suite asserts.

**Captures are copies, so a recursive group rebuilds itself.**  Nothing in the
language is mutable, so a closure holds values and not cells — and then a local
`fun` that calls itself has nothing to back-patch, because the closure would have
to contain itself.  Instead every member of a recursive group captures *the same
vector*, the free variables of the group as a whole; and a reference from inside
the group to any member, itself included, is a `MakeClosure` that rebuilds that
member out of the vector the running member is already holding.  No recursive
cell, no back-patch, no instruction that exists only for recursion.

```
fun repeat (base, n) =
  let fun go (i) = if i = 0 then base else go (i - 1)
  in go (n) end
```

```
function 2 go: arity 1, locals 1, captures 1, stack 3
  constant 0 = 0
  constant 1 = 1
     0  LoadLocal 0
     1  Const 0                      ; 0
     2  EqI64
     3  JumpIfFalse 6
     4  LoadCapture 0
     5  Return
     6  MakeClosure 2 [capture 0]    ; go      <- itself, out of its own captures
     7  LoadLocal 0
     8  Const 1                      ; 1
     9  SubI64
    10  ReturnCall 1
```

The one case this does not cover is a closure *inside* a group member that
captures the member, because a capture has to come from a local or a capture and
"rebuild it" is neither.  Then the member is materialised into a slot at the top
of the function — but only in the functions where that actually happens.

**A function that captures nothing is a global.**  Its closure has no captures,
so there is exactly one of it: calling it needs no closure value on the stack
(`CallStatic`), and naming it as a value allocates nothing, because that one
closure sits in the constant pool.  Most top-level functions are globals, and so
is every local `fun` whose free variables are themselves globals.

**The verifier makes the stack discipline static.**  Before a program runs, every
operand index, jump target and known-callee arity is checked, and the operand
stack's height is walked over the whole function: if two paths reach an
instruction with the stack at different heights, "the second operand of this add"
would mean different things depending on how control arrived, and the program is
rejected.  The same walk answers `max_stack`, so the compiler asks the verifier
for the number rather than counting as it emits.  `dune test` hand-writes
programs the compiler would never produce — a jump to nowhere, a join whose paths
disagree, a static call of a function that captures — and checks each is refused.

**There are three back ends, and the tests demand they agree.**  Besides the
machine there is a tree-walking evaluator over the core tree, and another over
A-normal form, each small enough to read in one sitting.  Every golden test runs
all three and requires the same text, character for character: a golden file on
its own only says the answer has not changed, but three implementations agreeing
says the answer is right.

## A-normal form, and the join point

Two rules make a program A-normal: every operand is an atom — a constant or a
name, never a computation — and every intermediate result is named by a `let`.
That is the same claim the machine makes about its code, made with names instead
of stack slots, so the two forms are worth reading side by side.

The interesting case is a branch.  An operand has to be an atom, so
`let x = if c then a else b in rest` cannot be written in this form at all, and
A-normalisation's usual answer is to push the continuation into both arms — which
writes `rest` out twice.  In this language `andalso`, `orelse` and `not` are all
`if`, so an ordinary line of boolean arithmetic would double the rest of the
program once per operator.

The answer that does not is a *join point*: `rest` is named, and both arms jump
to the name.  A jump is not a call — it takes no closure, keeps no return
address, and cannot be a value — and it is exactly the `JumpIfFalse` the compiler
emits, with a name where the machine has a number.

```sml
val a = 1
val flag = if a = 1 then true else false
val b = if flag andalso a < 3 then a + 1 else a - 1
```

```
let a.1 = 1
let t.10 = (eq a.1 1)
join join.11 (flag.2) =
  join join.8 (t.4) =
    join join.5 (b.3) =
      (a.1, flag.2, b.3)
    in if t.4
    then let t.7 = (add a.1 1)
      in jump join.5 (t.7)
    else let t.6 = (sub a.1 1)
      in jump join.5 (t.6)
  in if flag.2
  then let t.9 = (lt a.1 3)
    in jump join.8 (t.9)
  else jump join.8 (false)
in if t.10
then jump join.11 (true)
else jump join.11 (false)
```

Nothing is written twice, and the size stays proportional: twenty bound branches
in a row are 62 lines of core dump and 142 of ANF, where pushing the continuation
into both arms would have written the tail out 2^20 times.  A tail branch gets no
join point at all — both arms end the function, so there is nothing after them to
share — and the tests count them: none for a tail branch, one for a bound one,
three for `a andalso b andalso c` with a `not` after it.

## How fast it is not

The machine is not faster than the evaluators it is checked against.  On
`examples/collatz.pol` — 19 million instructions — best of five runs each:

| | |
|---|---|
| the evaluator over the core tree | 0.26s |
| the machine | 0.36s |
| the evaluator over A-normal form | 0.44s |

The values are boxed the same way in all three, so what differs is dispatch and
where the intermediates live, and that is the whole of the ordering.  The core
evaluator keeps an intermediate in an OCaml local, which costs nothing at all.
The machine puts every one of them through a mutable heap array — a write barrier
per push — and allocates a locals array and a frame per call.  And the ANF
evaluator has to *name* every intermediate, which in an interpreter means
inserting it into a map: it pays the most for making explicit exactly what the
machine's operand stack is for.

So a compiled machine wins against an interpreter that walks the *surface* tree
with string lookups and scope chains; against a walker of a tree that has already
been alpha-renamed and desugared, on a runtime with a fast generational GC, it
does not — not until the values are unboxed and the dispatch is gone, which is
what a native back end would be for.

What the machine buys instead is that it is a compilation target: a fixed
instruction set, a stack discipline that can be checked rather than trusted, tail
calls that are stated rather than inferred, and a place for a code generator to
stop.

## The language

Types are inferred, so annotations are never required, and the top level prints
the ones it found.  There are five kinds of value: 64-bit integers, booleans,
unit, tuples, and functions.

```sml
val answer = 6 * 7                     (* val binds; ~ negates; (* comments nest *) *)
val (x, y) = (3, 4)                    (* irrefutable patterns, and _ *)
val first = #1 (x, y)                  (* projection, one-based *)

fun distance (x, y) = x * x + y * y    (* a function of two arguments *)
fun swap ((a, b)) = (b, a)             (* a function of one, which is a pair *)
fun nothing () = ()                    (* a function of none *)

val closure = fn (n) => n + answer     (* fn is the anonymous form *)
val applied = distance (3, 4)

fun even (n) = if n = 0 then true else odd (n - 1)   (* mutual recursion *)
and odd (n) = if n = 0 then false else even (n - 1)

val local =
  let val doubled = answer * 2         (* let ... in ... end, with fun inside *)
      fun go (i, acc) = if i = 0 then acc else go (i - 1, acc + i)
  in go (doubled, 0) end
```

Two things in that are worth saying outright.

**A parenthesised list after a function is an argument list, not a tuple.**
`f (a, b)` calls `f` with two arguments and `f ((a, b))` calls it with one, which
is a pair.  Arity is a property of a function here, not of the value it is
applied to — the machine's `Call` takes that arity — so the syntax says it too.
Currying is still available where it is wanted: `fun adder (k) = fn (n) => n + k`
is applied as `adder (10) (5)`.

**Comparison is on integers.**  The machine has `EqI64` and its five friends and
nothing else, so `=` at any other type has no instruction to become; polymorphic
equality would need either a tag test at run time or a dictionary, and both are
larger decisions than a comparison operator should make.

Precedence, loosest first: `orelse`, `andalso`, the comparisons (which do not
associate, so `a < b < c` is a syntax error), `+` `-`, `*` `/` `mod`, the
prefixes `~` `not` `#n`, then application.  `if` and `fn` extend as far to the
right as they can.

## What is not in it

No mutation, no records, no arrays, no user-defined types, no strings, no
exceptions, no first-class continuations, no garbage collector of its own — the
values are OCaml values and OCaml collects them — and no encoding of the
instructions as bytes.

The two additions that would be felt everywhere else are cells and sums.  A
mutable binding would become a heap cell that closures capture by reference
rather than by copy, which is the one line of §7 of the design that would change;
and a sum type would give patterns something that can fail to match, which is
what `Trap` is in the instruction set for.  As it stands the compiler emits no
`Trap`, and no `StoreLocal` either — the machine and the verifier implement both,
and the test suite hand-writes the code that uses them.

## The files

| | |
|---|---|
| `src/lexer.ml` `src/parser.ml` | one scanning pass, then recursive descent, one function per precedence level |
| `src/types.ml` `src/typecheck.ml` | unification, levels, generalisation |
| `src/core.ml` `src/desugar.ml` | the core tree, and the rewritings that reach it |
| `src/resolve.ml` | lexical addressing and closure conversion, which are one pass |
| `src/machine.ml` | the values, the instructions, the shape of a program |
| `src/compile.ml` | resolved core to instructions, and the `tail` flag |
| `src/verify.ml` | the height walk, the bounds checks, and `max_stack` |
| `src/vm.ml` `src/value_stack.ml` `src/frame_stack.ml` | fetch, do, repeat |
| `src/eval.ml` | the second back end: a walker over the core tree |
| `src/anf.ml` `src/anf_eval.ml` | A-normal form, its join points, and the third back end |
| `src/dump.ml` `src/disasm.ml` | every stage, as text |
