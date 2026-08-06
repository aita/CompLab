# WolverineML, in Clojure

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
./make.sh                        # compile ahead of time into classes/
./run-tests.sh                   # 91 tests, 1,557 assertions

bin/wolv run     prog.wol        # compile, link, and run it
bin/wolv build   prog.wol -o prog
bin/wolv check   prog.wol        # types only
bin/wolv emit -s ssa prog.wol    # dump a stage
```

Clojure 1.12 and nothing else: `deps.edn` names one dependency, which is Clojure
itself. `make.sh` is not required — `bin/wolv` falls back to `clojure -M -m
wolv.cli`, which loads the namespaces from source — but that compiles the whole
tree on every start, and `compare.sh` starts it four hundred times.

Assembling and linking is a cross `gcc` (`aarch64-linux-gnu-gcc`, or `$WOLV_CC`),
and running is `qemu-aarch64` unless the machine is already an ARM. Without them
everything up to `emit` still works, and the tests that need a toolchain skip.

| flag | what it does |
| --- | --- |
| `--no-checks` | leave out the nil, bounds and divide-by-zero checks |
| `--no-opt` | skip the SSA optimiser |
| `--max-regs N` | pretend the machine has N registers, to make it spill |

## The tree

One namespace per pass under `src/wolv/`, named after the Python module it is a
port of. The book in [`../doc/`](../doc/index.md) is a chapter per pass and
describes this compiler as well as the other, chapter 7 aside.

| file | chapter |
| --- | --- |
| `lexer.clj`, `parser.clj` | [1. 字句と構文解析](../doc/01-syntax.md) |
| `types.clj`, `typecheck.clj` | [2. 型検査とエスケープ解析](../doc/02-types.md) |
| `ir.clj`, `lower.clj` | [3. CFG へ下げる](../doc/03-lower.md) |
| `ssa.clj` | [4. SSA 構築](../doc/04-ssa.md) |
| `opt.clj`, `liveness.clj` | [5. SSA 上の最適化](../doc/05-opt.md) |
| `dag.clj`, `select.clj`, `mach.clj` | [6. 命令選択](../doc/06-select.md) |
| `outofssa.clj`, `graph.clj`, `spill.clj`, `hints.clj`, `allocator.clj` | [8. レジスタ割り当て(2) グラフ彩色](../doc/08-graph.md) |
| `emit.clj`, `copies.clj`, `registers.clj` | [9. コード生成](../doc/09-emit.md) |
| `test/` | [10. 検証](../doc/10-verify.md) |

## What Clojure made different

**Nothing in this compiler is declared.** There is no `data`, no `sealed class`,
no `defrecord` and no `deftype` anywhere in the tree. An instruction is a map
with an `:op`:

```clojure
(defn i-bin [dst oper lhs rhs] {:op :bin :dst dst :oper oper :lhs lhs :rhs rhs})

(defmulti uses :op)
(defmethod uses :default [_] [])
(defmethod uses :bin [i] [(:lhs i) (:rhs i)])
(defmethod uses :store [i] [(:base i) (:src i)])
```

and a syntax node is a map with a `:node`. What that buys is the opposite of
what [`../haskell`](../haskell) buys: the instruction set is *open*. A method can
be added from any namespace, `:default` is what answers for everything nobody
wrote one for, and adding `:select` to the IR would touch no table anywhere else.
What it costs is the thing Haskell's sums and Kotlin's `when` are for — nothing
says a case is missing until it arrives.

The tree is open in the other direction too. Every other port makes room in each
node for the three things the checker works out — its type, what a name resolved
to, which word of a record a field access reads — and the checker fills the holes
in. There are no holes here: `(assoc e :ty t)` adds the key.

**A function is a value, so every pass is `func -> func`.** A `func` is a map
with `:blocks`, `:order`, `:params` and three counters; rewriting a block is
`update-in`, and no pass can see another's half-finished work because there is no
"the" function to see. The one seam that shows is the allocator, which rewrites
the function it is colouring when it spills, and therefore answers with both:

```clojure
(defn allocate [f machine] ... [f (ir/allocation colours saved slots)])
```

Three fixed points — dominance, liveness and the optimiser — are `=` on the
value, so no pass reports whether it did anything. Racket, Go and Ruby thread a
`changed` flag out of every one of the five optimiser passes; there is none here.

**Lowering is the pass that builds, so it is the pass that threads.** It has a
register counter, a block being filled, a stack of `break` targets and the module
around it, and every rule answers `[state register]`:

```clojure
(defmethod lower-exp :index [st e]
  (let [[st addr] (element-address st (:array e) (:index e))
        [st r] (reg st)]
    [(put st (ir/i-load r addr ir/WORD)) r]))
