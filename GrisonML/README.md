# GrisonML

An interpreter for the ML dialect whose grammar is in
[`spec/grammar.ebnf`](spec/grammar.ebnf): ML type variables, whitespace
application, `val` / `fun` / `type` with datatypes folded into `type`, `fn ...
=> ...`, `case ... of`, `let ... in ... end`, `begin ... end`, `and` / `or`,
`==` and `!=`, `sig` and `mod` in place of signature and structure, a functor
written as a `mod` with parameters, `import ... as ...` in place of `open`,
and `infixl` / `infixr` / `infix` with an explicit precedence.

Everything the grammar declares is implemented, and the type system is the one
the grammar implies rather than a subset of it: Hindley-Milner inference,
semantic signatures, opaque ascription, `where type`, generative functors, and
row-polymorphic records.
The front end is ocamllex and menhir, the back end is a tree walker, and there
is a coverage check between them.

```grison
sig ORD
  type t
  val compare : t * t -> int
end

mod MakeSet (O : ORD) : SET where type elem = O.t
  type elem = O.t
  type t = elem list

  val empty = []

  fun member x s =
    case s of
      [] => false
    | h :: rest => if O.compare (x, h) == 0 then true else member x rest

  fun insert x s = if member x s then s else x :: s
end

mod IntSet = MakeSet(IntOrd)
```

## Build and run

```sh
cd interpreter
dune build                          # builds _build/default/src/grison.exe
dune exec src/grison.exe examples/tour.gr
dune exec src/grison.exe -- -t examples/tour.gr   # print the top-level types
dune test                           # golden tests (dune promote to update)

echo 'val _ = println "hi"' | dune exec src/grison.exe   # no file reads stdin
```

The examples are [`tour.gr`](interpreter/examples/tour.gr) for the core
language, [`modules.gr`](interpreter/examples/modules.gr) for signatures and
functors, and [`calc.gr`](interpreter/examples/calc.gr), which is a lexer, a
recursive descent parser and an evaluator for arithmetic, written in GrisonML.

## The language

A program is a sequence of declarations; there are no top-level expressions,
so a program prints by binding one:

```grison
val _ = println "hello"
```

### Values and functions

```grison
val greeting = "grison"
val pi = 3.14159

fun square n = n * n
fun add a b = a + b          (* curried, by whitespace application *)
val add10 = add 10

fun zip xs ys =              (* several clauses choose together *)
    case (xs, ys) of
      (h :: t, u :: v) => (h, u) :: zip t v
    | (_, _) => []
```

A `fun` declaration may have several clauses separated by `|`, each repeating
the function's name, and the clauses match on all the parameters at once.  A
return type may be written after the parameters, `fun f x : int = ...`, and a
pattern may say what it matches wherever a bracket closes it, `fun mirror (p :
point) = ...`.

Adjacent `fun` declarations are one recursive group, so mutual recursion is
written by writing the functions next to each other:

```grison
fun even n = if n == 0 then true else odd (n - 1)
fun odd n = if n == 0 then false else even (n - 1)
```

### Types and datatypes

`type` declares both, and which one it is depends on whether the right-hand
side starts with a constructor:

```grison
type name = string
type ('k, 'v) entry = { key : 'k, value : 'v }
type 'a option = None | Some 'a
type 'a tree = Leaf | Node ('a tree * 'a * 'a tree)
```

A constructor takes at most one argument, so a constructor of several things
takes a tuple.  Lists are the one datatype the language does not declare:
`[]`, `::` and `[a, b, c]` are built in, and a list pattern is a `::` chain.

### Expressions

`fn` with several rules, `case ... of` with guards, `if ... then ... else`
with the `else` required, `let ... in ... end`, `begin e; e; e end`, tuples,
lists, records with punning, and field projection:

```grison
val classify =
  fn n =>
    case n of
      k if k < 0 => "negative"
    | 0 => "zero"
    | k if k % 2 == 0 => "even"
    | _ => "odd"

val p = { x = 1, y = 2 }
val q = { x = p.x, y = 3 }
val name = "Bob"
val r = { name, age = 7 }        (* punning: name = name *)
```

In `begin`, every expression but the last has to be `unit`.

### Operators

The precedence ladder of the grammar -- `or`, `and`, comparison, `::`,
additive, multiplicative -- is the *default* fixity table, and `infixl`,
`infixr` and `infix` change it.  An operator nobody has declared is `infixl 9`.
`infix` is the non-associative one, so `1 < 2 < 3` is rejected.

```grison
infixr 1 @@
infixl 6 <+>

fun (@@) f x = f x
fun (<+>) a b = a ^ " " ^ b

val _ = println @@ "these" <+> "compose"
```

An operator names a value wherever a lower-case identifier does -- in an
expression, in a binding, and in a specification:

