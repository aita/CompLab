from __future__ import annotations

from pathlib import Path

from wolv import ir, lower, opt, ssa
from wolv.parser import parse
from wolv.typecheck import check


def build(source: str, *, checks: bool = False) -> ir.Module:
    prog = parse(source)
    check(prog)
    return lower.lower(prog, lower.Options(checks=checks))


def in_ssa(source: str, *, checks: bool = False) -> ir.Module:
    mod = build(source, checks=checks)
    ssa.construct_module(mod)
    return mod


def main_of(mod: ir.Module) -> ir.Func:
    return mod.funcs[0]


LOOP = """
fun count (n : int) : int =
  let var i = 0
      var total = 0
  in
    while i < n do (total := total + i; i := i + 1);
    total
  end
val () = printInt (count (10))
"""


def test_lowering_writes_a_variable_more_than_once() -> None:
    func = build(LOOP).funcs[1]
    written: dict[int, int] = {}
    for block in func.walk():
        for instr in block.instrs:
            d = ir.defs(instr)
            if d is not None:
                written[d] = written.get(d, 0) + 1
    assert any(n > 1 for n in written.values())
    assert not any(block.phis for block in func.walk())


def test_construction_gives_one_definition_and_phis() -> None:
    func = in_ssa(LOOP).funcs[1]
    ssa.verify(func)
    assert any(block.phis for block in func.walk()), "a loop needs phis"


def test_every_function_verifies() -> None:
    source = (Path(__file__).parent.parent / "examples" / "tour.wol").read_text()
    for func in in_ssa(source, checks=True).funcs:
        ssa.verify(func)


def test_dominance_of_a_diamond() -> None:
    func = in_ssa(
        "fun f (c : bool) : int = if c then 1 else 2\nval () = printInt (f (true))"
    ).funcs[1]
    dom = ssa.dominance(func)
    entry = func.entry
    for label in func.blocks:
        assert dom.dominates(entry, label)
    joins = [b for b in func.walk() if len(b.preds) > 1]
    assert joins, "a diamond has a join"
    for join in joins:
        assert dom.idom[join.label] == entry


def test_a_phi_names_exactly_its_predecessors() -> None:
    for func in in_ssa(LOOP).funcs:
        for block in func.walk():
            for phi in block.phis:
                assert set(phi.args) == set(block.preds)


def test_optimisation_keeps_it_in_ssa() -> None:
    mod = in_ssa(LOOP)
    opt.optimise(mod)
    for func in mod.funcs:
        ssa.verify(func)


def test_constants_fold() -> None:
    mod = in_ssa("val () = printInt (2 * 3 + 4)")
    opt.optimise(mod)
    values = [
        i.value
        for block in main_of(mod).walk()
        for i in block.instrs
        if isinstance(i, ir.Const)
    ]
    assert values == [10]


def test_dead_code_goes() -> None:
    mod = in_ssa("fun f (n : int) : int = let val unused = n * n in n + 1 end\n"
                 "val () = printInt (f (2))")
    opt.optimise(mod)
    func = mod.funcs[1]
    assert not any(
        isinstance(i, ir.Bin) and i.op == "*" for b in func.walk() for i in b.instrs
    )


def test_unreachable_blocks_go() -> None:
    mod = in_ssa("val () = if true then print (\"a\") else print (\"b\")")
    opt.optimise(mod)
    calls = [
        i.callee
        for b in main_of(mod).walk()
        for i in b.instrs
        if isinstance(i, ir.Call)
    ]
    assert calls == ["wol_print"]


def test_splitting_leaves_phis_only_after_a_jump() -> None:
    mod = in_ssa(LOOP, checks=True)
    opt.optimise(mod)
    for func in mod.funcs:
        ssa.split_critical_edges(func)
        ssa.verify(func)
        for block in func.walk():
            if len(block.succs) > 1:
                for succ in block.succs:
                    assert not func.blocks[succ].phis
