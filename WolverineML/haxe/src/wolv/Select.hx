package wolv;

import haxe.Int64;
import wolv.Dag;
import wolv.Ir;

/* Instruction selection: cover the DAG with ARM instructions.
 *
 * Every node that has to become a register of its own is tiled, largest tile
 * first, pulling its foldable operands into the tile as it goes.  The tiles are
 * the things ARM can do in one instruction that the IR needs several nodes to
 * say:
 *
 *     a + b * c            madd
 *     a - b * c            msub
 *     a + (b lsl k)        add with a shifted operand
 *     a + 4095             add with an immediate
 *     a * 8                lsl
 *     [a + 24]             a load with the addition as its displacement
 *     a < b, then branch   cmp, and a branch on the flags
 *
 * What comes out is still the same CFG, and still in SSA — a tile defines one new
 * register — so liveness, the allocator and the verifier carry on as before.
 * What has gone is the guesswork the emitter used to do with its peepholes: an
 * instruction is now chosen where the whole expression is visible, rather than by
 * looking at the line before. */

/** What `add`, `sub` and `cmp` take as an immediate operand. */
private final IMMEDIATE_MAX = Int64.ofInt(4095);

private final LOGICAL_FORM = ["and" => "and", "or" => "orr", "xor" => "eor"];
private final SHIFT_FORM = ["shl" => "lsl", "shr" => "asr"];

function select(f:Func):Void {
  final live = Liveness.analyse(f);
  for (b in f.walk()) {
    b.instrs = new Selector(Dag.build(b, live.outOf(b.label))).run();
  }
}

function selectModule(m:Module):Void {
  for (f in m.funcs) select(f);
}

/** The DAGs a selection would work on, for `wolv emit -s dag`. */
function graphs(f:Func):Array<{label:String, graph:Graph}> {
  final live = Liveness.analyse(f);
  return f.walk().map(b -> {label: b.label, graph: Dag.build(b, live.outOf(b.label))});
}

/** Where the one set bit of a power of two is. */
private function log2(value:Int64):Int64 {
  var amount = Int64.ofInt(0);
  var left = value;
  while (!Int64.eq(Int64.ushr(left, 1), Int64.ofInt(0))) {
    left = Int64.ushr(left, 1);
    amount = Int64.add(amount, Int64.ofInt(1));
  }
  return amount;
}

private function isBin(n:Node, op:String):Bool {
  return switch n.instr {
    case Bin(_, o, _, _): o == op;
    case _: false;
  }
}

private function isPowerOfTwo(v:Int64):Bool {
  return Int64.compare(v, Int64.ofInt(0)) > 0
    && Int64.eq(Int64.and(v, Int64.sub(v, Int64.ofInt(1))), Int64.ofInt(0));
}

private class Selector {
  final graph:Graph;
  final out:Array<Instr> = [];
  final done = new Map<Int, Bool>();
  final absorbed = new Map<Int, Bool>();

  /** Set when a comparison was fused into the branch below it. */
  var fused = "";

  public function new(graph:Graph) {
    this.graph = graph;
  }

  function put(form:String, ?dst:Null<Reg>, ?srcs:Array<Reg>, ?imm:Int64, symbol = "",
      effectful = false):Void {
    out.push(Machine(new Ir.Mach(form, dst, srcs == null ? [] : srcs, imm, symbol, effectful)));
  }

  /* -- what can be folded, asked without deciding anything ------------------ */

  /**
   * A `x lsl k` that can be folded, however it was written: `* 8` says it too.
   * This decides nothing and emits nothing, so the plan and the tiles can both
   * ask it and get the same answer.
   */
  function asShift(index:Int):Null<{node:Node, amount:Int64}> {
    final n = graph.at(index);
    if (n == null || !n.alone()) return null;
    final op = switch n.instr {
      case Bin(_, o, _, _): o;
      case _: return null;
    };
    final constant = graph.constant(n.operand(1));
    if (constant == null) return null;
    var amount;
    if (op == "*") {
      if (!isPowerOfTwo(constant)) return null;
      amount = log2(constant);
    } else if (op == "shl") {
      amount = constant;
    } else {
      return null;
    }
    if (Int64.compare(amount, Int64.ofInt(0)) < 0
      || Int64.compare(amount, Int64.ofInt(64)) >= 0) return null;
    return {node: n, amount: amount};
  }

  /** `[pointer + 24]`, when what is added to the pointer is a constant. */
  function displaces(n:Node, offset:Int):Null<Int64> {
    if (!isBin(n, "+")) return null;
    final value = graph.constant(n.operand(1));
    if (value == null) return null;
    final total = Int64.add(Int64.ofInt(offset), value);
    if (Int64.compare(total, Int64.ofInt(0)) >= 0
      && Int64.compare(total, Int64.ofInt(32760)) <= 0
      && Int64.eq(Int64.mod(total, Int64.ofInt(Ir.WORD)), Int64.ofInt(0))) return total;
    if (Int64.compare(total, Int64.ofInt(-256)) >= 0
      && Int64.compare(total, Int64.ofInt(255)) <= 0) return total;
    return null;
  }

