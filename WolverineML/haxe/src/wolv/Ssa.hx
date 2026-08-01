package wolv;

import haxe.Int64;
import wolv.Ir;

/* SSA construction, the textbook way.
 *
 * Dominators by the iterative algorithm of Cooper, Harvey and Kennedy, dominance
 * frontiers from those, phis at the frontiers of every definition, and then one
 * walk of the dominator tree renaming as it goes.  This is minimal SSA and
 * nothing cleverer: a phi is placed wherever the frontier says, whether or not
 * the variable is live there, and the dead ones leave in `Opt.deadCode`.
 *
 * Only registers written more than once take part.  Everything lowering produced
 * once — a temporary — is already in SSA and is left with the name it has.
 *
 * Haxe's `Map` has no order, and the order phis are placed in is the order a dump
 * prints them in, so every set this pass walks is sorted before it is walked.
 * `sortedLabels` and `sortedRegs` are where that happens, and they are not
 * decoration: leave one out and the dump moves. */

function sortedLabels(set:Map<String, Bool>):Array<String> {
  final out = [for (k in set.keys()) k];
  out.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
  return out;
}

function sortedRegs(set:Map<Reg, Bool>):Array<Reg> {
  final out = [for (k in set.keys()) k];
  out.sort((a, b) -> a - b);
  return out;
}

class Dominance {
  public final idom = new Map<String, String>();
  public final children = new Map<String, Array<String>>();
  public final frontier = new Map<String, Map<String, Bool>>();
  public var order:Array<String> = [];

  public function new() {}

  public function dominates(a:String, b:String):Bool {
    var at = b;
    while (true) {
      if (a == at) return true;
      final parent = idom.get(at);
      if (parent == null || parent == at) return false;
      at = parent;
    }
  }
}

function dominance(f:Func):Dominance {
  final d = new Dominance();
  d.order = Ir.rpo(f);

  final rank = new Map<String, Int>();
  for (at in 0...d.order.length) rank.set(d.order[at], at);

  d.idom.set(f.entry, f.entry);

  function intersect(a:String, b:String):String {
    while (a != b) {
      while (rank.get(a) > rank.get(b)) a = d.idom.get(a);
      while (rank.get(b) > rank.get(a)) b = d.idom.get(b);
    }
    return a;
  }

  var changed = true;
  while (changed) {
    changed = false;
    for (at in 1...d.order.length) {
      final label = d.order[at];
      final preds = f.block(label).preds.filter(d.idom.exists);
      if (preds.length == 0) continue;
      var next = preds[0];
      for (i in 1...preds.length) next = intersect(preds[i], next);
      if (d.idom.get(label) != next) {
        d.idom.set(label, next);
        changed = true;
      }
    }
  }

  for (label in d.order) {
    d.children.set(label, []);
    d.frontier.set(label, new Map());
  }
  for (label in d.order) {
    final parent = d.idom.get(label);
    if (parent != label) d.children.get(parent).push(label);
  }

  for (label in d.order) {
    final b = f.block(label);
    if (b.preds.length < 2) continue;
    for (pred in b.preds) {
      var runner = pred;
      while (runner != d.idom.get(label)) {
        if (!d.idom.exists(runner)) break;
        d.frontier.get(runner).set(label, true);
        runner = d.idom.get(runner);
      }
    }
  }
  return d;
}

/**
 * Where each register is written, and how often.
 *
 * A register written twice in one block is as much a variable as one written in
 * two blocks, so the count is what decides, and the blocks are what the frontier
 * walk needs.
 */
private class Defs {
  public final sites = new Map<Reg, Map<String, Bool>>();
  public final count = new Map<Reg, Int>();

  public function new() {}

  public function record(r:Reg, label:String):Void {
    if (!sites.exists(r)) sites.set(r, new Map());
    sites.get(r).set(label, true);
    count.set(r, (count.exists(r) ? count.get(r) : 0) + 1);
  }

  /** The registers written more than once. */
  public function variables():Map<Reg, Bool> {
    final out = new Map<Reg, Bool>();
    for (r => n in count) if (n > 1) out.set(r, true);
    return out;
  }
}

private function definitions(f:Func):Defs {
  final d = new Defs();
  for (b in f.walk()) {
    for (i in b.instrs) {
      final r = Ir.defs(i);
      if (r != null) d.record(r, b.label);
    }
  }
  for (p in f.params) d.record(p, f.entry);
  return d;
}

/** Put a phi for each variable at every dominance frontier of a block defining it. */
private function placePhis(f:Func, dom:Dominance, d:Defs):Map<String, Array<Reg>> {
  final phiVars = new Map<String, Array<Reg>>();
  for (label in f.order) phiVars.set(label, []);
  for (v in sortedRegs(d.variables())) {
    final sites = d.sites.get(v);
    final placed = new Map<String, Bool>();
    // A stack whose initial contents are the defining blocks in ascending order,
    // taken from the top.
    final work = sortedLabels(sites);
    work.reverse();
    while (work.length > 0) {
      final b = work.shift();
      for (target in sortedLabels(dom.frontier.get(b))) {
        if (placed.exists(target)) continue;
        placed.set(target, true);
        phiVars.get(target).push(v);
        final block = f.block(target);
        block.phis.push(new Phi(v, block.preds.map(pred -> new PhiArg(pred, v))));
        if (!sites.exists(target)) work.unshift(target);
      }
    }
  }
  return phiVars;
}

private class Renamer {
  final fn:Func;
  final dom:Dominance;
  final phiVars:Map<String, Array<Reg>>;
  final vars:Map<Reg, Bool>;
  final stacks = new Map<Reg, Array<Reg>>();
  final undefined = new Map<Reg, Reg>();
  final undefOrder:Array<Reg> = [];

