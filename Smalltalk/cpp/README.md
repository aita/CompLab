# small Smalltalk — C++

A C++23 port of the [Python implementation](../python/README.md), built with
**C++20 modules**. Same language subset and VM design; different constraints:

- **No `shared_ptr` / reference counting.** Heap objects are owned by a `Heap`
  and reclaimed by a **mark-and-sweep** garbage collector over raw pointers
  (`src/heap.cppm`). Activations (`Context`) and closures (`Block`) are objects
  too, so a captured frame stays alive as long as a closure references it.
- **Restricted exceptions.** Builds with `-fno-exceptions -fno-rtti`. Errors are
  reported by return values / a VM error flag, numbers are parsed with
  `std::from_chars`, and control flow (`^`, doesNotUnderstand) uses the VM's
  explicit activation stack — never C++ exceptions.

## Pipeline

```
source → lexer → parser → AST → compiler → bytecode → VM → value
```

One module `st`, split into partitions mirroring the Python `st/` package:

| file | module | role |
|------|--------|------|
| `src/bytecode.cppm` | `st:bytecode` | opcodes + `Instr` |
| `src/objects.cppm`  | `st:objects`  | `Value` + all heap object types |
| `src/heap.cppm`     | `st:heap`     | mark-and-sweep GC (traces every type) |
| `src/lexer.cppm`    | `st:lexer`    | tokenizer |
| `src/ast.cppm`      | `st:ast`      | AST (owned by `unique_ptr`) |
| `src/parser.cppm`   | `st:parser`   | recursive descent |
| `src/compiler.cppm` | `st:compiler` | AST → bytecode; inlining + lexical addressing |
| `src/vm.cppm`       | `st:vm`       | non-recursive stack machine + closures + `^` |
| `src/kernel.cppm`   | `st:kernel`   | base classes and primitives |
| `src/system.cppm`   | `st:system`   | facade: eval / define_class / define_method |
| `src/st.cppm`       | `st`          | primary interface, re-exports partitions |

The compiler inlines `ifTrue:` / `whileTrue:` / `and:` / `or:` **and**
`to:do:` / `timesRepeat:` (their loop variable is bound to a local slot), so a
primitive never has to re-enter the VM to run a block — which is what keeps the
loop non-recursive and exception-free.

## What works

`3 + 4 factorial`, temps and workspace globals, cascades, blocks and closures
(`value` family), inlined control flow and loops, `super`, non-local return
`^`, and user classes with instance variables:

```smalltalk
"defined via the System API (see main.cpp)"
Counter >> init       count := 0
Counter >> increment  count := count + 1
Counter >> count      ^count
```

`Character`, `Array`, `String`, `OrderedCollection`, and `Dictionary` with the
higher-order protocol — `do:`, `collect:`, `select:`, `reject:`,
`detect:ifNone:`, `inject:into:`, `includes:`, `at:ifAbsent:`,
`keysAndValuesDo:`, … The iteration methods are written **in Smalltalk** (a
prelude in `system.cppm`) on top of `at:` / `size` / `whileTrue:` / `value:`, so
block sends and `^` flow through the one non-recursive loop — no primitive
re-enters the VM, no exceptions.

Performance mirrors the Python port: a per-class method-lookup cache (flushed on
any method/hierarchy change) and an inline SmallInteger arithmetic fast path in
the VM loop (auto-disabled if a numeric class overrides an operator). The opcode
`switch` is already a jump table, so no dispatch reordering is needed.

Not yet ported from the Python side: metaclasses and the IDE.

## Build & run

Needs CMake ≥ 3.28, Ninja, and a modules-capable compiler.

```sh
cmake -S . -B build -G Ninja
cmake --build build
./build/smalltalk        # demo + a small REPL
ctest --test-dir build   # unit tests
```

> **Compiler note.** Use **Clang** (developed with Clang 22). GCC 16's C++20
> modules currently fail to read this project's `st:vm` module ("Bad file
> data"); the `CMakeLists.txt` therefore prefers `clang++` for a fresh build
> tree. Override with `-DCMAKE_CXX_COMPILER=...`. BMIs are compiler-specific and
> not portable — pick one compiler per build tree.

### Editor / clangd (Zed, VS Code)

The build emits `build/compile_commands.json`, and `.clangd` points clangd at
it — so `import` / `export module` / `std::print` resolve. **Build once first**
(clangd reads the module `.pcm` files the build produced), then restart the
language server. Without this, clangd falls back to bad flags and reports
spurious errors. clangd's named-modules support is still experimental, so an
occasional `import :partition;` may stay underlined even though the build is
clean — the CMake/Ninja build is authoritative.
