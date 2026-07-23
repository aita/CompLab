"""Run a MinPython source file.

    uv run python -m minpython FILE            # run on the bytecode VM
    uv run python -m minpython --jit FILE      # + the loop-tracing JIT
    uv run python -m minpython --method FILE   # + the method (function) JIT
    uv run python -m minpython --dis FILE      # disassemble, don't run
    uv run python -m minpython --loops FILE    # run, then report hot back-edges

`--jit` compiles hot `while` loops to native code; `--method` compiles hot
(non-loop) functions -- recursion included. The two can be combined, and each
prints its stats afterwards.
"""

from __future__ import annotations

import sys
from pathlib import Path

from .bytecode import disassemble
from .compile import compile_module
from .vm import VM


def main(argv: list[str]) -> int:
    flags = {a for a in argv if a.startswith("-")}
    paths = [a for a in argv if not a.startswith("-")]
    if len(paths) != 1:
        print("usage: python -m minpython [--jit|--method|--dis|--loops] FILE",
              file=sys.stderr)
        return 2
    source = Path(paths[0]).read_text()

    if "--dis" in flags:
        print(disassemble(compile_module(source)))
        return 0

    vm = VM(profile=True)
    jit = method = None
    if "--jit" in flags:
        from .jit import TracingJIT
        jit = TracingJIT(vm, threshold=50, log="--verbose" in flags)
    if "--method" in flags:
        from .jit import MethodJIT
        method = MethodJIT(vm, threshold=10, log="--verbose" in flags)
    vm.run(source)

    if jit is not None:
        print(f"\n--- trace jit stats --- {jit.stats()}", file=sys.stderr)
    if method is not None:
        print(f"\n--- method jit stats --- {method.stats()}", file=sys.stderr)

    if "--loops" in flags and vm.loop_counts:
        print("\n--- back-edge hits (hot loops) ---", file=sys.stderr)
        for (_code_id, target), count in sorted(
                vm.loop_counts.items(), key=lambda kv: -kv[1]):
            print(f"  loop @ pc {target}: {count}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
