from __future__ import annotations

import pytest

from wolv import allocator, ir, liveness, lower, machine, opt, outofssa, ssa
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

NAMES = sorted(allocator.ALLOCATORS)


def prepared(name: str, source: str = SOURCE) -> ir.Module:
    """The pipeline up to the point where an allocator takes over."""
    prog = parse(source)
    check(prog)
    mod = lower.lower(prog, lower.Options(checks=True))
    ssa.construct_module(mod)
    opt.optimise(mod)
    for func in mod.funcs:
        ssa.split_critical_edges(func)
    if not allocator.ALLOCATORS[name].on_ssa:
        outofssa.destruct_module(mod)
    return mod


def allocated(
    name: str, registers: machine.Registers | None = None, source: str = SOURCE
) -> ir.Module:
    mod = prepared(name, source)
    allocator.allocate_module(mod, allocator.ALLOCATORS[name], registers)
    return mod


# -- what both of them promise ------------------------------------------------


@pytest.mark.parametrize("name", NAMES)
def test_every_value_gets_a_colour(name: str) -> None:
    for func in allocated(name).funcs:
        for block in func.walk():
            for phi in block.phis:
                assert phi.dst in func.colours
            for instr in block.instrs:
                for r in [*instr.uses(), instr.defs()]:
                    assert r is None or r in func.colours


@pytest.mark.parametrize("name", NAMES)
def test_values_live_together_differ(name: str) -> None:
    for func in allocated(name).funcs:
        allocator.verify(func)


@pytest.mark.parametrize("name", NAMES)
def test_a_value_live_across_a_call_is_callee_saved(name: str) -> None:
    for func in allocated(name).funcs:
        live = liveness.analyse(func)
        for reg in liveness.across_calls(func, live):
            assert func.colours[reg] in machine.CALLEE_SAVED


@pytest.mark.parametrize("name", NAMES)
def test_only_the_callee_saved_it_used_are_saved(name: str) -> None:
    for func in allocated(name).funcs:
        assert set(func.saved) == set(func.colours.values()) & set(
            machine.CALLEE_SAVED
        )


@pytest.mark.parametrize("name", NAMES)
@pytest.mark.parametrize("size", [5, 6, 8, 12, 16, 26])
def test_a_smaller_machine_still_works(name: str, size: int) -> None:
    registers = machine.limited(size)
    for func in allocated(name, registers).funcs:
        allocator.verify(func)
        for colour in func.colours.values():
            assert colour in registers.anywhere


@pytest.mark.parametrize("name", NAMES)
def test_a_small_machine_spills(name: str) -> None:
    mod = allocated(name, machine.limited(6))
    assert any(func.spill_slots for func in mod.funcs), "nothing spilled"
    for func in mod.funcs:
        for slot in func.spill_slots.values():
            assert slot < func.nslots


@pytest.mark.parametrize("name", NAMES)
def test_pressure_falls_to_what_the_machine_has(name: str) -> None:
    registers = machine.limited(5)
    for func in allocated(name, registers).funcs:
        live = liveness.analyse(func)
        assert liveness.pressure(func, live) <= registers.count()


@pytest.mark.parametrize("name", NAMES)
def test_an_impossible_demand_is_reported(name: str) -> None:
    source = (
        "fun ten (a : int, b : int, c : int, d : int, e : int,\n"
        "         f : int, g : int, h : int, i : int, j : int) : int = a + j\n"
        "val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))\n"
    )
    mod = prepared(name, source)
    with pytest.raises(allocator.OutOfRegisters, match="more registers"):
        allocator.allocate_module(mod, allocator.ALLOCATORS[name], machine.limited(8))


# -- what each of them does about copies --------------------------------------


def test_the_walk_gives_a_phi_and_its_arguments_one_colour() -> None:
    """Biased colouring is all `chordal` has, and it is usually enough."""
    kept, dropped = 0, 0
    for func in allocated("chordal").funcs:
        for block in func.walk():
            for phi in block.phis:
                for arg in phi.args.values():
                    if func.colours[arg] == func.colours[phi.dst]:
                        dropped += 1
                    else:
                        kept += 1
    assert dropped > 0
    assert dropped > kept


def test_leaving_ssa_removes_every_phi() -> None:
    for func in prepared("graph").funcs:
        for block in func.walk():
            assert not block.phis


def test_leaving_ssa_makes_copies_and_coalescing_eats_them() -> None:
    mod = prepared("graph")
    before = sum(
        1
        for func in mod.funcs
        for block in func.walk()
        for instr in block.instrs
        if isinstance(instr, ir.Move)
    )
    assert before > 0, "leaving SSA should have made copies"
    allocator.allocate_module(mod, allocator.ALLOCATORS["graph"])
    left = sum(
        1
        for func in mod.funcs
        for block in func.walk()
        for instr in block.instrs
        if isinstance(instr, ir.Move)
        and func.colours[instr.dst] != func.colours[instr.src]
    )
    assert left <= before // 10, f"{left} of {before} copies survived"
