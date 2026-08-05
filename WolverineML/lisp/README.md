# WolverineML, in Common Lisp

The same compiler as [`../python`](../python): Tiger's language in SML's
syntax, compiled to ARMv8. Same passes, same order, same shapes — a
hand-written scanner and a Pratt parser, monomorphic checking with escape
analysis on the side, a three-address IR, SSA built with dominance frontiers,
five optimisations to a fixed point, instructions chosen by covering a DAG of
each block, and an ARMv8 emitter in AAPCS64.

One thing is deliberately missing. The Python tree allocates registers **two**
ways over the same IR so that the two can be measured against each other; this
tree keeps the graph — leave SSA, build the interference graph, colour it with
Chaitin's algorithm and George and Appel's iterated coalescing.

Everything else agrees to the byte. For every example and test program in the
tree, every stage of the pipeline — `tokens`, `ast`, `ir`, `ssa`, `opt`, `dag`,
`mach`, `flat`, `ra` and the assembly itself — dumps exactly what the Python one
dumps with `--regalloc graph`, in all four configurations.

```sh
./make.sh                        # compile, and dump an image at bin/wolv
./run-tests.sh                   # 94 tests

bin/wolv run     prog.wol        # compile, link, and run it
bin/wolv build   prog.wol -o prog
bin/wolv check   prog.wol        # types only
bin/wolv emit -s ssa prog.wol    # dump a stage
```

SBCL, and nothing else: the only dependency is `uiop`, which comes with ASDF,
and it is used for two things — running `gcc` and finding a temporary file.
`wolv.asd` is there for anyone who would rather load the system than build an
image; `build.lisp` compiles the files in order and is what both scripts use.

Assembling and linking is a cross `gcc` (`aarch64-linux-gnu-gcc`, or
`$WOLV_CC`), and running is `qemu-aarch64` unless the machine is already an ARM.
Without them everything up to `emit` still works, and the tests that need a
toolchain say so and carry on.

| flag | what it does |
| --- | --- |
| `--no-checks` | leave out the nil, bounds and divide-by-zero checks |
| `--no-opt` | skip the SSA optimiser |
| `--max-regs N` | pretend the machine has N registers, to make it spill |

## The tree

One file per pass under `src/`, one package apiece, and each package names the
others under a local nickname — which is what `import wolv.ir as ir` is in
Python and `(prefix-in ir: …)` is in Racket. The book in
[`../doc/`](../doc/index.md) is a chapter per pass and describes this compiler
as well as the other, chapter 7 aside.

| file | chapter |
| --- | --- |
| `lexer.lisp`, `parser.lisp` | [1. 字句と構文解析](../doc/01-syntax.md) |
| `types.lisp`, `typecheck.lisp` | [2. 型検査とエスケープ解析](../doc/02-types.md) |
| `ir.lisp`, `lower.lisp` | [3. CFG へ下げる](../doc/03-lower.md) |
| `ssa.lisp` | [4. SSA 構築](../doc/04-ssa.md) |
| `opt.lisp`, `liveness.lisp` | [5. SSA 上の最適化](../doc/05-opt.md) |
| `dag.lisp`, `select.lisp`, `mach.lisp` | [6. 命令選択](../doc/06-select.md) |
| `outofssa.lisp`, `graph.lisp`, `spill.lisp`, `hints.lisp`, `allocator.lisp` | [8. レジスタ割り当て(2) グラフ彩色](../doc/08-graph.md) |
| `emit.lisp`, `copies.lisp`, `registers.lisp` | [9. コード生成](../doc/09-emit.md) |
| `test/` | [10. 検証](../doc/10-verify.md) |

## What Common Lisp made different

**One macro writes the instruction protocol, five methods at a time.** Every
pass over a function asks an instruction the same five questions — what it
writes, what it reads, rewrite what it reads, must it be kept, and how is it
printed — and in every other port those answers are written out sixteen times.
Here an instruction *declares which of its slots hold registers* and the
answers follow:

```lisp
(define-instr i-bin ((dst :def) op (lhs :use) (rhs :use))
  (:show (format nil "~A = ~A ~A ~A" (% dst) (% lhs) op (% rhs))))

(define-instr i-cbr ((test :use) then els (code :plain ""))
  (:reads-when (string= code ""))
  (:effect)
  (:show ...))
```

