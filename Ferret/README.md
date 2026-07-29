# Ferret

A node-based editor in the browser, and a compiler that turns the graph you
draw into a real WebAssembly module and runs it on the spot.

The point of the exercise is that there is no interpreter behind the canvas.
Dragging an edge changes a graph; the graph is lowered to a small IR with no
branch in it, and the IR is written out as `\0asm` bytes by hand — sections,
LEB128 lengths, opcodes and all. The page then hands those bytes to
`WebAssembly.instantiate` and calls the exported `main`, over and over. What
runs is what the compiler emitted.

![the editor](doc/editor.png)

The compiler is OCaml. It builds twice: as `ferretc`, a command-line compiler
that reads a graph and writes a `.wasm` file, and — through js\_of\_ocaml — as a
script the editor loads, so the browser and the terminal run the same code.

This file is the overview. The chapter-per-concern write-up is in
[`doc/`](doc/index.md), in Japanese, with the real dumps and byte counts
pasted in: [グラフがプログラムであるということ](doc/graph.md) ·
[グラフから IR へ](doc/lower.md) · [数に型をつける](doc/types.md) ·
[バイト列を手で書く](doc/emit.md) · [止まるデバッガ](doc/debug.md) ·
[エディタと橋渡し](doc/editor.md)。

## Running it

```
cd editor
npm install
npm run dev
```

`npm run dev` builds the OCaml compiler to JavaScript first (so you need an
opam switch with `yojson` and `js_of_ocaml`), drops it in `editor/public/`, and
then starts Vite on <http://localhost:5173>.

**File** in the toolbar starts a new graph, opens a `.json` one, saves the
current one, or loads an example. What it saves is the same file `ferretc`
takes on the command line, so a graph drawn in the editor can be compiled from
a terminal without a conversion step. Whatever you last edited is kept in the
browser and comes back on reload.

Without the editor:

```
dune test
dune exec compiler/bin/ferretc.exe -- examples/bounce.json -o bounce.wasm
dune exec compiler/bin/ferretc.exe -- --emit wat examples/bounce.json
dune exec compiler/bin/ferretc.exe -- --emit ir examples/count.json
dune exec compiler/bin/ferretc.exe -- --emit spec
```

The host has to supply all five imports and call `main` more than once;
`compiler/test/run_wasm.mjs` shows the whole of what that takes.

## The graph is the program

There is one kind of edge, and it says where a value comes from. Nothing says
what happens next: **the order things are worked out in falls out of what
depends on what**, and there is no other order.

Running the graph once, end to end, is a **cook**. That is exactly what the
module's `main` does, and a graph gets somewhere by being cooked again — the
host drives the repetition, the way a frame does in a patcher. ▶ Play in the
Run panel cooks every 100 ms; ↻ Cook does it once.

Inside a cook the graph is acyclic. **Feedback** is the one node that crosses
from one cook to the next: reading it gives what the last cook left, and what
it is fed is taken up at the end of this one, at the same moment as every
other Feedback. So a wire that comes back round is not a cycle — it lands in
the next cook.

| node | what it is |
| --- | --- |
| Out | what a cook comes back with; a graph can have one, or none |
| Log | call the imported `env.log` with a value |
| Say | hand a piece of text to the host |
| Feedback | what the last cook left, and what this one leaves for the next |
| Input | a number the Run panel asks for before the run starts |
| Time | what the host says the time is, asked once per cook |
| Random | a number in `[min, max)`, drawn once per cook per node |
| Choose | one of two values, by a condition |
| Expression | a whole calculation typed as text; the names it leaves free are its input ports |
| Text | a piece of text, written down |
| Yes or No | a true or false, written down |
| Constant, Arithmetic, Math function, Comparison, Logic | the expression nodes |

Out, Log and Say are what a cook is *for*: everything else is worked out
because one of them, or a Feedback, asked for it. A node nothing asks for
emits nothing.

The palette offers an operator at a time under the name of the family it
belongs to — Multiply under Arithmetic, At most under Comparison — so what you
reach for is the operation rather than a node you then have to set. One node
kind still backs the whole family, and the card names itself after the
operator it is on; the dropdown in the inspector is there to change your mind
without redrawing the wires.

A number port with nothing plugged into it is a place to type a number, so a
one-off constant does not need a node of its own; the Constant node is for
when the same number is wanted in several places.

Arithmetic drawn out of nodes gets long, so `x * x + y * y < 1` can also be
typed into an Expression node as that one line. It is parsed, not evaluated:
what comes out is the same tree the wired-up version would have produced, and
the names the text leaves free — `x` and `y` here — become the node's input
ports, so it plugs into the graph like anything else rather than being an
escape hatch. `min`, `max`, `abs`, `sqrt`, `floor`, `ceil`, `round` and
`random` are available as calls.

