// Instruction selection: cover the DAG with ARM instructions.
//
// Every node that has to become a register of its own is tiled, largest tile
// first, pulling its foldable operands into the tile as it goes.  The tiles are
// the things ARM can do in one instruction that the IR needs several nodes to say:
//
//     a + b * c            madd
//     a - b * c            msub
//     a + (b << k)         add with a shifted operand
//     a + 4095             add with an immediate
//     a * 8                lsl
//     [a + 24]             a load with the addition as its displacement
//     a < b, then branch   cmp, and a branch on the flags
//
// What comes out is still the same CFG, and still in SSA — a tile defines one new
// register — so liveness, the allocator and the verifier carry on as before.  What
// has gone is the guesswork the emitter used to do with its peepholes: an
// instruction is now chosen where the whole expression is visible, rather than by
// looking at the line before.

import * as dag from "./dag.ts";
import * as ir from "./ir.ts";
import * as liveness from "./liveness.ts";
import { CONDITION, Mach } from "./mach.ts";

/** What `add`, `sub` and `cmp` take as an immediate operand. */
const IMMEDIATE = 4095n;

const LOGICAL = new Map([["and", "and"], ["or", "orr"], ["xor", "eor"]]);
const SHIFTS = new Map([["shl", "lsl"], ["shr", "asr"]]);

/** Where the one set bit of a power of two is. */
const log2 = (value: bigint): bigint => BigInt(value.toString(2).length - 1);

export function selectModule(mod: ir.Module): void {
  for (const f of mod.funcs) select(f);
}

export function select(f: ir.Func): void {
  const live = liveness.analyse(f);
  for (const b of f.walk()) {
    b.instrs = new Selector(dag.build(b, live.out(b.label))).run();
  }
}

/** The DAGs a selection would work on, for `wolv emit -s dag`. */
export function graphs(f: ir.Func): Map<string, dag.Dag> {
  const live = liveness.analyse(f);
  return new Map(f.walk().map((b) => [b.label, dag.build(b, live.out(b.label))]));
}

class Selector {
  private readonly graph: dag.Dag;
  private readonly out: ir.Instr[] = [];
  private readonly done = new Set<number>();
  private readonly absorbed = new Set<number>();

  constructor(graph: dag.Dag) { this.graph = graph; }

