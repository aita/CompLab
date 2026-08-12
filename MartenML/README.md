# MartenML

An ML-like language compiled to RISC-V, in OCaml, with register allocation by
graph colouring.

The point of the exercise is the back end: a real control-flow graph, liveness
analysis, an interference graph, and Chaitin–Briggs colouring with iterated
coalescing and spilling. The front end is a complete little ML — Hindley–Milner
inference, algebraic data types, pattern matching compiled to decision trees,
closures — so that the allocator has something worth allocating.

```
$ cd compiler
$ dune build
$ dune test
$ ./martenml examples/tour.mml
$ ./martenml -nregs 10 --dump-regalloc examples/pressure.mml
```

`./martenml` compiles a program, links it against the runtime with
`riscv64-linux-gnu-gcc` and runs it under `qemu-riscv64`; `./martenml -S` stops at
the assembly.

The compiler is in [`compiler/`](compiler) and the book is in [`doc/`](doc/index.md):
see [`compiler/README.md`](compiler/README.md) for the language and how to build
it, and [`doc/index.md`](doc/index.md) for a chapter per pass.  Two to start with,
in Japanese:
[パイプライン解説](doc/00-pipeline.md) と
[レジスタ割り付け解説](doc/08-regalloc.md)。

The two grammars on their own, apart from the book, are
[`spec/grammar.md`](spec/grammar.md): the tokens and an EBNF for each form, the
precedence ladder, the productions themselves, and where the 36 shift/reduce
conflicts in the ML form and the 3 in the brace form are -- all of them left to
the default resolution, and all of them wanting it.