  public function new(fn:Func, dom:Dominance, phiVars:Map<String, Array<Reg>>,
      vars:Map<Reg, Bool>) {
    this.fn = fn;
    this.dom = dom;
    this.phiVars = phiVars;
    this.vars = vars;
  }

  /** A variable read on a path that never wrote it reads zero. */
  function undef(v:Reg):Reg {
    if (undefined.exists(v)) return undefined.get(v);
    final fresh = fn.newReg();
    undefined.set(v, fresh);
    undefOrder.push(v);
    return fresh;
  }

  function top(v:Reg):Reg {
    final stack = stacks.get(v);
    return stack == null || stack.length == 0 ? undef(v) : stack[0];
  }

  function rename(v:Reg):Reg {
    final fresh = fn.newReg();
    if (!stacks.exists(v)) stacks.set(v, []);
    stacks.get(v).unshift(fresh);
    return fresh;
  }

  function use(r:Reg):Reg {
    return vars.exists(r) ? top(r) : r;
  }

  function renameBlock(label:String):Array<Reg> {
    final b = fn.block(label);
    final mine:Array<Reg> = [];
    final here = phiVars.get(label);
    for (at in 0...b.phis.length) {
      final v = here[at];
      b.phis[at].dst = rename(v);
      mine.push(v);
    }
    for (at in 0...b.instrs.length) {
      var i = Ir.mapUses(b.instrs[at], use);
      final d = Ir.defs(i);
      if (d != null && vars.exists(d)) {
        i = Ir.withDef(i, rename(d));
        mine.push(d);
      }
      b.instrs[at] = i;
    }
    for (succ in b.succs()) {
      final target = fn.block(succ);
      final theirs = phiVars.get(succ);
      for (at in 0...target.phis.length) target.phis[at].setArg(label, top(theirs[at]));
    }
    return mine;
  }

  public function walkDominators(label:String):Void {
    final mine = renameBlock(label);
    for (child in dom.children.get(label)) walkDominators(child);
    for (v in mine) {
      final stack = stacks.get(v);
      if (stack != null && stack.length > 0) stack.shift();
    }
  }

  public function plantUndefined():Void {
    final entry = fn.block(fn.entry);
    for (v in undefOrder) entry.instrs.unshift(Const(undefined.get(v), Int64.ofInt(0)));
  }

  public function renameParams():Void {
    for (at in 0...fn.params.length) {
      if (vars.exists(fn.params[at])) fn.params[at] = rename(fn.params[at]);
    }
  }
}

/** Rewrite one function into SSA, in place. */
function construct(f:Func):Void {
  Ir.recomputePreds(f);
  final dom = dominance(f);
  final d = definitions(f);
  final phiVars = placePhis(f, dom, d);
  final r = new Renamer(f, dom, phiVars, d.variables());
  r.renameParams();
  r.walkDominators(f.entry);
  r.plantUndefined();
}

function constructModule(m:Module):Void {
  for (f in m.funcs) construct(f);
}

/**
 * Give every phi a place to put its copy in.
 *
 * An edge from a block with several successors into a block with several
 * predecessors has nowhere to hold the copies a phi turns into, so it gets a
 * block of its own.  The same goes for any edge into a block that still has a
 * phi, so that the emitter only ever has to put copies before a `jmp`.
 */
function splitCriticalEdges(f:Func):Void {
  for (label in f.order.copy()) {
    final b = f.block(label);
    final succs = b.succs();
    if (succs.length < 2) continue;
    for (succ in succs) {
      final target = f.block(succ);
      if (target.preds.length < 2 && target.phis.length == 0) continue;
      final split = f.addBlock('$label.$succ');
      split.instrs.push(Jmp(succ));
      final last = b.instrs.length - 1;
      b.instrs[last] = Ir.renameTarget(b.instrs[last], succ, split.label);
      for (phi in target.phis) {
        final arg = phi.removeArg(label);
        if (arg != null) phi.setArg(split.label, arg);
      }
    }
  }
  Ir.recomputePreds(f);
}

/** Check what SSA promises: one definition per register, and it dominates. */
function verify(f:Func):Void {
  final dom = dominance(f);
  final definition = new Map<Reg, String>();

  function claim(r:Reg, label:String):Void {
    if (definition.exists(r)) throw '%$r defined twice';
    definition.set(r, label);
  }

  for (b in f.walk()) {
    for (phi in b.phis) claim(phi.dst, b.label);
    for (i in b.instrs) {
      final d = Ir.defs(i);
      if (d != null) claim(d, b.label);
    }
  }
  for (p in f.params) if (!definition.exists(p)) definition.set(p, f.entry);

  function where(r:Reg):String {
    final label = definition.get(r);
    if (label == null) throw '%$r is never defined';
    return label;
  }

  for (b in f.walk()) {
    for (phi in b.phis) {
      final named = phi.preds().copy();
      final preds = b.preds.copy();
      named.sort((x, y) -> x < y ? -1 : (x > y ? 1 : 0));
      preds.sort((x, y) -> x < y ? -1 : (x > y ? 1 : 0));
      if (named.join(",") != preds.join(",")) {
        throw 'phi in ${b.label} names ${named.join(",")}, preds are ${preds.join(",")}';
      }
      for (a in phi.args) {
        if (!dom.dominates(where(a.arg), a.pred)) {
          throw '%${a.arg} does not reach ${b.label} through ${a.pred}';
        }
      }
    }
    for (i in b.instrs) {
      for (r in Ir.uses(i)) {
        if (!dom.dominates(where(r), b.label)) {
          throw '%$r does not dominate its use in ${b.label}';
        }
      }
    }
  }
}