An Input node is a number the Run panel asks for before the run starts: it
carries a default, the panel shows a box for it as soon as the node is put
down — wired up or not — and the graph reads it like any other value. It is
written once and read from then on, so every cook of a run sees the same
number. The default is the global's initial value in the module, so a host
that sets nothing still gets the number the graph was drawn with.

Every number is an `f64` or an `i64`, and a condition is an `i32` used as a
boolean. Mixing them is what the type check catches: a Choose's `if` port will
not accept a number, and Out's `value` will not accept a comparison. A Yes or
No node writes a flag down, and both Feedback and Choose can be set to work on
flags instead of numbers, so a yes-or-no is something a graph can keep and
pick between rather than only work out.

Text is the one value that is not a number at all, and it is deliberately
thin: a Text node holds a literal and a Say node hands it to the host. There
is no memory in a graph to build a string in, so nothing takes text apart or
puts it together — the literals go end to end into the module's memory at
compile time, and `env.say(ptr, len)` is a slice of it. The memory is exported
so the host can read the bytes back:

```wat
(memory (export "memory") 1)
(data (i32.const 0) "blink")
…
i32.const 0
i32.const 5
call $say
```

## Nothing is written by name

There could be nodes that read and wrote a named variable. There are not,
because matching one node's `total` against another's would mean comparing
strings by eye, when an edge can be seen.

Feedback took their place, and it is the only node that holds anything. It
starts at a value the node itself carries — there is no entry point to
initialise it from, so that value is the global's initial value — and every
cook it hands out what it holds and takes in whatever it is fed. The value
comes out of a port rather than out of a name, and **which state a node means
is the node itself**: two Feedbacks called the same thing are two different
states.

They all take their new values at the same moment, at the end of the cook, so
two of them can read each other without the order mattering. `examples/bounce.json`
is that: a position and a direction, each reading the other.

```
(set x_next next_value)
(set rising_next (select (or (>= next_value 10) (<= next_value 0)) (not rising) rising))
(set x x_next)              ; every commit is after every read
(set rising rising_next)
```

Loops are not drawn either. A graph that has to count runs many times rather
than looping once, which is why what a Feedback holds outlives a call: it is a
module global, exported as `state_<name>`, so the host reads where a program
got to without the program reporting anything.

## The pipeline

| module | what it does |
| --- | --- |
| `compiler/lib/graph.ml` | reads React Flow's own save format; ports are `sourceHandle`/`targetHandle` |
| `compiler/lib/spec.ml` | the node catalogue the editor draws from: ports, colours, the inspector's fields |
| `compiler/lib/lower.ml` | validates, type checks, and lowers the graph to the IR |
| `compiler/lib/ir.ml` | one function of no arguments: typed locals, a flat list of statements |
| `compiler/lib/wasm.ml` | the binary writer — LEB128, sections, opcodes |
| `compiler/lib/emit.ml` | IR to a module |
| `compiler/lib/wat.ml` | the same instruction stream as text, for the editor's Code tab |

Lowering is one walk, backwards. It starts at the sinks — Out, Log, Say, and
every Feedback that is fed something — and follows data edges from an input
port to build an expression tree, refusing to loop. The walk stops at a
Feedback, which is a global read: that is what keeps the cycle in the picture
from being a cycle in the recursion.

What comes out has the same skeleton every time: the hoisted shared values,
then the sinks, then each Feedback's new value into a local of its own, then
all the commits, then the return. The split between the last two is what makes
"every Feedback takes its new value at once" true.

The IR has no branch in it — assignment, a store to a global, log, say,
return, and `select` as an expression. Emitting a wasm `select` rather than a
branch is sound because nothing in a graph has an effect where it is read, so
working out the arm that is not taken costs nothing but time. A language whose
edges said what happens next would need a relooper here: dominators, back
edges, and irreducible graphs to refuse.

It prints as S-expressions, because it is a tree and so is the graph it came
from — an expression's shape is the nesting rather than a precedence table you
have to know. That is not wat: `wat.ml` writes the stack machine, one
instruction to a line, while here a call still has its arguments inside it.
The locals all appear during lowering; none of them exist in the graph.

Errors are collected rather than thrown at the first one, and each carries the
id of the node that caused it, so the editor can outline the offending node
and print the message underneath it. The editor recompiles on every edit,
which is what makes that feel like a linter rather than a build step.

