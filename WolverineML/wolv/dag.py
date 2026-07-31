"""The data-flow DAG of one basic block.

Instruction selection wants to see a block as expressions, not as a list: `a +
(i << 3)` is one ARM instruction and `a + b*c` is another, and neither is
visible while the operands are separate lines with names in between.  So each
block is read into a graph — a node per instruction, an edge per operand — and
the selector covers that graph with instructions.

It is a graph and not a tree because a value can be read twice.  That is what
`users` counts, and it is what decides whether a node may be folded into the
instruction that reads it or has to become an instruction of its own: a node
read twice would otherwise be computed twice.  A value that leaves the block
counts as read as well, and so does one a phi in a successor names.

Only pure nodes are ever folded, and only into a reader whose instruction
really absorbs them.  Both halves matter.  Folding moves a computation to where
it is read, which is fine for arithmetic and not fine for a load, because a
store in between would change what it reads; and folding a chain of nodes that
nothing absorbs would move a whole expression to its last line, leaving every
value it read alive until then.  So the selector plans first — it asks, of each
node with one reader, whether that reader has a tile that takes it — and
everything else is computed where it was written.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from wolv import ir


@dataclass(slots=True)
class Node:
    index: int
    instr: ir.Instr
    operands: list[int | None]  # a node in this block, or None for a value from outside
    users: int = 0
    reader: int | None = None  # the only node that reads it, when there is one
    escapes: bool = False  # read after the block ends, or by a phi in a successor

    @property
    def value(self) -> ir.Reg | None:
        return self.instr.defs()

    def alone(self) -> bool:
        """Read exactly once, inside the block, and computable where read."""
        return self.users == 1 and not self.escapes and isinstance(self.instr, ir.Bin)


@dataclass(slots=True)
class Dag:
    nodes: list[Node] = field(default_factory=list)
    by_value: dict[ir.Reg, int] = field(default_factory=dict)

    def of(self, index: int | None) -> Node | None:
        return None if index is None else self.nodes[index]

    def rematerialisable(self, index: int | None) -> Node | None:
        """A constant, which costs nothing to repeat and is often not an
        instruction at all once it has become an immediate operand."""
        node = self.of(index)
        if node is None or node.escapes or not isinstance(node.instr, ir.Const):
            return None
        return node

    def constant(self, index: int | None) -> int | None:
        """The value at `index`, if it is a constant — however many read it.

        Even one that has to exist in a register for somebody else can be an
        immediate here, so this asks less than `foldable` does.
        """
        node = self.of(index)
        match node:
            case Node(instr=ir.Const(_, value)):
                return value
            case _:
                return None


def build(block: ir.Block, live_out: set[ir.Reg]) -> Dag:
    """Read a block into a graph.  `live_out` includes what the phis will read."""
    dag = Dag()
    for i, instr in enumerate(block.instrs):
        operands: list[int | None] = [dag.by_value.get(r) for r in instr.uses()]
        node = Node(i, instr, operands)
        dag.nodes.append(node)
        defined = instr.defs()
        if defined is not None:
            dag.by_value[defined] = i
        for operand in operands:
            if operand is not None:
                read = dag.nodes[operand]
                read.users += 1
                read.reader = i if read.users == 1 else None
    for node in dag.nodes:
        value = node.value
        if value is not None and value in live_out:
            node.escapes = True
    return dag


def show(dag: Dag) -> str:
    lines: list[str] = []
    for node in dag.nodes:
        reads = ", ".join(
            "-" if o is None else str(o) for o in node.operands
        )
        marks = "".join(
            [
                "*" if node.escapes else "",
                "!" if node.instr.has_effect() else "",
            ]
        )
        lines.append(
            f"  {node.index:>3}{marks:<2} {node.instr.show(_plain):<38}"
            f" reads [{reads}]  users {node.users}"
        )
    return "\n".join(lines)


def _plain(r: ir.Reg) -> str:
    return f"%{r}"
