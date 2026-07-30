# The MinkML laboratory

One language, six typecheckers, one machine. This file is the language
reference and the map of the implementation; the book in [`../doc/`](../doc/index.md)
explains how each system works.

## Building and running

The only requirements are OCaml and dune; menhir and ocamllex come from opam.
It was developed with OCaml 5.4 and dune 3.21.

```sh
dune build
dune exec src/mink.exe examples/poly.mnk
dune test                     # golden tests (dune promote to accept new output)
```

```sh
./_build/default/src/mink.exe examples/dep.mnk
```

## The command line

```
mink [options] file.mnk

  -s, --system NAME   check with this system, overriding #system
      --list          list the systems and what each one is about
      --dump-anf      print the A-normal form of every binding
      --dump-vc       print every verification condition as SMT-LIB 2
      --dump-infer    print the unifications inference performs (hm only)
      --smt CMD       decide verification conditions with CMD instead of the
                      built-in procedure (try --smt "z3 -in")
      --trace         print every step the machine takes
  -h, --help
```

A program says which type system it wants on its first line:

```sml
#system poly
```

`-s` overrides it, which is how the same file can be shown to two systems.
Every binding is reported as `name : type = value`; the `dep` system prints a
normal form where the others print a value, because normalising is what running
means there.

## The systems

| system | what it is | inferred | must be written |
| --- | --- | --- | --- |
| `hm` | Hindley-Milner as Algorithm W: substitutions composed by hand | everything it can express | nothing (and rank-2 cannot be expressed) |
| `poly` | higher-rank predicative polymorphism, bidirectional (Dunfield & Krishnaswami 2013) | monotypes, rank-1 generalisation | polymorphic arguments (rank 2 and up) |
| `row` | the same inference with mutable cells and levels, over row types: extensible records and variants | everything | nothing |
| `refine` | refinement types on base types, verified by a solver | nothing about predicates | parameter and result types |
| `linear` | linear types with `lin`/`un`, and session-typed channels | closure qualifiers | parameter types, protocols |
| `dep` | dependent types: universes, Π, Σ, `nat`, equality, by normalisation by evaluation | results of application and elimination | argument types, `val` types, pair types |

Each system rejects the type syntax it does not own, and says whose it is:

```
$ mink -s poly examples/rows.mnk
examples/rows.mnk:6:22: type error: records and variants belong to #system row
```

## The language

SML-flavoured: `val` and `fun` declarations, `fn x => e`, `case e of`,
`let ... in ... end`, `(* nesting comments *)`, `'a` type variables,
`andalso`/`orelse`/`div`/`mod`/`<>`. Equality is `==`.

```sml
#system poly

val id = fn x => x                      (* val does not recur *)
fun twice f x = f (f x)                 (* fun does *)

fun sumTo n =
  let fun go i acc = if i > n then acc else go (i + 1) (acc + i)
      val start = 0
  in go start 0 end
```

Types are written in three places, and all three mean the same thing:

```sml
val useTwice : (forall 'a. 'a -> 'a) -> int * bool = fn f => (f 1, f true)
fun inc (n : { v : int | v >= 0 }) : { v : int | v > 0 } = n + 1
val n = (someExpression : int)
```

There is no separate grammar of types: a type *is* a term, so `x * y` is one
node that means multiplication or a product depending on where it stands, and
each system reads the tree it understands out of the one the parser builds.
[The grammar chapter](../doc/1-syntax.md) has the whole grammar in EBNF, and
explains that choice.

### Inference with nothing written — `hm` and `row`

```sml
val id = fn x => x                      (* forall 'a. 'a -> 'a *)
fun twice f x = f (f x)                 (* forall 'a. ('a -> 'a) -> 'a -> 'a *)
val usedTwice = let val same = fn x => x in (same 1, same true) end
```

`hm` is Algorithm W written the way it is presented on paper: unification
returns a substitution, and generalisation asks what is free in the type but not
in the environment. `row` is the same inference done the way an implementation
would, with mutable cells and levels — and with rows on top. `--dump-infer`
shows `hm` working:

```
$ dune exec src/mink.exe -- --dump-infer tests/infer.mnk
-- infer twice
  unify  ?2  ~  ?3 -> ?4
  solve  ?2 := ?3 -> ?4
  ...
  generalise (?5 -> ?5) -> ?5 -> ?5  over env {}  =>  forall 'a. ('a -> 'a) -> 'a -> 'a
```

### Records, variants and rows — `row`

