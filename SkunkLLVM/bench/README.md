# bench

Four programs, each aimed at one thing a back end is supposed to be good at.
They are SkunkML's, unchanged, so the two back ends can be compared on the same
code.

```
$ dune build
$ bench/run.sh
```

`run.sh` compiles every `bench/*.sk` twice — `-O2` and `-O0` — runs both, runs
the interpreter, and prints the three wall times and an instruction count next
to the checksum. It fails loudly if the three disagree. That check is the point:
the whole project rests on the claim that `skunk` and `skunkllvm` are two
readings of one language, so a benchmark that runs fast and prints something
else is worth nothing.

`-O0` is in the table because it is the honest floor. LLVM runs no pass at all
there, so the gap between the two columns is what `default<O2>` is worth on
this program. `-O0` finishing at all is also what says `musttail` is doing its
job: LLVM's own sibling-call optimisation does not run there, and every loop in
this language is a tail call.

Each program prints one line, and it is a checksum rather than a picture or a
sorted array, so that comparing the runs is `cmp` and not judgement.

## What each one is for

**`fib.sk` — the cost of a call.** Naive Fibonacci, two calls per node and no
work between them. Nothing allocates, nothing loops, so the time is entry,
return, and the branch in between. LLVM wins this one by two, and the margin is
register allocation and block placement.

**`nqueens.sk` — allocation and lists.** Eleven queens by backtracking. Every
partial solution is a cons cell that dies one recursion later, and every call
carries a tuple, so most of the time is the allocator and the walk over cells
that were just made.

**`sort.sk` — the store.** Insertion sort over seven thousand elements,
quadratic on purpose: the inner loop is `Array.sub`, a comparison and
`Array.update` and nothing else. This is the one this back end loses badly, and
the reason is visible in `-S`: `Array.sub (a, j)` passes a tuple to a
one-argument function, so every array read allocates two words, and nothing
here inlines it away ([14章](../doc/14-opt.md)の4節).

**`aobench.sk` — arithmetic.** Ambient occlusion over three spheres and a
plane, in Q16.16 fixed point because neither compiler has `real`. Long runs of
multiplies and square roots, a short-lived tuple per vector, and an array of
sample directions read on every shadow ray. `div` by a constant is everywhere,
which is why writing `sdiv` instead of calling the runtime is worth a third of
the time here.

## Comparing with SkunkML

The numbers in [14章](../doc/14-opt.md) put these next to SkunkML's
hand-written amd64 back end on the same four programs. If both trees are built,
that is:

```sh
../SkunkML/_build/default/src/compiler/skunkc.exe -o /tmp/a bench/fib.sk
./_build/default/src/llvm/skunkllvm.exe -o /tmp/b bench/fib.sk
```

They have to print the same thing too — one front end, three back ends.
