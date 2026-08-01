// SSA construction, the textbook way.
//
// Dominators by the iterative algorithm of Cooper, Harvey and Kennedy, dominance
// frontiers from those, phis at the frontiers of every definition, and then one
// walk of the dominator tree renaming as it goes.  This is minimal SSA and
// nothing cleverer: a phi is placed wherever the frontier says, whether or not
// the variable is live there, and the dead ones leave in `opt.deadCode`.
//
// Only registers written more than once take part.  Everything lowering produced
// once — a temporary — is already in SSA and is left with the name it has.

import * as ir from "./ir.ts";

export class Dominance {
  readonly idom: Map<string, string>;
  readonly children: Map<string, string[]>;
  readonly frontier: Map<string, Set<string>>;
  readonly order: string[];

  constructor(
    idom: Map<string, string>, children: Map<string, string[]>,
    frontier: Map<string, Set<string>>, order: string[],
  ) {
    this.idom = idom; this.children = children;
    this.frontier = frontier; this.order = order;
  }

  dominates(a: string, b: string): boolean {
    let at = b;
    for (;;) {
      if (a === at) return true;
      const parent = this.idom.get(at)!;
      if (parent === at) return false;
      at = parent;
    }
  }
}

export function dominance(f: ir.Func): Dominance {
  const order = ir.rpo(f);
  const rank = new Map(order.map((label, i) => [label, i] as const));
  const idom = new Map<string, string>([[f.entry, f.entry]]);

  const intersect = (first: string, second: string): string => {
    let a = first;
    let b = second;
    while (a !== b) {
      while (rank.get(a)! > rank.get(b)!) a = idom.get(a)!;
      while (rank.get(b)! > rank.get(a)!) b = idom.get(b)!;
    }
    return a;
  };

  let changed = true;
  while (changed) {
    changed = false;
    for (const label of order.slice(1)) {
      const preds = f.block(label).preds.filter((p) => idom.has(p));
      if (preds.length === 0) continue;
      let next = preds[0]!;
      for (const p of preds.slice(1)) next = intersect(p, next);
      if (idom.get(label) !== next) { idom.set(label, next); changed = true; }
    }
  }

  const children = new Map<string, string[]>(order.map((label) => [label, []]));
  for (const label of order) {
    const parent = idom.get(label)!;
    if (parent !== label) children.get(parent)!.push(label);
  }

  const frontier = new Map<string, Set<string>>(order.map((label) => [label, new Set()]));
  for (const label of order) {
    const b = f.block(label);
    if (b.preds.length < 2) continue;
    for (const pred of b.preds) {
      let runner = pred;
      while (runner !== idom.get(label) && idom.has(runner)) {
        frontier.get(runner)!.add(label);
        runner = idom.get(runner)!;
      }
    }
  }
  return new Dominance(idom, children, frontier, order);
}

/**
 * Where each register is written, and how often.
 *
 * A register written twice in one block is as much a variable as one written in
 * two blocks, so the count is what decides, and the blocks are what the frontier
 * walk needs.
 */
class Defs {
  readonly blocks = new Map<ir.Reg, Set<string>>();
  readonly count = new Map<ir.Reg, number>();

  record(r: ir.Reg, label: string): void {
    let at = this.blocks.get(r);
    if (at === undefined) { at = new Set(); this.blocks.set(r, at); }
    at.add(label);
    this.count.set(r, (this.count.get(r) ?? 0) + 1);
  }

  /** The registers written more than once, in ascending order. */
  variables(): ir.Reg[] {
    return [...this.count].filter(([, n]) => n > 1).map(([r]) => r).sort((a, b) => a - b);
  }
}

function definitions(f: ir.Func): Defs {
  const defs = new Defs();
  for (const b of f.walk()) {
    for (const instr of b.instrs) {
      const d = instr.defs();
      if (d !== null) defs.record(d, b.label);
    }
  }
  for (const r of f.params) defs.record(r, f.entry);
  return defs;
}

/** Put a phi for `v` at every dominance frontier of a block defining `v`. */
function placePhis(f: ir.Func, dom: Dominance, defs: Defs): Map<string, ir.Reg[]> {
  const phiVars = new Map<string, ir.Reg[]>([...f.blocks.keys()].map((label) => [label, []]));
  for (const v of defs.variables()) {
    const sites = defs.blocks.get(v)!;
    const placed = new Set<string>();
    const work = [...sites].sort();
    while (work.length > 0) {
      const b = work.pop()!;
      for (const target of [...dom.frontier.get(b)!].sort()) {
        if (placed.has(target)) continue;
        placed.add(target);
        phiVars.get(target)!.push(v);
        const block = f.block(target);
        block.phis.push(new ir.Phi(v, new Map(block.preds.map((p) => [p, v]))));
        if (!sites.has(target)) work.push(target);
      }
    }
  }
  return phiVars;
}

class Renamer {
  private readonly fn: ir.Func;
  private readonly dom: Dominance;
  private readonly phiVars: Map<string, ir.Reg[]>;
  readonly variables: Set<ir.Reg>;
  private readonly stacks = new Map<ir.Reg, ir.Reg[]>();
  private readonly undefined_ = new Map<ir.Reg, ir.Reg>();

  constructor(fn: ir.Func, dom: Dominance, phiVars: Map<string, ir.Reg[]>, variables: Set<ir.Reg>) {
    this.fn = fn; this.dom = dom; this.phiVars = phiVars; this.variables = variables;
  }

