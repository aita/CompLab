# WolverineML, in Ruby

The same compiler as [`../python`](../python): Tiger's language in SML's syntax,
compiled to ARMv8. Same passes, same order, same shapes — a one-pass scanner and
a Pratt parser, monomorphic checking with escape analysis on the side, a
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
rake                             # 94 tests
ruby -Ilib -Itest test/middle_test.rb

./bin/wolv run     prog.wol      # compile, link, and run it
./bin/wolv build   prog.wol -o prog
./bin/wolv check   prog.wol      # types only
./bin/wolv emit -s ssa prog.wol  # dump a stage
```

Ruby 3.3 or later, because `Data` is 3.2 and the pattern matching is 3.0. There
are no gems beyond the standard library, so there is no `Gemfile`: `set`,
`optparse`, `open3` and `minitest` ship with Ruby.

Assembling and linking is a cross `gcc` (`aarch64-linux-gnu-gcc`, or `$WOLV_CC`),
and running is `qemu-aarch64` unless the machine is already an ARM. Without them
everything up to `emit` still works, and the tests that need a toolchain skip.

| flag | what it does |
| --- | --- |
| `--no-checks` | leave out the nil, bounds and divide-by-zero checks |
| `--no-opt` | skip the SSA optimiser |
| `--max-regs N` | pretend the machine has N registers, to make it spill |

## The tree

One file per pass under `lib/wolv/`, named after the Python module it is a port
of, each a module or a class inside `module Wolv`. The book in
[`../doc/`](../doc/index.md) is a chapter per pass and describes this compiler as
well as the other, chapter 7 aside.

| file | chapter |
| --- | --- |
| `lexer.rb`, `parser.rb` | [1. 字句と構文解析](../doc/01-syntax.md) |
| `types.rb`, `typecheck.rb` | [2. 型検査とエスケープ解析](../doc/02-types.md) |
| `ir.rb`, `lower.rb` | [3. CFG へ下げる](../doc/03-lower.md) |
| `ssa.rb` | [4. SSA 構築](../doc/04-ssa.md) |
| `opt.rb`, `liveness.rb` | [5. SSA 上の最適化](../doc/05-opt.md) |
| `dag.rb`, `select.rb`, `mach.rb` | [6. 命令選択](../doc/06-select.md) |
| `outofssa.rb`, `graph.rb`, `spill.rb`, `hints.rb`, `allocator.rb` | [8. レジスタ割り当て(2) グラフ彩色](../doc/08-graph.md) |
| `emit.rb`, `copies.rb`, `registers.rb` | [9. コード生成](../doc/09-emit.md) |
| `test/` | [10. 検証](../doc/10-verify.md) |

## What Ruby made different

**`Data` for an instruction, `Struct` for the tree.** Ruby has two value types
and this compiler wants both. An instruction is a `Data` — frozen, so a rewrite
answers with a new one and `Data#with` is what writes it:

```ruby
Bin = Data.define(:dst, :op, :lhs, :rhs) do
  def map_uses(&f) = with(lhs: f.(lhs), rhs: f.(rhs))
end
```

The syntax tree is a `Struct`, because the parser builds a node with three holes
in it — the type, what a name resolved to, which word of a record a field access
reads — and the checker fills them in. Both deconstruct in `case/in`, so which
one a file uses changes nothing about how it is read.

**A mixin is the base class.** Python's `Instr` is a base class with five
methods that mostly return nothing; here it is `module Instr`, `include`d by
every instruction of both instruction sets. `Data` cannot inherit from anything,
so the mixin was the only way — and it is the better one, because `Mach::Instr`
picks up the same defaults without pretending to be a kind of three-address
instruction.

**A hash is ordered, which is half the port for free.** Ruby's `Hash` and `Set`
iterate in insertion order, exactly as Python's `dict` and `set` do, so a phi's
arguments are a `Hash` and the module's literals are a `Hash` and both print in
the order they were put there. Go and Racket had to keep association lists and
sort every worklist by hand; here the only `sort` is where the Python also says
`sorted`.

**Integers are exact, so `/` is not `sdiv`.** Ruby's `/` floors and its `%`
follows the sign of the divisor, which is Python's answer and not ARM's:
`-7 / 2` is `-4` where `sdiv` says `-3`. `i64.rb` is the whole of the
difference — a `wrap` through `% 2**64`, a division written out of `abs`, and
the two shifts guarded past 63 so that `1 << 70` does not build a very large
exact integer on the way to being masked back to zero.

**The scanner is `StringScanner`.** Every other tree walks the source a
character at a time and compares by hand; Ruby has a cursor over a string in the
standard library, so every lexical rule here is a regular expression anchored at
that cursor and the cursor only moves by matching one. `Regexp.union` even
carries the "longest punctuation wins" rule for free, because it keeps the order
of the table it was built from and an alternation tries its branches in order.

What `StringScanner` does not keep is the line and the column, which are what
every error message and the `tokens` dump are made of. So one method wraps
`scan`, and counting the newlines out of whatever the match consumed is the only
bookkeeping left:

```ruby
def eat(pattern)
  text = @ss.scan(pattern) or return nil
  text.each_char { |c| c == "\n" ? (@line += 1; @col = 1) : @col += 1 }
  text
end
```

**A byte string is an encoding, not a convention.** A literal in this language
is bytes, and Ruby has a string type for that: the scanner builds the text in
`ASCII-8BIT`, where `length` is the byte count `size` returns at run time and
`each_byte` is what the emitter escapes. The price is at the two dumps that
print a literal, which have to write each byte as the character at that code
point — Python's `str` had already decoded them that way, and matching it to the
byte means `[b].pack("U")`.

**Two names Ruby had first.** `TypeError` is a core class, and inside
`module Wolv` that name would shadow it — so the checker raises `CheckError`,
and an ordinary bug still raises Ruby's. `undef` is a keyword, so the renamer's
"what does a variable read before it was written" is `undefined`.

## Verification

- **400/400 dumps match `python --regalloc graph`** (10 stages × 10 programs × 4
  configurations)
- **94 tests, 1770 assertions, none skipped** — including the end-to-end runs
  under qemu and the random-program oracle
- 4718 lines in 26 modules and the `bin/wolv` script (3404 of them code), and 1186
  in the tests
