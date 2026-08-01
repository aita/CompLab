# WolverineML, in Racket

The same compiler as [`../python`](../python): Tiger's language in SML's syntax,
compiled to ARMv8. Same passes, same order, same shapes — a hand-written scanner
and a Pratt parser, monomorphic checking with escape analysis on the side, a
three-address IR, SSA built with dominance frontiers, five optimisations to a
fixed point, instructions chosen by covering a DAG of each block, and an ARMv8
emitter in AAPCS64. No `parser-tools`, no `#lang` of its own: the scanner and
the parser are the same hand-written pair as everywhere else, because the point
of the exercise is the compiler and not the reader.

One thing is deliberately missing. The Python tree allocates registers **two**
ways over the same IR so that the two can be measured against each other; this
tree keeps the graph — leave SSA, build the interference graph, colour it with
Chaitin's algorithm and George and Appel's iterated coalescing.

Everything else agrees to the byte. For every example and test program in the
tree, every stage of the pipeline — `tokens`, `ast`, `ir`, `ssa`, `opt`, `dag`,
`mach`, `flat`, `ra` and the assembly itself — dumps exactly what the Python one
dumps with `--regalloc graph`, in all four configurations.

```sh
raco make src/main.rkt           # not required; Racket runs it from source
raco test test/                  # 94 tests

racket src/main.rkt run     prog.wol      # compile, link, and run it
racket src/main.rkt build   prog.wol -o prog
racket src/main.rkt check   prog.wol      # types only
racket src/main.rkt emit -s ssa prog.wol  # dump a stage
```

Assembling and linking is a cross `gcc` (`aarch64-linux-gnu-gcc`, or `$WOLV_CC`),
and running is `qemu-aarch64` unless the machine is already an ARM. Without them
everything up to `emit` still works, and the tests that need a toolchain say so
and carry on.

| flag | what it does |
| --- | --- |
| `--no-checks` | leave out the nil, bounds and divide-by-zero checks |
| `--no-opt` | skip the SSA optimiser |
| `--max-regs N` | pretend the machine has N registers, to make it spill |

## The tree

One module per pass under `src/`, named after the Python module it is a port of,
and each one `require`d under a prefix by whoever needs it. The book in
[`../doc/`](../doc/index.md) is a chapter per pass and describes this compiler as
well as the other, chapter 7 aside.

| file | chapter |
| --- | --- |
| `lexer.rkt`, `parser.rkt` | [1. 字句と構文解析](../doc/01-syntax.md) |
| `types.rkt`, `typecheck.rkt` | [2. 型検査とエスケープ解析](../doc/02-types.md) |
| `ir.rkt`, `lower.rkt` | [3. CFG へ下げる](../doc/03-lower.md) |
| `ssa.rkt` | [4. SSA 構築](../doc/04-ssa.md) |
| `opt.rkt`, `liveness.rkt` | [5. SSA 上の最適化](../doc/05-opt.md) |
| `dag.rkt`, `select.rkt`, `mach.rkt` | [6. 命令選択](../doc/06-select.md) |
| `outofssa.rkt`, `graph.rkt`, `spill.rkt`, `hints.rkt`, `allocator.rkt` | [8. レジスタ割り当て(2) グラフ彩色](../doc/08-graph.md) |
| `emit.rkt`, `copies.rkt`, `registers.rkt` | [9. コード生成](../doc/09-emit.md) |
| `test/` | [10. 検証](../doc/10-verify.md) |

## What Racket made different

**A struct is a pattern, so nothing names an accessor twice.** Every question a
pass asks an instruction is one `match`, and the instruction comes apart where it
is asked about:

```racket
(define (uses i)
  (match i
    [(i:bin _ _ lhs rhs) (list lhs rhs)]
    [(i:store base _ src) (list base src)]
    [(i:cbr cond _ _ "") (list cond)]
    ...))
```

`ir.rkt` alone has six of these — `defs`, `uses`, `map-uses`, `with-def`,
`has-effect?` and the printer — and the tree walks in the checker, the lowering
and the dump are the same shape. What went with the accessors is the class of
mistake they invite: `(i:bin-lhs i)` beside `(i:cmp-rhs i)` typechecks.

**`map-uses` is one expression per instruction, because Racket promises an
order.** Renaming allocates — a variable read on a path that never wrote it
invents a register — so the order the operands are rewritten in is the order they
are numbered in. Racket evaluates the arguments of an application left to right
and says so, which is why `(i:bin dst op (f lhs) (f rhs))` is safe here and the
OCaml port has to write the same thing in two lines.

**A struct is immutable unless it says otherwise, so an instruction is a value.**
`(struct i:bin (dst op lhs rhs))` cannot be written to, so every rewrite answers
with a new instruction and the caller puts it back where the old one was. That is
what `map-instrs!` is: the pass says what an instruction becomes, and the block
is what remembers.

```racket
(ir:map-instrs! b (λ (i) (ir:map-uses i resolve)))
```

Haxe reached the same place from its immutable `enum`; here it is the default for
every struct in the program, and the fields that do change — a block's phis, a
function's register count, the type and the symbol the checker writes on a node —
are marked `#:mutable` one at a time. Grepping for `#:mutable` is a short and
readable list of everything this compiler mutates.

**Exact integers are the wrong width, and that is the whole of `i64.rkt`.**
Racket's numbers are unbounded, so nothing wraps on its own: `1000000 * 1000000`
is exact and eight bytes too wide. Every operation the optimiser folds goes
through `wrap`, and the two that Racket gets right for free are the ones that
usually need care — `quotient` and `remainder` truncate towards zero, which is
what `sdiv` does. TypeScript's `BigInt` had `asIntN` to do the wrapping; here the
wrap is a `modulo` and a subtraction, written once.

**Prefixes instead of namespaces.** `(prefix-in ir: "ir.rkt")` gives what
Python's `import wolv.ir as ir` gives, so `ir:i:bin` and `ast:e:bin` coexist
without renaming either. What the prefix cannot do is shadow: `if`, `let` and
`while` are Racket's, so the syntax tree calls its nodes `e:if`, `e:let` and
`e:while`, and `check` had to be brought in under `types:` in the tests because
`rackunit` exports one too.

**A hash has no order, and phis are printed in one.** Racket's `hash` and
`mutable-seteqv` iterate in an order nothing promises, which is exactly what the
placement of a phi and the walk of a worklist must not depend on. So a phi's
arguments are an association list — `(pred . reg)`, in the order they were put
there — and the two places in the allocator that *choose* go through `sorted` or
`least`. Go had to do the same; Python and TypeScript got it from the language.

**Escape continuations are how the pipeline stops.** `compile-module` runs the
whole pipeline and `stop-at?` returns out of it the moment the caller's stage has
something to show, so there is one description of the order the passes run in and
not two. `(let/ec return …)` and `(return m (hash))` — two values, because the
allocation is the second one and there is nowhere on a function to hang it.

**`0` is true.** Half the ports needed an `is not None` or a `!= null` where this
one needs nothing: a displacement of zero, a colour of `x0`, a constant `0` all
read as themselves, and only `#f` means "there is none". `(and value (<= 0 value
IMMEDIATE))` says what Python needs two clauses for.

## Verification

- **400/400 dumps match `python --regalloc graph`** (10 stages × 10 programs × 4
  configurations)
- **94 tests, none skipped** — including the end-to-end runs under qemu and the
  random-program oracle
- 4602 lines in 26 modules (3353 of them code), and 1276 in the tests
