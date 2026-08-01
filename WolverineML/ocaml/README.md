# WolverineML, in OCaml

The same compiler as [`../python`](../python): Tiger's language in SML's syntax,
compiled to ARMv8. Same passes, same order, same shapes — a hand-written scanner
and a Pratt parser, monomorphic checking with escape analysis on the side, a
three-address IR, SSA built with dominance frontiers, five optimisations to a
fixed point, instructions chosen by covering a DAG of each block, and an ARMv8
emitter in AAPCS64. No ocamllex and no menhir: the scanner and the parser are
written out, because the point is that they are the same scanner and the same
parser as the other three.

One thing is deliberately missing. The Python tree allocates registers **two**
ways over the same IR so that the two can be measured against each other; this
tree keeps the graph — leave SSA, build the interference graph, colour it with
Chaitin's algorithm and George and Appel's iterated coalescing.

Everything else agrees to the byte. For every example and test program in the
tree, every stage of the pipeline — `tokens`, `ast`, `ir`, `ssa`, `opt`, `dag`,
`mach`, `flat`, `ra` and the assembly itself — dumps exactly what the Python one
dumps with `--regalloc graph`, in all four configurations.

```sh
dune test                                  # 620 assertions
dune build

./_build/default/bin/main.exe run     prog.wol      # compile, link, and run it
./_build/default/bin/main.exe build   prog.wol -o prog
./_build/default/bin/main.exe check   prog.wol      # types only
./_build/default/bin/main.exe emit -s ssa prog.wol  # dump a stage
```

Assembling and linking is a cross `gcc` (`aarch64-linux-gnu-gcc`, or `$WOLV_CC`),
and running is `qemu-aarch64` unless the machine is already an ARM. Without them
everything up to `emit` still works, and the tests that need a toolchain say so
and skip. The run-time system is compiled into the binary as a string and written
back out to hand to the cross compiler.

Two dependencies. `uucp`, because OCaml's standard library has no Unicode
character database and the scanner wants Python's `isalpha` exactly; and
`containers`, for `CCList.take`/`drop` (which stop at the end of the list, the
way a Python slice does) and `CCString.replace`, each of which was a hand-written
helper here before.

| flag | what it does |
| --- | --- |
| `--no-checks` | leave out the nil, bounds and divide-by-zero checks |
| `--no-opt` | skip the SSA optimiser |
| `--max-regs N` | pretend the machine has N registers, to make it spill |

## The tree

One library, one file per pass, named after the Python module it is a port of.
The book in [`../doc/`](../doc/index.md) is a chapter per pass and describes this
compiler as well as the other, chapter 7 aside.

| file | chapter |
| --- | --- |
| `lexer.ml`, `parser.ml` | [1. 字句と構文解析](../doc/01-syntax.md) |
| `types.ml`, `typecheck.ml` | [2. 型検査とエスケープ解析](../doc/02-types.md) |
| `ir.ml`, `lower.ml` | [3. CFG へ下げる](../doc/03-lower.md) |
| `ssa.ml` | [4. SSA 構築](../doc/04-ssa.md) |
| `opt.ml`, `liveness.ml` | [5. SSA 上の最適化](../doc/05-opt.md) |
| `dag.ml`, `select.ml`, `mach.ml` | [6. 命令選択](../doc/06-select.md) |
| `outofssa.ml`, `graph.ml`, `spill.ml`, `hints.ml`, `allocator.ml` | [8. レジスタ割り当て(2) グラフ彩色](../doc/08-graph.md) |
| `emit.ml`, `copies.ml`, `registers.ml` | [9. コード生成](../doc/09-emit.md) |
| `tests/` | [10. 検証](../doc/10-verify.md) |

## What OCaml made different

**One variant, and the questions are functions.** The other three ports put the
six questions an instruction answers — what it writes, what it reads, how to
rewrite those, how to set the definition, whether it has an effect, how to print
it — on the instruction itself, as methods. Here the instruction is one variant
and each question is one function with a `match`. That inverts the shape: adding
an instruction means touching six functions rather than writing one class, and
the compiler names all six when you forget.

**Where the seam had to move.** OCaml cannot add a constructor to a variant from
another file, so `Machine` and the record it carries are declared in `ir.ml` even
though `mach.ml` owns everything about what they mean — the table of forms, which
ones the emitter expands, and the verifier. The two instruction sets are still
two, but the line between them runs through a different place than it does in the
other three trees, and this is the only place where the language chose.

**Mutable fields inside the variant.** `Const of { mutable dst : reg; … }`. The
passes rewrite the IR in place, the way the Python does, and inline records with
mutable fields are what make that a port rather than a rewrite. `Dynarray` is the
instruction list, because the passes append, insert and replace by index.

**Ordered sets are the determinism.** `Set.Make(Int)` iterates in ascending order
and has `min_elt`, so the allocator's worklists are deterministic by construction.
The Python has to say `sorted` at each of those points and the Go has to sort by
hand; here `IntSet.min_elt c.simplify_worklist` is both the algorithm and the
guarantee.

**Evaluation order is the sharp edge.** OCaml evaluates function arguments right
to left and `let … and …` in no particular order, and a register number is the
order the instructions came out in. Three real bugs came from that — the `not`
builtin, the `for` step, and the block labels of every `if` — and the fix is
sequential `let`s and `Util.map_in_order`, which exists only because `List.map`
does not promise an order.

**64 bits.** `Int64` wraps, and `div` and `rem` truncate towards zero the way
`sdiv` does, `min_int / -1` included. Only the shifts need saying, because a shift
of 64 or more is undefined in OCaml and defined in the language.

**Lists are not arrays, and the compiler notices.** The first version of this tree
appended to lists — `f.order <- f.order @ [label]`, the phi list of a block, the
move list of the allocator — and looked up a block's reverse-post-order number in
an association list inside the dominator fix point. On a program of four thousand
blocks that made it the slowest of the four ports, slower than CPython, with SSA
construction alone taking 0.58s against Go's 0.02s. The shapes that fixed it are
the ordinary ones: `Dynarray` where the Python has a list, `Hashtbl` where it has
a dict, and prepend-then-reverse where the order has to be kept. Nothing about the
algorithms changed and every dump is still byte-identical; it is now second of the
four, behind Go.

| on a 4200-block function | before | after |
| --- | ---: | ---: |
| lowering | 0.21s | 0.09s |
| SSA construction | 0.58s | 0.03s |
| the whole pipeline | 1.09s | 0.39s |
