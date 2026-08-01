package wolv;

import wolv.Ir;
import wolv.Registers.Machine;

/* The seam the register allocator is reached through, and what it promises.
 *
 * There is one allocator here: leave SSA, build the interference graph, and
 * colour it the way Chaitin's algorithm does, with the iterated coalescing that
 * eats the copies leaving SSA made.  The Python tree beside this one carries a
 * second allocator that colours the SSA itself in dominance order, so that the
 * two can be measured against each other; this tree keeps the graph. */

function allocateModule(m:Module, machine:Machine):Void {
  for (f in m.funcs) Graph.allocate(f, machine);
}

private function coloured(f:Func, r:Reg):Void {
  if (!f.colours.exists(r)) throw '%$r has no colour';
}

/** Nothing else live here may hold the colour `written` was just given. */
private function noClash(f:Func, alive:IntSet, written:Reg, where:String):Void {
  final colour = f.colours.get(written);
  if (colour == null) return;
  for (other in alive.ordered()) {
    if (other == written || f.colours.get(other) != colour) continue;
    throw 'x$colour holds %$written and %$other at once in $where';
  }
}

/**
 * No two values that hold different things at once may share a colour.
 *
 * The check is made where the interference graph joins values — at each
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
function verify(f:Func):Void {
  final live = Liveness.analyse(f);
  for (b in f.walk()) {
    final alive = new IntSet();
    for (r in live.outOf(b.label).keys()) alive.add(r);
    var at = b.instrs.length - 1;
    while (at >= 0) {
      final i = b.instrs[at];
      switch i {
        case Move(_, src): alive.remove(src);
        case _:
      }
      for (r in Ir.uses(i)) coloured(f, r);
      final d = Ir.defs(i);
      if (d != null) {
        coloured(f, d);
        alive.add(d);
        noClash(f, alive, d, b.label);
        alive.remove(d);
      }
      alive.addAll(Ir.uses(i));
      at -= 1;
    }

    final entering = new IntSet();
    for (r in live.into(b.label).keys()) entering.add(r);
    for (phi in b.phis) {
      coloured(f, phi.dst);
      entering.add(phi.dst);
      noClash(f, entering, phi.dst, b.label);
    }
    if (b.label == f.entry) {
      for (param in f.params) {
        entering.add(param);
        noClash(f, entering, param, b.label);
      }
    }
  }
}
