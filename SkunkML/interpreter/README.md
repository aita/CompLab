# The SkunkML interpreter

One language, four intermediate forms and a machine. This file is the language
reference and the map of the implementation; the book in
[`../doc/`](../doc/index.md) explains how each pass works.

## Building and running

The only requirements are OCaml and dune; menhir and ocamllex come from opam.
It was developed with OCaml 5.4 and dune 3.21.

```sh
dune build
dune exec src/skunk.exe examples/tour.sk
dune test                     # golden tests (dune promote to accept new output)
```

```sh
./_build/default/src/skunk.exe examples/modules.sk
```

## The command line

```
skunk [options] file.sk

      --dump-core   print the typed Core -- A-normal form, patterns intact
      --dump-flat   print the flat IR: code blocks, closures, join points
      --trace       print every step the machine takes (to stderr)
      --steps       report how many steps the machine took
      --no-prelude  do not load the part of the basis written in SkunkML
  -h, --help
```

Every binding is reported as it is run:

```
$ ./_build/default/src/skunk.exe examples/tour.sk
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
`andalso`/`orelse`/`div`/`mod`/`<>`, `~` for negation.

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
       | int | bool | string | unit
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

`print`, `not`, `!`, and three structures written in OCaml because the machine
has to do them itself:

| | |
| --- | --- |
| `Int` | `toString`, `abs`, `min`, `max`, `compare` |
| `String` | `size`, `compare`, `substring` |
| `Array` | `array`, `fromList`, `toList`, `length`, `sub`, `update` |

`Option` and `List` are written in SkunkML and go through the same pipeline as
a user's program; `--no-prelude` leaves them out. `List` has `null`, `length`,
`rev`, `map`, `app`, `filter`, `foldl`, `foldr`, `exists`, `all`, `find`,
`concat` and `tabulate`.

`=` and `<>` are structural, and only on **equality types**: a function is a
type error, not a runtime one, and a type variable that has to be compared
prints as `''a`. `<` and friends are overloaded over `int` and `string` and
default to `int` when nothing decides — so `fun bigger (a, b) = if a < b then b
else a` is `int * int -> int`, exactly as in SML.

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
     |  machine.ml
     v
   a value
```

| file | lines | what it does |
| --- | --- | --- |
| `loc.ml` | 37 | source positions, the one exception, the warning list |
| `lexer.mll` | 114 | ocamllex scanner (nesting comments, `'a`, `List.map` as one token) |
| `parser.mly` | 326 | menhir grammar, conflict-free |
| `ast.ml` | 139 | the surface tree |
| `types.ml` | 516 | types, levels, destructive unification, equality and order, schemes |
| `sem.ml` | 512 | environments, semantic signatures, matching, realisation |
| `core.ml` | 294 | typed Core, its free variables, and its printer |
| `elab.ml` | 1007 | inference and normalisation in one pass; modules become records |
| `patmat.ml` | 335 | pattern matrices, decision trees, exhaustiveness |
| `flat.ml` | 153 | the flat IR, and its printer |
| `closure.ml` | 113 | code blocks, captures, and what is deliberately not captured |
| `machine.ml` | 498 | the CESK machine and the primitives |
| `basis.ml` | 162 | the initial environment, and the prelude source |
| `skunk.ml` | 148 | the command line |

## Layout

```
src        the implementation
examples   tour, matching, modules, store
tests      golden tests, and errors/ for the messages
```

The examples are the tests: `dune test` runs them all and diffs their output.
Three more files test the machinery — `tests/core.sk` dumps the typed Core,
`tests/flat.sk` dumps the flat IR, and `tests/warn.sk` is a program that runs
but that the decision-tree compiler has something to say about. Every program
in `tests/errors/` is expected to fail with the message in
`tests/errors.expected`.

## What is deliberately missing

No exceptions, so no `raise` and no `handle`, and a match that fails stops the
program. No characters and no reals, so `<` is overloaded over two types where
SML has four. No `op`, no user-defined infix operators, no `local`, `abstype`,
`withtype` or `sharing`. No polymorphic recursion, no separate compilation, no
optimiser, and no garbage collector: the store only grows.

A written type variable *is* a promise, as it should be. `val id : 'a -> 'a`
reads its `'a` as a rigid constant while the body is checked and quantifies it
afterwards, so `fn x => x + 1` is rejected and `fn x => x` is not. Scoping is
per declaration, which is roughly SML's implicit rule and not exactly it.