  /** Whether the instruction chosen for `reader` has room for `node`. */
  function swallows(reader:Node, node:Node):Bool {
    return switch reader.instr {
      case Bin(_, op, _, _):
        if (op != "+" && op != "-") false;
        else if (reader.operand(1) != node.index) false;
        else asShift(node.index) != null || isBin(node, "*");
      case Load(_, _, offset):
        reader.operand(0) == node.index && displaces(node, offset) != null;
      case Store(_, offset, _):
        reader.operand(0) == node.index && displaces(node, offset) != null;
      case _: false;
    }
  }

  /**
   * Decide which nodes a tile is going to swallow, before emitting any.
   *
   * Nothing may be deferred on the chance that its reader takes it.  A node left
   * out of the order and then not absorbed would be computed at its reader
   * instead, and a chain of those — `a + b + c + ...`, where every term has one
   * reader — would move the whole sum to its last line and keep every term alive
   * until then.
   */
  function plan():Void {
    for (n in graph.nodes) {
      if (n.alone() && n.reader != Dag.NO_NODE && swallows(graph.nodes[n.reader], n)) {
        absorbed.set(n.index, true);
      }
    }
  }

  /* -- emitting ------------------------------------------------------------- */

  public function run():Array<Instr> {
    plan();
    for (at in 0...graph.nodes.length) {
      if (absorbed.exists(at)) continue; // part of the tile that reads it
      if (graph.rematerialisable(at) != null) continue; // only where a register wants it
      if (fuseComparison(at)) continue;
      done.set(at, true);
      tile(graph.nodes[at]);
    }
    return out;
  }

  function tile(n:Node):Reg {
    switch n.instr {
      case Const(dst, value):
        put("const", dst, null, value);
        return dst;

      case StrConst(dst, symbol):
        put("adr", dst, null, null, symbol);
        return dst;

      case Bin(dst, op, lhs, rhs):
        arithmetic(n, dst, op, lhs, rhs);
        return dst;

      case Cmp(dst, op, lhs, rhs):
        compare(n, lhs, rhs);
        put("cset", dst, null, null, Mach.codeOf(op));
        return dst;

      case Load(dst, base, offset):
        final a = address(n.operand(0), base, offset);
        put("ldr", dst, [a.pointer], a.displacement);
        return dst;

      case Store(base, offset, src):
        final value = at(n.operand(1), src);
        final a = address(n.operand(0), base, offset);
        put("str", null, [a.pointer, value], a.displacement, "", true);
        return src;

      case other:
        // Moves, calls, slot accesses and the terminator are machine instructions
        // already, and a phi is not in this list at all.  None of them folds
        // anything, so every operand that was left to be folded has to be
        // computed here instead.
        for (operand in n.operands) force(operand);
        out.push(switch other {
          case CBr(cond, t, e, _) if (fused != ""): CBr(cond, t, e, fused);
          case _: other;
        });
        final d = Ir.defs(other);
        return d != null ? d : 0;
    }
  }

  /**
   * The register holding an operand, computing it here if it was deferred.
   *
   * Only two kinds of node were left out of the order: a constant, which is tiled
   * the first time somebody needs it in a register and read from there
   * afterwards, and a node the plan said would be absorbed, which ends up here
   * only if the tile that was to absorb it changed its mind.
   */
  function at(index:Int, reg:Reg):Reg {
    final n = graph.at(index);
    if (n == null || done.exists(n.index)) return reg;
    final deferred = absorbed.exists(n.index) || graph.rematerialisable(n.index) != null;
    if (!deferred) return reg;
    done.set(n.index, true);
    return tile(n);
  }

  /** Compute a deferred operand for a reader that has no tile to take it. */
  function force(index:Int):Void {
    final n = graph.at(index);
    if (n == null) return;
    final v = Ir.defs(n.instr);
    at(index, v != null ? v : 0);
  }

  /** Both operands in registers, which is what the plain forms want. */
  function both(n:Node, lhs:Reg, rhs:Reg):Array<Reg> {
    final a = at(n.operand(0), lhs);
    final b = at(n.operand(1), rhs);
    return [a, b];
  }

  function arithmetic(n:Node, dst:Reg, op:String, lhs:Reg, rhs:Reg):Void {
    switch op {
      case "+" | "-": additive(n, dst, op, lhs, rhs);
      case "*": multiply(n, dst, lhs, rhs);
      case "/": put("sdiv", dst, both(n, lhs, rhs));
      case "shl" | "shr": shift(n, dst, op, lhs, rhs);
      case "and" | "or" | "xor": logical(n, dst, op, lhs, rhs);
      case _: throw 'no instruction for `$op`';
    }
  }

