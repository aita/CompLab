# WolverineML, in Guile

The same compiler as [`../python`](../python): Tiger's language in SML's syntax,
compiled to ARMv8. Same passes, same order, same shapes — a hand-written scanner
and a Pratt parser, monomorphic checking with escape analysis on the side, a
three-address IR, SSA built with dominance frontiers, five optimisations to a
fixed point, instructions chosen by covering a DAG of each block, and an ARMv8
emitter in AAPCS64.

One thing is deliberately missing. The Python tree allocates registers **two**
ways over the same IR so that the two can be measured against each other; this
tree keeps the graph — leave SSA, build the interference graph, colour it with
Chaitin's algorithm and George and Appel's iterated coalescing.

Everything else agrees to the byte. For every example and test program in the
tree, every stage of the pipeline — `tokens`, `ast`, `ir`, `ssa`, `opt`, `dag`,
`mach`, `flat`, `ra` and the assembly itself — dumps exactly what the Python one
dumps with `--regalloc graph`, in all four configurations.

```sh
./make.sh                        # compile every module into ccache/
./run-tests.sh                   # 7 suites, 1,148 checks

bin/wolv run     prog.wol        # compile, link, and run it
bin/wolv build   prog.wol -o prog
bin/wolv check   prog.wol        # types only
bin/wolv emit -s ssa prog.wol    # dump a stage
```

Guile 3, and nothing else: GOOPS, SRFI-1, SRFI-64 and `(ice-9 format)` all come
with it. `make.sh` is not required — Guile will interpret the tree as it stands —
but the bytecode is about twenty times faster and `compare.sh` runs the compiler
four hundred times.

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

One module per pass under `src/wolv/`, named after the Python module it is a
port of, and each one brought in by `#:use-module` — under a `#:prefix` where two
of them export the same name. The book in [`../doc/`](../doc/index.md) is a
chapter per pass and describes this compiler as well as the other, chapter 7
aside.

| file | chapter |
| --- | --- |
| `lexer.scm`, `parser.scm` | [1. 字句と構文解析](../doc/01-syntax.md) |
| `types.scm`, `typecheck.scm` | [2. 型検査とエスケープ解析](../doc/02-types.md) |
| `ir.scm`, `lower.scm` | [3. CFG へ下げる](../doc/03-lower.md) |
| `ssa.scm` | [4. SSA 構築](../doc/04-ssa.md) |
| `opt.scm`, `liveness.scm` | [5. SSA 上の最適化](../doc/05-opt.md) |
| `dag.scm`, `select.scm`, `mach.scm` | [6. 命令選択](../doc/06-select.md) |
| `outofssa.scm`, `graph.scm`, `spill.scm`, `hints.scm`, `allocator.scm` | [8. レジスタ割り当て(2) グラフ彩色](../doc/08-graph.md) |
| `emit.scm`, `copies.scm`, `registers.scm` | [9. コード生成](../doc/09-emit.md) |
| `test/` | [10. 検証](../doc/10-verify.md) |

## What Guile made different

**Every node is a class, and every question is a generic function.** The other
Scheme in this tree, [`../racket`](../racket), is structs and `match`: a pass is
one big `match` over the node constructors, and the compiler has sixteen of them.
Guile has GOOPS, so this tree is the other design — a class per node, and a
method per node per question:

```scheme
(define-generic defs)
(define-method (defs (i <instr>)) #f)
(define-method (defs (i <i-const>)) (instr-dst i))
(define-method (defs (i <i-arith>)) (instr-dst i))
...
(define-method (lower-exp (e <e-while>) me)
  (while-exp! me (e-while-test e) (e-while-body e))
  #f)
```

The answer lives next to the thing it is about, rather than in the pass's table
of all the things it is not about. Adding `i-select` to the IR would be a class
and its five methods, all in one place, and no `match` anywhere would have to
learn about it — which is exactly the trade CLOS makes in
[`../lisp`](../lisp), reached there through a macro and here through the
language.

What it costs is the same thing it costs there: nothing checks that the methods
are complete. Kotlin's `when` over a sealed hierarchy will not compile with a
case missing; here a node nobody wrote a method for is "No applicable method"
at run time. The base-class method — `(defs (i <instr>))` answering `#f` — is
what turns most of those into an answer rather than a crash, and is the reason
the five questions have one.

**A syntax tree is a hierarchy, so the wrapper goes.** Python, Racket and
TypeScript all wrap each expression node in an outer record carrying its span,
its type, what its name resolved to and which word of a record a field access
reads — because a struct cannot inherit those. `<exp>` has them as slots and
every expression class inherits from it, so `(node-at e)` and `(exp-ty e)` are
asked of the node itself and there is no `(exp-node e)` in the way. Half the
`ast:` prefixes in the Racket tree are that unwrapping.

**Two classes are the language's, and `define-class` redefines rather than
shadows.** `<frame>` and `<module>` are Guile's own — GOOPS exports a class for
VM frames and one for modules — and `(define-class <frame> () ...)` does not
shadow them, it *redefines them*, which is a feature and here a trap: the first
run got "No applicable method for initialize" from a class that was no longer
the one it had been. So the frame layout is `<frame-layout>` and the compilation
unit is `<ir-module>`. Racket had the same problem with `if` and `let` and
answered it the same way.

**Sets of registers are sorted lists, because the order is the answer.** Which
node the allocator simplifies first and which copy it looks at first decide the
colouring, so anything walked has to be walked in a fixed order. `regset.scm` is
sets as sorted lists — union and subtract are one merge each, `equal?` is set
equality, which is what the liveness fixed point tests for, and walking one is
already in order. The allocator's worklists are hash tables, because they are
membership tests and not walks, and the two places that *choose* — `simplify!`
and `coalesce!` — go through `sorted` and `least`.

**`map` does not promise an order and `map-in-order` does.** SSA renaming
allocates a register for every variable it renames, so the order the operands of
an instruction are rewritten in *is* the numbering, and a dump that disagrees
with Python by one register number is a dump that disagrees. Guile's `map` is
free to apply its procedure in any order; `map-in-order` is not. Every place
where the mapped procedure allocates — renaming, lowering a call's arguments,
rewriting an instruction's uses — says `map-in-order`, and the ones that do not
are pure.

**A failure is a `throw` with a key.** There is no condition hierarchy to
declare: `(throw 'wolv kind at message)` is the whole of it, `kind` is `lex`,
`parse` or `type` so a test can ask for the one it means, and the three handlers
in `cli.scm` are the only place that catches anything. The spiller's "this
function wants more registers than exist" is a second key, and the toolchain's
"there is no cross gcc" a third.

**Two streams and an exit status is what a shell redirection is for.** Racket
has `system*/exit-code` with ports to parameterize; Guile's `open-pipe*` gives
one direction. So `driver.scm` writes the input to a file, runs
`cmd < in > out 2> err` through `system`, and reads the two back — which is
three lines and needs no process plumbing.

**The tests are SRFI-64 with a quieter runner.** The framework ships with Guile;
what it does not have is a runner that says nothing when everything passes, so
`test/harness.scm` builds one out of `test-runner-null` and two hooks, and a
suite is a procedure that exits 1 if anything failed. That is what lets
`run-tests.sh` be a `for` loop.

## Verification

- **400/400 dumps match `python --regalloc graph`** (10 stages × 10 programs ×
  4 configurations), by `../compare.sh guile/bin/wolv`
- **1,148 checks in 7 suites, none skipped** — including the end-to-end runs
  under qemu and the random-program oracle
- 4,301 lines of code in 27 modules, with the comments taken out; 5,697 with
  them, and 1,112 in the tests
