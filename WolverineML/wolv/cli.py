"""The command line."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from wolv import driver, regalloc
from wolv.diag import WolvError


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    opts = driver.Options(
        checks=not args.no_checks,
        optimise=not args.no_opt,
        max_regs=args.max_regs,
    )
    path = Path(args.file)
    try:
        source = path.read_text()
    except OSError as error:
        print(f"wolv: {error}", file=sys.stderr)
        return 1

    try:
        match args.command:
            case "check":
                driver.to_ir(source, opts)
            case "emit":
                sys.stdout.write(driver.stage(source, args.stage, opts))
            case "build":
                out = Path(args.out) if args.out else path.with_suffix("")
                driver.build(source, out, opts)
            case "run":
                done = driver.run(source, opts, stdin=_stdin())
                sys.stdout.write(done.stdout)
                sys.stderr.write(done.stderr)
                return done.returncode
    except WolvError as error:
        print(f"{path}:{error}", file=sys.stderr)
        return 1
    except (driver.ToolchainError, regalloc.OutOfRegisters) as error:
        print(f"wolv: {error}", file=sys.stderr)
        return 1
    return 0


def _stdin() -> str:
    return "" if sys.stdin.isatty() else sys.stdin.read()


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="wolv", description="compile WolverineML to ARMv8"
    )
    p.add_argument(
        "command",
        choices=("build", "run", "emit", "check"),
        help="build an executable, run it, dump a stage, or only typecheck",
    )
    p.add_argument("file", help="a .wol source file")
    p.add_argument("-o", "--out", help="where to write the executable")
    p.add_argument(
        "-s",
        "--stage",
        choices=driver.STAGES,
        default="asm",
        help="which stage `emit` should show",
    )
    p.add_argument("--no-checks", action="store_true", help="no nil or bounds checks")
    p.add_argument("--no-opt", action="store_true", help="do not optimise the SSA")
    p.add_argument(
        "--max-regs",
        type=int,
        help="pretend the machine has this many registers, to force spilling",
    )
    return p


if __name__ == "__main__":
    raise SystemExit(main())
