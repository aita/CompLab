# The SkunkLLVM implementation

One language, one front end, and two back ends: a machine that runs the
program, and a compiler that writes LLVM IR. This file is the language
reference and the map of the source; the book in
[`../doc/`](../doc/index.md) explains how each pass works.

```
src/front/         the front end, shared by both              -> a library
src/interpreter/   the CESK machine                           -> skunk
src/llvm/          the lowering, and the text it prints       -> skunkllvm
src/runtime/       the runtime, in freestanding C             -> linked in
```

The front end is its own directory because that is what it is: neither back end
appears in it, and it does not know which one will run. By the time it is
finished the program has no modules, no patterns and no nested functions left,
so neither back end has heard of any of them -- and neither back end depends on
the other, only on this.

## Building and running

OCaml and dune, menhir and ocamllex from opam, and `clang` on the path.
Nothing links against LLVM: the compiler builds a module by printing it and
hands the `.ll` to clang, which parses it, verifies it, optimises it and writes
the object. Developed with OCaml 5.4, dune 3.21 and clang 22, and there is
nothing pinning it to that version ([10章](../doc/10-llvm.md)).

```sh
dune build
dune exec src/interpreter/skunk.exe examples/tour.sk
dune test                     # golden tests (dune promote to accept new output)
bench/run.sh                  # the table in 14章
```

```sh
./_build/default/src/interpreter/skunk.exe examples/modules.sk
./_build/default/src/llvm/skunkllvm.exe --emit-llvm -O0 tests/join.sk
```

## The command lines

```
skunk [options] file.sk

      --dump-core   print the typed Core -- A-normal form, patterns intact
      --dump-flat   print the flat IR: code blocks, closures, join points
      --trace       print every step the machine takes (to stderr)
      --steps       report how many steps the machine took
      --no-prelude  do not load the part of the basis written in SkunkML
  -h, --help
```

```
skunkllvm [options] file.sk

  -o FILE           write the output here (the default is a.out)
      --emit-llvm   write LLVM IR instead of an executable
  -S                write assembly instead of an executable
  -c                write an object file instead of an executable
  -O0 -O1 -O2 -O3   how hard LLVM should try (the default is -O2)
      --dump-flat   print the A-normal form the module was built from
  -h, --help
```

`--emit-llvm -O0` is the module exactly as this compiler wrote it — LLVM does
not run at all to produce it — and `--emit-llvm` is the same file after clang
has had it. Reading the two side by side is how to see what `-O2` did.

What the generated code and the runtime agree on -- the value representation, the
descriptor, the calling convention, the section the collector scans, the symbol
names, and what the collector requires of anyone calling in -- is written down in
[the ABI reference](../doc/12-abi.md). That is the file to read before touching
`src/runtime/runtime.c`.

`skunkllvm` writes a static ELF64 with no libc. The runtime travels inside the
compiler as bytes, so what it needs on disk is `clang`:

```sh
./_build/default/src/llvm/skunkllvm.exe -o /tmp/tour examples/tour.sk
/tmp/tour | diff - <(./_build/default/src/interpreter/skunk.exe examples/tour.sk) && echo same
```

Its output has to match `skunk`'s byte for byte, error messages included. That
is the differential test, and `dune test` runs it for every example -- at `-O2`,
and at `-O0` for the two programs where the optimiser is not what keeps them
correct.

Every binding is reported as it is run:

```
$ ./_build/default/src/interpreter/skunk.exe examples/tour.sk
val greeting : string = "hello"
val answer : int = 42
...
datatype 'a tree = Leaf | Node of 'a tree * 'a * 'a tree
val sorted : int list = [1, 3, 5, 8]
```

A program is checked all the way through before any of it runs, so a program
that does not typecheck never prints half of its output first.

## The language

Standard ML, cut down. `val` and `fun` declarations, `fn x => e`, `case e of`,
`let ... in ... end`, `(* nesting comments *)`, `'a` type variables,
`andalso`/`orelse`/`div`/`mod`/`<>`, `~` for negation, `1.0` and `1.5E~3` for
reals.

