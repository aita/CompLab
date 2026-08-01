// Liveness.
//
// The only subtlety is the phi.  A phi does not read its arguments where it
// stands; it reads them on the edges, so an argument is live at the end of the
// predecessor it is paired with and not anywhere inside the block that holds the
// phi.  Getting that wrong is what makes phi-related values interfere when they
// should not.

import * as ir from "./ir.ts";

export const sameSet = (a: Set<number>, b: Set<number>): boolean =>
  a.size === b.size && [...a].every((x) => b.has(x));

export class Liveness {
  readonly liveIn = new Map<string, Set<ir.Reg>>();
  readonly liveOut = new Map<string, Set<ir.Reg>>();

  in_(label: string): Set<ir.Reg> { return this.liveIn.get(label)!; }
  out(label: string): Set<ir.Reg> { return this.liveOut.get(label)!; }
}

export function analyse(f: ir.Func): Liveness {
  const upward = new Map<string, Set<ir.Reg>>();
  const killed = new Map<string, Set<ir.Reg>>();
  for (const b of f.walk()) {
    const use = new Set<ir.Reg>();
    const kill = new Set<ir.Reg>();
    for (const phi of b.phis) kill.add(phi.dst);
    for (const instr of b.instrs) {
      for (const r of instr.uses()) if (!kill.has(r)) use.add(r);
      const d = instr.defs();
      if (d !== null) kill.add(d);
    }
    upward.set(b.label, use);
    killed.set(b.label, kill);
  }

  const live = new Liveness();
  for (const label of f.blocks.keys()) {
    live.liveIn.set(label, new Set());
    live.liveOut.set(label, new Set());
  }

  const order = ir.rpo(f).reverse();
  let changed = true;
  while (changed) {
    changed = false;
    for (const label of order) {
      const b = f.block(label);
      const out = new Set<ir.Reg>();
      for (const succ of b.succs) {
        for (const r of live.in_(succ)) out.add(r);
        for (const phi of f.block(succ).phis) {
          const arg = phi.args.get(label);
          if (arg !== undefined) out.add(arg);
        }
      }
      const newIn = new Set(upward.get(label)!);
      for (const r of out) if (!killed.get(label)!.has(r)) newIn.add(r);
      if (!sameSet(out, live.out(label)) || !sameSet(newIn, live.in_(label))) {
        live.liveOut.set(label, out);
        live.liveIn.set(label, newIn);
        changed = true;
      }
    }
  }
  return live;
}

/** Values live across a call, and so unable to sit in a scratch register. */
export function acrossCalls(f: ir.Func, live: Liveness): Set<ir.Reg> {
  const out = new Set<ir.Reg>();
  for (const b of f.walk()) {
    const after = new Set(live.out(b.label));
    for (let at = b.instrs.length - 1; at >= 0; at--) {
      const instr = b.instrs[at]!;
      const d = instr.defs();
      if (d !== null) after.delete(d);
      if (instr instanceof ir.Call) for (const r of after) out.add(r);
      for (const r of instr.uses()) after.add(r);
    }
  }
  return out;
}

/** The most values live at any one point — the registers the function wants. */
export function pressure(f: ir.Func, live: Liveness): number {
  let most = 0;
  for (const b of f.walk()) {
    const after = new Set(live.out(b.label));
    most = Math.max(most, after.size);
    for (let at = b.instrs.length - 1; at >= 0; at--) {
      const instr = b.instrs[at]!;
      const d = instr.defs();
      if (d !== null) after.delete(d);
      for (const r of instr.uses()) after.add(r);
      most = Math.max(most, after.size);
    }
    const entry = new Set(live.in_(b.label));
    for (const phi of b.phis) entry.add(phi.dst);
    most = Math.max(most, entry.size);
  }
  return most;
}
