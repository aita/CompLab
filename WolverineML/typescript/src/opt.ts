// Optimisation on SSA.
//
// Five small passes run to a fixed point.  Each is cheap because SSA makes it
// cheap: a register has one definition, so constant folding and copy propagation
// are a lookup rather than a dataflow problem, and a phi whose arguments all
// agree is a copy that was never needed.
//
//     fold constants   ->  arithmetic on known values
//     propagate copies ->  `Move`, and phis that turned into one
//     simplify phis    ->  a phi with one distinct argument is that argument
//     fold branches    ->  a branch on a known value, and the blocks it strands
//     dead code        ->  anything computed and not used

import * as ir from "./ir.ts";

export function optimise(mod: ir.Module): void {
  for (const f of mod.funcs) optimiseFunc(f);
}

export function optimiseFunc(f: ir.Func): void {
  const passes = [foldConstants, propagateCopies, simplifyPhis, foldBranches, deadCode];
  for (;;) {
    // Every pass runs every round: they are cheap, and one enables another.
    const changes = passes.map((run) => run(f));
    if (!changes.some(Boolean)) return;
  }
}

// -- rewriting ----------------------------------------------------------------

/** Replace registers everywhere they are read, phi arguments included. */
export function rewrite(f: ir.Func, mapping: Map<ir.Reg, ir.Reg>): void {
  if (mapping.size === 0) return;
  const resolve = (start: ir.Reg): ir.Reg => {
    let r = start;
    const seen = new Set<ir.Reg>();
    while (mapping.has(r) && !seen.has(r)) {
      seen.add(r);
      r = mapping.get(r)!;
    }
    return r;
  };
  for (const b of f.walk()) {
    for (const phi of b.phis) {
      for (const [pred, r] of phi.args) phi.args.set(pred, resolve(r));
    }
    for (const instr of b.instrs) instr.mapUses(resolve);
  }
}

export function constants(f: ir.Func): Map<ir.Reg, bigint> {
  const known = new Map<ir.Reg, bigint>();
  for (const b of f.walk()) {
    for (const instr of b.instrs) {
      if (instr instanceof ir.Const) known.set(instr.dst, instr.value);
    }
  }
  return known;
}

/**
 * The language's arithmetic, in the 64 bits it is done in.
 *
 * `BigInt` is exact and `BigInt.asIntN` is the wrap, so nothing here has to mask
 * or sign-extend by hand.  `/` and `%` already truncate towards zero the way
 * `sdiv` does, `MIN / -1` included, and a shift of 64 or more falls out of the
 * wrap rather than needing a case of its own.
 */
export function arith(op: string, a: bigint, b: bigint): bigint | null {
  const wrap = (v: bigint): bigint => BigInt.asIntN(64, v);
  switch (op) {
    case "+": return wrap(a + b);
    case "-": return wrap(a - b);
    case "*": return wrap(a * b);
    case "/": return b === 0n ? null : wrap(a / b);
    case "mod": return b === 0n ? null : wrap(a % b);
    case "and": return wrap(a & b);
    case "or": return wrap(a | b);
    case "xor": return wrap(a ^ b);
    case "shl": return b < 0n ? null : wrap(a << b);
    case "shr": return b < 0n ? null : wrap(a >> b);
    default: return null;
  }
}

export function order(op: string, a: bigint, b: bigint): boolean {
  switch (op) {
    case "=": return a === b;
    case "<>": return a !== b;
    case "<": return a < b;
    case "<=": return a <= b;
    case ">": return a > b;
    case ">=": return a >= b;
    case "u<": return BigInt.asUintN(64, a) < BigInt.asUintN(64, b);
    case "u>=": return BigInt.asUintN(64, a) >= BigInt.asUintN(64, b);
    default: throw new Error(`unknown comparison ${op}`);
  }
}