```sml
val answer = 6 * 7
fun twice f x = f (f x)

fun fact n = if n = 0 then 1 else n * fact (n - 1)

fun even 0 = true
  | even n = odd (n - 1)
and odd 0 = false
  | odd n = even (n - 1)
```

### Types

```
type ::= 'a | ''a                         any type / an equality type
       | int | real | bool | string | unit
       | type * type * ...                a tuple is a record: { 1 : t, 2 : u }
       | { l : type, ... }                record
       | type -> type
       | type tycon                       postfix application: int list
       | (type, type) tycon
       | Path.tycon
```

A type is written in three places, and all three mean the same thing:

```sml
val n : int = 41 + 1
fun size (xs : int list) : int = List.length xs
val m = (someExpression : int)
```

An *expression* annotation must be parenthesised — `(e : t)`, not `e : t` —
which is what makes the grammar conflict-free: without the brackets, `x : int
* int` cannot decide whether the `*` is multiplication or a product. A
*pattern* annotation needs no brackets, because patterns have no `*`, and that
is the one people write: `val n : int = 1`, `fun f (a : string, b) = ...`.

### Data

A tuple *is* a record, as in the Definition: `(1, true)` is `{ 1 = 1, 2 = true }`
and `unit` is the record with no fields. So there is one product here, `#1`
works on a pair, and the decision-tree compiler never has to tell the two
apart.

```sml
val pair = (1, true)                       (* int * bool *)
val first = #1 pair
val origin = { x = 0, y = 0 }              (* { x : int, y : int } *)
val xs = [1, 2, 3]                         (* int list *)
val more = 0 :: xs @ [4]

datatype 'a tree = Leaf | Node of 'a tree * 'a * 'a tree
datatype ('a, 'b) either = Left of 'a | Right of 'b
```

Fields are sorted — numeric labels by value and before the alphabetic ones — so
`{ y = 1, x = 2 }` and `{ x = 2, y = 1 }` are one type and one value. `#lab r`
only works where the record's type is already known, as in SML:

```sml
fun getX r = #x r            (* rejected: which record? *)
fun getX (r : { x : int, y : int }) = #x r
```

### Mutation

`ref` is a datatype with one constructor, so `ref x` is an expression and a
pattern both; `array` is the same idea several addresses at a time.

```sml
val counter = ref 0
val () = counter := !counter + 1
fun bump (r as ref n) = (r := n + 1; !r)
```

`ref` and `array` are compared by identity: a cell is equal to itself and to
nothing else. Because they exist, `val` generalises only non-expansive
right-hand sides — the value restriction.

### Patterns

```
pattern ::= _ | x | 42 | "s" | ~1
          | Con | Con pattern | p1 :: p2 | [p, q]      (* `ref p` is one of these *)
          | (p, q) | { l = p, ... } | { l, ... } | { l = p, ... , ... }
          | x as pattern | pattern : type
```

A bare name is a constructor if the environment says so and a variable
otherwise, which is why `nil`, `true` and `NONE` need no special case. `...` in
a record pattern means "and whatever else this record has".

Matches are compiled to decision trees, and the compiler says what it noticed:

```
$ skunk warn.sk
warn.sk:5:5: warning: this match does not cover every case
warn.sk:8:5: warning: this pattern can never match: 0
```

### Modules

```sml
signature ORD = sig
  type t
  val compare : t * t -> int
end

structure IntOrd : ORD = struct           (* transparent: IntOrd.t is int *)
  type t = int
  val compare = Int.compare
end

functor MakeSet (O : ORD) :> SET where type elem = O.t = struct
  ...                                     (* opaque: a set is not a list *)
end

structure IntSet = MakeSet (IntOrd)
open IntSet
```

Specifications are `val x : t`, `type t`, `eqtype t`, `type t = ty`,
`datatype`, `structure X : S` and `include S`. An abstract type does not admit
equality; `eqtype` is how a signature says it does. `S where type t = ty` gives one of a
signature's abstract types a definition, which is how a functor's result
signature talks about its argument.

