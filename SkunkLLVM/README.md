# SkunkLLVM

[SkunkML](../SkunkML)'s front end, with LLVM behind it.

Same language — Standard ML with modules and functors, Hindley–Milner
inference, and four intermediate languages between the source and the machine
that runs it. Same parser, same inference, same decision trees, same closure
conversion. What is different is everything after that:

```
                     SkunkML                      SkunkLLVM
   Flat  ────────▶   value SSA                    LLVM IR, as text
                     dominators, opt, licm        clang -O2
                     instruction selection (DP)   LLVM's selector
                     graph colouring              LLVM's allocator
                     its own assembler            LLVM's
                     its own ELF linker           clang -nostdlib -static
                     ────────────────────         ────────────────────
                     6532 lines                   1431 lines
```

```sh
$ dune build
$ ./_build/default/src/llvm/skunkllvm.exe -o /tmp/tour examples/tour.sk
$ /tmp/tour | diff - <(./_build/default/src/interpreter/skunk.exe examples/tour.sk) && echo same
same
```

That diff is the test the whole back end is aimed at, and `dune test` runs it
for every example: LLVM may pick different instructions every time it is
updated, but the program may not print anything different.

## Two lines do most of the work

**A join point is already a basic block with phi nodes.** The front end writes
join points down — a `case` whose value is wanted becomes a label its arms jump
to, and a decision tree's shared arm becomes another. Their parameters *are*
the phis. So the famous SSA construction, placing phi-functions on dominance
frontiers, is never run; nor is variable renaming; nor is the dominator tree
built at all. LLVM's verifier is what answers "is every use dominated by its
definition", and `dune test` asks it for every program in the repository.

```
  join k (v) =                    "join.k":
    let t.62 = +(v, 100)            %"v" = phi i64 [ %_4, %"arm" ], [ %_6, %"arm.0" ], [ %_8, %"default" ]
    ret t.62                        %_9 = add i64 %"v", 201
  switch x.12 of                    %_10 = sub i64 %_9, 1
  | 1 => jump k (y)                 ret i64 %_10
  | 2 => ...
```

**A tail call is `musttail`.** There are no loops in this language: a join
point can only jump outwards, so a function's control-flow graph is acyclic and
every loop a program has is a tail call. A back end that merely *hoped* for a
tail call would turn `fun count (0, acc) = acc | count (n, acc) = count (n - 1,
acc + 1)` into a stack overflow. So it is not a hope — `musttail` fails to
compile rather than compiling to a call — and the signature that makes it legal
is the same one that lets a call go through a word read out of a closure: every
code block is `i64 (i64, i64)`. Twenty million iterations at `-O0`, where
LLVM's own sibling-call optimisation does not run.

## Nothing is linked against LLVM

The compiler builds a module by **printing it**, and hands the `.ll` to
`clang`. There is no library to link, no binding, no C stubs and no headers —
`ldd` on the compiler shows libc and libm.

That is not only because the official OCaml binding is unusable here (opam stops
at 19; this machine has LLVM 22; 19 is not in the distribution's repositories
either). It is because everything the API makes you carry, the text already has
a word for.

- **Enumeration constants.** With the C API, `LLVMBuildICmp`'s second argument
  is `40` for a signed less-than, and knowing that 32 is where the integer
  predicates start is your problem, not the linker's. In text it is `slt`.
- **`dso_local`.** Without it a *static* executable still reaches through the
  PLT and the GOT. There is no `LLVMSetDSOLocal` in the C API — you have to set
  hidden visibility and let `maybeSetDsoLocal` notice. In text it is
  `dso_local`.

What text costs instead is **names**: unnamed values have to be numbered in
exactly the order LLVM would have numbered them, so `ir.ml` names everything
(`%_7` for a temporary, the front end's own spelling in quotes for anything
else) and one table per function keeps the two apart — labels included, since
in LLVM a label and a local value share a namespace. And a phi has to be filled
in after its line would have been printed, so blocks are buffered until the
function ends. That second one is not a cost of text: it is the same shape the
LLVM builder has, for the same reason.

Verification is clang's parser and verifier. When a module is wrong, the
message comes from LLVM and the `.ll` is left on disk with its path printed.

## What the compiler still has to know

