# WolverineML, in Kotlin

The same compiler as [`../python`](../python): Tiger's language in SML's syntax,
compiled to ARMv8. Same passes, same order, same shapes — a hand-written scanner
and a Pratt parser, monomorphic checking with escape analysis on the side, a
three-address IR, SSA built with dominance frontiers, five optimisations to a
fixed point, instructions chosen by covering a DAG of each block, and an ARMv8
emitter in AAPCS64.

One thing is deliberately missing. The Python tree allocates registers **two**
ways over the same IR so that the two can be measured against each other; this
tree keeps the graph — leave SSA, build the interference graph, colour it with
Chaitin's algorithm and George and Appel's iterated coalescing. Reading
`allocator/` here is reading one allocator rather than a comparison.

Everything else agrees to the byte. For every example and test program in the
tree, every stage of the pipeline — `tokens`, `ast`, `ir`, `ssa`, `opt`, `dag`,
`mach`, `flat`, `ra` and the assembly itself — dumps exactly what the Python one
dumps with `--regalloc graph`.

```sh
./gradlew test                              # 151 tests
./gradlew installDist                       # a `wolv` launcher under build/install

./build/install/wolv/bin/wolv run     prog.wol       # compile, link, and run it
./build/install/wolv/bin/wolv build   prog.wol -o prog
./build/install/wolv/bin/wolv check   prog.wol       # types only
./build/install/wolv/bin/wolv emit -s ssa prog.wol   # dump a stage
```

A JDK 21 is what Gradle's toolchain asks for; the launcher wants a `java` of at
least that on `PATH` or `JAVA_HOME`. Assembling and linking is a cross `gcc`
(`aarch64-linux-gnu-gcc`, or `$WOLV_CC`), and running is `qemu-aarch64` unless
the machine is already an ARM. Without them everything up to `emit` still works,
and the tests that need a toolchain skip.

| flag | what it does |
| --- | --- |
| `--no-checks` | leave out the nil, bounds and divide-by-zero checks |
| `--no-opt` | skip the SSA optimiser |
| `--max-regs N` | pretend the machine has N registers, to make it spill |

## The tree

The book in [`../doc/`](../doc/index.md) is a chapter per pass and describes this
compiler as well as the other, chapter 7 aside. What each chapter is about lives
here in these files:

| file | chapter |
| --- | --- |
| `Lexer.kt`, `Parser.kt` | [1. 字句と構文解析](../doc/01-syntax.md) |
| `Types.kt`, `Typecheck.kt` | [2. 型検査とエスケープ解析](../doc/02-types.md) |
| `Ir.kt`, `Lower.kt` | [3. CFG へ下げる](../doc/03-lower.md) |
| `Ssa.kt` | [4. SSA 構築](../doc/04-ssa.md) |
| `Opt.kt`, `Liveness.kt` | [5. SSA 上の最適化](../doc/05-opt.md) |
| `Dag.kt`, `Select.kt`, `Mach.kt` | [6. 命令選択](../doc/06-select.md) |
| `OutOfSsa.kt`, `allocator/` | [8. レジスタ割り当て(2) グラフ彩色](../doc/08-graph.md) |
| `Emit.kt`, `Copies.kt`, `Registers.kt` | [9. コード生成](../doc/09-emit.md) |
| `src/test/` | [10. 検証](../doc/10-verify.md) |

## What the two languages made different

The compiler is the same compiler, so the differences are all in how a thing is
said rather than what it is.

**Two instruction sets, one base class.** `Ir.Instr` is an open class with five
questions on it — what it writes, what it reads, how to rewrite those, whether it
has an effect, how to print it — and `Mach.Instr` is one more subclass of it. That
is what lets liveness, dominance, the allocator and the verifiers work on either
level without knowing which they are looking at, and it is the same arrangement
the Python has, minus the duck typing.

**Sealed where the Python has a fallthrough.** `Ast.Exp`, `Ast.Decl` and `Type`
are sealed, so a `when` over them is exhaustive and the "unknown expression" arm
the Python needs is gone. `Ir.Instr` is deliberately not sealed: a pass is meant
to ask it questions rather than match on it.

**64 bits, on purpose.** Python's integers are arbitrary, so the constant folder
has to mask and sign-extend by hand after every operation; `Long` already wraps,
and `/` and `%` already truncate towards zero the way `sdiv` does. What is left
of that code is the two shifts, because Kotlin takes its shift amount modulo 64
and the language does not.

**Strings are bytes either way.** A literal is scanned into a `String` whose every
character is one byte of UTF-8, which is what `size` and `substring` count at run
time and what the emitter writes back out. The scanner reads code points and not
UTF-16 units, so a character outside the basic plane is one column and its own
four bytes rather than two halves of a surrogate pair.

**Determinism is spelled out.** The Python sorts wherever a set is iterated and
the answer has to be stable; so does this, and every map that a dump or a pass
walks in order is a `LinkedHashMap`.
