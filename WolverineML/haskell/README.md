# WolverineML, in Haskell

The same compiler as [`../python`](../python): Tiger's language in SML's syntax,
compiled to ARMv8. Same passes, same order, same shapes — a hand-written scanner
and a Pratt parser, monomorphic checking with escape analysis on the side, a
three-address IR, SSA built with dominance frontiers, five optimisations to a
fixed point, instructions chosen by covering a DAG of each block, and an ARMv8
emitter in AAPCS64. The parser is Parsec's, over the token stream; everything
else is written out.

One thing is deliberately missing. The Python tree allocates registers **two**
ways over the same IR so that the two can be measured against each other; this
tree keeps the graph — leave SSA, build the interference graph, colour it with
Chaitin's algorithm and George and Appel's iterated coalescing.

Everything else agrees to the byte. For every example and test program in the
tree, every stage of the pipeline — `tokens`, `ast`, `ir`, `ssa`, `opt`, `dag`,
`mach`, `flat`, `ra` and the assembly itself — dumps exactly what the Python one
dumps with `--regalloc graph`, in all four configurations.

```sh
cabal build                      # GHC 9.4 or later
cabal test                       # 88 tests

cabal run wolv -- run     prog.wol      # compile, link, and run it
cabal run wolv -- build   prog.wol -o prog
cabal run wolv -- check   prog.wol      # types only
cabal run wolv -- emit -s ssa prog.wol  # dump a stage
```

Nothing outside what GHC ships is needed: `base`, `containers`, `mtl`, `parsec`,
`directory`, `filepath` and `process` are all boot packages, so `cabal build
--offline` works on a machine that has never fetched an index. The test harness
is thirty lines in `test/Check.hs` for the same reason.

Assembling and linking is a cross `gcc` (`aarch64-linux-gnu-gcc`, or `$WOLV_CC`),
and running is `qemu-aarch64` unless the machine is already an ARM. Without them
everything up to `emit` still works, and the tests that need a toolchain say so
and skip.

| flag | what it does |
| --- | --- |
| `--no-checks` | leave out the nil, bounds and divide-by-zero checks |
| `--no-opt` | skip the SSA optimiser |
| `--max-regs N` | pretend the machine has N registers, to make it spill |

## The tree

One module per pass under `src/Wolv/`, named after the Python module it is a
port of. The book in [`../doc/`](../doc/index.md) is a chapter per pass and
describes this compiler as well as the other, chapter 7 aside.

| file | chapter |
| --- | --- |
| `Lexer.hs`, `Parser.hs` | [1. 字句と構文解析](../doc/01-syntax.md) |
| `Types.hs`, `Typecheck.hs` | [2. 型検査とエスケープ解析](../doc/02-types.md) |
| `Ir.hs`, `Lower.hs` | [3. CFG へ下げる](../doc/03-lower.md) |
| `Ssa.hs` | [4. SSA 構築](../doc/04-ssa.md) |
| `Opt.hs`, `Liveness.hs` | [5. SSA 上の最適化](../doc/05-opt.md) |
| `Dag.hs`, `Select.hs`, `Mach.hs` | [6. 命令選択](../doc/06-select.md) |
| `OutOfSsa.hs`, `Graph.hs`, `Spill.hs`, `Hints.hs`, `Allocator.hs` | [8. レジスタ割り当て(2) グラフ彩色](../doc/08-graph.md) |
| `Emit.hs`, `Copies.hs`, `Registers.hs` | [9. コード生成](../doc/09-emit.md) |
| `test/` | [10. 検証](../doc/10-verify.md) |

## What Haskell made different

**The checker's tree is a different type from the parser's.** Every other port
parses a tree with three holes in each node — the type, what a name resolved to,
which word of a record a field access reads — and the checker fills them in.
Nothing here can be filled in, so `check` returns a second tree; and because it
is a second tree, it does not have to have the same type as the first.

The tree is indexed by which pass made it. An annotation is a type family:

```haskell
data Phase = Parsed | Typed

type family Ann (p :: Phase) a where
  Ann 'Parsed a = ()
  Ann 'Typed a = a

data Exp p = Exp {eAt :: Span, eTy :: Ann p Type, eNode :: Node p}
data Node p = … | EVar String (Ann p VarSym) | ECall String [Exp p] (Ann p FunSym) | …
```

`parse` answers a `Program 'Parsed`, where every annotation is `()`. `check`
answers a `Program 'Typed`, where each is the thing that pass worked out. So
lowering, which takes a `Program 'Typed`, gets a `VarSym` from `EVar name sym`
and not a `Maybe VarSym` it would have to open with an error for a case the
checker has already ruled out. Five `error`s went with it: "a variable with no
symbol", "a call with no symbol", "an assignment with no symbol", "a for with no
symbol", and `tyOf`, which is now `eTy`.

What a `val` binds is the same idea one step down. It was a `Maybe String` and a
`Maybe VarSym` that had to agree about whether this was `val () = e`; it is a
`Maybe (Binder p)`, and the name and the symbol travel together.

The other eight ports have exactly this invariant and check none of it: a
mutable field that is null until the checker runs, and a lowering pass that
trusts it. Here the checker is the only thing that can make a tree lowering will
take.

**One case split, not two.** `defs` said which register an instruction writes
and `withDef` made it write another, over the same fourteen constructors — and
`withDef` had an `error` for the ones that write nothing, which the caller had
just asked `defs` about. They are one function:

```haskell
definition :: Instr -> Maybe (Reg, Reg -> Instr)
defs = fmap fst . definition
```

The renamer gets the register and the way to change it from the same answer.
The two had already drifted: `StrConst` was in `defs` and missing from
`withDef`, so a renamed string constant would have hit the `error`.