  run(): ir.Instr[] {
    this.plan();
    this.graph.nodes.forEach((node, at) => {
      if (this.absorbed.has(at)) return; // part of the tile that reads it
      if (this.graph.rematerialisable(at) !== null) return; // computed where wanted
      if (this.fuseComparison(at)) return;
      this.done.add(at);
      this.tile(node);
    });
    return this.out;
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
  private plan(): void {
    for (const node of this.graph.nodes) {
      if (!node.alone() || node.reader === null) continue;
      if (this.swallows(this.graph.nodes[node.reader]!, node)) this.absorbed.add(node.index);
    }
  }

  /** Whether the instruction chosen for `reader` has room for `node`. */
  private swallows(reader: dag.Node, node: dag.Node): boolean {
    const instr = reader.instr;
    if (instr instanceof ir.Bin) {
      if (instr.op !== "+" && instr.op !== "-") return false;
      if (reader.operands[1] !== node.index) return false;
      return this.asShift(node.index) !== null || this.isBin(node, "*");
    }
    if (instr instanceof ir.Load) {
      return reader.operands[0] === node.index && this.displaces(node, instr.offset) !== null;
    }
    if (instr instanceof ir.Store) {
      return reader.operands[0] === node.index && this.displaces(node, instr.offset) !== null;
    }
    return false;
  }

  /** `[pointer + 24]`, when what is added to the pointer is a constant. */
  private displaces(node: dag.Node, offset: number): bigint | null {
    if (!this.isBin(node, "+")) return null;
    const value = this.graph.constant(node.operands[1]!);
    if (value === null) return null;
    const total = BigInt(offset) + value;
    if (total >= 0n && total <= 32760n && total % BigInt(ir.WORD) === 0n) return total;
    if (total >= -256n && total <= 255n) return total;
    return null;
  }

  // -- emitting -----------------------------------------------------------

  /** Every caller names `dst`, because leaving it out would mean x0. */
  private mach(m: Mach): void { this.out.push(m); }

  /**
   * The register holding an operand, computing it here if it was deferred.
   *
   * Only two kinds of node were left out of the order: a constant, which is tiled
   * the first time somebody needs it in a register and read from there afterwards,
   * and a node the plan said would be absorbed, which ends up here only if the
   * tile that was to absorb it changed its mind.
   */
  private at(index: number | null, reg: ir.Reg): ir.Reg {
    const node = this.graph.of(index);
    if (node === null || this.done.has(node.index)) return reg;
    const deferred = this.absorbed.has(node.index)
      || this.graph.rematerialisable(node.index) !== null;
    if (!deferred) return reg;
    this.done.add(node.index);
    return this.tile(node);
  }

  // -- one node -----------------------------------------------------------

  private tile(node: dag.Node): ir.Reg {
    const instr = node.instr;
    if (instr instanceof ir.Const) {
      this.mach(new Mach("const", instr.dst, [], instr.value));
      return instr.dst;
    }
    if (instr instanceof ir.StrConst) {
      this.mach(new Mach("adr", instr.dst, [], 0n, instr.symbol));
      return instr.dst;
    }
    if (instr instanceof ir.Bin) {
      this.arithmetic(node, instr.dst, instr.op, instr.lhs, instr.rhs);
      return instr.dst;
    }
    if (instr instanceof ir.Cmp) {
      this.compare(node, instr.lhs, instr.rhs);
      this.mach(new Mach("cset", instr.dst, [], 0n, CONDITION.get(instr.op)!));
      return instr.dst;
    }
    if (instr instanceof ir.Load) {
      const [pointer, displacement] = this.address(node.operands[0]!, instr.base, instr.offset);
      this.mach(new Mach("ldr", instr.dst, [pointer], displacement));
      return instr.dst;
    }
    if (instr instanceof ir.Store) {
      const value = this.at(node.operands[1]!, instr.src);
      const [pointer, displacement] = this.address(node.operands[0]!, instr.base, instr.offset);
      this.mach(new Mach("str", null, [pointer, value], displacement, "", true));
      return instr.src;
    }
    // Moves, calls, slot accesses and the terminator are machine instructions
    // already, and a phi is not in this list at all.  None of them folds anything,
    // so every operand that was left to be folded has to be computed here instead.
    for (const operand of node.operands) this.force(operand);
    this.out.push(instr);
    return instr.defs() ?? 0;
  }

  // -- the tiles ----------------------------------------------------------

  private arithmetic(node: dag.Node, dst: ir.Reg, op: string, lhs: ir.Reg, rhs: ir.Reg): void {
    switch (op) {
      case "+": case "-": this.additive(node, dst, op, lhs, rhs); return;
      case "*": this.multiply(node, dst, lhs, rhs); return;
      case "/": this.mach(new Mach("sdiv", dst, this.both(node, lhs, rhs))); return;
      case "shl": case "shr": this.shift(node, dst, op, lhs, rhs); return;
      case "and": case "or": case "xor": this.logical(node, dst, op, lhs, rhs); return;
      default: throw new Error(`no instruction for \`${op}\``);
    }
  }

  /** Both operands in registers, which is what the plain forms want. */
  private both(node: dag.Node, lhs: ir.Reg, rhs: ir.Reg): ir.Reg[] {
    const a = this.at(node.operands[0]!, lhs);
    const b = this.at(node.operands[1]!, rhs);
    return [a, b];
  }

  /** `add` and `sub`, in whichever of their four forms fits. */
  private additive(node: dag.Node, dst: ir.Reg, op: string, lhs: ir.Reg, rhs: ir.Reg): void {
    // A shifted operand comes first: `a + b * 8` is one instruction that way and
    // two as a multiply-add, because the 8 would need a register.
    if (this.shiftInto(node, dst, op, lhs)) return;
    if (this.multiplyInto(node, dst, op, lhs)) return;
    const left = node.operands[0]!;
    const right = node.operands[1]!;
    const value = this.graph.constant(right);
    if (value !== null && value >= 0n && value <= IMMEDIATE) {
      this.mach(new Mach(op === "+" ? "addi" : "subi", dst, [this.at(left, lhs)], value));
      return;
    }
    if (op === "+") {
      // Only addition may take its constant from the other side.
      const other = this.graph.constant(left);
      if (other !== null && other >= 0n && other <= IMMEDIATE) {
        this.mach(new Mach("addi", dst, [this.at(right, rhs)], other));
        return;
      }
    }
    this.mach(new Mach(op === "+" ? "add" : "sub", dst, this.both(node, lhs, rhs)));
  }

  private multiply(node: dag.Node, dst: ir.Reg, lhs: ir.Reg, rhs: ir.Reg): void {
    const value = this.graph.constant(node.operands[1]!);
    if (value !== null && value > 0n && (value & (value - 1n)) === 0n) {
      this.mach(new Mach("lsli", dst, [this.at(node.operands[0]!, lhs)], log2(value)));
      return;
    }
    this.mach(new Mach("mul", dst, this.both(node, lhs, rhs)));
  }

  private shift(node: dag.Node, dst: ir.Reg, op: string, lhs: ir.Reg, rhs: ir.Reg): void {
    const value = this.graph.constant(node.operands[1]!);
    if (value !== null && value >= 0n && value < 64n) {
      this.mach(new Mach(SHIFTS.get(op)! + "i", dst, [this.at(node.operands[0]!, lhs)], value));
      return;
    }
    this.mach(new Mach(SHIFTS.get(op)!, dst, this.both(node, lhs, rhs)));
  }

  private logical(node: dag.Node, dst: ir.Reg, op: string, lhs: ir.Reg, rhs: ir.Reg): void {
    if (op === "xor" && this.graph.constant(node.operands[1]!) === 1n) {
      // Which is how `not` arrives.
      this.mach(new Mach("eori", dst, [this.at(node.operands[0]!, lhs)], 1n));
      return;
    }
    this.mach(new Mach(LOGICAL.get(op)!, dst, this.both(node, lhs, rhs)));
  }

  /** `a + b * c` and `a - b * c` are one instruction each. */
  private multiplyInto(node: dag.Node, dst: ir.Reg, op: string, lhs: ir.Reg): boolean {
    const product = this.graph.of(node.operands[1]!);
    if (product === null || !product.alone() || !this.isBin(product, "*")) return false;
    const inner = product.instr as ir.Bin;
    const x = this.at(product.operands[0]!, inner.lhs);
    const y = this.at(product.operands[1]!, inner.rhs);
    const z = this.at(node.operands[0]!, lhs);
    this.mach(new Mach(op === "+" ? "madd" : "msub", dst, [x, y, z]));
    return true;
  }

  /** The second operand of an `add` may be shifted on the way in. */
  private shiftInto(node: dag.Node, dst: ir.Reg, op: string, lhs: ir.Reg): boolean {
    const shifted = this.asShift(node.operands[1]!);
    if (shifted === null) return false;
    const [inner, amount] = shifted;
    const bin = inner.instr as ir.Bin;
    const a = this.at(node.operands[0]!, lhs);
    const b = this.at(inner.operands[0]!, bin.lhs);
    this.mach(new Mach(op === "+" ? "adds" : "subs", dst, [a, b], amount));
    return true;
  }

  /**
   * A `x << k` that can be folded, however it was written: `* 8` says it too.
   * This decides nothing and emits nothing, so the plan and the tiles can both
   * ask it and get the same answer.
   */
  private asShift(index: number | null): [dag.Node, bigint] | null {
    const node = this.graph.of(index);
    if (node === null || !node.alone() || !(node.instr instanceof ir.Bin)) return null;
    let amount = this.graph.constant(node.operands[1]!);
    if (amount === null) return null;
    if (node.instr.op === "*") {
      if (amount <= 0n || (amount & (amount - 1n)) !== 0n) return null;
      amount = log2(amount);
    } else if (node.instr.op !== "shl") {
      return null;
    }
    if (amount < 0n || amount >= 64n) return null;
    return [node, amount];
  }

  /** A pointer and a displacement, taking in an addition if there is one. */
  private address(index: number | null, base: ir.Reg, offset: number): [ir.Reg, bigint] {
    const node = this.graph.of(index);
    if (node !== null && node.alone()) {
      const displaced = this.displaces(node, offset);
      if (displaced !== null) {
        const inner = node.instr as ir.Bin;
        return [this.at(node.operands[0]!, inner.lhs), displaced];
      }
    }
    return [this.at(index, base), BigInt(offset)];
  }

  // -- comparisons and the branch that reads them --------------------------

  private compare(node: dag.Node, lhs: ir.Reg, rhs: ir.Reg): void {
    const left = node.operands[0]!;
    const right = node.operands[1]!;
    const value = this.graph.constant(right);
    if (value !== null && value >= 0n && value <= IMMEDIATE) {
      this.mach(new Mach("cmpi", null, [this.at(left, lhs)], value));
      return;
    }
    const a = this.at(left, lhs);
    const b = this.at(right, rhs);
    this.mach(new Mach("cmp", null, [a, b]));
  }

  /** A comparison the branch below it is the only reader of sets the flags. */
  private fuseComparison(index: number): boolean {
    const nodes = this.graph.nodes;
    const node = nodes[index]!;
    const instr = node.instr;
    if (!(instr instanceof ir.Cmp) || index + 1 !== nodes.length - 1) return false;
    const terminator = nodes[nodes.length - 1]!.instr;
    if (!(terminator instanceof ir.CBr) || terminator.cond !== instr.dst) return false;
    if (node.users !== 1 || node.escapes) return false;
    this.compare(node, instr.lhs, instr.rhs);
    terminator.code = CONDITION.get(instr.op)!;
    return true;
  }

  // -- reading operands ----------------------------------------------------

  /** Compute a deferred operand for a reader that has no tile to take it. */
  private force(index: number | null): void {
    const node = this.graph.of(index);
    if (node === null) return;
    this.at(index, node.value ?? 0);
  }

  private isBin(node: dag.Node, op: string): boolean {
    return node.instr instanceof ir.Bin && node.instr.op === op;
  }
}