  private top(v: ir.Reg): ir.Reg {
    const stack = this.stacks.get(v);
    if (stack !== undefined && stack.length > 0) return stack[stack.length - 1]!;
    return this.undef(v);
  }

  /** A variable read on a path that never wrote it reads zero. */
  private undef(v: ir.Reg): ir.Reg {
    let r = this.undefined_.get(v);
    if (r === undefined) { r = this.fn.newReg(); this.undefined_.set(v, r); }
    return r;
  }

  plantUndefined(): void {
    const entry = this.fn.block(this.fn.entry);
    for (const r of this.undefined_.values()) entry.instrs.unshift(new ir.Const(r, 0n));
  }

  rename(v: ir.Reg): ir.Reg {
    const fresh = this.fn.newReg();
    let stack = this.stacks.get(v);
    if (stack === undefined) { stack = []; this.stacks.set(v, stack); }
    stack.push(fresh);
    return fresh;
  }

  run(): void {
    const walk = (label: string): void => {
      const mine = this.block(label);
      for (const child of this.dom.children.get(label)!) walk(child);
      for (const v of mine) this.stacks.get(v)!.pop();
    };
    walk(this.fn.entry);
  }

  private block(label: string): ir.Reg[] {
    const b = this.fn.block(label);
    const mine: ir.Reg[] = [];
    b.phis.forEach((phi, at) => {
      const v = this.phiVars.get(label)![at]!;
      phi.dst = this.rename(v);
      mine.push(v);
    });
    for (const instr of b.instrs) {
      instr.mapUses((r) => this.use(r));
      const d = instr.defs();
      if (d !== null && this.variables.has(d)) {
        instr.setDef(this.rename(d));
        mine.push(d);
      }
    }
    for (const succ of b.succs) {
      const target = this.fn.block(succ);
      target.phis.forEach((phi, at) => {
        phi.args.set(label, this.top(this.phiVars.get(succ)![at]!));
      });
    }
    return mine;
  }

  private use(r: ir.Reg): ir.Reg {
    return this.variables.has(r) ? this.top(r) : r;
  }
}

/** Rewrite one function into SSA, in place. */
export function construct(f: ir.Func): void {
  ir.recomputePreds(f);
  const dom = dominance(f);
  const defs = definitions(f);
  const phiVars = placePhis(f, dom, defs);
  const variables = new Set(defs.variables());
  const renamer = new Renamer(f, dom, phiVars, variables);
  f.params.forEach((p, at) => {
    if (variables.has(p)) f.params[at] = renamer.rename(p);
  });
  renamer.run();
  renamer.plantUndefined();
}

export function constructModule(mod: ir.Module): void {
  for (const f of mod.funcs) construct(f);
}

/**
 * Give every phi a place to put its copy in.
 *
 * An edge from a block with several successors into a block with several
 * predecessors has nowhere to hold the copies a phi turns into, so it gets a
 * block of its own.  The same goes for any edge into a block that still has a
 * phi, so that the emitter only ever has to put copies before a `jmp`.
 */
export function splitCriticalEdges(f: ir.Func): void {
  for (const label of [...f.order]) {
    const b = f.block(label);
    if (b.succs.length < 2) continue;
    for (const succ of [...b.succs]) {
      const target = f.block(succ);
      if (target.preds.length < 2 && target.phis.length === 0) continue;
      const split = f.addBlock(`${label}.${succ}`);
      split.instrs.push(new ir.Jmp(succ));
      ir.renameTarget(b.terminator, succ, split.label);
      for (const phi of target.phis) {
        if (phi.args.has(label)) {
          const arg = phi.args.get(label)!;
          phi.args.delete(label);
          phi.args.set(split.label, arg);
        }
      }
    }
  }
  ir.recomputePreds(f);
}

/** Check what SSA promises: one definition per register, and it dominates. */
export function verify(f: ir.Func): void {
  const dom = dominance(f);
  const definition = new Map<ir.Reg, string>();
  const claim = (r: ir.Reg, label: string): void => {
    if (definition.has(r)) throw new Error(`%${r} defined twice`);
    definition.set(r, label);
  };
  for (const b of f.walk()) {
    for (const phi of b.phis) claim(phi.dst, b.label);
    for (const instr of b.instrs) {
      const d = instr.defs();
      if (d !== null) claim(d, b.label);
    }
  }
  for (const p of f.params) if (!definition.has(p)) definition.set(p, f.entry);
  const where = (r: ir.Reg): string => {
    const at = definition.get(r);
    if (at === undefined) throw new Error(`%${r} is never defined`);
    return at;
  };
  for (const b of f.walk()) {
    for (const phi of b.phis) {
      const named = [...phi.args.keys()].sort().join(",");
      const preds = [...b.preds].sort().join(",");
      if (named !== preds) {
        throw new Error(`phi in ${b.label} names ${named}, preds are ${preds}`);
      }
      for (const [pred, r] of phi.args) {
        if (!dom.dominates(where(r), pred)) {
          throw new Error(`%${r} does not reach ${b.label} through ${pred}`);
        }
      }
    }
    for (const instr of b.instrs) {
      for (const r of instr.uses()) {
        if (!dom.dominates(where(r), b.label)) {
          throw new Error(`%${r} does not dominate its use in ${b.label}`);
        }
      }
    }
  }
}
