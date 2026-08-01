# WolverineML, in Go

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
go test ./...                    # 98 tests and 54 subtests
go build -o bin/wolv .

./bin/wolv run     prog.wol      # compile, link, and run it
./bin/wolv build   prog.wol -o prog
./bin/wolv check   prog.wol      # types only
./bin/wolv emit -s ssa prog.wol  # dump a stage
```

Assembling and linking is a cross `gcc` (`aarch64-linux-gnu-gcc`, or `$WOLV_CC`),
and running is `qemu-aarch64` unless the machine is already an ARM. Without them
everything up to `emit` still works, and the tests that need a toolchain skip.
The run-time system is embedded in the binary and unpacked to compile, so the
`wolv` binary is the whole toolchain.

| flag | what it does |
| --- | --- |
| `--no-checks` | leave out the nil, bounds and divide-by-zero checks |
| `--no-opt` | skip the SSA optimiser |
| `--max-regs N` | pretend the machine has N registers, to make it spill |

## The tree

One package, flat, one file per pass, named after the Python module it is a port
of. The book in [`../doc/`](../doc/index.md) is a chapter per pass and describes
this compiler as well as the other, chapter 7 aside.

| file | chapter |
| --- | --- |
| `lexer.go`, `parser.go` | [1. 字句と構文解析](../doc/01-syntax.md) |
| `types.go`, `typecheck.go` | [2. 型検査とエスケープ解析](../doc/02-types.md) |
| `ir.go`, `lower.go` | [3. CFG へ下げる](../doc/03-lower.md) |
| `ssa.go` | [4. SSA 構築](../doc/04-ssa.md) |
| `opt.go`, `liveness.go` | [5. SSA 上の最適化](../doc/05-opt.md) |
| `dag.go`, `select.go`, `mach.go` | [6. 命令選択](../doc/06-select.md) |
| `outofssa.go`, `graph.go`, `spill.go`, `hints.go`, `allocator.go` | [8. レジスタ割り当て(2) グラフ彩色](../doc/08-graph.md) |
| `emit.go`, `copies.go`, `registers.go` | [9. コード生成](../doc/09-emit.md) |
| `*_test.go` | [10. 検証](../doc/10-verify.md) |

## What Go made different

**A sentinel instead of an option.** Registers are numbered from zero, so `noReg`
is `-1` and every "does this instruction write anything" question is answered
with it rather than with a second return value. `if d := instr.defs(); d != noReg`
reads the way the Python `if d is not None` does and costs nothing. The one place
it bites is a struct literal: `&Mach{Form: "cmp"}` would mean *x0*, not *nothing*,
so every one of them names `Dst` even when the answer is `noReg`.

**Embedding is the base class.** `Instr` is an interface of six questions and
`instrBase` answers all six the boring way; every instruction embeds it and
overrides what it actually does. That is the same arrangement the Python has,
written out.

**Panic and recover at the pass boundary.** The scanner, the parser and the
checker are recursive and every step of them can fail. They say so by panicking
with a `*wolvError`, and `lex`, `parse` and `check` each `defer catch(&err)` to
turn it back into an ordinary error return. Threading `(x, error)` through a
Pratt parser would say the same thing three times a line, and nothing outside
those three functions ever sees a panic.

**Order has to be asked for.** Python's dictionaries keep their insertion order
and its sets iterate the same way twice; Go's maps do neither. Anything a dump
prints or a pass walks is a slice: a phi's arguments are `[]PhiArg` and not a
map, the module's string literals are a `[]StringLit`, and every set that decides
something — the allocator's worklists above all — is sorted before it is walked.
That is not a translation artefact, it is the same discipline the Python already
has written down, because both allocators had to be reproducible.

**`int64` is the machine's word.** Constant folding needs no masking, and `/` and
`%` already truncate towards zero the way `sdiv` does, `MIN / -1` included. Only
the shifts need saying, because Go treats a shift of 64 or more as itself and the
language does not.

**A byte string is not text.** A literal is a Go `string` of the bytes it will be
at run time, which is exactly what `size` and `substring` count. Writing one into
a dump is the one place that matters: `asText` widens each byte to the character
of the same number, which is what the Python and Kotlin trees do implicitly when
they print one, and is why the dumps agree.

**Slices do not clamp.** `--max-regs 26` asks for more callee-saved registers than
this machine has. Python and Kotlin quietly hand back what there is; Go panics on
the slice bound, so `limitedRegisters` says `min` out loud. A test found that one.
