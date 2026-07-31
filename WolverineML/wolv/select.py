"""Instruction selection: cover the DAG with ARM instructions.

Every node that has to become a register of its own is tiled, largest tile
first, pulling its foldable operands into the tile as it goes.  The tiles are
the things ARM can do in one instruction that the IR needs several nodes to
say:

    a + b * c            madd
    a - b * c            msub
    a + (b << k)         add with a shifted operand
    a + 4095             add with an immediate
    a * 8                lsl
    [a + (i << 3)]       a scaled indexed load
    a < b, then branch   cmp, and a branch on the flags

What comes out is still the same CFG, and still in SSA — a tile defines one
new register — so liveness, both allocators and the verifier carry on as
before.  What has gone is the guesswork the emitter used to do with its
peepholes: an instruction is now chosen where the whole expression is visible,
rather than by looking at the line before.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from wolv import dag, ir, liveness

# What `add`, `sub` and `cmp` take as an immediate operand.
IMMEDIATE = 4095

CONDITIONS: dict[str, str] = {
    "=": "eq",
    "<>": "ne",
    "<": "lt",
    "<=": "le",
    ">": "gt",
    ">=": "ge",
    "u<": "lo",
    "u>=": "hs",
}

INVERSE: dict[str, str] = {
    "eq": "ne",
    "ne": "eq",
    "lt": "ge",
    "ge": "lt",
    "gt": "le",
    "le": "gt",
    "lo": "hs",
    "hs": "lo",
}

LOGICAL: dict[str, str] = {"and": "and", "or": "orr", "xor": "eor"}
SHIFTS: dict[str, str] = {"shl": "lsl", "shr": "asr"}


def select_module(mod: ir.Module) -> None:
    for func in mod.funcs:
        select(func)


def select(func: ir.Func) -> None:
    live = liveness.analyse(func)
    for block in func.walk():
        graph = dag.build(block, live.live_out[block.label])
        block.instrs = _Selector(func, graph).run()


def graphs(func: ir.Func) -> dict[str, dag.Dag]:
    """The DAGs a selection would work on, for `wolv emit -s dag`."""
    live = liveness.analyse(func)
    return {
        block.label: dag.build(block, live.live_out[block.label])
        for block in func.walk()
    }


@dataclass(slots=True)
class _Selector:
    func: ir.Func
    graph: dag.Dag
    out: list[ir.Instr] = field(default_factory=list)
    done: set[int] = field(default_factory=set)
    absorbed: set[int] = field(default_factory=set)

    def run(self) -> list[ir.Instr]:
        self.plan()
        nodes = self.graph.nodes
        for i, node in enumerate(nodes):
            if i in self.absorbed:
                continue  # part of the tile that reads it
            if self.graph.rematerialisable(i) is not None:
                continue  # a constant, computed only where a register wants it
            if self.fuse_comparison(i):
                continue
            self.done.add(i)
            self.tile(node)
        return self.out

    def plan(self) -> None:
        """Decide which nodes a tile is going to swallow, before emitting any.

        Nothing may be deferred on the chance that its reader takes it.  A node
        left out of the order and then not absorbed would be computed at its
        reader instead, and a chain of those — `a + b + c + ...`, where every
        term has one reader — would move the whole sum to its last line and
        keep every term alive until then.
        """
        for node in self.graph.nodes:
            if not node.alone() or node.reader is None:
                continue
            if self.swallows(self.graph.nodes[node.reader], node):
                self.absorbed.add(node.index)

    def swallows(self, reader: dag.Node, node: dag.Node) -> bool:
        """Whether the instruction chosen for `reader` has room for `node`."""
        match reader.instr:
            case ir.Bin(_, op, _, _) if op in ("+", "-"):
                if reader.operands[1] != node.index:
                    return False
                return self.as_shift(node.index) is not None or self.is_bin(node, "*")
            case ir.Load(_, _, offset) | ir.Store(_, offset, _):
                return reader.operands[0] == node.index and (
                    self.indexable(node, offset)
                    or self.displaces(node, offset) is not None
                )
            case _:
                return False

    def indexable(self, node: dag.Node, offset: int) -> bool:
        """`[pointer + (index << k)]`, which needs nothing added to it."""
        if offset != 0 or not self.is_bin(node, "+"):
            return False
        shift = self.as_shift(node.operands[1])
        return shift is not None and shift[1] <= 4

    def displaces(self, node: dag.Node, offset: int) -> int | None:
        """`[pointer + 24]`, when what is added to the pointer is a constant."""
        if not self.is_bin(node, "+"):
            return None
        value = self.constant(node.operands[1])
        if value is None:
            return None
        total = offset + value
        if 0 <= total <= 32760 and total % ir.WORD == 0:
            return total
        if -256 <= total <= 255:
            return total
        return None

    # -- emitting ---------------------------------------------------------

    def emit(self, instr: ir.Instr) -> None:
        self.out.append(instr)

    def mach(
        self,
        form: str,
        dst: ir.Reg | None,
        srcs: list[ir.Reg],
        imm: int = 0,
        symbol: str = "",
        effect: bool = False,
    ) -> None:
        self.emit(ir.Mach(form, dst, srcs, imm, symbol, effect))

    def reg(self) -> ir.Reg:
        return self.func.new_reg()

    def operand(self, index: int | None, reg: ir.Reg) -> ir.Reg:
        """The register holding an operand, computing it here if it was deferred.

        Only two kinds of node were left out of the order: a constant, which is
        tiled the first time somebody needs it in a register and read from
        there afterwards, and a node the plan said would be absorbed, which
        ends up here only if the tile that was to absorb it changed its mind.
        """
        node = self.graph.of(index)
        if node is None or node.index in self.done:
            return reg
        deferred = (
            node.index in self.absorbed
            or self.graph.rematerialisable(node.index) is not None
        )
        if not deferred:
            return reg
        self.done.add(node.index)
        return self.tile(node)

    # -- one node ---------------------------------------------------------

    def tile(self, node: dag.Node) -> ir.Reg:
        instr = node.instr
        match instr:
            case ir.Const(dst, value):
                self.mach("const", dst, [], imm=value)
                return dst
            case ir.StrConst(dst, symbol):
                self.mach("adr", dst, [], symbol=symbol)
                return dst
            case ir.Bin(dst, op, lhs, rhs):
                self.arithmetic(node, dst, op, lhs, rhs)
                return dst
            case ir.Cmp(dst, op, lhs, rhs):
                self.compare(node, op, lhs, rhs)
                self.mach("cset", dst, [], symbol=CONDITIONS[op])
                return dst
            case ir.Load(dst, base, offset):
                self.load(node, dst, base, offset)
                return dst
            case ir.Store(base, offset, src):
                self.store(node, base, offset, src)
                return src
            case _:
                # Moves, calls, slot accesses and the terminator are machine
                # instructions already, and a phi is not in this list at all.
                # None of them folds anything, so every operand that was left
                # to be folded has to be computed here instead.
                for index in node.operands:
                    self.force(index)
                self.emit(instr)
                defined = ir.defs(instr)
                return defined if defined is not None else 0

    # -- the tiles --------------------------------------------------------

    def arithmetic(
        self, node: dag.Node, dst: ir.Reg, op: str, lhs: ir.Reg, rhs: ir.Reg
    ) -> None:
        left, right = node.operands[0], node.operands[1]
        # A shifted operand comes first: `a + b * 8` is one instruction that
        # way and two as a multiply-add, because the 8 would need a register.
        if op in ("+", "-") and self.shift_into(node, dst, op, lhs, rhs):
            return
        if op in ("+", "-") and self.multiply_into(node, dst, op, lhs, rhs):
            return
        if op in ("+", "-"):
            value = self.constant(right)
            if value is not None and 0 <= value <= IMMEDIATE:
                self.mach("addi" if op == "+" else "subi", dst, [self.at(left, lhs)],
                          imm=value)
                return
            if op == "+":
                value = self.constant(left)
                if value is not None and 0 <= value <= IMMEDIATE:
                    self.mach("addi", dst, [self.at(right, rhs)], imm=value)
                    return
            self.mach("add" if op == "+" else "sub", dst,
                      [self.at(left, lhs), self.at(right, rhs)])
            return
        if op == "*":
            value = self.constant(right)
            if value is not None and value > 0 and value & (value - 1) == 0:
                self.mach("lsli", dst, [self.at(left, lhs)], imm=value.bit_length() - 1)
                return
            self.mach("mul", dst, [self.at(left, lhs), self.at(right, rhs)])
            return
        if op == "/":
            self.mach("sdiv", dst, [self.at(left, lhs), self.at(right, rhs)])
            return
        if op in SHIFTS:
            value = self.constant(right)
            if value is not None and 0 <= value < 64:
                self.mach(SHIFTS[op] + "i", dst, [self.at(left, lhs)], imm=value)
                return
            self.mach(SHIFTS[op], dst, [self.at(left, lhs), self.at(right, rhs)])
            return
        if op in LOGICAL:
            value = self.constant(right)
            if op == "xor" and value == 1:
                self.mach("eori", dst, [self.at(left, lhs)], imm=1)
                return
            self.mach(LOGICAL[op], dst, [self.at(left, lhs), self.at(right, rhs)])
            return
        raise AssertionError(f"no instruction for `{op}`")

    def multiply_into(
        self, node: dag.Node, dst: ir.Reg, op: str, lhs: ir.Reg, rhs: ir.Reg
    ) -> bool:
        """`a + b * c` and `a - b * c` are one instruction each."""
        product = self.graph.of(node.operands[1])
        if product is None or not product.alone() or not self.is_bin(product, "*"):
            return False
        assert isinstance(product.instr, ir.Bin)
        factors = [
            self.at(product.operands[0], product.instr.lhs),
            self.at(product.operands[1], product.instr.rhs),
        ]
        self.mach(
            "madd" if op == "+" else "msub",
            dst,
            [*factors, self.at(node.operands[0], lhs)],
        )
        return True

    def shift_into(
        self, node: dag.Node, dst: ir.Reg, op: str, lhs: ir.Reg, rhs: ir.Reg
    ) -> bool:
        """The second operand of an `add` may be shifted on the way in."""
        shift = self.as_shift(node.operands[1])
        if shift is None:
            return False
        shifted, amount = shift
        assert isinstance(shifted.instr, ir.Bin)
        self.mach(
            "adds" if op == "+" else "subs",
            dst,
            [
                self.at(node.operands[0], lhs),
                self.at(shifted.operands[0], shifted.instr.lhs),
            ],
            imm=amount,
        )
        return True

    def as_shift(self, index: int | None) -> tuple[dag.Node, int] | None:
        """A `x << k` that can be folded, however it was written: `* 8` says it too.

        This decides nothing and emits nothing, so the plan and the tiles can
        both ask it and get the same answer.
        """
        node = self.graph.of(index)
        if node is None or not node.alone() or not isinstance(node.instr, ir.Bin):
            return None
        amount = self.constant(node.operands[1])
        if amount is None:
            return None
        if node.instr.op == "*":
            if amount <= 0 or amount & (amount - 1):
                return None
            amount = amount.bit_length() - 1
        elif node.instr.op != "shl":
            return None
        if not 0 <= amount < 64:
            return None
        return node, amount

    def load(self, node: dag.Node, dst: ir.Reg, base: ir.Reg, offset: int) -> None:
        indexed = self.indexed(node.operands[0], offset)
        if indexed is not None:
            pointer, index, scale = indexed
            self.mach("ldrx", dst, [pointer, index], imm=scale)
            return
        pointer, offset = self.address(node.operands[0], base, offset)
        self.mach("ldr", dst, [pointer], imm=offset)

    def store(
        self, node: dag.Node, base: ir.Reg, offset: int, src: ir.Reg
    ) -> None:
        value = self.at(node.operands[1], src)
        indexed = self.indexed(node.operands[0], offset)
        if indexed is not None:
            pointer, index, scale = indexed
            self.mach("strx", None, [pointer, index, value], imm=scale, effect=True)
            return
        pointer, offset = self.address(node.operands[0], base, offset)
        self.mach("str", None, [pointer, value], imm=offset, effect=True)

    def address(
        self, index: int | None, base: ir.Reg, offset: int
    ) -> tuple[ir.Reg, int]:
        """A pointer and a displacement, taking in an addition if there is one."""
        node = self.graph.of(index)
        if node is not None and node.alone():
            displaced = self.displaces(node, offset)
            if displaced is not None:
                assert isinstance(node.instr, ir.Bin)
                return self.at(node.operands[0], node.instr.lhs), displaced
        return self.at(index, base), offset

    def indexed(
        self, address: int | None, offset: int
    ) -> tuple[ir.Reg, ir.Reg, int] | None:
        """`[pointer + (index << k)]` is one addressing mode, if nothing is added."""
        total = self.graph.of(address)
        if total is None or not total.alone() or not self.indexable(total, offset):
            return None
        assert isinstance(total.instr, ir.Bin)
        shift = self.as_shift(total.operands[1])
        assert shift is not None
        shifted, amount = shift
        assert isinstance(shifted.instr, ir.Bin)
        return (
            self.at(total.operands[0], total.instr.lhs),
            self.at(shifted.operands[0], shifted.instr.lhs),
            amount,
        )

    # -- comparisons and the branch that reads them ------------------------

    def compare(self, node: dag.Node, op: str, lhs: ir.Reg, rhs: ir.Reg) -> None:
        left, right = node.operands[0], node.operands[1]
        value = self.constant(right)
        if value is not None and 0 <= value <= IMMEDIATE:
            self.mach("cmpi", None, [self.at(left, lhs)], imm=value)
            return
        self.mach("cmp", None, [self.at(left, lhs), self.at(right, rhs)])

    def fuse_comparison(self, index: int) -> bool:
        """A comparison the branch below it is the only reader of sets the flags."""
        nodes = self.graph.nodes
        node = nodes[index]
        if not isinstance(node.instr, ir.Cmp) or index + 1 != len(nodes) - 1:
            return False
        terminator = nodes[-1].instr
        if not isinstance(terminator, ir.CBr) or terminator.cond != node.instr.dst:
            return False
        if node.users != 1 or node.escapes:
            return False
        self.compare(node, node.instr.op, node.instr.lhs, node.instr.rhs)
        terminator.code = CONDITIONS[node.instr.op]
        return True

    # -- reading operands -------------------------------------------------

    def at(self, index: int | None, reg: ir.Reg) -> ir.Reg:
        return self.operand(index, reg)

    def force(self, index: int | None) -> None:
        """Compute a deferred operand for a reader that has no tile to take it."""
        node = self.graph.of(index)
        if node is not None:
            self.operand(index, node.value if node.value is not None else 0)

    def constant(self, index: int | None) -> int | None:
        return self.graph.constant(index)

    def is_bin(self, node: dag.Node, op: str) -> bool:
        return isinstance(node.instr, ir.Bin) and node.instr.op == op