```grison
val plus = (+)                                   (* passed to a function *)
val (<+>) : point -> point -> point = fn a => fn b => ...
sig VEC  type t  val (<+>) : t -> t -> t  end    (* so a sealed mod exports it *)
```

`::` is the one that is not a value: it names the list constructor, so `(::)`
is the function `'a * 'a list -> 'a list` and `fun (::) a b = ...` is rejected,
because `a :: b` is decided before any binding could be.  Its fixity can still
be declared, since that is only a question of shape.  `=`, `|`, `:`, `->` and
`=>` are punctuation and cannot be named at all, although they are made of
operator characters.

### Modules

A `sig` declares types, values, sub-modules and `include`; a `mod` defines
them.  A signature on a module seals it, and the sealing is opaque: a type the
signature leaves abstract is a type constructor nobody outside the module has,
whatever the module defines it as.  `where type` makes an abstract type
manifest at the point of use, and reaches through `include` and through
sub-modules.

```grison
sig COUNTER
  type t
  val zero : t
  val bump : t -> t
  val get : t -> int
end

mod Counter : COUNTER
  type t = int
  val zero = 0
  fun bump n = n + 1
  fun get n = n
end

val _ = println (intToString (Counter.get (Counter.bump Counter.zero)))
val bad = Counter.zero + 1     (* rejected: t is not int out here *)
```

A `mod` with parameters is a functor, and it is generative: two applications
produce two abstract types, even of the same argument.  A module expression
applies exactly one argument, so a functor of two parameters is applied by
binding the half-applied one to a name:

```grison
mod HalfPair = MakePair(IntOrd)
mod IntStringPair = HalfPair(StringOrd)
```

`import M` brings everything M defines into scope, `import M as N` renames it,
`import M (f, g)` takes only what it names, and `include M`, inside a `mod`,
splices M's contents into the module being defined.  A signature cannot name a
constructor -- there is no variant specification in the grammar -- so sealing
a module always hides its constructors, and an abstract type is reached only
through the functions the signature exposes.

### The prelude

`option` and `either`, `id`, `ignore`, `fst`, `snd`, `sepBy`, and the modules
`Option` and `List` are written in GrisonML in
[`src/prelude.ml`](interpreter/src/prelude.ml), and go through the same five
phases a program does before the program does.  The primitives under it are in
[`src/prims.ml`](interpreter/src/prims.ml): arithmetic and comparison, `^`,
`print` and `println`, the conversions between `int`, `real`, `char`, `bool`
and `string`, `size` / `substring` / `explode` / `implode`, and `error`.

## Types

Inference is Hindley-Milner with Remy's levels, and generalization is
unrestricted: the language has no reference and no assignment, so there is
nothing for the value restriction to protect.

**Overloading.**  The grammar writes `+` for both `int` and `real` and `<` for
both `int` and `string` and gives no way to declare either.  A type variable
therefore carries a class -- `Num` over `{int, real}`, `Ord` over `{int, real,
char, string}` -- which unification narrows.  Unlike Standard ML, an
unresolved class is *quantified* rather than defaulted to `int`:

```
val double : 'a[num] -> 'a[num]
val between : 'a[ord] -> 'a[ord] -> 'a[ord] -> bool
```

Standard ML defaults because it has to choose a machine instruction; here the
primitive dispatches on the value it is handed, so keeping the quantifier
costs nothing and `double` works on both `int` and `real`.

**Records** are structural, and a record type is a *row*: a list of fields
ending either in nothing, which is that record and no other, or in a variable,
which is every record that has them.  `{x : int, y : int}` is closed and
`{x : int | 'r}` is open, and the second is what a projection asks for, so

```grison
fun distance a b =
  let val dx = a.x - b.x
      val dy = a.y - b.y
  in dx * dx + dy * dy end
```

is inferred as `{x : 'a[num], y : 'a[num] | 'b} -> {x : 'a[num], y : 'a[num] |
'c} -> 'a[num]` and takes any two records that have an `x` and a `y`, whatever
else is in them.  A record pattern is open the same way, so `fun shift {x, y}
= ...` does not care what else the record carries; a record expression is
closed, since it is exactly what it lists.  A row variable carries the labels
it may not gain, which is what stops a record from being given a field twice.

An annotation closes a record where you want it closed, and it can go on a
pattern, `fun mirror (p : point) = ...`, or on the binding, `val getX : point
-> int = ...`.  An annotation on a binding is pushed into `fn`, `case`, `if`,
`let` and `begin`, so it reaches the parameter it needs to.

**Equality** is structural and works at any type, and raises at run time on a
function.  The grammar has no equality types to say so in.

**Coverage** is checked with Maranget's usefulness relation, and reported as a
warning rather than an error:

```
warning: warnings.gr:9:27: this match does not match every value: _ :: _ :: _ is not matched
warning: warnings.gr:11:50: this rule cannot be reached
```

A rule with a guard is left out of the matrix, so it neither covers what
follows it nor makes it unreachable.

