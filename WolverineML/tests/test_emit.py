from __future__ import annotations

from pathlib import Path

from wolv import copies, driver

HERE = Path(__file__).parent


def asm(source: str, opts: driver.Options | None = None) -> str:
    return driver.compile_to_asm(source, opts or driver.Options())


# -- parallel copies ----------------------------------------------------------


def perform(steps: list[copies.Step], registers: dict[int, str]) -> dict[int, str]:
    state = dict(registers)
    for step in steps:
        match step:
            case copies.Mov(dst, src):
                state[dst] = state[src]
            case copies.Swap(a, b):
                state[a], state[b] = state[b], state[a]
    return state


def check(moves: list[tuple[int, int]], borrowed: int | None) -> list[copies.Step]:
    """Run a parallel copy on a register file and insist it did what it said."""
    registers = {r: f"v{r}" for r in range(32)}
    steps = copies.sequentialize(moves, borrowed)
    after = perform(steps, registers)
    for dst, src in moves:
        assert after[dst] == registers[src], f"x{dst} should hold v{src}"
    return steps


def test_a_copy_with_no_cycle_is_just_moves() -> None:
    steps = check([(1, 2), (3, 4), (5, 5)], borrowed=9)
    assert all(isinstance(s, copies.Mov) for s in steps)
    assert len(steps) == 2


def test_a_chain_is_ordered_so_nothing_is_lost() -> None:
    check([(1, 2), (2, 3), (3, 4)], borrowed=9)


def test_a_cycle_borrows_a_register_when_there_is_one() -> None:
    steps = check([(1, 2), (2, 1)], borrowed=9)
    assert all(isinstance(s, copies.Mov) for s in steps)
    assert any(s.dst == 9 for s in steps if isinstance(s, copies.Mov))


def test_a_cycle_swaps_when_there_is_nothing_to_borrow() -> None:
    steps = check([(1, 2), (2, 1)], borrowed=None)
    assert [isinstance(s, copies.Swap) for s in steps] == [True]


def test_a_longer_cycle_swaps_its_way_round() -> None:
    steps = check([(1, 2), (2, 3), (3, 1)], borrowed=None)
    assert all(isinstance(s, copies.Swap) for s in steps)
    assert len(steps) == 2


def test_two_cycles_at_once() -> None:
    check([(1, 2), (2, 1), (3, 4), (4, 3)], borrowed=None)
    check([(1, 2), (2, 1), (3, 4), (4, 3)], borrowed=9)


# -- what the scratch registers used to be for --------------------------------


def test_the_remainder_is_a_divide_and_an_msub() -> None:
    text = asm("fun f (a : int, b : int) : int = a mod b\nval () = printInt (f (7, 2))")
    assert text.count("sdiv") == 1
    assert text.count("msub") == 1
    assert "mul" not in text


def test_ordinary_code_keeps_no_register_back() -> None:
    """x17 is only for an address the emitter cannot reach any other way."""
    text = asm((HERE.parent / "examples" / "tour.wol").read_text())
    assert "x17" not in text


def test_x16_is_allocatable() -> None:
    """It used to be held back for the emitter; a busy function should take it."""
    text = asm((HERE / "programs" / "pressure.wol").read_text())
    assert "x16" in text