A node whose output feeds several inputs is computed once, into a local, and
read from there. With no way to name an intermediate value in the graph,
sending one output to many places is how you are meant to work, and expanding
it at every use doubles the emitted code at every level: a chain of twenty-two
nodes wired that way takes 6.8 seconds and 12,583,046 bytes without this, and
38 ms and 285 bytes with it.

What makes hoisting sound is that it is scoped to a *group* — one place where
a set of expressions is worked out together — and a group never writes a local
that its own expressions read. A whole cook is one group: the graph has no
assignment in it, and the writes to the globals are all at the very end.

Random and Time are hoisted however few edges leave them. A node that asks the
host something *is* its answer, and an edge count does not see a formula that
names it twice.

The one expression that needs a scratch local of its own is `%`, which wasm
has no instruction for: it becomes `x - trunc(x / y) * y`, with each operand
parked in a local so neither runs twice.

The generated module imports `env.log`, `env.random`, `env.watch`, `env.now`
and `env.say`, and exports `main`, the globals a graph holds, and — if it says
anything — its memory. No table.

## The editor draws what the compiler describes

There is one list of node kinds, and it is in `compiler/lib/spec.ml`: what each
one is called, its colour, the fields the inspector offers, and the ports it
draws. The editor asks for it over the same bridge it asks for a compile —
`ferret.specs()` for the catalogue, `ferret.describe(kind, settings)` for one
node — and `ferretc --emit spec` prints the same JSON for a test to pin.

Ports are why this is worth doing. A port id drawn on a card is the string the
lowering reads back out of `sourceHandle`, so the two used to be the same
string held in two files. Now the card is drawn from what the compiler says,
and the ports that depend on a node's own settings — a Logic node that is set
to `not` and so takes one side, a Feedback or a Choose set to work on flags,
an Expression node whose ports are whatever names its text leaves free — are
answered by the code that will read them.

That last one had a copy of the parser in it. The editor scanned the text with
a regular expression for names not followed by `(`, and guessed at whether the
result was a number or a condition by looking for a comparison outside any
bracket. Both are gone: the real lexer lists the names, and whether the result
is a condition is the operator at the top of the parsed tree rather than a
guess. A formula that is halfway typed still has ports, because the names come
off the tokens rather than off a tree that does not exist yet.

A card asks on every render, so the answers are memoised on the node's
settings, which only change on an edit: dragging a node across the canvas asks
none, and typing eight characters into a formula asks eight.

## Whole numbers

Every number could be an f64. Instead the lowering types them: a literal that
is whole is an i64, and so is anything built only out of those. A value widens
where it meets an f64 — Time, Random and Input all arrive from the host as
f64, a quotient is not whole even when both ends are, and `log`, `out` and a
breakpoint all hand f64s back — and it never narrows.

```
(global i int)
(func main (result f64)
  (local result float)
  (local i_next int)
  (log (float (% i 3)))       ; i64.rem_s, then one convert for the host
  (set result (/ (float i) 2))
  (set i_next (+ i 1))        ; i64.add
  (set i i_next)
  (return result))
```

A Feedback's slot cannot be typed by looking at it once, because its new value
reads the slot. So the whole lowering is its own fixpoint: it starts by
assuming every slot is whole and runs again whenever that turns out to be too
narrow. An assumption only ever loosens, so it settles in at most one pass per
slot. That is why `examples/count.json` ends up with an f64 `count` — its step
is an Input, which arrives from the host — while the same graph with a
Constant step is whole all the way through.

What it buys, in bytes, against a build of the compiler with every literal
forced to f64:

| | every number an f64 | whole numbers as i64 |
| --- | --- | --- |
| the typing fixture above | 212 | **180** |
| Bounce | 252 | **223** |
| Monte Carlo | 360 | **328** |
| Blink | 217 | **204** |
| Counting | 199 | 199 |
| Wave | 228 | 228 |

The last two have no whole number in them to begin with — an Input and 0.25 —
so there is nothing for the inference to do. On a module this small the
sections that describe it outweigh the code in it either way.

An `f64.const` is nine bytes and an `i64.const` is two, which is most of the
difference, and `%` on whole numbers is one instruction instead of the eight
and two scratch locals it takes to fake on floats.

Two things change beyond speed and size, and both are the point rather than an
accident. A Feedback that accumulates keeps going for as long as the host
keeps cooking, and an i32 runs out at 2^31 — a graph adding a million a cook
would break in half an hour. And an i64 stays exact past 2^53, where an f64
starts rounding, so an integer program is more accurate, not less; the one
place it is worse is that `%` by zero traps instead of producing a NaN.

## The one impure node

Random is the only expression that is not a function of its inputs, which
makes the two places that assume purity worth spelling out.

