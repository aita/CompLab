# Ferret

A node-based editor in the browser, and a compiler that turns the graph you
draw into a real WebAssembly module and runs it on the spot.

The point of the exercise is that there is no interpreter behind the canvas.
Dragging an edge changes a graph; the graph is lowered to a small structured
IR, and the IR is written out as `\0asm` bytes by hand — sections, LEB128
lengths, opcodes and all. The page then hands those bytes to
`WebAssembly.instantiate` and calls the exported function. What runs is what
the compiler emitted.

![the editor](doc/editor.png)

The compiler is OCaml. It builds twice: as `ferretc`, a command-line compiler
that reads a graph and writes a `.wasm` file, and — through js\_of\_ocaml — as a
script the editor loads, so the browser and the terminal run the same code.

## Running it

```
cd editor
npm install
npm run dev
```

`npm run dev` builds the OCaml compiler to JavaScript first (so you need an
opam switch with `yojson` and `js_of_ocaml`), drops it in `editor/public/`, and
then starts Vite on <http://localhost:5173>.

Without the editor:

```
dune test
dune exec compiler/bin/ferretc.exe -- examples/collatz.json -o collatz.wasm
dune exec compiler/bin/ferretc.exe -- --emit wat examples/collatz.json
dune exec compiler/bin/ferretc.exe -- --emit ir examples/sum.json
```

## The graph is the program

A graph has two kinds of edge, drawn differently and checked separately.

**Exec edges** — square ports — say what happens next. Execution starts at the
one 開始 node and follows them. **Data edges** — round ports — say where a value
comes from, and are pulled backwards from whatever needs them.

| node | what it is |
| --- | --- |
| 開始 | the entry point; its inputs are the exported function's parameters |
| 終了 | return a value |
| 条件分岐 | `if`: a `then` chain, an `else` chain, and a `next` they both rejoin |
| 繰り返し | `while`: a `body` chain, and a `next` for when the condition fails |
| ログ出力 | call the imported `env.log` with a value |
| 変数に代入 / 変数を読む | a named `f64` local; reading one never written gives 0 |
| 定数, 計算, 関数, 比較, 論理 | the expression nodes |

Every value is an `f64`, except conditions, which are `i32` used as booleans.
Mixing the two is what the type check catches: the 条件 port of an `if` will not
accept a number, and 戻り値 will not accept a comparison.

Control flow is structured *by construction*, and that is the one real
constraint the editor imposes. An `if` owns the chains on both of its branches
and the chain after them, so exec edges always form a tree. That is why the
back end never needs a control-flow graph, dominators, or a relooper to
rebuild the `block`/`loop`/`br` nesting wasm requires — the nesting is already
there in the graph. Wiring two branches into the same node is rejected rather
than structured after the fact.

## The pipeline

| module | what it does |
| --- | --- |
| `compiler/lib/graph.ml` | reads React Flow's own save format; ports are `sourceHandle`/`targetHandle` |
| `compiler/lib/lower.ml` | validates, type checks, and lowers the graph to the IR |
| `compiler/lib/ir.ml` | one function: `f64` parameters, `f64` locals, structured statements |
| `compiler/lib/wasm.ml` | the binary writer — LEB128, sections, opcodes |
| `compiler/lib/emit.ml` | IR to a module |
| `compiler/lib/wat.ml` | the same instruction stream as text, for the 生成コード tab |

Lowering is two walks over the same graph. The forward walk follows exec edges
from 開始 and turns each node into a statement; the backward walk follows data
edges from an input port and builds an expression tree, refusing to loop.

Errors are collected rather than thrown at the first one, and each carries the
id of the node that caused it, so the editor can outline the offending node
and print the message underneath it. The editor recompiles on every edit,
which is what makes that feel like a linter rather than a build step.

A shared subexpression is emitted once per use rather than hoisted into a
temporary. That is not laziness: `x` read twice on either side of an
assignment to `x` must read twice, and the dataflow nodes are pure, so
recomputing is both correct and cheap. The only expression that does need a
scratch local is `%`, which wasm has no instruction for; it becomes
`x - trunc(x / y) * y`, with each operand parked in a local so neither runs
twice.

The generated module imports `env.log` and exports `main`. Nothing else: no
memory, no table, no globals.

## Running what was generated

The editor instantiates the module in a Web Worker rather than on the UI
thread. A `while` node is enough to write a loop that never ends, and a worker
can be killed after three seconds; a hung tab cannot.

## What is deliberately missing

There is one function and no calls, so there is no recursion and no function
section worth the name. There are no arrays, strings or memory — every value
is a number. There is no optimiser: the emitter is a direct syntax-directed
walk of the IR, so `x + 0` survives into the bytes.
