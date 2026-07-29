# MinkML

One small ML, and five type systems to check it with. The syntax is SML's, the
runtime is shared, and the first line of a program says which type theory it
should be held to.

```sml
#system poly

val useTwice : (forall 'a. 'a -> 'a) -> int * bool = fn f => (f 1, f true)
val both = useTwice (fn x => x)
```

```sml
#system linear

fun classify (c : chan (?int ; !bool ; stop)) : unit =
  let val (n, c) = recv c
      val c = send (n > 10) c
  in close c end
```

The point of the exercise is comparison. Row polymorphism, refinement types,
linearity and dependent types are usually met in separate languages, each with
its own syntax, its own runtime and its own ideas about what a program looks
like. Here they share all of that, so what is left is the type theory.

| system | what it explores |
| --- | --- |
| `poly` | higher-rank polymorphism, checked bidirectionally with ordered contexts |
| `row` | row polymorphism: extensible records and variants, scoped labels, full inference |
| `refine` | refinement types, verification conditions, and a solver to discharge them |
| `linear` | linear types, and session-typed channels on top of them |
| `dep` | dependent types: universes, Π and Σ, `nat` and equality, normalisation by evaluation |

```
$ cd lab
$ dune build
$ dune test
$ ./_build/default/src/mink.exe examples/rows.mnk
origin : { x : int, y : int } = { x = 0, y = 0 }
getX : { x : 'a, ..'b } -> 'a = <fun>
shadowed : { x : bool, x : int, y : int } = { x = true, x = 0, y = 0 }
describe : [ `Int : int, `Bool : bool, `Pair : { x : int, ..'a } ] -> int = <fun>
...
```

The implementation is in [`lab/`](lab) and the book is in
[`doc/`](doc/index.md): see [`lab/README.md`](lab/README.md) for the language,
the command line and a map of the source, and [`doc/index.md`](doc/index.md)
for a chapter per system. Two to start with, in Japanese:
[プログラムが通る道](doc/0-pipeline.md) と
[構文と型の書き方](doc/1-syntax.md)。

## What is shared, and what is not

Everything up to the typechecker is shared, and everything after it too.

```
   .mnk  ->  lexer  ->  parser  ->  one syntax tree
                                        |
                     #system chooses one of five checkers
                                        |
                            A-normal form  ->  CEK machine
```

There is no separate grammar of types. `int -> bool`, `{ v : int | v > 0 }` and
`!int ; ?bool ; stop` are all terms in the same tree, and `x * y` is one node
that means multiplication or a product depending on where it stands. Each
system reads what it understands and refuses the rest by name:

```
$ ./_build/default/src/mink.exe -s poly examples/rows.mnk
examples/rows.mnk:6:22: type error: records and variants belong to #system row
```

What is *not* shared is the type representation. `poly` has ordered contexts
and existential variables, `row` has mutable unification variables and rows,
`refine` has predicates, `linear` has qualifiers, and `dep` does not distinguish
types from terms at all. Sharing those would mean every system paying for every
other system's needs.

## The solver

`refine` generates implications and has to decide them. There is a built-in
procedure so that nothing needs installing: it splits on the boolean structure
and eliminates variables by Fourier-Motzkin, which decides satisfiability over
the rationals. Since the variables are integers, that is sound in the direction
that matters — rational unsatisfiability implies integer unsatisfiability, so a
proof it finds is a real proof — and incomplete in the other, where it says
"cannot verify" rather than "false".

Any real solver can be used instead, over SMT-LIB 2 on standard input:

```sh
./_build/default/src/mink.exe --smt "z3 -in" examples/refine.mnk
./_build/default/src/mink.exe --dump-vc examples/refine.mnk    # see the obligations
```

## What is deliberately missing

No modules, no separate compilation, no optimiser, no type classes. Recursion is
`fun`, and in `dep` there is none at all. `poly` does not do polymorphic
recursion, `row` has no record subtyping, `refine` does not infer refinements
(liquid typing's Horn constraints are absent — a function says what it
promises), `linear` has no recursive session types, and `dep` has no inductive
families, implicit arguments or universe polymorphism.

Each chapter of the book ends with the list for that system, and with why.
