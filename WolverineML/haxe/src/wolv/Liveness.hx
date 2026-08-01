package wolv;

import wolv.Ir;

/* Liveness.
 *
 * The only subtlety is the phi.  A phi does not read its arguments where it
 * stands; it reads them on the edges, so an argument is live at the end of the
 * predecessor it is paired with and not anywhere inside the block that holds the
 * phi.  Getting that wrong is what makes phi-related values interfere when they
 * should not. */

class Liveness {
  public final liveIn = new Map<String, Map<Reg, Bool>>();
  public final liveOut = new Map<String, Map<Reg, Bool>>();

  public function new() {}

  public function into(label:String):Map<Reg, Bool> return liveIn.get(label);

  public function outOf(label:String):Map<Reg, Bool> return liveOut.get(label);
}

private function copy(s:Map<Reg, Bool>):Map<Reg, Bool> {
  final out = new Map<Reg, Bool>();
  for (r in s.keys()) out.set(r, true);
  return out;
}

private function size(s:Map<Reg, Bool>):Int {
  var n = 0;
  for (_ in s.keys()) n += 1;
  return n;
}

private function sameSet(a:Map<Reg, Bool>, b:Map<Reg, Bool>):Bool {
  for (r in a.keys()) if (!b.exists(r)) return false;
  for (r in b.keys()) if (!a.exists(r)) return false;
  return true;
}

function analyse(f:Func):Liveness {
  // What each block reads before writing, and what it writes at all.
  final upward = new Map<String, Map<Reg, Bool>>();
  final killed = new Map<String, Map<Reg, Bool>>();
  for (b in f.walk()) {
    final use = new Map<Reg, Bool>();
    final kill = new Map<Reg, Bool>();
    for (phi in b.phis) kill.set(phi.dst, true);
    for (i in b.instrs) {
      for (r in Ir.uses(i)) if (!kill.exists(r)) use.set(r, true);
      final d = Ir.defs(i);
      if (d != null) kill.set(d, true);
    }
    upward.set(b.label, use);
    killed.set(b.label, kill);
  }

  final live = new Liveness();
  for (label in f.order) {
    live.liveIn.set(label, new Map());
    live.liveOut.set(label, new Map());
  }

  // Backwards, to a fixed point.
  final order = Ir.rpo(f);
  order.reverse();
  var changed = true;
  while (changed) {
    changed = false;
    for (label in order) {
      final b = f.block(label);
      final out = new Map<Reg, Bool>();
      for (succ in b.succs()) {
        for (r in live.into(succ).keys()) out.set(r, true);
        for (phi in f.block(succ).phis) {
          final a = phi.arg(label);
          if (a != null) out.set(a.arg, true);
        }
      }
      final kill = killed.get(label);
      final newIn = copy(upward.get(label));
      for (r in out.keys()) if (!kill.exists(r)) newIn.set(r, true);
      if (!sameSet(out, live.outOf(label)) || !sameSet(newIn, live.into(label))) {
        live.liveOut.set(label, out);
        live.liveIn.set(label, newIn);
        changed = true;
      }
    }
  }
  return live;
}

/** The values live across a call, and so unable to sit in a scratch register. */
function acrossCalls(f:Func, live:Liveness):Map<Reg, Bool> {
  final out = new Map<Reg, Bool>();
  for (b in f.walk()) {
    // A call's own arguments are not live across it, so the set is read after its
    // result is taken out and before its arguments go back in.
    final after = copy(live.outOf(b.label));
    var at = b.instrs.length - 1;
    while (at >= 0) {
      final i = b.instrs[at];
      final d = Ir.defs(i);
      if (d != null) after.remove(d);
      if (i.match(Call(_, _, _))) for (r in after.keys()) out.set(r, true);
      for (r in Ir.uses(i)) after.set(r, true);
      at -= 1;
    }
  }
  return out;
}

/** The most values live at any one point — the registers the function wants. */
function pressure(f:Func, live:Liveness):Int {
  var most = 0;
  for (b in f.walk()) {
    final after = copy(live.outOf(b.label));
    if (size(after) > most) most = size(after);
    var at = b.instrs.length - 1;
    while (at >= 0) {
      final i = b.instrs[at];
      final d = Ir.defs(i);
      if (d != null) after.remove(d);
      for (r in Ir.uses(i)) after.set(r, true);
      if (size(after) > most) most = size(after);
      at -= 1;
    }
    // At entry the phis are all written at once, so they are all live together.
    final entry = copy(live.into(b.label));
    for (phi in b.phis) entry.set(phi.dst, true);
    if (size(entry) > most) most = size(entry);
  }
  return most;
}