Sharing decides how often it is drawn. A node's output feeding several inputs
is computed once, so **the node is the draw**: wire one Random into both sides
of a multiply and you square one number, rather than multiplying two different
ones. Two Random nodes are two draws, and a new cook draws again. That is what
the Monte Carlo example relies on — and why it holds even when the reader is
an Expression naming it twice down a single edge, which is the one case an
edge count gets wrong.

Choose evaluates both arms, because it compiles to wasm's `select` rather than
a branch. A Random in the arm that is not taken is still drawn. Nothing else
in an expression can trap or be observed, so this is the only case where that
matters.

`random(min, max)` is `min + random() * (max - min)`, which reads `min` twice;
as with `%`, it is parked in a scratch local first, unless it is already a
literal or a local.

## Breakpoints

Right-click a node and add a breakpoint, and the compiler plants a call to a
third import, `env.watch(index, value) -> value`, where that node's value is
worked out. The call hands the number to the page and gives it straight back,
so the program computes what it would have computed either way; what changes
is that the page now sees it.

Where the call goes follows from the sharing rule. A node that feeds several
inputs is computed once, so its breakpoint is hit once per cook rather than
once per reader. A Feedback reports the value it is about to take, not the one
it is handing out — the cook before already reported that.

`--emit ir` shows exactly where they landed:

```
(global i int)
(func main (result f64)
  (local result float)
  (local i_next int)
  (set result (float i))
  (set i_next (watch 1 (watch 0 (+ i 1))))   ; the sum, then the feedback
  (set i i_next)
  (return result))
```

The compiler returns the table those indices point into — node id and label
per index — so the Run panel can name what it stopped at.

Which nodes a run stops at is the page's to say — see Stepping below — so a
breakpoint is a mark on a node rather than something compiled in.

A stop shows what the graph is holding, not just the value that was reported:
its state is in exported globals, so the worker reads all of them at the stop
and the panel lists them. Stepping through a cook shows those numbers *not*
moving — every Feedback commits at the end — and then all of them moving at
once when it finishes. The panel also says which cook the stop is in, which is
the only way to read a state table for a program that keeps running.

Stopping at one is the awkward part. A wasm call is synchronous: the only way
to hold a program inside one is to hold the thread it runs on, so the worker
blocks in `Atomics.wait` on a `SharedArrayBuffer` the page can write to, and
Continue is a store and a notify. That needs the page to be cross-origin
isolated, which is why the Vite config sends COOP and COEP. Served without
those headers everything still works, minus the stopping: the cook reports each
hit and finishes, and the panel says so. The runaway clock is stopped while a
breakpoint holds a cook, so thinking at one is not mistaken for hanging. Play
keeps its place too — the next cook is not sent until the held one comes back.

## Stepping

Step compiles a second module with a report on every node, and stopping at one
is the page's decision rather than the module's: the worker reads a flag out
of the shared buffer at each report, and **the page can change that flag while
the worker is held at one**. That is all stepping is.

| | the flag says | where it stops next |
| --- | --- | --- |
| Cook, Play | marked | a node you put a breakpoint on |
| Step | every | the first node of that cook |
| Next | every | whatever reports next — one node |
| Continue | marked | the next breakpoint |

So a cook stops at a breakpoint and you carry on from there a node at a time,
which is what a debugger is meant to do. Stepping `bounce` walks its eleven
nodes in the order they are evaluated — `step`, `next`, `show`, `out`, `x`,
`top`, `bottom`, `turn`, `flip`, `keep`, `dir` — a stop per node evaluation,
once each however many readers a value has, and the whole list again on the
next cook.

Cook and Play with no breakpoints are the case that does not use the reporting
build at all: with nothing to stop for, what runs is the graph as drawn.

Every stop centres the canvas on the node being evaluated and selects it.
That selection would read as the user reaching for the inspector, which would
take the panel away from the run it is showing; opening the inspector belongs
to the click, not to the selection.

## Running what was generated

The editor instantiates the module in a Web Worker rather than on the UI
thread, and **leaves it standing**: what one cook puts in the Feedbacks is
what the next one reads, so a run is the instance plus however many times it
has been cooked. Stopping a run is terminating the worker — there is nothing
else holding the state. A worker can also be killed after three seconds, which
a hung tab cannot.

## What is deliberately missing

There is one function and no calls, so there is no recursion and no function
section worth the name. There are no arrays, and the only memory is a
read-only slab of string literals. Beyond the sharing described above there is
no optimiser: the emitter is a direct syntax-directed walk of the IR, so
`x + 0` survives into the bytes.
