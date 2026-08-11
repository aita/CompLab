# small Smalltalk

A small Smalltalk implementation in Python: a **bytecode virtual machine**
plus a **PySide6 IDE** (System Browser + Workspace + Transcript).

Deep dives live in [`docs/`](docs/README.md): [syntax](docs/syntax.md),
[object model](docs/objects.md), [bytecode](docs/bytecode.md). The book that
walks both implementations chapter by chapter is [`../doc/`](../doc/index.md).

## Pipeline

```
source ──lexer──▶ tokens ──parser──▶ AST ──compiler──▶ bytecode ──VM──▶ value
```

| module           | role                                                          |
|------------------|---------------------------------------------------------------|
| `st/lexer.py`    | tokenizer (numbers, strings, symbols, `$c`, `#(...)`, `:=`)   |
| `st/parser.py`   | recursive descent; unary > binary > keyword, cascades, blocks |
| `st/ast.py`      | AST node dataclasses                                           |
| `st/bytecode.py` | opcode set + `CompiledMethod` / `CompiledBlock`               |
| `st/compiler.py` | AST → bytecode; inlines `ifTrue:`/`whileTrue:`/`and:`/`or:`    |
| `st/vm.py`       | non-recursive stack machine; closures + non-local return      |
| `st/kernel.py`   | base classes and Python primitives                            |
| `st/system.py`   | `Smalltalk` facade: eval / define class / define method       |
| `ide/`           | PySide6 IDE                                                    |

The compiler inlines the common boolean/loop selectors into conditional jumps
when their arguments are literal zero-argument blocks; every other block
becomes a real closure invoked through the `value` primitive.

## Run

```sh
uv sync
uv run python main.py          # launch the IDE
uv run python main.py repl     # terminal REPL
uv run pytest                  # 55 tests
```

## IDE

- **Workspace** — type an expression, select it, then **Print it** (Ctrl-P)
  inserts the result, or **Do it** (Ctrl-D) runs it for its side effects.
- **System Browser** — pick a class, edit a method, **Accept** (Ctrl-S) to
  compile and install it. *New Class* adds a subclass. Instance/class side
  toggle.
- **Transcript** — receives `Transcript show:`/`showCr:` output.

## Language coverage

Literals (`42`, `3.14`, `16rFF`, `'str'`, `#sym`, `$c`, `#(1 2 3)`, `{a. b}`),
temps `| a b |`, assignment `:=`, cascades `;`, blocks `[:x | ...]`, returns
`^`, and non-local returns from blocks. Kernel: `Object`, `Boolean`, `Number`/
`Integer`/`Float`, `Character`, `String`/`Symbol`, `Array`,
`OrderedCollection`, `Dictionary`, `Association`, `Point`, `BlockClosure`,
`Transcript`, `Error` (`on:do:`/`ensure:`).

```smalltalk
Object subclass: Counter (count)
    Counter >> initialize   count := 0
    Counter >> increment    count := count + 1
    Counter >> count        ^count
```
