package wolv;

import haxe.Int64;
import wolv.Ir;

/* The data-flow DAG of one basic block.
 *
 * Instruction selection wants to see a block as expressions, not as a list:
 * `a + (i lsl 3)` is one ARM instruction and `a + b*c` is another, and neither is
 * visible while the operands are separate lines with names in between.  So each
 * block is read into a graph — a node per instruction, an edge per operand — and
 * the selector covers that graph with instructions.
 *
 * It is a graph and not a tree because a value can be read twice.  That is what
 * `users` counts, and it is what decides whether a node may be folded into the
 * instruction that reads it or has to become an instruction of its own: a node
 * read twice would otherwise be computed twice.  A value that leaves the block
 * counts as read as well, and so does one a phi in a successor names.
 *
 * Only pure nodes are ever folded, and only into a reader whose instruction
 * really absorbs them.  Both halves matter.  Folding moves a computation to where
 * it is read, which is fine for arithmetic and not fine for a load, because a
 * store in between would change what it reads; and folding a chain of nodes that
 * nothing absorbs would move a whole expression to its last line, leaving every
 * value it read alive until then.  So the selector plans first — it asks, of each
 * node with one reader, whether that reader has a tile that takes it — and
 * everything else is computed where it was written. */

/** What an operand holds when the value came from outside the block. */
final NO_NODE = -1;

class Node {
  public final index:Int;
  public final instr:Instr;
  public final operands:Array<Int>;
  public var users = 0;

  /** The only node that reads it, when there is one; else `NO_NODE`. */
  public var reader = NO_NODE;

  /** Read after the block ends, or by a phi in a successor. */
  public var escapes = false;

  public function new(index:Int, instr:Instr, operands:Array<Int>) {
    this.index = index;
    this.instr = instr;
    this.operands = operands;
  }

  public function operand(at:Int):Int {
    return at < operands.length ? operands[at] : NO_NODE;
  }

  /** Read exactly once, inside the block, and computable where read. */
  public function alone():Bool {
    return users == 1 && !escapes && instr.match(Bin(_, _, _, _));
  }
}

class Graph {
  public final nodes:Array<Node>;

  public function new(nodes:Array<Node>) {
    this.nodes = nodes;
  }

  public function at(index:Int):Null<Node> {
    return index == NO_NODE ? null : nodes[index];
  }

  /**
   * A constant, which costs nothing to repeat and is often not an instruction at
   * all once it has become an immediate operand.
   */
  public function rematerialisable(index:Int):Null<Node> {
    final n = at(index);
    return n != null && !n.escapes && n.instr.match(Const(_, _)) ? n : null;
  }

  /**
   * The value at `index`, if it is a constant — however many read it.  Even one
   * that has to exist in a register for somebody else can be an immediate here,
   * so this asks less than folding does.
   */
  public function constant(index:Int):Null<Int64> {
    final n = at(index);
    if (n == null) return null;
    return switch n.instr {
      case Const(_, value): value;
      case _: null;
    }
  }
}

/** Read a block into a graph.  `liveOut` includes what the phis will read. */
function build(b:Block, liveOut:Map<Reg, Bool>):Graph {
  final byValue = new Map<Reg, Int>();
  final nodes = [];
  for (at in 0...b.instrs.length) {
    final instr = b.instrs[at];
    final operands = Ir.uses(instr).map(r -> byValue.exists(r) ? byValue.get(r) : NO_NODE);
    final d = Ir.defs(instr);
    if (d != null) byValue.set(d, at);
    nodes.push(new Node(at, instr, operands));
  }
  for (n in nodes) {
    for (operand in n.operands) {
      if (operand == NO_NODE) continue;
      final read = nodes[operand];
      read.users += 1;
      read.reader = read.users == 1 ? n.index : NO_NODE;
    }
  }
  for (n in nodes) {
    final v = Ir.defs(n.instr);
    if (v != null && liveOut.exists(v)) n.escapes = true;
  }
  return new Graph(nodes);
}

private function padRight(width:Int, text:String):String {
  return StringTools.rpad(text, " ", width);
}

private function padLeft(width:Int, text:String):String {
  return StringTools.lpad(text, " ", width);
}

function show(d:Graph):String {
  final plain:Name = r -> "%" + r;
  return d.nodes.map(n -> {
    final reads = n.operands.map(o -> o == NO_NODE ? "-" : Std.string(o)).join(", ");
    final marks = (n.escapes ? "*" : "") + (Ir.hasEffect(n.instr) ? "!" : "");
    '  ${padLeft(3, Std.string(n.index))}${padRight(2, marks)} '
      + '${padRight(38, Ir.showInstr(plain, n.instr))} reads [$reads]  users ${n.users}';
  }).join("\n");
}
