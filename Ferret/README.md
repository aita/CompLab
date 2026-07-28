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

**File** in the toolbar starts a new flow, opens a `.json` one, saves the
current one, or loads an example. What it saves is the same file `ferretc`
takes on the command line, so a flow drawn in the editor can be compiled from
a terminal without a conversion step. Whatever you last edited is kept in the
browser and comes back on reload.

Without the editor:

```
dune test
dune exec compiler/bin/ferretc.exe -- examples/collatz.json -o collatz.wasm
dune exec compiler/bin/ferretc.exe -- --emit wat examples/collatz.json
dune exec compiler/bin/ferretc.exe -- --emit ir examples/sum.json
dune exec compiler/bin/ferretc.exe -- --emit spec
```

The host has to supply all five imports; `compiler/test/run_wasm.mjs` shows
the whole of what that takes.

## The graph is the program

A graph has two kinds of edge, drawn differently and checked separately.

**Exec edges** — square ports — say what happens next. Execution starts at the
one Start node and follows them. **Data edges** — round ports — say where a
value comes from, and are pulled backwards from whatever needs them.

| node | what it is |
| --- | --- |
| Start | the entry point; the one thing it hands out is when the run began |
| End | return a value |
| Condition | sends the flow one way or the other; a wire back into one is a loop |
| Counter | counts: it starts at a value and adds its step every time the flow passes through |
| State | remembers: passing through stores what it is fed, and passing through its `reset` way puts back what it started with |
| For Loop | counts from one value to another, running the body once for each: a Counter and a Condition packed into one node |
| Choose | one of two values, by a condition |
| Log | call the imported `env.log` with a value |
| Wait for Event | stops until the host sends one, and hands over the number it sent |
| Expression | a whole calculation typed as text; the names it leaves free are its input ports |
| Constant, Random, Arithmetic, Math function, Comparison, Logic | the expression nodes |

Choose has no square ports, so it is an expression like the rest of them; it
sits under Flow in the palette because that is where you go looking for a
branch that picks a value rather than a path.

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

A graph takes no arguments. The one thing the host gives it is the time the
run started, which the Start node hands out on a port of its own — asked for
once, so every reader of it sees the same moment. Anything else a program
needs is typed into a port or wired from a Constant.

Every value is an `f64`, except conditions, which are `i32` used as booleans.
Mixing the two is what the type check catches: a Condition's `test` port will
not accept a number, and End's `result` will not accept a comparison.

## Nothing is written by name

There used to be nodes that read and wrote a named variable. They are gone
because matching one node's `total` against another's meant comparing strings
by eye, when an edge can be seen.

Counter and State are what took their place, and they are the only nodes that
hold anything. A Counter starts at one value and adds its step every time the
flow passes through it, so an accumulator is a Counter whose step is not a
constant. A State stores what it is fed instead of adding it — "the next value
is this" rather than "move by this". Either way the value comes out of a port
rather than out of a name, and **which state a node means is the node itself**:
two States called the same thing are two different states.

A Counter is set up once, at the entry to the function, whichever loop it
later turns out to sit inside — so a Counter inside a loop does not start
again on each pass. That is what a State's second way through is for: `reset`
puts back the initial value, and it carries on from a `after reset` pin of its
own, because the place you reset is usually not the place you store. Resetting
before an inner loop and storing inside it is how a running total per pass is
written:

```
(loop $1                       ; outer
  (if (<= r 5)
    (then
      (set run 0)              ; reset, once per outer pass
      (set c 1)
      (loop $2                 ; inner
        (if (<= c r)
          (then
            (set run (+ run c))  ; in, once per inner pass
            …
```

Loops are drawn rather than declared: run a wire from the end of the body back
into a Condition and that is a loop. So the exec edges form a real graph, and
the `block`/`loop`/`br` nesting wasm requires has to be recovered from it —
dominators, back edges, and where two branches join. A loop with two ways into
the middle of it cannot be written with wasm's blocks without duplicating
code, and is refused rather than guessed at.

Counting from one number to another is most of what that gets used for, and
drawing it takes a Counter, a Comparison and a Condition every time, so For
Loop is that arrangement as one node. It has `body` and `done` where a
Condition has `true` and `false`, and the body does not need the wire back:
whatever the body reaches that leads nowhere goes to the loop's step, the way
a Blueprint macro closes itself. Unlike a Counter it is set up where it is
entered rather than at the entry to the function, so a For Loop inside another
one starts again on every pass of the outer.

## The pipeline

