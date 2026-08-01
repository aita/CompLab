package wolv;

import wolv.Ir;

/* Spilling.
 *
 * A spilled value gets a frame slot, a store after every definition of it and a
 * reload in front of every use.  The reloads are new registers, live from the
 * load to the instruction under it and nowhere else, which is what makes the
 * pressure come down.  Nothing here assumes SSA: a value written twice gets two
 * stores, and a phi argument is reloaded at the end of the predecessor it comes
 * from, so the same rewrite would serve a walk of the dominator tree as well as
 * the graph. */

/** Raised when spilling cannot help either. */
class OutOfRegisters {
  public final detail:String;

  public function new(detail:String) {
    this.detail = detail;
  }

  public function toString():String return detail;
}

/**
 * How deeply each block is nested in loops, for weighing what a use costs.
 *
 * A back edge is an edge into a block that dominates its source; everything that
 * can reach the source without leaving the dominated region is in that loop.
 */
function loopDepth(f:Func):Map<String, Int> {
  final dom = Ssa.dominance(f);
  final depth = new Map<String, Int>();
  for (label in f.order) depth.set(label, 0);
  for (b in f.walk()) {
    for (succ in b.succs()) {
      if (!dom.dominates(succ, b.label)) continue;
      final body = new Map<String, Bool>();
      body.set(succ, true);
      final stack = [b.label];
      while (stack.length > 0) {
        final label = stack.shift();
        if (body.exists(label)) continue;
        body.set(label, true);
        for (pred in f.block(label).preds) stack.unshift(pred);
      }
      for (label in body.keys()) depth.set(label, depth.get(label) + 1);
    }
  }
  return depth;
}

/** What spilling a value would cost: its reads and writes, weighed by loops. */
function costs(f:Func):Map<Reg, Float> {
  final depth = loopDepth(f);
  inline function scaleOf(label:String):Float {
    final d = depth.get(label);
    return Math.pow(10, d < 4 ? d : 4);
  }
  final weight = new Map<Reg, Float>();
  inline function add(r:Reg, amount:Float):Void {
    weight.set(r, (weight.exists(r) ? weight.get(r) : 0.0) + amount);
  }
  for (b in f.walk()) {
    final scale = scaleOf(b.label);
    for (phi in b.phis) {
      for (a in phi.args) add(a.arg, scaleOf(a.pred));
      add(phi.dst, scale);
    }
    for (i in b.instrs) {
      for (r in Ir.uses(i)) add(r, scale);
      final d = Ir.defs(i);
      if (d != null) add(d, scale);
    }
  }
  return weight;
}

private function insertBeforeLast(b:Block, i:Instr):Void {
  final at = b.instrs.length - 1;
  b.instrs = b.instrs.slice(0, at).concat([i]).concat(b.instrs.slice(at));
}

/** Give `victim` a frame slot, and return the reloads that replaced it. */
function spill(f:Func, victim:Reg):IntSet {
  final slot = f.newSlot();
  f.spillSlots.set(victim, slot);
  final isParam = f.params.contains(victim);
  final reloads = new IntSet();

  for (b in f.walk()) {
    var definesIt = false;
    for (phi in b.phis) if (phi.dst == victim) definesIt = true;
    if (definesIt) b.instrs.unshift(StoreSlot(slot, victim));
    if (isParam && b.label == f.entry) b.instrs.unshift(StoreSlot(slot, victim));

    final rebuilt:Array<Instr> = [];
    for (i in b.instrs) {
      final spillStore = switch i {
        case StoreSlot(s, _): s == slot;
        case _: false;
      };
      var here = i;
      if (Ir.uses(i).contains(victim) && !spillStore) {
        final fresh = f.newReg();
        reloads.add(fresh);
        here = Ir.mapUses(i, r -> r == victim ? fresh : r);
        rebuilt.push(LoadSlot(fresh, slot));
      }
      rebuilt.push(here);
      if (Ir.defs(i) == victim) rebuilt.push(StoreSlot(slot, victim));
    }
    b.instrs = rebuilt;
  }

  for (b in f.walk()) {
    for (phi in b.phis) {
      for (a in phi.args) {
        if (a.arg != victim) continue;
        final fresh = f.newReg();
        reloads.add(fresh);
        insertBeforeLast(f.block(a.pred), LoadSlot(fresh, slot));
        a.arg = fresh;
      }
    }
  }
  return reloads;
}
