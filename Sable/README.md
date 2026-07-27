# Sable

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
$ ./sable examples/tour.sbl
$ ./sable -nregs 10 --dump-regalloc examples/pressure.sbl
```

`./sable` compiles a program, links it against the runtime with
`riscv64-linux-gnu-gcc` and runs it under `qemu-riscv64`; `./sable -S` stops at
the assembly.

Everything lives in [`compiler/`](compiler): see
[`compiler/README.md`](compiler/README.md) for the language, the pipeline, and a
walk through the allocator.  Two longer write-ups, in Japanese:
[パイプライン解説](compiler/doc/pipeline.md) と
[レジスタ割り付け解説](compiler/doc/regalloc.md)。