`Parser.hs` had the same shape — a table of binding powers and a table of
spellings, and an `error "not a binary operator"` for a token in one and not the
other. `infixOp` returns the node to build with the two powers, so there is one
table.

**A `newtype` is free, so the three integers are three types.** A virtual
register, a machine register and a frame slot are all `Int`, and as plain `Int`s
any of them typechecks where another was meant. `newtype Reg = Reg {unReg ::
Int}` is erased at run time — unlike Kotlin's `@JvmInline`, which still boxes at
a map key — so the distinction costs nothing anywhere, and the emitter is the one
place that turns a `Reg` into the colour it was given.

**The operators are a sum, so every table over them is exhaustive.** `Bin Reg
String Reg Reg` had 120 operator literals scattered over the tree and six
`error`s for "no instruction for `op`", "not a shift", "unknown comparison" and
the rest. They are `data Op`, `data Rel` and `data Cond` now: the folder, the
selector and the emitter each answer one question per operator, and the compiler
is what says none is missing. What the strings were is `showOp`/`showRel`, and
only a dump asks. Lowering is where a surface operator becomes a machine one,
which is the seam that was implicit before.

`CBr` says the same thing in its type: the condition code is a `Maybe Cond`
rather than a `String` whose emptiness meant "test the register".

**The four instructions the emitter expands are four constructors.** The machine
instruction used to be a form-as-a-string with a symbol, an immediate and an
"is it effectful" flag — enough fields for every shape, and a lookup that could
fail. `MConst`, `MAdr`, `MLoad` and `MStore` are their own constructors now,
which is what "not one instruction each" means, and what is left is uniform:

```haskell
Machine {mForm :: Form, mDst :: Maybe Reg, mSrcs :: [Reg], mImm :: Int64}
```

The symbol field and the effect flag are gone — the form says both — and the
emitter's table is `template :: Form -> String`, a total function. `Mach.verify`
had two things to check and has one: nothing can name an instruction that does
not exist.

**There is no remainder in the IR.** `Op` had a `Mod` that lowering never
built — it spells the remainder out as a divide, a multiply and a subtract, so
the quotient in between is a value the allocator can place. The constructor was
still there, which meant a fold case that could not fire and an `error` in the
selector for an instruction that could not arrive. Deleting it deletes both.

**Identity is a number, because a value has none.** Whether a variable escapes
is settled long after the node that mentions it was made, and where it ended up
living is settled later still. So a `VarSym` carries an `Int` that is only ever
compared, `check` answers with the set of numbers that escaped beside the tree,
and lowering keeps a map from the number to the frame slot or register. A record
type is the same trick: nominal equality is `==` on its number, and the fields
live in a table the checker keeps and nothing after it asks for.

```haskell
data Checked = Checked {ckProgram :: Program, ckEscapes :: Set.Set Int}
```

**`Int64` is the machine's word, exactly.** It wraps on overflow, `quot` and
`rem` truncate towards zero the way `sdiv` does, and the bit operations are the
bit operations. `I64.hs` is thirty lines and says only the three things GHC and
ARM disagree about: the two shifts past 63, and `minBound `quot` (-1)`, which
the machine wraps back to `minBound` and which GHC raises an overflow for.

**A `Set` is ordered, so nothing is sorted.** "The least node in the worklist" is
`Set.findMin` and "walk the neighbours in order" is `Set.toAscList`, because
`Data.Set` is a search tree and not a hash table. Go, Ruby and Racket have to
sort at each of those places to keep the colouring the same twice; here the order
is the container's, and the allocator has no `sort` in it at all.

**Parsec, and only for what it is good at.** The parser is a
`ParsecT [Token] () (Either WolvError)` over the tokens the scanner made. Parsec
carries the stream and the position and gives `between`, `sepBy1` and `option`
their ordinary meanings — but it chooses nothing, because this grammar never
needs it to: every decision is one token of lookahead, and every rejection is a
`lift (Left …)` carrying the message the other implementations print, which no
backtracking can undo. The scanner stayed hand-written, because Parsec's
`SourcePos` advances a tab to the next multiple of eight and the column in a
`tokens` dump has to be the character count.

**Every pass is `Func -> Func`, and the stateful ones say so.** Lowering, SSA
renaming and the colouring are imperative algorithms; each is a `State` over a
record that holds the function being built. What that buys is that the seams are
honest, and that nothing else can see a half-rewritten function is a fact about
the types rather than a convention.

**A fixed point asks `==`, so no pass reports whether it did anything.** Three
places here are "run it again until it stops moving" — dominance, liveness and
the optimiser — and every other port threads a `changed` flag out of every step
to drive them. A pass here answers with a value, so the question is already
answerable:

```haskell
converge :: (Eq a) => (a -> a) -> a -> a
converge step = go where go x = let y = step x in if x == y then x else go y

optimiseFunc :: Func -> Func
optimiseFunc = converge (\f -> foldl' (flip ($)) f passes)
```

The flag is gone from all three, and `Pass` is `Func -> Func` rather than
`Func -> (Func, Bool)`.

**The pipeline is a list, and a dump is that list cut short.** The stages are
`[(String, Carried -> Either Failure Carried)]` named after what each leaves
behind, and stopping early is `break` on the name — so the order the passes run
in is written down exactly once, and `emit -s opt` cannot drift from `build`.

## Verification

- **400/400 dumps match `python --regalloc graph`** (10 stages × 10 programs × 4
  configurations)
- **88 tests, none skipped** — including the end-to-end runs under qemu and the
  random-program oracle
- **no warnings** at `-Wall`
- 5309 lines in 26 modules (4001 of them code), and 1170 in the tests
