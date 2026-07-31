"""End to end: compile to ARMv8, assemble, link, and run it.

These are the only tests that need a toolchain.  Without a cross `gcc` and
`qemu-aarch64` they skip rather than fail, so the rest of the suite still runs
on a machine that has neither.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from wolv import driver

HERE = Path(__file__).parent
PROGRAMS = sorted((HERE / "programs").glob("*.wol"))
EXAMPLES = sorted((HERE.parent / "examples").glob("*.wol"))

CONFIGURATIONS = {
    "default": driver.Options(),
    "no-opt": driver.Options(optimise=False),
    "no-checks": driver.Options(checks=False),
    "spilling": driver.Options(max_regs=12),
    "spilling-no-opt": driver.Options(max_regs=12, optimise=False),
    "graph": driver.Options(regalloc="graph"),
    "graph-no-opt": driver.Options(regalloc="graph", optimise=False),
    "graph-spilling": driver.Options(regalloc="graph", max_regs=12),
}


def toolchain() -> None:
    try:
        driver.cross_cc()
        driver.emulator()
    except driver.ToolchainError as error:
        pytest.skip(str(error))


def run(source: str, opts: driver.Options, stdin: str = "") -> str:
    done = driver.run(source, opts, stdin=stdin)
    assert done.returncode == 0, done.stderr
    return done.stdout


@pytest.mark.parametrize("program", PROGRAMS, ids=lambda p: p.stem)
@pytest.mark.parametrize("configuration", CONFIGURATIONS)
def test_programs(program: Path, configuration: str) -> None:
    """Every option gives the same answer; only the code differs."""
    toolchain()
    expected = program.with_suffix(".out").read_text()
    assert run(program.read_text(), CONFIGURATIONS[configuration]) == expected


@pytest.mark.parametrize("example", EXAMPLES, ids=lambda p: p.stem)
def test_examples_agree_with_themselves(example: Path) -> None:
    """No expected output on file: what matters is that the stages agree."""
    toolchain()
    source = example.read_text()
    baseline = run(source, CONFIGURATIONS["default"])
    assert baseline
    for name in ("no-opt", "spilling", "graph", "graph-spilling"):
        assert run(source, CONFIGURATIONS[name]) == baseline, name


def test_the_checks_catch_what_they_are_for() -> None:
    toolchain()
    cases = [
        ("val a = array (3, 0)\nval () = printInt (a[5])", "outside an array"),
        (
            "type t = { x : int }\nval n : t = nil\nval () = printInt (n.x)",
            "field of nil",
        ),
        ("var z = 0\nval () = printInt (7 / z)", "division by zero"),
    ]
    for source, message in cases:
        done = driver.run(source, driver.Options())
        assert done.returncode == 1
        assert message in done.stderr


def test_a_check_can_be_turned_off() -> None:
    toolchain()
    source = "val a = array (3, 0)\nval () = printInt (a[1])\n"
    assert run(source, driver.Options(checks=False)) == "0"


def test_standard_input() -> None:
    toolchain()
    source = """
var line = ""
var c = getChar ()
val () = while c <> "" andalso c <> "\\n" do (line := line ^ c; c := getChar ())
val () = print ("read: " ^ line ^ " (" ^ intToString (size (line)) ^ ")\\n")
"""
    assert run(source, driver.Options(), stdin="hello\n") == "read: hello (5)\n"


def test_exit_code() -> None:
    toolchain()
    done = driver.run("val () = (print (\"bye\\n\"); exit (3))", driver.Options())
    assert done.returncode == 3
    assert done.stdout == "bye\n"
