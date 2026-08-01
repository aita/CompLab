"""Optimisation on SSA.

Five small passes run to a fixed point.  Each is cheap because SSA makes it
cheap: a register has one definition, so constant folding and copy propagation
are a lookup rather than a dataflow problem, and a phi whose arguments all
agree is a copy that was never needed.

    fold constants   ->  arithmetic on known values
    propagate copies ->  `Move`, and phis that turned into one
    simplify phis    ->  a phi with one distinct argument is that argument
    fold branches    ->  a branch on a known value, and the blocks it strands
    dead code        ->  anything computed and not used
"""

from __future__ import annotations

from collections.abc import Callable

from wolv import ir


def optimise(mod: ir.Module) -> None:
    for func in mod.funcs:
        optimise_func(func)


def optimise_func(func: ir.Func) -> None:
    passes: list[Callable[[ir.Func], bool]] = [
        fold_constants,
        propagate_copies,
        simplify_phis,
        fold_branches,
        dead_code,
    ]
    while True:
        # Every pass runs every round: they are cheap, and one enables another.
        changes = [run(func) for run in passes]
        if not any(changes):
            return


# -- rewriting ----------------------------------------------------------------


def rewrite(func: ir.Func, mapping: dict[ir.Reg, ir.Reg]) -> None:
    """Replace registers everywhere they are read, phi arguments included."""
    if not mapping:
        return

    def resolve(r: ir.Reg) -> ir.Reg:
        seen: set[ir.Reg] = set()
        while r in mapping and r not in seen:
            seen.add(r)
            r = mapping[r]
        return r

    for block in func.walk():
        for phi in block.phis:
            phi.args = {p: resolve(r) for p, r in phi.args.items()}
        for instr in block.instrs:
            instr.map_uses(resolve)


def constants(func: ir.Func) -> dict[ir.Reg, int]:
    known: dict[ir.Reg, int] = {}
    for block in func.walk():
        for instr in block.instrs:
            match instr:
                case ir.Const(dst, value):
                    known[dst] = value
    return known


# -- the passes ---------------------------------------------------------------


def fold_constants(func: ir.Func) -> bool:
    known = constants(func)
    changed = False
    for block in func.walk():
        for i, instr in enumerate(block.instrs):
            folded = _fold(instr, known)
            if folded is not None:
                block.instrs[i] = folded
                match folded:
                    case ir.Const(dst, value):
                        known[dst] = value
                changed = True
    return changed


def _fold(instr: ir.Instr, known: dict[ir.Reg, int]) -> ir.Instr | None:
    match instr:
        case ir.Bin(dst, op, lhs, rhs):
            a, b = known.get(lhs), known.get(rhs)
            if a is not None and b is not None:
                value = _arith(op, a, b)
                return None if value is None else ir.Const(dst, value)
            if b == 0 and op in ("+", "-", "or", "xor", "shl", "shr"):
                return ir.Move(dst, lhs)
            if b == 1 and op in ("*", "/"):
                return ir.Move(dst, lhs)
            if a == 0 and op == "+":
                return ir.Move(dst, rhs)
            return None
        case ir.Cmp(dst, op, lhs, rhs):
            a, b = known.get(lhs), known.get(rhs)
            if a is None or b is None:
                return None
            return ir.Const(dst, 1 if _order(op, a, b) else 0)
        case _:
            return None


def _arith(op: str, a: int, b: int) -> int | None:
    mask = (1 << 64) - 1
    match op:
        case "+":
            value = a + b
        case "-":
            value = a - b
        case "*":
            value = a * b
        case "/":
            if b == 0:
                return None
            value = abs(a) // abs(b) * (1 if (a < 0) == (b < 0) else -1)
        case "mod":
            if b == 0:
                return None
            value = a - (abs(a) // abs(b) * (1 if (a < 0) == (b < 0) else -1)) * b
        case "and":
            value = a & b
        case "or":
            value = a | b
        case "xor":
            value = a ^ b
        case "shl":
            value = a << b
        case "shr":
            value = a >> b
        case _:
            return None
    value &= mask
    return value - (1 << 64) if value >= (1 << 63) else value


def _order(op: str, a: int, b: int) -> bool:
    mask = (1 << 64) - 1
    match op:
        case "=":
            return a == b
        case "<>":
            return a != b
        case "<":
            return a < b
        case "<=":
            return a <= b
        case ">":
            return a > b
        case ">=":
            return a >= b
        case "u<":
            return (a & mask) < (b & mask)
        case "u>=":
            return (a & mask) >= (b & mask)
        case _:
            raise AssertionError(f"unknown comparison {op}")


def propagate_copies(func: ir.Func) -> bool:
    mapping: dict[ir.Reg, ir.Reg] = {}
    for block in func.walk():
        for instr in block.instrs:
            match instr:
                case ir.Move(dst, src):
                    mapping[dst] = src
    if not mapping:
        return False
    rewrite(func, mapping)
    for block in func.walk():
        block.instrs = [i for i in block.instrs if not isinstance(i, ir.Move)]
    return True


def simplify_phis(func: ir.Func) -> bool:
    mapping: dict[ir.Reg, ir.Reg] = {}
    changed = False
    for block in func.walk():
        keep: list[ir.Phi] = []
        for phi in block.phis:
            others = {r for r in phi.args.values() if r != phi.dst}
            if len(others) == 1:
                mapping[phi.dst] = others.pop()
                changed = True
            else:
                keep.append(phi)
        block.phis = keep
    if changed:
        rewrite(func, mapping)
    return changed


def fold_branches(func: ir.Func) -> bool:
    known = constants(func)
    changed = False
    for block in func.walk():
        match block.terminator:
            case ir.CBr(cond, then, els):
                value = known.get(cond)
                if value is None and then != els:
                    continue
                taken = then if value is None or value != 0 else els
                block.instrs[-1] = ir.Jmp(taken)
                changed = True
    if changed:
        ir.drop_unreachable(func)
    return changed


def dead_code(func: ir.Func) -> bool:
    changed = False
    while True:
        used: set[ir.Reg] = set()
        for block in func.walk():
            for phi in block.phis:
                used.update(phi.args.values())
            for instr in block.instrs:
                used.update(instr.uses())
        round_changed = False
        for block in func.walk():
            phis = [p for p in block.phis if p.dst in used]
            if len(phis) != len(block.phis):
                block.phis = phis
                round_changed = True
            kept: list[ir.Instr] = []
            for instr in block.instrs:
                d = instr.defs()
                if d is not None and d not in used and not instr.has_effect():
                    round_changed = True
                    continue
                kept.append(instr)
            block.instrs = kept
        if not round_changed:
            return changed
        changed = True
