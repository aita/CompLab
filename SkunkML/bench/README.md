# bench

Four programs, each aimed at one thing the compiler is supposed to be good at.

```
$ dune build
$ bench/run.sh
```

`run.sh` compiles every `bench/*.sk`, runs it, runs it again under the
interpreter, and prints the compiled wall time and the instruction count next
to the checksum. It fails loudly if the two back ends disagree. That check is
the point: the whole project rests on the claim that `skunk` and `skunkc` are
two readings of one language, so a benchmark that runs fast and prints
something else is worth nothing.

Each program prints one line, and it is a checksum rather than a picture or a
sorted array, so that comparing the two back ends is `cmp` and not judgement.

## What each one is for

**`fib.sk` — the cost of a call.** Naive Fibonacci, two calls per node and no
work between them. Nothing allocates, nothing loops, so the time is entry,
return, and the branch in between. It is where inlining a small body and
flattening an argument out of its tuple show up with nothing to hide behind.

**`nqueens.sk` — allocation and lists.** Eleven queens by backtracking. Every
partial solution is a cons cell that dies one recursion later, and every call
carries a tuple, so most of the time is the allocator and the walk over cells
that were just made. It says how much a short-lived heap value costs.

**`sort.sk` — arrays and refs.** Insertion sort over seven thousand elements,
quadratic on purpose, so that the inner loop is nothing but `Array.sub`, a
comparison and `Array.update`. The checksum loop adds a `ref` that never
escapes. Both ask the same question: do these turn into instructions, or into
calls to the runtime?

**`aobench.sk` — arithmetic and allocation together.** Ambient occlusion over
three spheres and a plane: primary rays through a 96 by 96 image, four samples
a pixel, twelve shadow rays wherever one lands. Multiplies, divisions and
square roots, a tuple allocated for every vector, a datatype for whether a ray
hit anything, and an array of sample directions read on every shadow ray. It is
the only one where no single cost dominates, which is what makes it useful.

## Why aobench is in fixed point

Because the compiler has no `real`. The interpreter has one, but `skunkc` still
answers `unsupported` for it, and a benchmark whose whole purpose is that both
back ends print the same bytes cannot use a type that only one of them has. So
`aobench.sk` is Q16.16 throughout — an int stands for itself divided by 65536,
`mul` and `dvd` put the scale back after multiplying and dividing, and every
constant is its real value times 65536. Rejection sampling picks the shadow-ray
directions, which is also a fixed-point decision: it needs no trigonometry.

The arithmetic is therefore integer arithmetic, and the benchmark measures
integer multiply, divide and branch rather than anything floating point. When
the compiler grows `real`, this file should be the first thing rewritten, and
the difference between the two versions will be worth measuring on its own.

## Reading the numbers

The instruction count is `skunkc --dump-mach` with the block labels and blank
lines stripped: one line per machine instruction after register allocation,
counting the basis, which is compiled into every program. It is a number to
compare against its own history, not against another compiler.

The interpreted time is in the table too, and it is two orders of magnitude
larger. That is not a defect being measured — it is a tree walk over the flat
IR against native code — but it does set the sizes. Each benchmark is tuned so
the compiled run takes a fraction of a second and the interpreted run still
finishes in under a minute, which is a narrower window than it sounds.
