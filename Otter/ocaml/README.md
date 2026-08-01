# The OCaml interpreter

A tree-walking interpreter for [Otter](../README.md), written in OCaml. It
reads the same language as [the C++ one](../interpreter), runs the same
programs, and reports the same diagnostics down to the column.

```
dune build
./_build/default/bin/otter.exe examples/tour.otter
dune test
```

It needs OCaml 5, dune, menhir and ocamllex; it was developed with OCaml 5.4
and dune 3.21.

## How it is put together

One pass per concern, and each concern is one module:

| module | what it does |
| --- | --- |
| `Diagnostics` | source positions, and the two kinds of error |
| `Types` | the type objects, and what it means for two of them to be one type |
| `Ast` | the tree the rest of the program works on |
| `Lexer`, `Parser` | the tokens and the grammar, from ocamllex and menhir |
| `Parse` | drives them, and turns their complaints into ours |
| `Program` | finds and loads the modules a program reaches |
| `Check` | resolves names and gives every expression a type |
| `Value` | the runtime representation of a value, and the census |
| `Builtins` | the host functions, and the modules the implementation provides |
| `Interp` | walks the tree and runs it |

Syntax is handled by a generator: [`src/lexer.mll`](src/lexer.mll) and
[`src/parser.mly`](src/parser.mly) are the last word on it, and the parser
builds the tree the checker annotates directly in its actions.

The modules that ship with the interpreter — `io`, `str`, `math` and `gc` —
are described in [`src/builtins.ml`](src/builtins.ml): a name, a signature, and
the host function each one stands for. `Program` turns a description into an
ordinary module whose functions have no body, which is what a body-less function
is anywhere else, so from there on they are checked and run through exactly the
same path as a program's own modules.

The checker runs in phases, so that declarations may appear in any order: every
struct gets a type before any field is resolved, and every function signature is
registered before any body is checked. That is what makes mutual recursion and
self-referential structs work without forward declarations.

Types are compared by `Types.equal` rather than by OCaml's structural equality,
because a struct is nominal — two declarations with identical fields are still
different types — and because a struct that holds itself through a pointer is a
cyclic value that structural equality would walk forever.

Evaluation is a plain recursive walk. Control flow is a returned value rather
than an exception, so a `return` inside a loop costs a comparison. Faults that
the language checks for — a null dereference, an index out of range, a division
by zero — are raised, and reported with the position of the expression that
caused them.

## Memory

Memory is OCaml's to reclaim, and its collector traces, so a closure and the
scope that holds it — which point at each other — are collected like anything
else.

What `Value.Census` adds is a count. Every array, string, struct, closure,
scope and cell the program makes is entered in a weak table, so asking how many
are still there keeps none of them alive: that is what
[`gc.live()`](../doc/language.md#gc) reports, and `gc.collect()` runs a full
collection and drops the entries that emptied. When the table fills, a
collection runs on its own, which is what keeps the count the size of what is
alive rather than of everything ever made.

## Where it differs from the C++ interpreter

Both accept the same programs and write the same things; these are the two
places where a difference is visible.

- A syntax error is reported in this parser's words rather than ANTLR's. The
  file, line and column are the same.
- An `if` written where a statement can start is read as the statement form,
  and a block that ends in one gives it as a value only when something asks the
  block for one. So `{ if (c) { 1 } else { 2 } }` stands for a value where a
  value is wanted, which is what programs write; what this loses is an operator
  applied to that if, as in `{ if (c) { 1 } else { 2 } * 3 }`, which is read as
  a statement followed by a stray `* 3` and rejected.
  [`tests/cases/value_blocks.otter`](tests/cases/value_blocks.otter) pins down
  what is kept.

## Tests

`tests/cases` holds programs that run to completion and are compared on their
standard output; `tests/errors` holds programs that must be rejected or must
fault, and are compared on their diagnostics; the examples are documentation,
so they are held to running as well. A test exists for every `.expected` file,
so adding one is a matter of writing the program and recording what it should
say.