`clang -O2` is one line, and it is the whole optimiser: folding, SCCP, GVN,
DCE, scheduling, instruction selection, register allocation. What is left in
`lower.ml` is only what LLVM has no way to know.

- **An integer is 2n + 1**, so `a + b` is `a + b - 1`, and the tagged
  representation is monotone — which is why two integers compare as their
  tagged words do, with no untagging at all.
- **A closure's first word is its code**, so a call is a load and an indirect
  call, and `Capture i` is word *i* + 1.
- **A `case` over a datatype compares the tag in a descriptor**, one word back
  from the value.
- **`div` by a constant is worth writing as `sdiv`.** Not for the division —
  for handing LLVM a division it can *see*, so that strength reduction (which
  it knows and this compiler does not) can have it.
- **`true` is a heap block.** `bool` is an ordinary datatype, so a comparison
  has to produce one, and the `case` that reads it a line later would go back to
  memory for a descriptor and a tag to learn what the comparison already knew.
  So the `i1` is kept beside the block, the `case` switches on it, and the block
  is left for whoever finds it dead.

## And a garbage collector that had to change

The collector is mark-sweep with conservative roots, and nothing moves, which
is what makes guessing safe. SkunkML's version asks only about block *starts*,
because its own code generator kept the start of a block in a register for as
long as it wanted any field of it.

LLVM makes no such promise. It will compute `v + 24` once and let `v` die, so
the only surviving reference to a live cell can be a pointer into the middle of
it. So the question had to change from "is this a block's start" to "which
block is this address inside", answered by walking back to the nearest start
byte and checking that the block there reaches this far — bounded by the widest
block ever allocated.

That is the cost of putting a real optimiser in front of a conservative
collector. It is also why the runtime is *not* emitted into the same module:
inlining `collect` would move the bottom of the stack scan, and inferring
`noalias` on `skunk_alloc` would let a store into a fresh block sink past the
next allocation — where the collector would read the field before it was
written.

## Is it faster?

Sometimes. Four benchmarks against SkunkML's hand-written amd64 back end;
seconds, best of three for the compiled columns and a single run for the
interpreter, which is 200–500× either way:

| | `skunkc` | `skunkllvm -O2` | `-O0` | interpreter |
|---|---|---|---|---|
| aobench | **0.134** | 0.260 | 0.275 | 35.3 |
| fib | 0.236 | **0.109** | 0.163 | 54.3 |
| nqueens | **0.144** | 0.147 | 0.177 | 27.5 |
| sort | **0.073** | 0.444 | 0.478 | 39.1 |

`fib` is calls and branches and nothing else, and LLVM wins it twice over.
`sort` is an inner loop of `Array.sub`, a comparison and `Array.update`, and it
loses by six.

The reason is one thing, and it is not a missing LLVM pass. `Array.sub (a, j)`
is a call to a one-argument function with a tuple, so **every array read
allocates two words on the heap** — and nothing inlines it away. LLVM cannot:
inlining needs to know the callee, and after closure conversion the callee is a
word in a heap block. The pass that could have done it is SkunkML's `inline.ml`,
which runs on `Flat`, *before* the information is thrown away.

So what this back end gives up, in exchange for deleting 5100 lines of back end, is
inlining — and only inlining. Everything downstream of it, LLVM does at least
as well. [14章](doc/14-opt.md) has the measurements and the assembly.

## Where things are

The implementation is in [`src/`](src) and the book is in
[`doc/`](doc/index.md): see [`src/README.md`](src/README.md) for the language,
the two command lines and a map of the source, and
[`doc/index.md`](doc/index.md) for a chapter per pass. Chapters 1–9 are
SkunkML's, because the front end is; the new ones are
[LLVM の呼び方 — テキストを書いて渡す](doc/10-llvm.md)、[Flat から LLVM IR へ](doc/11-lower.md)、
[保守的 GC と最適化器](doc/13-gc.md)、
そして[LLVM に見えるもの、見えないもの](doc/14-opt.md)。取り決めだけ見たいなら
[ABI リファレンス](doc/12-abi.md)。

## What is deliberately missing

No exceptions, no characters, no user-defined infix operators, no polymorphic
recursion, no separate compilation, and no inliner. Reals the interpreter has
and the compiler does not: there is no representation for one yet and it says
so rather than guessing. Each chapter of the book ends with the list for its
pass, and with why.