`define-instr` expands to the `defclass`, a constructor of the same name, and
`defs`, `(setf defs)`, `uses`, `map-uses`, `has-effect-p` and `show`. It is
worth about 200 lines, but that is not the point: the point is that `uses` and
`map-uses` can no longer disagree, which is a bug this compiler could otherwise
have — `map-uses` has to rewrite exactly the registers `uses` returns, in the
same order, because SSA renaming allocates and the order is the numbering.

`mach.lisp` uses the same macro for its one instruction, so the machine IR gets
the protocol for free and `ir:dst` means the same thing at both levels.

**Every question is a generic function; there is no dispatching `case` in the
compiler.** The checker's rule for `while` is a method on `while-exp`, the
lowering's is a method on `while-exp`, the dump's is a method on `while-exp`,
and none of the three is in a conditional with the other twenty forms:

```lisp
(defmethod check-exp ((e ast:while-exp) ck)
  (unify ty:+bool+ (exp-type ck (ast:test e)) ... "as a `while` condition")
  (incf (loops ck))
  (unify ty:+unit+ (exp-type ck (ast:body e)) ... "in a `while` body")
  (decf (loops ck))
  ty:+unit+)
```

What that costs is exhaustiveness. Kotlin's `when` over a sealed hierarchy and
Haskell's pattern match both refuse to compile when a case is missing; here a
node nobody wrote a method for is a run-time error, and the base method on
`ast:expression` exists to make it a legible one. The trade is real and it went
the way it did because the alternative — one enormous `typecase` per pass — is
the thing CLOS was built to replace.

**Type equality is the one place with two arguments, so it is written with
two.** `same-p` and `compatible-p` specialise on both, and the rule that `nil`
stands in for any record is two methods rather than a clause:

```lisp
(defmethod same-p ((a array-type) (b array-type)) (same-p (elem a) (elem b)))
(defmethod same-p ((a record-type) (b record-type)) (eq a b))
(defmethod same-p (a b) nil)

(defmethod compatible-p (a b) (same-p a b))
(defmethod compatible-p ((a nil-type) (b record-type)) t)
(defmethod compatible-p ((a record-type) (b nil-type)) t)
```

Multiple dispatch is the feature every other port in this tree had to write
around, and this is the only place in the compiler that wanted it.

**`0` is true, and that removed a clause everywhere.** A displacement of zero, a
colour of `x0`, a constant `0` and a register numbered `0` all read as
themselves; only `nil` means "there is none". Python needs `is not None` in the
selector eight times over, and `(and value (<= 0 value +immediate+))` is the
whole of it here.

**Package locks decide some names.** `exp`, `mod`, `load`, `bit-and` and
`array` belong to Common Lisp and cannot be taken from it — not even as a
`loop` variable, which is how `(loop for rest on params)` became `tail`. So the
syntax tree's base class is `expression`, an instruction is `i-const` and
`i-load`, and `wolv.diag` shadows one name (`parse-error`) rather than fifty.
Racket had the same problem with `if` and `let` and answered it the same way.

**A condition is how a pass fails.** `lex-error`, `parse-error` and
`type-check-error` all inherit from `wolv-error`, which carries a span and
prints itself, so no pass has to hand a failure back to the one above it and
the whole of the error handling is one `handler-case` in `cli.lisp`.

**The worklists are hash tables and are sorted wherever they choose.** A hash
table promises no order, and the order matters: which node is simplified first
and which copy is looked at first decide the colouring. So `graph.lisp` sorts
at every point that picks, and `regset.lisp` — sets of registers as sorted
lists — is what liveness uses, where `equal` is set equality for free. Racket,
Go and Ruby all had to do the same; Python got it from `sorted()` being the
obvious thing to write.

**A saved image is how it becomes a command.** `make.sh` compiles the tree and
calls `save-lisp-and-die`, so `bin/wolv` is a 40 MB executable that starts in a
few milliseconds instead of compiling itself first. There is no other way to
make a Lisp program start quickly, and it is a good deal better than the
alternatives in this tree that shell out to a runtime.

**The test harness is eighty lines of macro.** There is no dependency to add, so
`deftest` registers a closure and `is` keeps the form it was given, which is
what a failure prints:

```
FAIL middle/a small constant is an immediate: (FORMS (FUNCTION-SOURCE "a + 5"))
      wanted ("addi")
      got    ("const" "add")
```

## Verification

- **400/400 dumps match `python --regalloc graph`** (10 stages × 10 programs ×
  4 configurations), by `../compare.sh lisp/bin/wolv`
- **94 tests, none skipped** — including the end-to-end runs under qemu and the
  random-program oracle
- 5,085 lines in 27 modules, and 1,277 in the tests
