from __future__ import annotations

from wolv import dag, driver, ir, liveness, lower, mach, opt, select, ssa
from wolv.parser import parse
from wolv.typecheck import check


def selected(source: str, *, checks: bool = False) -> ir.Module:
    prog = parse(source)
    check(prog)
    mod = lower.lower(prog, lower.Options(checks=checks))
    ssa.construct_module(mod)
    opt.optimise(mod)
    for func in mod.funcs:
        ssa.split_critical_edges(func)
    select.select_module(mod)
    return mod


def forms(source: str, name: str = "f", *, checks: bool = False) -> list[str]:
    """The instructions chosen inside one function, the caller's aside."""
    func = next(f for f in selected(source, checks=checks).funcs if f.name == name)
    return [
        instr.form
        for block in func.walk()
        for instr in block.instrs
        if isinstance(instr, mach.Mach)
    ]


def asm(source: str) -> str:
    return driver.compile_to_asm(source, driver.Options(checks=False))


FUNCTION = "fun f (a : int, b : int, c : int) : int = {}\nval () = printInt (f (1, 2, 3))"


# -- the tiles ----------------------------------------------------------------


def test_multiply_add_is_one_instruction() -> None:
    chosen = forms(FUNCTION.format("a + b * c"))
    assert "madd" in chosen
    assert "mul" not in chosen


def test_multiply_subtract_is_one_instruction() -> None:
    chosen = forms(FUNCTION.format("a - b * c"))
    assert "msub" in chosen
    assert "mul" not in chosen


def test_a_shifted_operand_beats_a_multiply_add() -> None:
    """`a + b * 8` is one instruction with a shift and two as a multiply-add."""
    chosen = forms(FUNCTION.format("a + b * 8"))
    assert chosen.count("adds") == 1
    assert "madd" not in chosen and "lsli" not in chosen


def test_a_small_constant_is_an_immediate() -> None:
    assert forms(FUNCTION.format("a + 5")) == ["addi"]
    assert forms(FUNCTION.format("(a + 5) - 7")) == ["addi", "subi"]


def test_a_large_constant_is_not() -> None:
    assert "const" in forms(FUNCTION.format("a + 100000"))


def test_a_multiply_by_a_power_of_two_is_a_shift() -> None:
    chosen = forms(FUNCTION.format("a * 8"))
    assert "lsli" in chosen and "mul" not in chosen


def test_a_comparison_read_only_by_its_branch_sets_the_flags() -> None:
    mod = selected("fun f (a : int) : int = if a < 3 then 1 else 2\n"
                   "val () = printInt (f (1))")
    codes = [
        block.terminator.code
        for func in mod.funcs
        for block in func.walk()
        if isinstance(block.terminator, ir.CBr)
    ]
    assert "lt" in codes
    assert "cset" not in forms("fun f (a : int) : int = if a < 3 then 1 else 2\n"
                               "val () = printInt (f (1))")


def test_a_comparison_read_by_something_else_is_a_value() -> None:
    chosen = forms("fun f (a : int) : bool = a < 3\nval () = print (\"x\")")
    assert "cset" in chosen


def test_an_array_element_takes_two_instructions() -> None:
    text = asm("val a = array (4, 0)\nval () = printInt (a[2] + a[3])")
    assert "lsl #3" in text or "ldr" in text
    body = [line.strip() for line in text.splitlines() if line.startswith("\t")]
    assert sum(1 for line in body if line.startswith("ldr ")) == 2


# -- what the plan is for -----------------------------------------------------


def test_a_constant_read_twice_is_still_an_immediate() -> None:
    """It costs nothing to repeat, so two readers may both take it."""
    chosen = forms(FUNCTION.format("(a + 1) * (b + 1)"))
    assert chosen.count("addi") == 2
    assert "const" not in chosen


def test_a_chain_of_additions_is_not_deferred_to_its_last_line() -> None:
    """Folding a whole spine would keep every term live until the end."""
    source = (
        "fun sum (a : int, b : int, c : int, d : int, e : int, f : int) : int =\n"
        "  a + b + c + d + e + f\n"
        "val () = printInt (sum (1, 2, 3, 4, 5, 6))\n"
    )
    mod = selected(source)
    func = next(f for f in mod.funcs if f.name == "sum")
    live = liveness.analyse(func)
    assert liveness.pressure(func, live) <= 8


def test_a_node_read_twice_is_computed_once() -> None:
    source = FUNCTION.format("let val t = a * b in t + t end")
    chosen = forms(source)
    assert chosen.count("mul") == 1


def test_the_graph_counts_its_readers() -> None:
    mod = selected(FUNCTION.format("a + b"), checks=False)
    func = next(f for f in mod.funcs if f.name == "f")
    live = liveness.analyse(func)
    for block in func.walk():
        graph = dag.build(block, live.live_out[block.label])
        for node in graph.nodes:
            expected = sum(
                1
                for other in graph.nodes
                for operand in other.operands
                if operand == node.index
            )
            assert node.users == expected


def test_selection_keeps_ssa() -> None:
    for func in selected(FUNCTION.format("a + b * c + 8"), checks=True).funcs:
        ssa.verify(func)