  /** `add` and `sub`, in whichever of their four forms fits. */
  function additive(n:Node, dst:Reg, op:String, lhs:Reg, rhs:Reg):Void {
    // A shifted operand comes first: `a + b * 8` is one instruction that way and
    // two as a multiply-add, because the 8 would need a register.
    if (shiftInto(n, dst, op, lhs)) return;
    if (multiplyInto(n, dst, op, lhs)) return;
    final left = n.operand(0);
    final right = n.operand(1);
    final onRight = graph.constant(right);
    if (onRight != null && inImmediateRange(onRight)) {
      put(op == "+" ? "addi" : "subi", dst, [at(left, lhs)], onRight);
      return;
    }
    // Only addition may take its constant from the other side.
    final onLeft = op == "+" ? graph.constant(left) : null;
    if (onLeft != null && inImmediateRange(onLeft)) {
      put("addi", dst, [at(right, rhs)], onLeft);
      return;
    }
    put(op == "+" ? "add" : "sub", dst, both(n, lhs, rhs));
  }

  function inImmediateRange(v:Int64):Bool {
    return Int64.compare(v, Int64.ofInt(0)) >= 0 && Int64.compare(v, IMMEDIATE_MAX) <= 0;
  }

  function multiply(n:Node, dst:Reg, lhs:Reg, rhs:Reg):Void {
    final value = graph.constant(n.operand(1));
    if (value != null && isPowerOfTwo(value)) {
      put("lsli", dst, [at(n.operand(0), lhs)], log2(value));
    } else {
      put("mul", dst, both(n, lhs, rhs));
    }
  }

  function shift(n:Node, dst:Reg, op:String, lhs:Reg, rhs:Reg):Void {
    final value = graph.constant(n.operand(1));
    if (value != null && Int64.compare(value, Int64.ofInt(0)) >= 0
      && Int64.compare(value, Int64.ofInt(64)) < 0) {
      put(SHIFT_FORM.get(op) + "i", dst, [at(n.operand(0), lhs)], value);
    } else {
      put(SHIFT_FORM.get(op), dst, both(n, lhs, rhs));
    }
  }

  function logical(n:Node, dst:Reg, op:String, lhs:Reg, rhs:Reg):Void {
    final value = graph.constant(n.operand(1));
    if (op == "xor" && value != null && Int64.eq(value, Int64.ofInt(1))) {
      // Which is how `not` arrives.
      put("eori", dst, [at(n.operand(0), lhs)], Int64.ofInt(1));
    } else {
      put(LOGICAL_FORM.get(op), dst, both(n, lhs, rhs));
    }
  }

  /** `a + b * c` and `a - b * c` are one instruction each. */
  function multiplyInto(n:Node, dst:Reg, op:String, lhs:Reg):Bool {
    final product = graph.at(n.operand(1));
    if (product == null || !product.alone() || !isBin(product, "*")) return false;
    switch product.instr {
      case Bin(_, _, innerLhs, innerRhs):
        final x = at(product.operand(0), innerLhs);
        final y = at(product.operand(1), innerRhs);
        final z = at(n.operand(0), lhs);
        put(op == "+" ? "madd" : "msub", dst, [x, y, z]);
        return true;
      case _:
        return false;
    }
  }

  /** The second operand of an `add` may be shifted on the way in. */
  function shiftInto(n:Node, dst:Reg, op:String, lhs:Reg):Bool {
    final found = asShift(n.operand(1));
    if (found == null) return false;
    switch found.node.instr {
      case Bin(_, _, innerLhs, _):
        final a = at(n.operand(0), lhs);
        final b = at(found.node.operand(0), innerLhs);
        put(op == "+" ? "adds" : "subs", dst, [a, b], found.amount);
        return true;
      case _:
        return false;
    }
  }

  /** A pointer and a displacement, taking in an addition if there is one. */
  function address(index:Int, base:Reg, offset:Int):{pointer:Reg, displacement:Int64} {
    final n = graph.at(index);
    if (n != null && n.alone()) {
      final displaced = displaces(n, offset);
      if (displaced != null) {
        switch n.instr {
          case Bin(_, _, innerLhs, _):
            return {pointer: at(n.operand(0), innerLhs), displacement: displaced};
          case _:
        }
      }
    }
    return {pointer: at(index, base), displacement: Int64.ofInt(offset)};
  }

  function compare(n:Node, lhs:Reg, rhs:Reg):Void {
    final left = n.operand(0);
    final right = n.operand(1);
    final value = graph.constant(right);
    if (value != null && inImmediateRange(value)) {
      put("cmpi", null, [at(left, lhs)], value);
    } else {
      final a = at(left, lhs);
      final b = at(right, rhs);
      put("cmp", null, [a, b]);
    }
  }

  /**
   * A comparison the branch below it is the only reader of sets the flags.
   *
   * The code it sets is remembered rather than written into the branch, because
   * an instruction here is a value: the branch is emitted later, by `tile`, and
   * that is where the code goes on.
   */
  function fuseComparison(index:Int):Bool {
    final nodes = graph.nodes;
    if (index + 1 != nodes.length - 1) return false;
    final n = nodes[index];
    return switch [n.instr, nodes[nodes.length - 1].instr] {
      case [Cmp(dst, op, lhs, rhs), CBr(cond, _, _, _)] if (cond == dst && n.users == 1
        && !n.escapes):
        compare(n, lhs, rhs);
        fused = Mach.codeOf(op);
        true;
      case _: false;
    }
  }
}
