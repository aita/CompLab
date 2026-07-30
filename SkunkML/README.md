# SkunkML

A Standard ML with modules and functors, Hindley–Milner inference, and four
intermediate languages between the source and the machine that runs it.

```sml
signature ORD = sig type t val compare : t * t -> int end

functor MakeSet (O : ORD) :> SET where type elem = O.t = struct
  type elem = O.t
  type set = elem list
  val empty = []
  fun add (x, []) = [x]
    | add (x, y :: ys) =
        let val n = O.compare (x, y)
        in if n < 0 then x :: y :: ys else if n = 0 then y :: ys else y :: add (x, ys)
        end
end

structure IntSet = MakeSet (IntOrd)
structure StringSet = MakeSet (StringOrd)
```

Two applications of that functor make two different types, and the interpreter
says so:

```
val ints : IntSet.set = [1, 2, 3, 4, 5, 6, 9]
val words : StringSet.set = ["apple", "pear"]
```

```
$ dune build
$ dune test
$ ./_build/default/src/interpreter/skunk.exe examples/tour.sk
$ ./_build/default/src/compiler/skunkc.exe --dump-ssa tests/join.sk
```

The point of the exercise is the road from the source to the value, and the
fact that it has four surfaces rather than one:

```
Surface AST                 SML, with a grammar of types of its own
   |   inference and normalisation, in one type-directed pass
   v
Typed Core in A-normal form patterns and lambdas still in it, and types on
   |                        every binding -- because the next pass needs them
   |   pattern-match compilation: decision trees
   v
Typed Core with switches    ... and the first join points
   |   closure conversion
   v
ANF + explicit join points  code blocks, captures, and labels that are not
   |                        closures
   v
a CESK machine
```

Every one of those can be looked at: `--dump-core` prints the second,
`--dump-flat` the fourth, and `--trace` the machine taking the fourth apart.

## What each surface is for

**Types survive into Core** because pattern-match compilation needs them.
Deciding whether a `switch` on a datatype needs a default means knowing how
many constructors that datatype has, and that is a question about types, asked
after inference is over.

**Join points appear twice, for two reasons.** A `case` whose value is wanted
by something else cannot be written in plain A-normal form, so its continuation
becomes a label the arms jump to — where a compiler without join points would
allocate a closure. And a decision tree reaches the same arm from several
leaves, so a shared arm becomes a label too. An arm reached once is written out
where it is used, so a dump shows a `join` exactly where something is shared.

**Closure conversion converts closures and not join points**, which is the
whole reason the two are told apart. A lambda's free variables are captured
into a block; a join point's free variables stay free, because a jump can only
come from inside the block that defines it.

**The machine has a store** because the language has `ref` and `array`.
Everything else it builds is built once and never changes; a `ref` is one
address and an array is a run of them, so a variable denotes a place and the
store says what is in it. That is the S that CEK does not have.

## Modules

A signature is a semantic object: lists of type components, value schemes and
sub-structures. Every type it declares is a *hole*, and matching a structure
against it fills the holes in. What happens to that realisation afterwards is
the only difference between the two ascriptions — `:` keeps it, so `X.t` is
still `int`; `:>` throws it away, so nothing outside can see through it.

A functor is the same idea one level up: its parameter's holes are its type
parameters, its body is checked once, and an application pushes the argument's
realisation through the body's signature. Types the body itself made are given
new identities at every application, which is what makes functors generative.

None of that survives into Core. A structure is a record, a functor is a
function, and the passes after elaboration have never heard of either.

## And a compiler

There is a second back end in [`src/compiler/`](src/compiler), sharing the
front end. It starts from Flat — where there are no modules, no patterns and no
nested functions left — and builds **value SSA**: a value is an operation
together with the values it uses, not a name something was assigned to.

Building it is a change of shape and almost nothing else, because *a join point
with parameters is a block with phi-functions*. The famous construction —
placing phi-functions on dominance frontiers — is never run: the phis arrived
already placed. The dominator tree is still built, and used to check the claim
rather than assert it: every use dominated by its definition, on every program
in the repository.

From there it goes all the way to a file. Instruction selection covers the value
graph with amd64 tiles, choosing them with a dynamic program over the cost of
producing each value as each kind of operand -- and the DP only has to run where
the graph branches, which value SSA answers with a field rather than an
analysis. The phis become copies, and then the interference graph is coloured:
Chaitin's algorithm with Briggs' optimistic push, spilling to the frame and
re-running until it fits.

Then it writes the executable itself. There is no `as` and no `ld` after
selection: the compiler encodes the instructions, assigns the addresses, patches
the relocations and writes a static ELF64 -- and since there is no linker to
hand a C object to, the runtime is written in amd64 too -- including the garbage
collector. `mmap` for the heap, `write` for output, `exit` at the end, and no
libc.

The collector is mark-sweep with conservative roots, and the one decision that
shapes it is that roots are *guessed* rather than known: every word of the stack
and the data section is asked "could this be a pointer?". That is safe here only
because nothing moves -- a word that looks like a pointer but is not one keeps an
object alive, and never breaks anything. Two things make the guess good: an
integer is 2n + 1, so an integer can never be mistaken for a pointer, and a map
with a byte per heap word says where blocks actually start, so a raw length that
lands in the heap is rejected rather than followed into nonsense.

```sh
$ ./_build/default/src/compiler/skunkc.exe -o /tmp/tour examples/tour.sk
$ /tmp/tour | diff - <(./_build/default/src/interpreter/skunk.exe examples/tour.sk) && echo same
same
```

That diff is the test the whole back end is aimed at, and `dune test` runs it for
every example: the compiler may pick different instructions every time it
changes, but it may not print anything different.

The implementation is in [`src/`](src) and the book is in
[`doc/`](doc/index.md): see [`src/README.md`](src/README.md) for the language,
the two command lines and a map of the source, and
[`doc/index.md`](doc/index.md) for a chapter per pass. Two to start with, in
Japanese: [プログラムが通る道](doc/00-pipeline.md) と
[パターンマッチを決定木にする](doc/05-matching.md)。バックエンドなら
[命令選択](doc/12-select.md) から [アセンブラ、リンカ、実行時](doc/14-elf.md) まで。

## What is deliberately missing

No exceptions, no characters or reals, no user-defined infix operators, no
polymorphic recursion, no separate compilation, no optimiser and no garbage
collector. Each chapter of the book ends with the list for its pass, and with
why.
