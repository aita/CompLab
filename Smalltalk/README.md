# Smalltalk

A small Smalltalk implemented twice, once per directory:

- [`python/`](python/README.md) — the reference implementation: a bytecode VM
  and a PySide6 IDE. Mature; 55 tests. Run with `uv`.
- [`cpp/`](cpp/README.md) — a C++23 port built with **C++20 modules** (one
  `stoat` module split into partitions mirroring the Python `st/` layout).
  Built with CMake + Ninja. Early / in progress.

Both target the same language subset and the same VM design (compile to
bytecode, run on a non-recursive stack machine with reified contexts). See
`python/docs/` for the language, object model, and bytecode reference that both
implementations follow.
