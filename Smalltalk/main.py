"""Entry point: ``st`` launches the IDE; ``st repl`` starts a terminal REPL."""

from __future__ import annotations

import sys

from st.objects import STError
from st.parser import ParseError
from st.system import Smalltalk


def repl() -> None:
    st = Smalltalk()
    print("small Smalltalk — bytecode VM. Type an expression, Ctrl-D to quit.")
    while True:
        try:
            line = input("st> ")
        except EOFError:
            print()
            return
        if not line.strip():
            continue
        try:
            print(st.eval_to_string(line))
        except (STError, ParseError) as e:
            print(f"Error: {e}")
        except Exception as e:  # noqa: BLE001 - REPL should not crash
            print(f"{type(e).__name__}: {e}")


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "repl":
        repl()
        return
    from ide.app import run_ide

    run_ide()


if __name__ == "__main__":
    main()
