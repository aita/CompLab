"""Random programs, compiled and checked against what Python says they mean."""

from __future__ import annotations

import pytest

from tests import oracle
from tests.test_programs import toolchain
from wolv import driver, emit

CONFIGURATIONS = {
    "default": driver.Options(),
    "no-opt": driver.Options(optimise=False),
    "graph": driver.Options(regalloc="graph"),
    "spilling": driver.Options(max_regs=10),
}


def check(source: str, expected: str, opts: driver.Options) -> None:
    done = driver.run(source, opts)
    assert done.returncode == 0, done.stderr
    if done.stdout != expected:
        got, want = done.stdout.splitlines(), expected.splitlines()
        for i, (g, w) in enumerate(zip(got, want, strict=False)):
            assert g == w, f"line {i}: got {g}, want {w}"
        raise AssertionError(f"{len(got)} lines, want {len(want)}")


@pytest.mark.parametrize("seed", [1, 2])
@pytest.mark.parametrize("configuration", CONFIGURATIONS)
def test_arithmetic(seed: int, configuration: str) -> None:
    toolchain()
    source, expected = oracle.arithmetic(seed, 25)
    check(source, expected, CONFIGURATIONS[configuration])


@pytest.mark.parametrize("seed", [1, 2])
@pytest.mark.parametrize("configuration", CONFIGURATIONS)
def test_arrays_loops_and_branches(seed: int, configuration: str) -> None:
    toolchain()
    source, expected = oracle.imperative(seed, 8)
    check(source, expected, CONFIGURATIONS[configuration])


def test_a_cycle_of_copies_can_be_done_without_a_scratch_register(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Force the swap: the borrowed register is what usually hides this path."""
    toolchain()
    source = (
        "fun spin (n : int) : int =\n"
        "  let var x = 1 var y = 2 var i = 0 in\n"
        "    while i < n do (let val t = x in x := y; y := t end; i := i + 1);\n"
        "    x + y * 10\n"
        "  end\n"
        "val () = (printInt (spin (2)); print (\" \"); printInt (spin (7)))\n"
    )
    assert driver.run(source, driver.Options()).stdout == "21 12"
    monkeypatch.setattr(emit.FuncEmitter, "borrowed", lambda self, moves: None)
    assert "eor x" in driver.compile_to_asm(source, driver.Options())
    assert driver.run(source, driver.Options()).stdout == "21 12"