Functors are **generative**: two applications make two different types, and the
report says which is which.

```
val ints : IntSet.set = [1, 2, 3]
val words : StringSet.set = ["apple"]
```

### The basis

`print`, `not`, `!`, and five structures written in OCaml because the machine
has to do them itself:

| | |
| --- | --- |
| `Int` | `toString`, `abs`, `min`, `max`, `compare` |
| `Real` | `toString`, `fromInt`, `floor`, `compare` |
| `Math` | `sqrt` |
| `String` | `size`, `compare`, `substring` |
| `Array` | `array`, `fromList`, `toList`, `length`, `sub`, `update` |

`Option` and `List` are written in SkunkML and go through the same pipeline as
a user's program; `--no-prelude` leaves them out. `List` has `null`, `length`,
`rev`, `map`, `app`, `filter`, `foldl`, `foldr`, `exists`, `all`, `find`,
`concat` and `tabulate`.

`=` and `<>` are structural, and only on **equality types**: a function is a
type error, not a runtime one, `real` is one too — `1.0 = 1.0` does not compile,
as the Definition says — and a type variable that has to be compared prints as
`''a`. `<` and friends are overloaded over `int`, `string` and `real`, and
`+`, `-`, `*` and `~` over `int` and `real`; all of them default to `int` when
nothing decides — so `fun bigger (a, b) = if a < b then b else a` is
`int * int -> int`, exactly as in SML. `/` is real-only and `div` and `mod` are
int-only, so neither division is overloaded.

How a real prints is specified, not left to a library: at most 12 significant
digits, always a digit after the point, `~` for the sign, and `1.0E12` outside
`0.0001 .. 10^12`. The specification is in `front/types.ml` because a compiled
program will have to produce the same bytes from freestanding C with no
`printf`.

## How it is put together

```
   .sk source
     |  lexer.mll / parser.mly
     v
   Ast            the surface tree, with a grammar of types of its own
     |  elab.ml + types.ml + sem.ml     inference and normalisation, together
     v
   Core           typed A-normal form -- patterns and lambdas still in it
     |  patmat.ml                       decision trees, and the first join points
     v
   Core           ... with switches instead of patterns
     |  closure.ml
     v
   Flat           A-normal form + explicit join points + explicit closures
     |
     +--> machine.ml                    a value
     |
     +--> lower.ml                      LLVM IR: a join point is a block with phis
            |  layout.ml                 descriptors, static blocks, globals
            |  prelude.ml                the basis, as data plus one stub each
            |  ir.ml                     ... and all of it printed as text
            v
          .ll            i64 functions, musttail, one section for the roots
            |  clang -O2                 everything LLVM knows how to do
            v
          .o             LLVM's instruction selection and register allocation
            |  clang -nostdlib -static
            v
          a static ELF64, with the runtime linked in
```

In `src/front/`, which is everything up to and including Flat:

| file | lines | what it does |
| --- | --- | --- |
| `loc.ml` | 37 | source positions, the one exception, the warning list |
| `lexer.mll` | 131 | ocamllex scanner (nesting comments, `'a`, `List.map` as one token) |
| `parser.mly` | 332 | menhir grammar, conflict-free |
| `ast.ml` | 140 | the surface tree |
| `types.ml` | 639 | types, levels, destructive unification, equality, order and arithmetic, schemes, and how a real is spelled |
| `sem.ml` | 524 | environments, semantic signatures, matching, realisation |
| `core.ml` | 299 | typed Core, its free variables, and its printer |
| `elab.ml` | 1025 | inference and normalisation in one pass; modules become records |
| `patmat.ml` | 335 | pattern matrices, decision trees, exhaustiveness |
| `flat.ml` | 156 | the flat IR, and its printer |
| `closure.ml` | 143 | code blocks, captures, and what is deliberately not captured |
| `basis.ml` | 181 | what the names in the initial environment are, and the prelude source |

And the two back ends. In `src/interpreter/`:

