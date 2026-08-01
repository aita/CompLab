// Spilling.
//
// A spilled value gets a frame slot, a store after every definition of it and a
// reload in front of every use.  The reloads are new registers, live from the load
// to the instruction under it and nowhere else, which is what makes the pressure
// come down.  Nothing here assumes SSA: a value written twice gets two stores, and
// a phi argument is reloaded at the end of the predecessor it comes from, so the
// same rewrite would serve a walk of the dominator tree as well as the graph.

import * as ir from "./ir.ts";
import * as ssa from "./ssa.ts";

/** Raised when spilling cannot help either. */
export class OutOfRegisters extends Error {
  constructor(message: string) {
    super(message);
    this.name = "OutOfRegisters";
  }
}

/**
 * How deeply each block is nested in loops, for weighing what a use costs.
 *
 * A back edge is an edge into a block that dominates its source; everything that
 * can reach the source without leaving the dominated region is in that loop.
 */
export function loopDepth(f: ir.Func): Map<string, number> {
  const dom = ssa.dominance(f);
  const depth = new Map<string, number>([...f.blocks.keys()].map((label) => [label, 0]));
  for (const b of f.walk()) {
    for (const succ of b.succs) {
      if (!dom.dominates(succ, b.label)) continue;
      const body = new Set([succ]);
      const stack = [b.label];
      while (stack.length > 0) {
        const label = stack.pop()!;
        if (body.has(label)) continue;
        body.add(label);
        stack.push(...f.block(label).preds);
      }
      for (const label of body) depth.set(label, depth.get(label)! + 1);
    }
  }
  return depth;
}

/** What spilling a value would cost: its reads and writes, weighed by loops. */
export function costs(f: ir.Func): Map<ir.Reg, number> {
  const depth = loopDepth(f);
  const weight = new Map<ir.Reg, number>();
  const add = (r: ir.Reg, amount: number): void => {
    weight.set(r, (weight.get(r) ?? 0) + amount);
  };
  const scaleOf = (label: string): number => 10 ** Math.min(depth.get(label)!, 4);
  for (const b of f.walk()) {
    const scale = scaleOf(b.label);
    for (const phi of b.phis) {
      for (const [pred, arg] of phi.args) add(arg, scaleOf(pred));
      add(phi.dst, scale);
    }
    for (const instr of b.instrs) {
      for (const r of instr.uses()) add(r, scale);
      const d = instr.defs();
      if (d !== null) add(d, scale);
    }
  }
  return weight;
}

/** Give `victim` a frame slot, and return the reloads that replaced it. */
export function spill(f: ir.Func, victim: ir.Reg): Set<ir.Reg> {
  const slot = f.newSlot();
  f.spillSlots.set(victim, slot);
  const isParam = f.params.includes(victim);
  const reloads = new Set<ir.Reg>();

  for (const b of f.walk()) {
    if (b.phis.some((phi) => phi.dst === victim)) {
      b.instrs.unshift(new ir.StoreSlot(slot, victim));
    }
    if (isParam && b.label === f.entry) b.instrs.unshift(new ir.StoreSlot(slot, victim));

    const rebuilt: ir.Instr[] = [];
    for (const instr of b.instrs) {
      const spillStore = instr instanceof ir.StoreSlot && instr.slot === slot;
      if (instr.uses().includes(victim) && !spillStore) {
        const fresh = f.newReg();
        reloads.add(fresh);
        rebuilt.push(new ir.LoadSlot(fresh, slot));
        instr.mapUses((r) => (r === victim ? fresh : r));
      }
      rebuilt.push(instr);
      if (instr.defs() === victim) rebuilt.push(new ir.StoreSlot(slot, victim));
    }
    b.instrs = rebuilt;
  }

  for (const b of f.walk()) {
    for (const phi of b.phis) {
      for (const [pred, arg] of [...phi.args]) {
        if (arg !== victim) continue;
        const source = f.block(pred);
        const fresh = f.newReg();
        reloads.add(fresh);
        source.instrs.splice(source.instrs.length - 1, 0, new ir.LoadSlot(fresh, slot));
        phi.args.set(pred, fresh);
      }
    }
  }
  return reloads;
}
