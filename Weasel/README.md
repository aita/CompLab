# Weasel

A WebAssembly runtime in C++23: the binary format, the text format, the
validator, and an interpreter that runs what the validator planned.

The claim it is built around is that **validation is the compiler**. Type
checking a wasm function requires knowing, at every instruction, how deep the
operand stack is and what each enclosing label expects — and those are precisely
the numbers a branch needs at run time. So the checker does not return a verdict.
It returns a program: a flat array of instructions in which `block`, `loop`,
`else` and `end` no longer exist, and a side table in which every branch target
is a position, a count of values to carry, and a stack height.

```
$ cat gcd.wat
(module
  (func $gcd (export "gcd") (param $a i32) (param $b i32) (result i32)
    (local $t i32)
    (block $done
      (loop $again
        (br_if $done (i32.eqz (local.get $b)))
        (local.set $t (i32.rem_u (local.get $a) (local.get $b)))
        (local.set $a (local.get $b))
        (local.set $b (local.get $t))
        (br $again)))
    (local.get $a)))

$ weasel plan gcd.wat
func[0] : (i32 i32) -> (i32)
  locals i32
  max operand stack 2
     0  local.get 1
     1  i32.eqz
     2  br_if -> 12 keep=0 height=0
     3  local.get 0
     4  local.get 1
     5  i32.rem_u
     6  local.set 2
     7  local.get 1
     8  local.set 0
     9  local.get 2
    10  local.set 1
    11  br -> 0 keep=0 height=0
    12  local.get 0
    13  return

$ weasel run gcd.wat --invoke gcd --arg 1071 --arg 462
21
```

Fourteen instructions, no labels, no block stack. `block` and `loop` planned to
nothing at all; `br_if` became one comparison and an assignment to the program
counter.

The chapter-per-concern write-up is in [`doc/`](doc/index.md), in Japanese.

## Build and run

Needs clang (for C++23 modules and `import std;`) and CMake ≥ 3.28.

```sh
cmake -S . -B build -G Ninja
cmake --build build

./build/weasel run   examples/sieve.wat
./build/weasel dump  file.wasm        # the module as it was read
./build/weasel plan  file.wat         # what validation planned
./build/weasel check file.wat         # decode and validate, silent on success
./build/weasel run   file.wat --invoke gcd --arg 12 --arg 8 --trace
```

`run` takes either format. A file that begins with `\0asm` is decoded as binary,
anything else is parsed as text — no extension is consulted.

## Tests

```sh
ctest --test-dir build --output-on-failure    # or ./build/weasel_tests
node tests/compare-with-v8.mjs                # the same expectations, on V8
```

Each file in [`tests/wat/`](tests/wat) is read twice: once by Weasel's own text
parser, and once by `wat2wasm` and then Weasel's binary decoder. Both must
produce a module that prints identically under `weasel dump`, so a mistake in
either front end shows up as a diff rather than as a wrong answer later.

The same files carry their expectations in comments the parser already ignores:

```wasm
;;= invoke gcd 1071 462 => 21
;;= trap   div_s 1 0 => integer divide by zero
;;= stdout hello, weasel
```

`weasel_tests` checks those against Weasel. `tests/compare-with-v8.mjs` checks
the *same lines* against node's WebAssembly, so they are facts about wasm rather
than a record of what Weasel happens to do.

## What it implements

WebAssembly 2.0 without SIMD: the MVP, plus sign extension, non-trapping
float-to-int conversions, bulk memory, reference types and multi-value.

| | |
|---|---|
| numeric | all i32/i64/f32/f64 instructions, including the sign-extension and saturating-truncation families |
| control | `block` `loop` `if`/`else` `br` `br_if` `br_table` `return` `call` `call_indirect`, with multi-value and block parameters |
| memory | one linear memory, `memory.size`/`grow`/`fill`/`copy`/`init`, `data.drop`, active and passive segments |
| tables | several tables, `funcref` and `externref`, `table.get`/`set`/`size`/`grow`/`fill`/`copy`/`init`, `elem.drop`, active, passive and declarative segments |
| modules | imports and exports of all four kinds, a real store shared between instances, `start`, the custom `name` section |
| host | `wasi_snapshot_preview1` far enough for `fd_write`, `fd_read`, `args`, `environ`, `clock_time_get`, `random_get` and `proc_exit`; and `env`, which is what the sibling [`Ferret`](../Ferret) compiles against |

Not implemented: SIMD, threads and atomics, exception handling, tail calls,
garbage collection, memory64, multiple memories, and the component model.
[Chapter 10](doc/10-next.md) says what each of them would cost.

Weasel runs what Ferret compiles:

```sh
cd ../Ferret && dune build
./_build/default/compiler/bin/ferretc.exe examples/pi.json -o /tmp/pi.wasm
cd ../Weasel && ./build/weasel run /tmp/pi.wasm --invoke main
```

## Structure

One module, `weasel`, split into partitions. Errors travel through a latched
`Diag` (before the module runs) or a latched `Trap` (while it runs); the build
has no exceptions and no RTTI.

| file | lines | what it is |
|---|---|---|
| `src/common.cppm` | 237 | integers, `Value`, the two error channels, the LEB128 reader |
| `src/opcode.cppm` | 316 | one table: name, opcode byte, immediate shape |
| `src/types.cppm` | 267 | what a module is, once read |
| `src/binary.cppm` | 589 | `\0asm` bytes into a module |
| `src/text.cppm` | 1379 | `.wat` into the same module |
| `src/validate.cppm` | 893 | the type checker, and the plan it leaves behind |
| `src/store.cppm` | 202 | memories, tables, globals, functions, instances, the linker |
| `src/instantiate.cppm` | 259 | imports resolved, segments copied, `start` run |
| `src/dump.cppm` | 283 | the two printers |
| `src/exec.cppm` | 869 | the loop |
| `src/wasi.cppm` | 263 | a small `wasi_snapshot_preview1` |
| `src/host.cppm` | 78 | the `env` module Ferret compiles against |
| `src/main.cpp` | 192 | the command line |
