// The seam the register allocator is reached through, and what it promises.
//
// There is one allocator here: leave SSA, build the interference graph, and colour
// it the way Chaitin's algorithm does, with the iterated coalescing that eats the
// copies leaving SSA made.  The Python tree beside this one carries a second
// allocator that colours the SSA itself in dominance order, so that the two can be
// measured against each other; this tree keeps the graph.

import * as ir from "./ir.ts";
import * as liveness from "./liveness.ts";
import { allocate } from "./graph.ts";
import { Registers } from "./registers.ts";

export { OutOfRegisters } from "./spill.ts";
export { Registers, limited } from "./registers.ts";

export function allocateModule(mod: ir.Module, machine = new Registers()): void {
  for (const f of mod.funcs) allocate(f, machine);
}

function coloured(f: ir.Func, r: ir.Reg): void {
  if (!f.colours.has(r)) throw new Error(`%${r} has no colour`);
}

/** Nothing else live here may hold the colour `written` was just given. */
function noClash(f: ir.Func, alive: Set<ir.Reg>, written: ir.Reg, where: string): void {
  const colour = f.colours.get(written);
  if (colour === undefined) return;
  for (const other of [...alive].sort((a, b) => a - b)) {
    if (other === written || f.colours.get(other) !== colour) continue;
    throw new Error(`x${colour} holds %${written} and %${other} at once in ${where}`);
  }
}

/**
 * No two values that hold different things at once may share a colour.
 *
 * The check is made where the interference graph joins values -- at each
 * definition, and at the top of a block for the phis and the parameters, which
 * define several at once.  Looking at a whole live set instead would be wrong,
 * not merely slower: both ends of a copy are live after it and hold the same
 * value, so they may share a register, and that is the entire point of
 * coalescing.  A verifier that rejected it would reject every program the
 * coalescer had done its job on.
 *
 * Nothing that interferes escapes this, because the later of the two definitions
 * that put the values there happens while the other is live.
 */
export function verify(f: ir.Func): void {
  const live = liveness.analyse(f);
  for (const b of f.walk()) {
    const alive = new Set(live.out(b.label));
    for (let at = b.instrs.length - 1; at >= 0; at -= 1) {
      const instr = b.instrs[at]!;
      if (instr instanceof ir.Move) alive.delete(instr.src);
      for (const r of instr.uses()) coloured(f, r);
      const d = instr.defs();
      if (d !== null) {
        coloured(f, d);
        alive.add(d);
        noClash(f, alive, d, b.label);
        alive.delete(d);
      }
      for (const r of instr.uses()) alive.add(r);
    }

    const entering = new Set(live.in_(b.label));
    for (const phi of b.phis) {
      coloured(f, phi.dst);
      entering.add(phi.dst);
      noClash(f, entering, phi.dst, b.label);
    }
    if (b.label === f.entry) {
      for (const param of f.params) {
        entering.add(param);
        noClash(f, entering, param, b.label);
      }
    }
  }
}
