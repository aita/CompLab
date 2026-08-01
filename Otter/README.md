# Otter

A small statically typed language, and two tree-walking interpreters for it:
one written in C++23, one written in OCaml.

Otter is a laboratory language: it has modules, structs, arrays, strings,
pointers, type aliases and first-class functions with closures, but no
generics, no inheritance and no exceptions. Memory is reclaimed by a
mark-and-sweep collector. That is enough to write real programs with, and small
enough that the whole front end fits in one afternoon's reading.

```
module hello;

import io;

fun main() -> int {
    io.println("hello, otter");
    return 0;
}
```

- [`doc/language.md`](doc/language.md) — the language reference.
- [`interpreter/grammar/Otter.g4`](interpreter/grammar/Otter.g4) — the grammar,
  which is the last word on the syntax.
- [`interpreter/examples/`](interpreter/examples) — programs to read, starting
  with `tour.otter`.

## The two interpreters

[`interpreter/`](interpreter) holds the one written in C++23, which is what the
rest of this file describes: ANTLR generates its parser, and it has a
mark-and-sweep collector of its own.

[`ocaml/`](ocaml) holds the one written in OCaml, described in
[`ocaml/README.md`](ocaml/README.md): ocamllex and menhir generate its parser,
and memory is OCaml's collector's to reclaim.

They read the same language and report the same diagnostics, down to the
column. Each tree carries the examples and the tests, so both are held to the
same programs.

## Building

The interpreter needs a C++23 compiler with module support, CMake 3.30 or
newer, Ninja, and a JRE for the parser generator. It was developed with GCC 16,
CMake 4.3 and OpenJDK 11.

```
cd interpreter
cmake -S . -B build -G Ninja
cmake --build build
```

The first configure downloads the ANTLR generator and its C++ runtime into the
build directory; nothing is installed outside it. After that:

```
./build/otter examples/tour.otter
ctest --test-dir build
```

## How it is put together

The interpreter is one pass per concern, and each concern is one C++ module:

| module | what it does |
| --- | --- |
| `otter.diagnostics` | source positions, and the two kinds of error |
| `otter.types` | the type objects, interned so that equality is pointer equality |
| `otter.ast` | the tree the rest of the program works on |
| `otter.parse` | drives the generated ANTLR parser and lowers its tree to the AST |
| `otter.program` | finds and loads the modules a program reaches |
| `otter.check` | resolves names and gives every expression a type |
| `otter.value` | the runtime representation of a value, and the collector |
| `otter.builtins` | the host functions, and the modules the implementation provides |
| `otter.interp` | walks the tree and runs it |

Syntax is handled by ANTLR: `grammar/Otter.g4` is a combined lexer and parser
grammar, and `cmake/Antlr.cmake` runs the generator at build time. The
generated parse tree is not the tree the interpreter runs; `otter.parse`
lowers it into a smaller AST that the checker can annotate.

The modules that ship with the interpreter — `io`, `str`, `math` and `gc` —
are described in `otter.builtins`: a name, a signature, and the host function
each one stands for. `otter.program` turns a description into an ordinary
module whose functions have no body, which is what a body-less function is
anywhere else, so from there on they are checked and run through exactly the
same path as a program's own modules.

The checker runs in phases, so that declarations may appear in any order:
every struct gets a type before any field is resolved, and every function
signature is registered before any body is checked. That is what makes mutual
recursion and self-referential structs work without forward declarations.

Evaluation is a plain recursive walk. Control flow is a returned enum rather
than a thrown exception, so a `return` inside a loop costs a comparison.
Faults that the language checks for — a null dereference, an index out of
range, a division by zero — are thrown, and reported with the position of the
expression that caused them.

## The collector

`otter.value` holds a mark-and-sweep heap. Arrays, strings, structs, closures,
scopes and variable cells are all objects in it, and nothing moves, so a raw
pointer stays good for as long as what it names is reachable. Marking uses an
explicit worklist rather than the C++ stack, so a long list cannot overflow it.

What that costs is a rule the evaluator has to keep: a value held only in a C++
local is invisible to the collector, so anything kept across a point where more
memory can be asked for is held in a `Root` instead, which registers it on a
shadow stack. Setting `OTTER_GC_THRESHOLD=1` collects at every single
allocation, which turns any missing root into an immediate failure; the test
suite is expected to pass under it.

```
OTTER_GC_THRESHOLD=1 ctest --test-dir build
```

Because it traces rather than counts, a closure and the scope that holds it —
which point at each other — are collected like anything else.

## What is deliberately missing

There is no separate compilation, no bytecode, and no optimiser. A module is
re-read and re-checked on every run. The collector stops the world, marks
everything reachable, and is not generational or incremental.