```sml
val origin = { x = 0, y = 0 }           (* { x : int, y : int } *)
fun getX r = r.x                        (* { x : 'a, ..'b } -> 'a *)
fun shiftX r dx = { x = r.x + dx, ..r \ x }
val shadowed = { x = true, ..origin }   (* { x : bool, x : int, y : int } *)

fun describe v =
  case v of
    `Int n => n
  | `Bool b => if b then 1 else 0
  | other => 0                          (* leaves the variant open *)
```

`r.l` selects, `r \ l` removes, `{ l = e, ..r }` extends, and `..'r` in a type
is a row variable. Labels are scoped: extending with a label that is already
there shadows it, and removing uncovers what was underneath.

### Refinements — `refine`

```sml
fun safeDiv (a : int) (b : { v : int | v <> 0 }) : int = a div b
fun abs (n : int) : { v : int | v >= 0 } = if n < 0 then -n else n
```

`{ v : B | p }` is the values of `B` satisfying `p`; `(x : A) -> B` lets the
result talk about the argument. Predicates are arithmetic, comparison and
logic over the names in scope. `div` and `mod` demand a non-zero right operand.
`--dump-vc` shows the obligations.

### Linearity and sessions — `linear`

```sml
fun classify (c : chan (?int ; !bool ; stop)) : unit =
  let val (n, c) = recv c
      val c = send (n > 10) c
  in close c end

val asked =
  let val c = fork classify
      val c = send 42 c
      val (big, c) = recv c
      val () = close c
  in big end
```

A channel endpoint is linear and its type is the protocol that remains.
`!A ; S` sends, `?A ; S` receives, `stop` finishes, `+{ `l : S }` is our choice
and `&{ `l : S }` is theirs; `fork` hands the dual end to a new process.
`lin`/`un` qualify other types, and `-o` is the linear arrow — which a closure
gets automatically when it captures something linear.

### Dependent types — `dep`

```sml
val plus : nat -> nat -> nat =
  fn n => fn m => natrec (fn _ => nat) m (fn _ => fn r => suc r) n

val vec : Type -> nat -> Type =
  fn a => fn n => natrec (fn _ => Type) unit (fn _ => fn rest => a * rest) n

val head : (a : Type) -> (n : nat) -> vec a (suc n) -> a =
  fn a => fn n => fn v => fst v
```

`Type`, `Type 1`, … are the universes; `(x : A) -> B` and `(x : A) * B` are Π
and Σ; `nat` comes with `suc` and `natrec`; equality comes with `Eq A a b`,
`refl` and `J`. There is no recursion — `fun` does not bind its own name here.

## How it is put together

One file per concern:

| file | what it does |
| --- | --- |
| `loc.ml` | source positions, and the one exception every error is |
| `lexer.mll` | ocamllex scanner (nesting comments, `'a`, the `#system` directive) |
| `parser.mly` | menhir grammar, conflict-free, one tree for types and terms |
| `ast.ml` | that tree |
| `system.ml` | what the command line needs from a type system |
| `hm.ml` | Hindley-Milner as Algorithm W: substitutions, unification, generalisation |
| `poly.ml` | ordered contexts, bidirectional checking, higher-rank polymorphism |
| `row.ml` | unification with levels, row unification, scoped labels |
| `refine.ml` | refinement types: subtyping becomes implication |
| `logic.ml` | the logic those implications are written in, and SMT-LIB 2 |
| `solver.ml` | the built-in decision procedure (DPLL over atoms, Fourier-Motzkin) |
| `smt.ml` | where a verification condition goes: built in, or an external solver |
| `linear.ml` | qualifiers, context splitting, session types and duality |
| `dep.ml` | dependent types, normalisation by evaluation, universes |
| `anf.ml` | normalisation to A-normal form |
| `core.ml` | the A-normal form, and its printer |
| `machine.ml` | the CEK machine, plus a store for channels |
| `mink.ml` | the command line |

Adding a system means writing one file and adding it to the list in `mink.ml`.
Nothing else has to change: the parser already accepts more syntax than any one
system uses, and the machine already runs whatever passes.

## Layout

```
src        the implementation
examples   one file per system: hm, poly, rows, refine, session, dep
tests      golden tests, and errors/ for the messages
```

The examples are the tests: `dune test` runs them all and diffs their output,
and every program in `tests/errors/` is expected to fail with the message in
`tests/errors.expected`. Three tests are about the machinery rather than a
system: `anf.mnk` dumps A-normal form, `vc.mnk` dumps verification conditions,
and `compare.mnk` is checked by `hm` and by `row` so that the two Hindley-Milner
implementations can be seen agreeing.