## Modules, and how the checker does them

A signature is elaborated twice against the module it is matched with, by the
same function with one argument different.

*Realized*: every abstract type in the signature stands for the type the
module actually has.  Values are checked against this copy, so the check knows
that `t` is `int` where the module says so.  A value matches when the module's
scheme is at least as general as the specification's, which is the
specification skolemized against the module's type instantiated.

*Sealed*: every abstract type in the signature is a type constructor nobody
else has.  This copy is what the rest of the program sees, and it is what
makes ascription opaque.

A functor keeps its body as syntax, together with the environment it was
written in, and elaborates that body again at every application.  That is
where generativity comes from -- two applications run the elaboration twice,
so the types they produce are two different type constructors -- and it is
also what gives the body the argument's own types to work with.  The body is
elaborated once more at the definition, against a parameter that is nothing
but its signature, so that a body that could never work is rejected where it
is written rather than where it is used.  The evaluator does the same thing
with values, and seals a module by dropping the names its signature does not
mention, so that a later `import` cannot bring back a name the checker had
already decided was not there.

## Where this differs from the grammar file

The grammar is followed except in these places, each of which is a place where
the file is either ambiguous, self-contradicting, or narrower than it plainly
means to be.

- **The operator ladder and the fixity declarations contradict each other.**
  The file fixes the precedence of `+` and `::` in its productions and also
  lets `infixl 7 +` be written.  Only one of the two can belong to the parser,
  so neither does: an infix chain is parsed flat and shaped afterwards, with
  the ladder as the starting table.  Without this, `infixl` / `infixr` /
  `infix` would parse and mean nothing.
- **`fn`, `if` and `case` in primary position make the grammar ambiguous**,
  because the expression that ends one of them can always be continued
  instead.  Every such choice is resolved greedily, so `f if a then b else c d`
  is `f (if a then b else (c d))`, and `(if ...).x` needs its parentheses.
- **`type-application` allows one postfix constructor**, so `int list list` is
  not derivable.  A chain is allowed here.
- **Only `function-name` and `import-name` can name an operator**, which leaves
  one definable and importable and nothing else: it could not be written in an
  expression, given a type by a `val`, or specified in a `sig` -- so a sealed
  `mod` could never let one out, and there would be no way to annotate one,
  which for an operator over records is the only way to type it at all.
  `( operator )` is a primary-expression, a value-declaration and a value-spec
  here as well.
- **There is no `and` for declarations**, so a function could only ever see
  itself.  A run of adjacent `fun` declarations is one recursive group.
- **The header comment and the productions disagree**: the comment says `match
  ... with` and that "match has no end", the productions say `case ... of`.
  The productions win.
- **`atomic-pattern` cannot carry a type**, so nothing in the file can say what
  a parameter is: the only annotations are on a `val` and on the result of a
  `fun`, and neither reaches a parameter.  A pattern may be annotated here
  wherever a bracket closes it -- `(p : point)`, `(n : int, s)`, `[x : int]`,
  `{f = (n : int)}` -- which is every position where `: type` cannot be read
  as belonging to the `val` or the clause instead.
- **`record-type` is closed**, so a row-polymorphic record type cannot be
  written down at all, although it is what is inferred for every projection.
  `{x : int | 'r}` is one here, and `'r` is a row variable.
- **`char-content` and `string-char` are declared implementation-defined**;
  they are any character other than the delimiter, plus the escapes `\n`,
  `\t`, `\r`, `\0`, `\\`, `\"` and `\'`.
- **A qualified name has no space around its dots**, which is what separates
  `M.x`, a value in a module, from `r.x`, a field of a record.  `M.r.x` is the
  field `x` of the record `M.r`.
- **A `signature-path` with a dot cannot resolve**, since `module-item` has no
  signature definition in it and so a signature can only be declared at the
  top level; it is a reported error rather than a parse failure.
- **`precedence` is a digit**, so fixities run from 0 to 9, and an operator
  that was never declared is `infixl 9`.

## The files

```
spec/grammar.ebnf           the grammar, as given
interpreter/src/
  ast.ml                    the surface syntax
  lexer.mll                 qualified names, operator runs, escapes
  parser.mly                the grammar, as LALR(1), with no conflicts
  fixity.ml                 flat infix chains into trees
  desugar.ml                fun clauses into fn and case; recursive groups
  types.ml                  types, levels, unification, classes, schemes
  exhaust.ml                Maranget's usefulness relation
  typecheck.ml              inference, signatures, sealing, functors
  value.ml                  runtime values and module fragments
  prims.ml                  the primitives, each with its type beside it
  prelude.ml                the prelude, in GrisonML
  eval.ml                   the tree walker
  driver.ml                 the five phases, twice
interpreter/examples/       tour.gr, modules.gr, calc.gr
interpreter/tests/          golden tests, and one program per error message
```
