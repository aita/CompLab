# WolverineML, in Prolog

The same compiler as [`../python`](../python): Tiger's language in SML's
syntax, compiled to ARMv8. Same passes, same order, same shapes — a scanner
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
./make.sh                        # save a state at bin/wolv
./run-tests.sh                   # 94 tests

bin/wolv run     prog.wol        # compile, link, and run it
bin/wolv build   prog.wol -o prog
bin/wolv check   prog.wol        # types only
bin/wolv emit -s ssa prog.wol    # dump a stage

swipl wolv.pl -- run prog.wol    # the same, from source
```

SWI-Prolog, and nothing outside its library: `assoc`, `ordsets`, `pairs`,
`record`, `process` and `plunit`.

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

One module per pass under `src/`, named after the Python module it is a port
of. The book in [`../doc/`](../doc/index.md) is a chapter per pass and
describes this compiler as well as the other, chapter 7 aside.

| file | chapter |
| --- | --- |
| `lexer.pl`, `parser.pl` | [1. 字句と構文解析](../doc/01-syntax.md) |
| `types.pl`, `typecheck.pl` | [2. 型検査とエスケープ解析](../doc/02-types.md) |
| `ir.pl`, `lower.pl` | [3. CFG へ下げる](../doc/03-lower.md) |
| `ssa.pl` | [4. SSA 構築](../doc/04-ssa.md) |
| `opt.pl`, `liveness.pl` | [5. SSA 上の最適化](../doc/05-opt.md) |
| `dag.pl`, `select.pl`, `mach.pl` | [6. 命令選択](../doc/06-select.md) |
| `outofssa.pl`, `graph.pl`, `spill.pl`, `hints.pl`, `allocator.pl` | [8. レジスタ割り当て(2) グラフ彩色](../doc/08-graph.md) |
| `emit.pl`, `copies.pl`, `registers.pl` | [9. コード生成](../doc/09-emit.md) |
| `test/` | [10. 検証](../doc/10-verify.md) |

## What Prolog made different

**The scanner is a grammar, and so is the parser, and so is the emitter.** A
DCG is what Prolog has instead of a loop over an index, and this compiler uses
it three times over three different alphabets — characters, tokens, and lines
of assembly:

```prolog
trivia(P0, P) -->
    (   [C], { space_code(C) } ->  { advance(C, P0, P1) }, trivia(P1, P)
    ;   "(*"                  ->  { advance_text("(*", P0, P1) },
                                  comment(1, P0, P1, P2), trivia(P2, P)
    ;   { P = P0 }
    ).

terminator(F, _, _, cbr(_, Then, Else, Code), Then) --> ...
```

The position the scanner is at is two extra arguments, threaded through, so a
token knows where it came from without anything being written on.

**A hole in the tree is a logic variable, and the checker fills it by
unification.** Every other port in this tree solves "the parser builds an
untyped tree and the checker types it" by mutating a field. Here the parser
leaves the field unbound:

```prolog
exp(bin_exp(Op, Lhs, Rhs), Span, Type)
```

and checking binds it — `Type = int` rather than `e.ty = INT`. The same holds
for the symbol a name stands for, the offset of a field selection, and the
order a record literal's initialisers end up in. Nothing is copied and nothing
is written twice; the tree the parser answered with *is* the typed tree, once
the checker has run.

The one thing that could not be a hole is the escape set, and it is worth
saying why: a variable is found to escape long after its own declaration has
been checked, and a bound variable cannot be bound again. So `check/2` answers
with an ordset of the variables that escape, and the lowering takes it as an
argument.

**The five questions about an instruction are five relations.** `defs/2` has
no solution for an instruction that writes nothing, which is what `is None` is
everywhere else; `uses/2` is a table; `map_uses/3` relates an instruction to
another instruction rather than changing one:

```prolog
defs(call(D, _, _), D) :- D \== none.
uses(cbr(T, _, _, Code), Regs) :- ( Code == '' -> Regs = [T] ; Regs = [] ).
map_uses(bin(D, Op, L0, R0), G, bin(D, Op, L, R)) :- call(G, L0, L), call(G, R0, R).
```

**A pass with state is a DCG whose list is one item long.** The checker carries
its scopes, the lowering its half-built function, the allocator twenty
worklists. `state.pl` is the whole of that trick, and what it buys is that
`emit(I)` does not have to name the state before and the state after:

```prolog
terminate(T) --> emit(T), fresh(dead, Label), set_via(set_cur_of_lw, Label).
```

Lowering a nested function saves the six function-shaped fields and puts them
back afterwards, which is what having a second object for it is in Python.

**The case analysis is in the clause heads.** Where the Python reads as a chain
of `if`, this reads as clauses in the order the cases are preferred, each one
testing before it emits so that a form which does not fit leaves nothing
behind:

```prolog
additive(N, D, Op, L, _) --> shift_into(N, D, Op, L), !.
additive(N, D, Op, L, _) --> multiply_into(N, D, Op, L), !.
additive(N, D, Op, L, _) --> immediate_right(N, D, Op, L), !.
additive(N, D, +,  _, R) --> immediate_left(N, D, R), !.
additive(N, D, Op, L, R) --> both(N, L, R, Srcs), ...
```

and the allocator's main loop is four clauses, because each of simplify,
coalesce, freeze and spill already fails when its own worklist is empty:

```prolog
main_loop --> simplify, !, main_loop.
main_loop --> coalesce, !, main_loop.
main_loop --> freeze, !, main_loop.
main_loop --> select_spill, !, main_loop.
main_loop --> [].
```

Two tests are head unification rather than a comparison: `merge_or_not(_, U,
U)` is "the two ends already have the same alias", and `terminator(..., cbr(_,
Then, _, _), Then)` is "the block this branch is true for is the next one".

**A record is a declaration, not a dict.** A function has thirteen fields, and
`library(record)` turns

```prolog
:- record func(label, name, params:list=[], depth:integer=0, entry=entry,
               blocks=t, order:list=[], nregs:integer=0, ...).
```

into the thirteen accessors and the thirteen setters, so `func_order/2` is a
relation between a function and its block order and `set_order_of_func/3` is a
relation between two functions. SWI's dicts would have worked and would have
read like a hash table; this reads like Prolog, and `state.pl` takes the
accessor by name so a call site says which record it is reading.

**Nothing is replaced in place.** Renaming a block reads it once and writes it
once — the new phis and the new instructions are related to the old ones by two
grammars — because a compiler that changed the fourth instruction of a list
would be an array assignment written in Prolog, and there is no such thing
here.

**Sets are ordsets and maps are assocs, so nothing has an order that has to be
justified.** A live set is a sorted list, so union is a merge and `==` is set
equality; a worklist is an ordset, so "the least" is the head of a list and the
colouring a program gets is the colouring it gets again. Every other port in
this tree had to remember to sort somewhere.

**The traps SWI set.** `u<` is two tokens and must be written `'u<'`. A clause
must have whitespace after its full stop, or `').kind_text('` becomes one term.
`swipl -O` is what `make.sh` uses and what `run-tests.sh` must not, because
plunit does not compile test units when optimisation is on. And once `swipl`
sees a bare file name, everything after it is an argument for the program
rather than an option for swipl — which is why both scripts pass `-l`.

## Verification

- **400/400 dumps match `python --regalloc graph`** (10 stages × 10 programs ×
  4 configurations), by `../compare.sh prolog/bin/wolv`
- **94 tests, none skipped** — including the end-to-end runs under qemu and the
  random-program oracle
- 5,873 lines in 27 modules, and 1,235 in the tests
