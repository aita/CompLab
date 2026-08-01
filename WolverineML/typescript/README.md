# WolverineML, in TypeScript

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
npm test                          # 151 tests
npm run check                     # tsc --noEmit

node src/main.ts run     prog.wol      # compile, link, and run it
node src/main.ts build   prog.wol -o prog
node src/main.ts check   prog.wol      # types only
node src/main.ts emit -s ssa prog.wol  # dump a stage
```

**There is no build step.** Node runs the TypeScript directly, so `src/main.ts`
is the compiler. `typescript` is a dev dependency and is only there for
`npm run check`; nothing is needed to run it but Node 22.18 or later.

Assembling and linking is a cross `gcc` (`aarch64-linux-gnu-gcc`, or `$WOLV_CC`),
and running is `qemu-aarch64` unless the machine is already an ARM. Without them
everything up to `emit` still works, and the tests that need a toolchain skip.

| flag | what it does |
| --- | --- |
| `--no-checks` | leave out the nil, bounds and divide-by-zero checks |
| `--no-opt` | skip the SSA optimiser |
| `--max-regs N` | pretend the machine has N registers, to make it spill |

## The tree

One file per pass, named after the Python module it is a port of, and imported
the same way: `import * as ir from "./ir.ts"` gives `ir.Bin` and `ast.Bin` side
by side, which is the one thing Kotlin could not do and had to work around. The
book in [`../doc/`](../doc/index.md) is a chapter per pass and describes this
compiler as well as the other, chapter 7 aside.

| file | chapter |
| --- | --- |
| `lexer.ts`, `parser.ts` | [1. 字句と構文解析](../doc/01-syntax.md) |
| `types.ts`, `typecheck.ts` | [2. 型検査とエスケープ解析](../doc/02-types.md) |
| `ir.ts`, `lower.ts` | [3. CFG へ下げる](../doc/03-lower.md) |
| `ssa.ts` | [4. SSA 構築](../doc/04-ssa.md) |
| `opt.ts`, `liveness.ts` | [5. SSA 上の最適化](../doc/05-opt.md) |
| `dag.ts`, `select.ts`, `mach.ts` | [6. 命令選択](../doc/06-select.md) |
| `outofssa.ts`, `graph.ts`, `spill.ts`, `hints.ts`, `allocator.ts` | [8. レジスタ割り当て(2) グラフ彩色](../doc/08-graph.md) |
| `emit.ts`, `copies.ts`, `registers.ts` | [9. コード生成](../doc/09-emit.md) |
| `test/` | [10. 検証](../doc/10-verify.md) |

## What TypeScript made different

**`BigInt` is the machine's word, exactly.** This is the one place where the host
language and the target agree without any help. `BigInt.asIntN(64, …)` is the
wrap, `/` and `%` truncate towards zero the way `sdiv` does — `-7n / 2n` is `-3n`
and `-7n % 2n` is `-1n` — and `MIN / -1` wraps back to `MIN`. Even the shifts
fall out: `1n << 64n` is an exact number that the wrap turns into `0n`, so unlike
Kotlin, Go, OCaml and Haxe there is no `>= 64` case to write. `opt.arith` here is
the shortest of the six ports and has no special case in it at all.

**Insertion order is the language's, not a discipline.** A JavaScript `Map` and
`Set` iterate in insertion order, which is what Python's `dict` does, so a phi's
arguments are a `Map` and the module's literals are a `Map` and both print in the
order they were put there. Go had to make those slices and sort every worklist by
hand; here the only sorting is where the Python also says `sorted`.

**Two instruction sets, two module objects.** `import * as ir` and `import * as
ast` give the same namespacing Python's modules do, so `ir.Bin` and `ast.Bin`
coexist with no renaming. Kotlin had to nest both in `object`s to get this.

**`null` and not a sentinel.** `defs(): Reg | null` is checked by the compiler,
so the "does it write anything" question needs no `noReg` the way Go's does, and
no `!!` the way Kotlin's does — `strict` plus `noUncheckedIndexedAccess` off but
`strictNullChecks` on means every `null` is looked at once, where it is.

**No parameter properties.** Node's type stripping runs `.ts` without compiling
it, and the one TypeScript feature it cannot strip is `constructor(public x: T)`,
because that emits code. Every class here writes its fields out. That is the
whole cost of having no build step.