| file | lines | what it does |
| --- | --- | --- |
| `machine.ml` | 596 | the CESK machine, the primitives, and the basis in its store |
| `skunk.ml` | 148 | the command line |

In `src/llvm/`:

| file | lines | what it does |
| --- | --- | --- |
| `ir.ml` | 318 | writing LLVM IR as text: names, buffered blocks, phis filled in late |
| `layout.ml` | 258 | descriptors, string blocks, static closures, globals, one section |
| `prelude.ml` | 108 | the basis, as static data plus one unpacking function each |
| `lower.ml` | 497 | Flat to LLVM IR, and the three things LLVM cannot know |
| `emit.ml` | 71 | the clang invocations, and the link |
| `skunkllvm.ml` | 179 | the command line |

And the runtime, in `src/runtime/`:

| file | lines | what it does |
| --- | --- | --- |
| `runtime.c` | 832 | the heap and the collector, equality, the string routines, `show` |

Freestanding: no headers, no libc, and three syscalls of inline assembly. It is
compiled by `clang -c`, carried inside the compiler as a string, and written out
beside the object at link time.

## Layout

```
src/front         the front end, shared              -> a library
src/interpreter   the CESK machine                   -> skunk
src/llvm          lowering, IR text, and emit       -> skunkllvm
examples          tour, matching, modules, store
tests             golden tests, and errors/ for the messages
bench             four programs, and a script that compares three ways of running them
```

The examples are the tests: `dune test` runs them all and diffs their output.
Four more files test the machinery — `tests/core.sk` dumps the typed Core,
`tests/flat.sk` dumps the flat IR, `tests/join.sk` is dumped as Core and
compiled, and `tests/warn.sk` is a program that runs but that the decision-tree
compiler has something to say about. Every program in `tests/errors/` is
expected to fail with the message in `tests/errors.expected`.

Then the same examples are compiled, run, and diffed against the interpreter's
output. `tests/verify.out` compiles seven programs to object files and compares
nothing: the test is that `skunkllvm` exits zero, which it only does if clang's
parser and verifier had nothing to say.

`tests/loop.sk` and `tests/gc.sk` are compiled twice, once at `-O0`. The first
is tail-recursive, so at `-O0` nothing but `musttail` keeps it from growing the
stack; the second allocates through three heaps, so finishing at all is the
evidence that collection happens.

`tests/nullary.sk` has two datatypes that number their constructors the same
way, so their descriptors hold the same six words and must still be two
addresses. It is the program that would start printing the wrong name if
anything in `layout.ml` were marked `constant`, because `constmerge` would fold
them into one.

`tests/reals.sk` is the one program only the interpreter runs, because the back
end has no representation for a real yet: it is where the printing specification
is pinned down, and it becomes a differential test like the others as soon as
there is a compiled half to diff it against.

## What is deliberately missing

No exceptions, so no `raise` and no `handle`, and a match that fails stops the
program. No characters, so `<` is overloaded over three types where SML has
four, and there is no `String.sub`. Reals exist but the compiler cannot do them
yet: it has no representation for one, so `skunkllvm` stops with a message when
it meets a real literal, the `Real` or `Math` structures, or `/`. No `op`, no
user-defined infix operators, no `local`, `abstype`, `withtype` or `sharing`.
No polymorphic recursion and no separate compilation. The interpreter's store
only grows; the compiled program collects.

And the back end has **no inliner**, which is the one thing `clang -O2` cannot
make up for: every call goes through a word read out of a closure, so LLVM
cannot see the callee, and the pass that could have is the one that has to run
before closure conversion. `Array.sub (a, i)` therefore allocates its argument
tuple on every array read. What that costs is measured in
[14章](../doc/14-opt.md).

A written type variable *is* a promise, as it should be. `val id : 'a -> 'a`
reads its `'a` as a rigid constant while the body is checked and quantifies it
afterwards, so `fn x => x + 1` is rejected and `fn x => x` is not. Scoping is
per declaration, which is roughly SML's implicit rule and not exactly it.