| module | what it does |
| --- | --- |
| `compiler/lib/graph.ml` | reads React Flow's own save format; ports are `sourceHandle`/`targetHandle` |
| `compiler/lib/spec.ml` | the node catalogue the editor draws from: ports, colours, the inspector's fields |
| `compiler/lib/lower.ml` | validates, type checks, and lowers the graph to the IR |
| `compiler/lib/ir.ml` | one function of no arguments: typed locals, structured statements |
| `compiler/lib/wasm.ml` | the binary writer — LEB128, sections, opcodes |
| `compiler/lib/emit.ml` | IR to a module |
| `compiler/lib/wat.ml` | the same instruction stream as text, for the editor's Code tab |

Lowering is two walks over the same graph. The forward walk follows exec edges
from Start and turns each node into a statement; the backward walk follows data
edges from an input port and builds an expression tree, refusing to loop. The
backward walk stops at a loop's current-value output, which is a local — that is what
keeps the cycle in the picture from being a cycle in the recursion.

The IR is an ordinary imperative core: assignment, `if`, and labelled
`block`/`loop`/`br` in wasm's own shape. It prints as S-expressions, because
it is a tree and so is the graph it came from — an expression's shape is the
nesting rather than a precedence table you have to know. That is not wat:
`wat.ml` writes the stack machine, one instruction to a line, while here a
call still has its arguments inside it. The locals and the labels all appear
during lowering; none of them exist in the graph.

Errors are collected rather than thrown at the first one, and each carries the
id of the node that caused it, so the editor can outline the offending node
and print the message underneath it. The editor recompiles on every edit,
which is what makes that feel like a linter rather than a build step.

A node whose output feeds several inputs is computed once, into a local, and
read from there. With no way to name an intermediate value in the graph,
sending one output to many places is how you are meant to work, and expanding
it at every use doubles the emitted code at every level: a chain of twenty
nodes wired that way took five seconds and twelve megabytes before this, and
219 bytes after.

What makes hoisting sound is that it is scoped to a *group* — one statement,
a loop's condition, a loop's whole set of next values — and a group never
writes a local that its own expressions read. Nothing is shared across
groups, so a value read on either side of a loop's update is read twice, as
it must be.

The one expression that needs a scratch local of its own is `%`, which wasm
has no instruction for: it becomes `x - trunc(x / y) * y`, with each operand
parked in a local so neither runs twice.

The generated module imports `env.log`, `env.random`, `env.watch`, `env.now`
and `env.wait`, and exports `main`, which takes no arguments. Nothing else: no
memory, no table, no globals.

## The editor draws what the compiler describes

There is one list of node kinds, and it is in `compiler/lib/spec.ml`: what each
one is called, its colour, the fields the inspector offers, and the ports it
draws. The editor asks for it over the same bridge it asks for a compile —
`ferret.specs()` for the catalogue, `ferret.describe(kind, settings)` for one
node — and `ferretc --emit spec` prints the same JSON for a test to pin.

Ports are why this is worth doing. A port id drawn on a card is the string the
lowering reads back out of `sourceHandle`, so the two used to be the same
string held in two files. Now the card is drawn from what the compiler says,
and the ports that depend on a node's own settings — a Start node's declared
inputs, a Logic node that is set to `not` and so takes one side, an Expression
node whose ports are whatever names its text leaves free — are answered by the
code that will read them.

That last one had a copy of the parser in it. The editor scanned the text with
a regular expression for names not followed by `(`, and guessed at whether the
result was a number or a condition by looking for a comparison outside any
bracket. Both are gone: the real lexer lists the names, and whether the result
is a condition is the operator at the top of the parsed tree rather than a
guess. A formula that is halfway typed still has ports, because the names come
off the tokens rather than off a tree that does not exist yet.

A card asks on every render, so the answers are memoised on the node's
settings, which only change on an edit: opening the six-node triangle example
asks five times, dragging a node across the canvas asks none, and typing eight
characters into a formula asks eight.

## Whole numbers

Every number used to be an f64. Now the lowering types them: a literal that is
whole is an i64, and so is anything built only out of those. A value widens
where it meets an f64 — a start node's inputs arrive from the host as f64, a
quotient is not whole even when both ends are, and `log`, `end` and a
breakpoint all hand f64s back — and it never narrows.

```
(func main (result f64)
  (local i int)
  (set i 0)
  (loop $1
    (if (< i 10)                  ; i64.lt_s
      (then
        (log (float (% i 3)))     ; i64.rem_s, then one convert for the host
        (set i (+ i 1))           ; i64.add
        (br $1))
      (else
        (return (/ (float i) 2))))))
```

A loop's slot cannot be typed by looking at it once, because its next value
reads the slot. So the whole lowering is its own fixpoint: it starts by
assuming every slot is whole and runs again whenever that turns out to be too
narrow. An assumption only ever loosens, so it settles in at most one pass per
slot. That is why the collatz example ends up with `steps` as an i64 and `cur`
as an f64 — `cur` starts from the function's parameter, and halving it would
not stay whole anyway.

