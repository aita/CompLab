// Leaving SSA before allocation.
//
// A phi is a copy that happens on an edge, so it becomes copies at the end of each
// predecessor.  Critical edges are already split, so a predecessor of a block with
// phis has nowhere else to go and the copies can simply be appended.
//
// The copies of one edge happen at once: every argument is read before any
// destination is written.  Usually that needs no care, because a phi's destination
// is defined nowhere else and so is nobody's argument — but a block that is its own
// predecessor can have two phis that swap, and then the copies go through
// temporaries, which is Sreedhar's answer and which coalescing is expected to
// remove again.
//
// That the copies are a cost to be paid is the point rather than a complaint:
// copies are what coalescing eats, and the allocator earns nearly all of them back.

import * as ir from "./ir.ts";

function copyInParallel(f: ir.Func, b: ir.Block, moves: [ir.Reg, ir.Reg][]): void {
  const real = moves.filter(([dst, src]) => dst !== src);
  if (real.length === 0) return;
  const written = new Set(real.map(([dst]) => dst));
  const read = new Set(real.map(([, src]) => src));
  const copies: ir.Instr[] = [];
  if ([...written].some((r) => read.has(r))) {
    const through = new Map(real.map(([dst]) => [dst, f.newReg()] as const));
    copies.push(...real.map(([dst, src]) => new ir.Move(through.get(dst)!, src)));
    copies.push(...real.map(([dst]) => new ir.Move(dst, through.get(dst)!)));
  } else {
    copies.push(...real.map(([dst, src]) => new ir.Move(dst, src)));
  }
  // Before the terminator, which is the last instruction of the block.
  b.instrs.splice(b.instrs.length - 1, 0, ...copies);
}

/** Replace every phi in `f` with copies in its predecessors. */
export function destruct(f: ir.Func): void {
  for (const b of f.walk()) {
    if (b.phis.length === 0) continue;
    for (const pred of b.preds) {
      const source = f.block(pred);
      if (source.succs.length !== 1) {
        throw new Error(`${pred} -> ${b.label} is a critical edge`);
      }
      copyInParallel(
        f, source,
        b.phis.map((phi) => [phi.dst, phi.args.get(pred)!] as [ir.Reg, ir.Reg]),
      );
    }
    b.phis = [];
  }
  ir.recomputePreds(f);
}

export function destructModule(mod: ir.Module): void {
  for (const f of mod.funcs) destruct(f);
}