function fold(instr: ir.Instr, known: Map<ir.Reg, bigint>): ir.Instr | null {
  if (instr instanceof ir.Bin) {
    const a = known.get(instr.lhs);
    const b = known.get(instr.rhs);
    if (a !== undefined && b !== undefined) {
      const value = arith(instr.op, a, b);
      return value === null ? null : new ir.Const(instr.dst, value);
    }
    if (b === 0n && ["+", "-", "or", "xor", "shl", "shr"].includes(instr.op)) {
      return new ir.Move(instr.dst, instr.lhs);
    }
    if (b === 1n && ["*", "/"].includes(instr.op)) return new ir.Move(instr.dst, instr.lhs);
    if (a === 0n && instr.op === "+") return new ir.Move(instr.dst, instr.rhs);
    return null;
  }
  if (instr instanceof ir.Cmp) {
    const a = known.get(instr.lhs);
    const b = known.get(instr.rhs);
    if (a === undefined || b === undefined) return null;
    return new ir.Const(instr.dst, order(instr.op, a, b) ? 1n : 0n);
  }
  return null;
}

// -- the passes ---------------------------------------------------------------

export function foldConstants(f: ir.Func): boolean {
  const known = constants(f);
  let changed = false;
  for (const b of f.walk()) {
    b.instrs.forEach((instr, at) => {
      const folded = fold(instr, known);
      if (folded === null) return;
      b.instrs[at] = folded;
      if (folded instanceof ir.Const) known.set(folded.dst, folded.value);
      changed = true;
    });
  }
  return changed;
}

export function propagateCopies(f: ir.Func): boolean {
  const mapping = new Map<ir.Reg, ir.Reg>();
  for (const b of f.walk()) {
    for (const instr of b.instrs) {
      if (instr instanceof ir.Move) mapping.set(instr.dst, instr.src);
    }
  }
  if (mapping.size === 0) return false;
  rewrite(f, mapping);
  for (const b of f.walk()) b.instrs = b.instrs.filter((i) => !(i instanceof ir.Move));
  return true;
}

export function simplifyPhis(f: ir.Func): boolean {
  const mapping = new Map<ir.Reg, ir.Reg>();
  let changed = false;
  for (const b of f.walk()) {
    const keep: ir.Phi[] = [];
    for (const phi of b.phis) {
      const others = new Set([...phi.args.values()].filter((r) => r !== phi.dst));
      if (others.size === 1) {
        mapping.set(phi.dst, [...others][0]!);
        changed = true;
      } else {
        keep.push(phi);
      }
    }
    b.phis = keep;
  }
  if (changed) rewrite(f, mapping);
  return changed;
}

export function foldBranches(f: ir.Func): boolean {
  const known = constants(f);
  let changed = false;
  for (const b of f.walk()) {
    const term = b.terminator;
    if (!(term instanceof ir.CBr)) continue;
    const value = known.get(term.cond);
    if (value === undefined && term.then !== term.els) continue;
    const taken = value === undefined || value !== 0n ? term.then : term.els;
    b.instrs[b.instrs.length - 1] = new ir.Jmp(taken);
    changed = true;
  }
  if (changed) ir.dropUnreachable(f);
  return changed;
}

export function deadCode(f: ir.Func): boolean {
  let changed = false;
  for (;;) {
    const used = new Set<ir.Reg>();
    for (const b of f.walk()) {
      for (const phi of b.phis) for (const r of phi.args.values()) used.add(r);
      for (const instr of b.instrs) for (const r of instr.uses()) used.add(r);
    }
    let roundChanged = false;
    for (const b of f.walk()) {
      const phis = b.phis.filter((phi) => used.has(phi.dst));
      if (phis.length !== b.phis.length) { b.phis = phis; roundChanged = true; }
      const kept: ir.Instr[] = [];
      for (const instr of b.instrs) {
        const d = instr.defs();
        if (d !== null && !used.has(d) && !instr.hasEffect()) { roundChanged = true; continue; }
        kept.push(instr);
      }
      b.instrs = kept;
    }
    if (!roundChanged) return changed;
    changed = true;
  }
}