What it buys, in bytes:

| | every number an f64 | whole numbers as i64 |
| --- | --- | --- |
| Sum of 1 to n | 169 | **160** |
| Collatz steps | 242 | **250** |
| π by throwing darts | 290 | **276** |
| the typing fixture above | 188 | **166** |

(The f64 column was measured back when a loop was one node rather than a
Condition with a wire back into it, and has not been measured again since; the
i64 column is what the compiler emits today, which also carries two imports
the f64 column never had — the import section is now the biggest part of a
small module.)

An `f64.const` is nine bytes and an `i64.const` is two, which is most of it,
and `%` on whole numbers is one instruction instead of the eight and two
scratch locals it takes to fake on floats.

Two things change beyond speed and size, and both are the point rather than an
accident. `sum(100000)` is 5,000,050,000, which is past what an i32 holds —
that is why the whole-number type is i64 and not i32. And an i64 stays exact
past 2^53, where an f64 starts rounding, so an integer program is now more
accurate, not less; the one place it is worse is that `%` by zero traps
instead of producing a NaN.

## The one impure node

Random is the only expression that is not a function of its inputs, which
makes the two places that assume purity worth spelling out.

Sharing decides how often it is drawn. A node's output feeding several inputs
is computed once, so **the node is the draw**: wire one Random into both sides
of a multiply and you square one number, rather than multiplying two different
ones. Two Random nodes are two draws. That is what the π example relies on.

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
inputs is computed once, so its breakpoint is hit once per evaluation rather
than once per reader. A breakpoint on a loop is different: it reports every
slot of its state from the top of each iteration, rather than every time a
slot is read, which is the thing you actually want to watch.

`--emit ir` shows exactly where they landed:

```
(loop $1
  (if (watch 0 (< i 3))        ; a Condition reports its test
    (then
      (set i (watch 1 (+ i 1)))  ; a Counter reports its new value
      (br $1))
    (else
      (return (float i)))))
```

The compiler returns the table those indices point into — node id and label
per index — so the Run panel can name what it stopped at.

Stopping at one is the awkward part. A wasm call is synchronous: the only way
to hold a program inside one is to hold the thread it runs on, so the worker
blocks in `Atomics.wait` on a `SharedArrayBuffer` the page can write to, and
Continue is a store and a notify. That needs the page to be cross-origin
isolated, which is why the Vite config sends COOP and COEP. Served without
those headers everything still works, minus the stopping: the run reports each
hit and finishes, and the panel says so. The runaway-loop clock is stopped
while a breakpoint holds the run, so thinking at one is not mistaken for
hanging.

## Event loops

Every other node is arithmetic, and a run goes from Start to End without
stopping. Wait for Event is the one that takes time: passing through it holds
the program until the host sends something, and what comes back is a number.
An event is a number.

Put one inside a loop and that loop is an event loop:

```
(loop $1
  (set e (wait))          ; stops here
  (if (!= e 0)
    (then
      (log e)
      (set seen (+ seen 1))
      (br $1))
    (else
      (return (float seen)))))
```

**The loop is in the graph rather than in the runtime.** This is not "register
a handler and let something else call it": it is wait, look, wait again, drawn
as wires, so where the program is stopped and where the value goes next are
both visible.

Stopping there needs no new machinery — it is the breakpoint's, with one more
flag. A wasm call is synchronous, so the only way to wait inside one is to
hold the thread: the worker blocks in `Atomics.wait` on the shared buffer, and
the page writes the number and notifies. Waiting is not hanging, so the
runaway-loop clock stops while a program waits, the same way it stops at a
breakpoint; a run held for six seconds and then sent an event carries on. And
as with breakpoints, a page that is not cross-origin isolated has no shared
buffer to wait on: there `wait()` hands back 0 immediately rather than
blocking.

## Stepping

Step in the Run panel compiles a second module with a breakpoint on every
node, so the same machinery stops at each one in turn. Every stop moves the
canvas to the node being evaluated and selects it, and Next carries on; the
panel stays where it is rather than switching to the inspector, since what is
being looked at is the run.

Neither module is the other's instrumentation: Run runs the graph as drawn,
and Step runs a build of its own. The bytes the page executes are always the
bytes the compiler emitted for the thing you asked it to do.

## Running what was generated

The editor instantiates the module in a Web Worker rather than on the UI
thread. One wire back into a Condition is enough to write a loop that never
ends, and a worker can be killed after three seconds; a hung tab cannot.

## What is deliberately missing

There is one function and no calls, so there is no recursion and no function
section worth the name. There are no arrays, strings or memory — every value
is a number. Beyond the sharing described above there is no optimiser: the
emitter is a direct syntax-directed walk of the IR, so `x + 0` survives into
the bytes.