```

`let` destructuring is what makes that readable, and it is also what makes the
order visible: the order operands are lowered in *is* the order registers are
numbered in, and a dump that disagrees with Python by one register number is a
dump that disagrees.

**A symbol has a number, because a value has no identity.** Whether a variable
escapes is settled long after the node that mentions it was made, and where it
lives later still, so a `var-sym` carries an `:id`, `check` answers with the set
of numbers that escaped beside the tree, and lowering keeps a table from the
number to the register or frame slot. A record type is the same: nominal equality
is `=` on its number, and `same?` — which is nominal for records and structural
for arrays — is therefore just `=`.

That has one visible consequence. Lowering needs to know how big a record is, and
the fields live in a table the checker kept; so it asks the *node*, whose
initialisers the checker has already put into declaration order and insisted are
all present. One fact, asked where it is known.

**Dispatch is on a value, not on a type.** `defmulti` takes any function of the
arguments, so `defs` and `uses` dispatch on `:op` — a keyword *in* the data — and
nothing had to be wrapped for it. It also means `with-def`, sixteen methods in
every other port, is one line here:

```clojure
(defn with-def [i r] (assoc i :dst r))
```

because every instruction that writes writes into a key of that name, and a map
does not mind being handed a key it already has.

**`+` throws and `unchecked-add` wraps.** A Clojure `long` is the machine's word
already, so `i64.clj` is the shortest in the tree — but the arithmetic has to be
asked for by name, because `(+ Long/MAX_VALUE 1)` is an `ArithmeticException` and
the language being compiled wraps. The two shifts past 63 need saying as well:
the JVM takes the count modulo 64, so `1 << 64` would be 1. `quot` and `rem`
truncate towards zero the way `sdiv` does, which is the one place the host agreed
without being asked.

The oracle found the third: `(- Long/MIN_VALUE)` overflows, and the literal the
language wants for that value is `~9223372036854775808`, so the negation that
prints it is the promoting `-'`.

**A `sorted-set` is ordered, so nothing is sorted.** "The least node in the
worklist" is `first` and "walk the neighbours in order" is `seq`, because the
allocator's worklists and every set of live registers are sorted sets. Go, Ruby
and Racket sort at each of those places to keep the colouring the same twice;
`graph.clj` has no `sort` in it at all.

**An error is an `ex-info`, and the map is the type.** `(throw (ex-info message
{:wolv :parse :at at}))` — the key says which pass raised it, so a test asks
`(:wolv (ex-data e))` and there is no condition hierarchy to declare. The
spiller's "this function wants more registers than exist" and the toolchain's
"there is no cross gcc" are two more values of the same key, and `cli.clj` is the
only place that catches anything.

**Two names are Clojure's.** `intern` and `resolve` belong to `clojure.core`, so
lowering's string table is `intern-string` and the checker's is `resolve-ty`.
Redefining either would work and would print a warning on the way — to standard
error, which a dump has to be free of.

## Verification

- **400/400 dumps match `python --regalloc graph`** (10 stages × 10 programs ×
  4 configurations), by `../compare.sh clojure/bin/wolv`
- **91 tests, 1,557 assertions, none skipped** — including the end-to-end runs
  under qemu and the random-program oracle
- 3,219 lines of code in 26 namespaces, with the comments and docstrings taken
  out; 4,556 with them, and 812 in the tests
