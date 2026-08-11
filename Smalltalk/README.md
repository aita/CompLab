# Smalltalk

A small Smalltalk implemented twice, once per directory:

- [`python/`](python/README.md) — the reference implementation: a bytecode VM
  and a PySide6 IDE. Mature; 55 tests. Run with `uv`.
- [`cpp/`](cpp/README.md) — a C++23 port built with **C++20 modules** (one `st`
  module split into partitions mirroring the Python `st/` layout). Built with
  CMake + Ninja. No IDE and no metaclasses; otherwise the same language, and
  faster.

Both target the same language subset and the same VM design (compile to
bytecode, run on a non-recursive stack machine with reified contexts).

- [`doc/index.md`](doc/index.md) — the book: how both implementations are built,
  one chapter per concern, in Japanese.
- [`python/docs/`](python/docs/README.md) — the Python-side reference: language,
  object model, and bytecode.
