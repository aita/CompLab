package wolv;

import wolv.Ir;

/* Leaving SSA before allocation.
 *
 * A phi is a copy that happens on an edge, so it becomes copies at the end of
 * each predecessor.  Critical edges are already split, so a predecessor of a
 * block with phis has nowhere else to go and the copies can simply be appended.
 *
 * The copies of one edge happen at once: every argument is read before any
 * destination is written.  Usually that needs no care, because a phi's
 * destination is defined nowhere else and so is nobody's argument — but a block
 * that is its own predecessor can have two phis that swap, and then the copies go
 * through temporaries, which is Sreedhar's answer and which coalescing is
 * expected to remove again.
 *
 * That the copies are a cost to be paid is the point rather than a complaint:
 * copies are what coalescing eats, and the allocator earns nearly all of them
 * back. */

function copyInParallel(f:Func, b:Block, moves:Array<{dst:Reg, src:Reg}>):Void {
  final real = moves.filter(m -> m.dst != m.src);
  if (real.length == 0) return;

  final read = real.map(m -> m.src);
  var clash = false;
  for (m in real) if (read.contains(m.dst)) clash = true;
  final copies:Array<Instr> = [];
  if (clash) {
    final through = new Map<Reg, Reg>();
    for (m in real) through.set(m.dst, f.newReg());
    for (m in real) copies.push(Move(through.get(m.dst), m.src));
    for (m in real) copies.push(Move(m.dst, through.get(m.dst)));
  } else {
    for (m in real) copies.push(Move(m.dst, m.src));
  }

  // Before the terminator, which is the last instruction of the block.
  final at = b.instrs.length - 1;
  b.instrs = b.instrs.slice(0, at).concat(copies).concat(b.instrs.slice(at));
}

/** Replace every phi in `f` with copies in its predecessors. */
function destruct(f:Func):Void {
  for (b in f.walk()) {
    if (b.phis.length == 0) continue;
    for (pred in b.preds) {
      final source = f.block(pred);
      if (source.succs().length != 1) throw '$pred -> ${b.label} is a critical edge';
      final moves = b.phis.map(phi -> {
        final a = phi.arg(pred);
        if (a == null) throw 'a phi in ${b.label} does not name $pred';
        {dst: phi.dst, src: a.arg};
      });
      copyInParallel(f, source, moves);
    }
    b.phis = [];
  }
  Ir.recomputePreds(f);
}

function destructModule(m:Module):Void {
  for (f in m.funcs) destruct(f);
}
