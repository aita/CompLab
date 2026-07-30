from __future__ import annotations

import pytest

from wolv import ir, liveness, lower, opt, regalloc, ssa
from wolv.parser import parse
from wolv.typecheck import check

SOURCE = """
type point = { x : int, y : int }

fun busy (n : int) : int =
  let
    var a = n + 1
    var b = n + 2
    var c = n + 3
    var d = n + 4
    var total = 0
  in
    while a < n * 10 do (
      total := total + a * b + c * d;
      a := a + 1;
      b := b + 2;
      c := c + 3;
      d := d + 4
    );
    total
  end

fun caller (n : int) : int = busy (n) + busy (n + 1) + busy (n + 2)

val p = point { x = 1, y = 2 }
val () = printInt (caller (3) + p.x)
"""


def prepared(source: str = SOURCE, *, checks: bool = True) -> ir.Module:
    prog = parse(source)
    check(prog)
    mod = lower.lower(prog, lower.Options(checks=checks))
    ssa.construct_module(mod)
    opt.optimise(mod)
    for func in mod.funcs:
        ssa.split_critical_edges(func)
    return mod


def allocated(machine: regalloc.Registers | None = None) -> ir.Module:
    mod = prepared()
    regalloc.allocate_module(mod, machine)
    return mod


def test_every_value_gets_a_colour() -> None:
    for func in allocated().funcs:
        for block in func.walk():
            for phi in block.phis:
                assert phi.dst in func.colours
            for instr in block.instrs:
                for r in [*ir.uses(instr), ir.defs(instr)]:
                    assert r is None or r in func.colours


def test_values_live_together_differ() -> None:
    for func in allocated().funcs:
        regalloc.verify(func)


def test_a_value_live_across_a_call_is_callee_saved() -> None:
    for func in allocated().funcs:
        live = liveness.analyse(func)
        for reg in liveness.across_calls(func, live):
            assert func.colours[reg] in regalloc.CALLEE_SAVED


def test_only_the_callee_saved_it_used_are_saved() -> None:
    for func in allocated().funcs:
        assert set(func.saved) == set(func.colours.values()) & set(
            regalloc.CALLEE_SAVED
        )


@pytest.mark.parametrize("size", [5, 6, 8, 12, 16, 26])
def test_a_smaller_machine_still_works(size: int) -> None:
    machine = regalloc.limited(size)
    mod = allocated(machine)
    for func in mod.funcs:
        regalloc.verify(func)
        ssa.verify(func)
        for colour in func.colours.values():
            assert colour in machine.anywhere


def test_a_small_machine_spills() -> None:
    mod = allocated(regalloc.limited(6))
    assert any(func.spill_slots for func in mod.funcs), "nothing spilled"
    for func in mod.funcs:
        for slot in func.spill_slots.values():
            assert slot < func.nslots


def test_pressure_falls_to_what_the_machine_has() -> None:
    machine = regalloc.limited(5)
    for func in allocated(machine).funcs:
        live = liveness.analyse(func)
        assert liveness.pressure(func, live) <= machine.count()


def test_a_phi_and_its_arguments_usually_share_a_colour() -> None:
    """Coalescing is biased colouring: the copy on the edge should vanish."""
    kept, dropped = 0, 0
    for func in allocated().funcs:
        for block in func.walk():
            for phi in block.phis:
                for arg in phi.args.values():
                    if func.colours[arg] == func.colours[phi.dst]:
                        dropped += 1
                    else:
                        kept += 1
    assert dropped > 0
    assert dropped > kept


def test_an_impossible_demand_is_reported() -> None:
    mod = prepared(
        "fun ten (a : int, b : int, c : int, d : int, e : int,\n"
        "         f : int, g : int, h : int, i : int, j : int) : int = a + j\n"
        "val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))\n"
    )
    with pytest.raises(regalloc.OutOfRegisters, match="more registers"):
        regalloc.allocate_module(mod, regalloc.limited(8))
