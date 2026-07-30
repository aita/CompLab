"""SSA construction, the textbook way.

Dominators by the iterative algorithm of Cooper, Harvey and Kennedy, dominance
frontiers from those, phis at the frontiers of every definition, and then one
walk of the dominator tree renaming as it goes.  This is minimal SSA and
nothing cleverer: a phi is placed wherever the frontier says, whether or not
the variable is live there, and the dead ones leave in `opt.dead_code`.

Only registers written more than once take part.  Everything lowering produced
once — a temporary — is already in SSA and is left with the name it has.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from wolv import ir


@dataclass(slots=True)
class Dominance:
    idom: dict[str, str]
    children: dict[str, list[str]]
    frontier: dict[str, set[str]]
    order: list[str]

    def dominates(self, a: str, b: str) -> bool:
        while True:
            if a == b:
                return True
            parent = self.idom[b]
            if parent == b:
                return False
            b = parent


def dominance(func: ir.Func) -> Dominance:
    order = ir.rpo(func)
    rank = {label: i for i, label in enumerate(order)}
    idom: dict[str, str] = {func.entry: func.entry}

    def intersect(a: str, b: str) -> str:
        while a != b:
            while rank[a] > rank[b]:
                a = idom[a]
            while rank[b] > rank[a]:
                b = idom[b]
        return a

    changed = True
    while changed:
        changed = False
        for label in order[1:]:
            preds = [p for p in func.blocks[label].preds if p in idom]
            if not preds:
                continue
            new = preds[0]
            for p in preds[1:]:
                new = intersect(p, new)
            if idom.get(label) != new:
                idom[label] = new
                changed = True

    children: dict[str, list[str]] = {label: [] for label in order}
    for label in order:
        parent = idom[label]
        if parent != label:
            children[parent].append(label)

    frontier: dict[str, set[str]] = {label: set() for label in order}
    for label in order:
        block = func.blocks[label]
        if len(block.preds) < 2:
            continue
        for pred in block.preds:
            runner = pred
            while runner != idom[label] and runner in idom:
                frontier[runner].add(label)
                runner = idom[runner]
    return Dominance(idom, children, frontier, order)


@dataclass(slots=True)
class _Defs:
    """Where each register is written, and how often.

    A register written twice in one block is as much a variable as one written
    in two blocks, so the count is what decides, and the blocks are what the
    frontier walk needs.
    """

    blocks: dict[ir.Reg, set[str]] = field(default_factory=dict)
    count: dict[ir.Reg, int] = field(default_factory=dict)

    def variables(self) -> set[ir.Reg]:
        return {r for r, n in self.count.items() if n > 1}


def _definitions(func: ir.Func) -> _Defs:
    defs = _Defs()
    for block in func.walk():
        for instr in block.instrs:
            r = ir.defs(instr)
            if r is not None:
                defs.blocks.setdefault(r, set()).add(block.label)
                defs.count[r] = defs.count.get(r, 0) + 1
    for r in func.params:
        defs.blocks.setdefault(r, set()).add(func.entry)
        defs.count[r] = defs.count.get(r, 0) + 1
    return defs


def place_phis(func: ir.Func, dom: Dominance, defs: _Defs) -> dict[str, list[ir.Reg]]:
    """Put a phi for `v` at every dominance frontier of a block defining `v`."""
    sites = defs.blocks
    variables = sorted(defs.variables())
    phi_vars: dict[str, list[ir.Reg]] = {label: [] for label in func.blocks}
    for v in variables:
        placed: set[str] = set()
        work = sorted(sites[v])
        while work:
            block = work.pop()
            for target in sorted(dom.frontier[block]):
                if target in placed:
                    continue
                placed.add(target)
                phi_vars[target].append(v)
                func.blocks[target].phis.append(
                    ir.Phi(v, {p: v for p in func.blocks[target].preds})
                )
                if target not in sites[v]:
                    work.append(target)
    return phi_vars


@dataclass(slots=True)
class _Renamer:
    func: ir.Func
    dom: Dominance
    phi_vars: dict[str, list[ir.Reg]]
    variables: set[ir.Reg]
    stacks: dict[ir.Reg, list[ir.Reg]] = field(default_factory=dict)
    undefined: dict[ir.Reg, ir.Reg] = field(default_factory=dict)

    def top(self, v: ir.Reg) -> ir.Reg:
        stack = self.stacks.get(v)
        if stack:
            return stack[-1]
        return self.undef(v)

    def undef(self, v: ir.Reg) -> ir.Reg:
        """A variable read on a path that never wrote it reads zero."""
        r = self.undefined.get(v)
        if r is None:
            r = self.func.new_reg()
            self.undefined[v] = r
        return r

    def plant_undefined(self) -> None:
        entry = self.func.blocks[self.func.entry]
        for r in self.undefined.values():
            entry.instrs.insert(0, ir.Const(r, 0))

    def rename(self, v: ir.Reg) -> ir.Reg:
        fresh = self.func.new_reg()
        self.stacks.setdefault(v, []).append(fresh)
        return fresh

    def run(self) -> None:
        work: list[tuple[str, bool]] = [(self.func.entry, False)]
        pushed: dict[str, list[ir.Reg]] = {}
        while work:
            label, done = work.pop()
            if done:
                for v in pushed[label]:
                    self.stacks[v].pop()
                continue
            pushed[label] = self.block(label)
            work.append((label, True))
            for child in reversed(self.dom.children[label]):
                work.append((child, False))

    def block(self, label: str) -> list[ir.Reg]:
        block = self.func.blocks[label]
        mine: list[ir.Reg] = []
        for phi, v in zip(block.phis, self.phi_vars[label], strict=True):
            phi.dst = self.rename(v)
            mine.append(v)
        for instr in block.instrs:
            ir.map_uses(instr, self.use)
            d = ir.defs(instr)
            if d is not None and d in self.variables:
                ir.set_def(instr, self.rename(d))
                mine.append(d)
        for succ in block.succs:
            for phi, v in zip(
                self.func.blocks[succ].phis, self.phi_vars[succ], strict=True
            ):
                phi.args[label] = self.top(v)
        return mine

    def use(self, r: ir.Reg) -> ir.Reg:
        return self.top(r) if r in self.variables else r


def construct(func: ir.Func) -> None:
    """Rewrite one function into SSA, in place."""
    ir.recompute_preds(func)
    dom = dominance(func)
    defs = _definitions(func)
    phi_vars = place_phis(func, dom, defs)
    renamer = _Renamer(func, dom, phi_vars, defs.variables())
    for i, p in enumerate(func.params):
        if p in renamer.variables:
            func.params[i] = renamer.rename(p)
    renamer.run()
    renamer.plant_undefined()


def construct_module(mod: ir.Module) -> None:
    for func in mod.funcs:
        construct(func)


def split_critical_edges(func: ir.Func) -> None:
    """Give every phi a place to put its copy in.

    An edge from a block with several successors into a block with several
    predecessors has nowhere to hold the copies a phi turns into, so it gets a
    block of its own.  The same goes for any edge into a block that still has
    a phi, so that the emitter only ever has to put copies before a `jmp`.
    """
    for label in list(func.order):
        block = func.blocks[label]
        if len(block.succs) < 2:
            continue
        for succ in list(block.succs):
            target = func.blocks[succ]
            if len(target.preds) < 2 and not target.phis:
                continue
            split = func.add_block(f"{label}.{succ}")
            split.instrs.append(ir.Jmp(succ))
            ir.rename_target(block.terminator, succ, split.label)
            for phi in target.phis:
                if label in phi.args:
                    phi.args[split.label] = phi.args.pop(label)
    ir.recompute_preds(func)


def verify(func: ir.Func) -> None:
    """Check what SSA promises: one definition per register, and it dominates."""
    dom = dominance(func)
    definition: dict[ir.Reg, str] = {}
    for block in func.walk():
        for phi in block.phis:
            assert phi.dst not in definition, f"{phi.dst} defined twice"
            definition[phi.dst] = block.label
        for instr in block.instrs:
            d = ir.defs(instr)
            if d is not None:
                assert d not in definition, f"%{d} defined twice"
                definition[d] = block.label
    for p in func.params:
        definition.setdefault(p, func.entry)
    for block in func.walk():
        for phi in block.phis:
            assert set(phi.args) == set(block.preds), (
                f"phi in {block.label} names {sorted(phi.args)}, "
                f"preds are {sorted(block.preds)}"
            )
            for pred, r in phi.args.items():
                where = definition.get(r)
                assert where is not None, f"%{r} is never defined"
                assert dom.dominates(where, pred), (
                    f"%{r} does not reach {block.label} through {pred}"
                )
        for instr in block.instrs:
            for r in ir.uses(instr):
                where = definition.get(r)
                assert where is not None, f"%{r} is never defined"
                assert dom.dominates(where, block.label), (
                    f"%{r} does not dominate its use in {block.label}"
                )
