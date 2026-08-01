// The data-flow DAG of one basic block.
//
// Instruction selection wants to see a block as expressions, not as a list: `a +
// (i << 3)` is one ARM instruction and `a + b*c` is another, and neither is
// visible while the operands are separate lines with names in between.  So each
// block is read into a graph — a node per instruction, an edge per operand — and
// the selector covers that graph with instructions.
//
// It is a graph and not a tree because a value can be read twice.  That is what
// `users` counts, and it is what decides whether a node may be folded into the
// instruction that reads it or has to become an instruction of its own: a node
// read twice would otherwise be computed twice.  A value that leaves the block
// counts as read as well, and so does one a phi in a successor names.
//
// Only pure nodes are ever folded, and only into a reader whose instruction really
// absorbs them.  Both halves matter.  Folding moves a computation to where it is
// read, which is fine for arithmetic and not fine for a load, because a store in
// between would change what it reads; and folding a chain of nodes that nothing
// absorbs would move a whole expression to its last line, leaving every value it
// read alive until then.  So the selector plans first — it asks, of each node with
// one reader, whether that reader has a tile that takes it — and everything else
// is computed where it was written.

import * as ir from "./ir.ts";

export class Node {
  readonly index: number;
  readonly instr: ir.Instr;
  /** A node in this block, or null for a value from outside. */
  readonly operands: (number | null)[];
  users = 0;
  /** The only node that reads it, when there is one. */
  reader: number | null = null;
  /** Read after the block ends, or by a phi in a successor. */
  escapes = false;

  constructor(index: number, instr: ir.Instr, operands: (number | null)[]) {
    this.index = index; this.instr = instr; this.operands = operands;
  }

  get value(): ir.Reg | null { return this.instr.defs(); }

  /** Read exactly once, inside the block, and computable where read. */
  alone(): boolean {
    return this.users === 1 && !this.escapes && this.instr instanceof ir.Bin;
  }
}

export class Dag {
  readonly nodes: Node[] = [];
  readonly byValue = new Map<ir.Reg, number>();

  of(index: number | null): Node | null {
    return index === null ? null : this.nodes[index]!;
  }

  /**
   * A constant, which costs nothing to repeat and is often not an instruction at
   * all once it has become an immediate operand.
   */
  rematerialisable(index: number | null): Node | null {
    const node = this.of(index);
    if (node === null || node.escapes || !(node.instr instanceof ir.Const)) return null;
    return node;
  }

  /**
   * The value at `index`, if it is a constant — however many read it.  Even one
   * that has to exist in a register for somebody else can be an immediate here,
   * so this asks less than folding does.
   */
  constant(index: number | null): bigint | null {
    const node = this.of(index);
    return node !== null && node.instr instanceof ir.Const ? node.instr.value : null;
  }
}

/** Read a block into a graph.  `liveOut` includes what the phis will read. */
export function build(b: ir.Block, liveOut: Set<ir.Reg>): Dag {
  const dag = new Dag();
  b.instrs.forEach((instr, at) => {
    const operands = instr.uses().map((r) => dag.byValue.get(r) ?? null);
    const node = new Node(at, instr, operands);
    dag.nodes.push(node);
    const defined = instr.defs();
    if (defined !== null) dag.byValue.set(defined, at);
    for (const operand of operands) {
      if (operand === null) continue;
      const read = dag.nodes[operand]!;
      read.users += 1;
      read.reader = read.users === 1 ? at : null;
    }
  });
  for (const node of dag.nodes) {
    const value = node.value;
    if (value !== null && liveOut.has(value)) node.escapes = true;
  }
  return dag;
}

const plain = (r: ir.Reg): string => `%${r}`;

export function show(dag: Dag): string {
  return dag.nodes.map((node) => {
    const reads = node.operands.map((o) => (o === null ? "-" : String(o))).join(", ");
    const marks = (node.escapes ? "*" : "") + (node.instr.hasEffect() ? "!" : "");
    return `  ${String(node.index).padStart(3)}${marks.padEnd(2)} `
      + `${node.instr.show(plain).padEnd(38)} reads [${reads}]  users ${node.users}`;
  }).join("\n");
}
