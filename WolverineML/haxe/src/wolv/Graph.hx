package wolv;

import wolv.Ir;
import wolv.Registers.Machine;

/* Register allocation by graph colouring, with iterated coalescing.
 *
 * The idea is Chaitin's: build a graph whose nodes are values and whose edges
 * join values that are live at the same time, then colour it with as many colours
 * as the machine has registers.  Colouring a graph is hard in general, but
 * Kempe's observation makes it practical: a node with fewer than K neighbours can
 * always be coloured whatever happens to the rest of the graph.  So remove such
 * nodes one at a time and push them on a stack; when the graph is empty, pop the
 * stack and give each node a colour its neighbours have not taken.  If every
 * remaining node has K or more neighbours, guess that one of them will not get a
 * colour and carry on — if the guess was wrong the value is rewritten to live in
 * memory and the whole thing runs again (Briggs' optimistic colouring).
 *
 * On top of that sits coalescing, which is why leaving SSA first costs nothing.
 * Leaving SSA fills the predecessors of every join with copies; coalescing merges
 * the two ends of a copy so that it disappears.  Merging aggressively can make a
 * graph uncolourable, so a merge only happens when Briggs' test proves it cannot:
 * the merged node must have fewer than K neighbours of significant degree.  That
 * test is only exact enough to be useful if degrees are up to date, and
 * simplifying lowers degrees while merging raises them — so the two run
 * interleaved, with freezing (giving up on a copy so its nodes can be simplified)
 * as the way out when neither applies.  Hence "iterated" (George and Appel, 1996).
 *
 * This machine has no fixed registers to colour against, so the calling
 * convention is carried as a set of colours each node may not take: a value live
 * across a call may not take a caller-saved one.  A node with `f` forbidden
 * colours and `d` neighbours needs `d + f < K` to be trivially colourable, so that
 * sum is what stands in for the degree everywhere below. */

/** A copy coalescing may be able to make disappear. */
private class Copy {
  public final dst:Reg;
  public final src:Reg;

  public function new(dst:Reg, src:Reg) {
    this.dst = dst;
    this.src = src;
  }
}

/** Colour `f`, rewriting and starting again for as long as it spills. */
function allocate(f:Func, machine:Machine):Void {
  var protectedRegs = new IntSet();
  while (true) {
    Ir.recomputePreds(f);
    final c = new Colouring(f, machine, protectedRegs);
    final spilled = c.run();
    if (spilled.isEmpty()) {
      f.colours = c.colours();
      final saved = new IntSet();
      for (colour in f.colours) if (Registers.isCalleeSaved(colour)) saved.add(colour);
      f.saved = saved.ordered();
      return;
    }
    for (victim in spilled.ordered()) {
      if (protectedRegs.has(victim)) {
        throw new Spill.OutOfRegisters(
          '`${f.name}` needs more registers at once than the machine has');
      }
      protectedRegs = protectedRegs.union(Spill.spill(f, victim));
    }
  }
}

private class Colouring {
  final fn:Func;
  final machine:Machine;

  /**
   * Values a previous round produced by reloading something.  Their live ranges
   * are a load and its one use, so spilling one again would only make another of
   * the same, and the rewriting would never end.
   */
  final protectedRegs:IntSet;

  final adjacent = new Map<Reg, IntSet>();
  final degrees = new Map<Reg, Int>();
  final forbidden = new Map<Reg, IntSet>();
  var preferred = new Map<Reg, Int>();

  var moves:Array<Copy> = [];
  final movesOf = new Map<Reg, IntSet>();
  var worklistMoves = new IntSet();
  var activeMoves = new IntSet();

  var simplifyWorklist = new IntSet();
  var freezeWorklist = new IntSet();
  var spillWorklist = new IntSet();

  final selectStack:Array<Reg> = [];
  final onStack = new IntSet();
  final coalesced = new IntSet();
  final alias = new Map<Reg, Reg>();
  final colour = new Map<Reg, Int>();

  public function new(fn:Func, machine:Machine, protectedRegs:IntSet) {
    this.fn = fn;
    this.machine = machine;
    this.protectedRegs = protectedRegs;
  }

  public function colours():Map<Reg, Int> return colour;

  inline function k():Int return machine.count();

  function neighboursOf(r:Reg):IntSet {
    final a = adjacent.get(r);
    return a == null ? new IntSet() : a;
  }

  function degree(r:Reg):Int return degrees.exists(r) ? degrees.get(r) : 0;

  function barred(r:Reg):IntSet {
    final s = forbidden.get(r);
    return s == null ? new IntSet() : s;
  }

  /** The degree, counting a forbidden colour as a neighbour holding it. */
  function weight(r:Reg):Int return degree(r) + barred(r).size();

  function node(r:Reg):Void {
    if (adjacent.exists(r)) return;
    adjacent.set(r, new IntSet());
    degrees.set(r, 0);
    forbidden.set(r, new IntSet());
  }

  function addEdge(a:Reg, b:Reg):Void {
    if (a == b || neighboursOf(a).has(b)) return;
    node(a);
    node(b);
    adjacent.get(a).add(b);
    adjacent.get(b).add(a);
    degrees.set(a, degree(a) + 1);
    degrees.set(b, degree(b) + 1);
  }

  function noteMove(r:Reg, index:Int):Void {
    if (!movesOf.exists(r)) movesOf.set(r, new IntSet());
    movesOf.get(r).add(index);
  }

  /** Parameters arrive together, so they interfere with each other. */
  function entryEdges(alive:IntSet):Void {
    final params = fn.params;
    for (at in 0...params.length) {
      for (other in alive.ordered()) addEdge(params[at], other);
      for (otherAt in (at + 1)...params.length) addEdge(params[at], params[otherAt]);
    }
  }

  function build():Void {
    preferred = Hints.preferences(fn);
    final live = Liveness.analyse(fn);
    final caller = IntSet.of(machine.caller);

    for (b in fn.walk()) {
      for (i in b.instrs) {
        for (r in Ir.uses(i)) node(r);
        final d = Ir.defs(i);
        if (d != null) node(d);
      }
    }
    for (p in fn.params) node(p);

    for (b in fn.walk()) {
      final alive = new IntSet();
      for (r in live.outOf(b.label).keys()) alive.add(r);
      var at = b.instrs.length - 1;
      while (at >= 0) {
        final i = b.instrs[at];
        switch i {
          case Move(dst, src):
            alive.remove(src);
            final index = moves.length;
            moves.push(new Copy(dst, src));
            noteMove(dst, index);
            noteMove(src, index);
            worklistMoves.add(index);
          case _:
        }
        final defined = Ir.defs(i);
        if (defined != null) {
          alive.add(defined);
          for (other in alive.ordered()) addEdge(defined, other);
        }
        if (i.match(Call(_, _, _))) {
          for (r in alive.ordered()) {
            if (r != defined) forbidden.set(r, barred(r).union(caller));
          }
        }
        if (defined != null) alive.remove(defined);
        alive.addAll(Ir.uses(i));
        at -= 1;
      }
      if (b.label == fn.entry) entryEdges(alive);
    }
  }

  /* -- the worklists -------------------------------------------------------- */

  function nodeMoves(r:Reg):IntSet {
    final of = movesOf.get(r);
    return of == null ? new IntSet() : of.inter(activeMoves.union(worklistMoves));
  }

  function moveRelated(r:Reg):Bool return !nodeMoves(r).isEmpty();

  function free(r:Reg):IntSet return neighboursOf(r).diff(onStack).diff(coalesced);

  function makeWorklists():Void {
    final all = [for (r in adjacent.keys()) r];
    all.sort((a, b) -> a - b);
    for (r in all) {
      if (weight(r) >= k()) spillWorklist.add(r);
      else if (moveRelated(r)) freezeWorklist.add(r);
      else simplifyWorklist.add(r);
    }
  }

  function enableMoves(nodes:IntSet):Void {
    for (r in nodes.ordered()) {
      for (index in nodeMoves(r).ordered()) {
        if (activeMoves.has(index)) {
          activeMoves.remove(index);
          worklistMoves.add(index);
        }
      }
    }
  }

  function decrementDegree(r:Reg):Void {
    final was = weight(r);
    degrees.set(r, degree(r) - 1);
    if (was != k()) return;
    // It has just become trivially colourable, so the copies around it may have
    // become safe to merge as well.
    enableMoves(free(r).copy().add(r));
    spillWorklist.remove(r);
    if (moveRelated(r)) freezeWorklist.add(r) else simplifyWorklist.add(r);
  }

  function simplify():Void {
    final r = simplifyWorklist.least();
    simplifyWorklist.remove(r);
    selectStack.unshift(r);
    onStack.add(r);
    for (other in free(r).ordered()) decrementDegree(other);
  }

  /* -- coalescing ----------------------------------------------------------- */

  function aliasOf(r:Reg):Reg {
    var at = r;
    while (coalesced.has(at)) at = alias.get(at);
    return at;
  }

  function addToWorklist(r:Reg):Void {
    if (weight(r) < k() && !moveRelated(r)) {
      freezeWorklist.remove(r);
      simplifyWorklist.add(r);
    }
  }

  /**
   * Briggs' test: the merged node must have fewer than K significant neighbours.
   * The colours the two ends may not take add up as well, and a colour the merged
   * node is barred from is one more thing standing in its way.
   */
  function conservative(u:Reg, v:Reg):Bool {
    final together = free(u).union(free(v));
    final bars = barred(u).union(barred(v)).size();
    var significant = 0;
    for (r in together.ordered()) if (weight(r) >= k()) significant += 1;
    return significant + bars < k();
  }

  function combine(u:Reg, v:Reg):Void {
    freezeWorklist.remove(v);
    spillWorklist.remove(v);
    coalesced.add(v);
    alias.set(v, u);
    final ofU = movesOf.exists(u) ? movesOf.get(u) : new IntSet();
    final ofV = movesOf.exists(v) ? movesOf.get(v) : new IntSet();
    movesOf.set(u, ofU.union(ofV));
    forbidden.set(u, barred(u).union(barred(v)));
    if (preferred.exists(v) && !preferred.exists(u)) preferred.set(u, preferred.get(v));
    enableMoves(new IntSet().add(v));
    for (other in free(v).ordered()) {
      addEdge(other, u);
      decrementDegree(other);
    }
    if (weight(u) >= k() && freezeWorklist.has(u)) {
      freezeWorklist.remove(u);
      spillWorklist.add(u);
    }
  }

  function coalesce():Void {
    final index = worklistMoves.least();
    final m = moves[index];
    worklistMoves.remove(index);
    final u = aliasOf(m.dst);
    final v = aliasOf(m.src);
    if (u == v) {
      addToWorklist(u);
    } else if (neighboursOf(u).has(v)) {
      addToWorklist(u);
      addToWorklist(v);
    } else if (conservative(u, v)) {
      combine(u, v);
      addToWorklist(u);
    } else {
      activeMoves.add(index);
    }
  }

  /* -- freezing and spilling ------------------------------------------------- */

  function freezeMoves(r:Reg):Void {
    for (index in nodeMoves(r).ordered()) {
      final m = moves[index];
      activeMoves.remove(index);
      worklistMoves.remove(index);
      final end = aliasOf(m.dst) == aliasOf(r) ? m.src : m.dst;
      final other = aliasOf(end);
      if (!moveRelated(other) && weight(other) < k()) {
        freezeWorklist.remove(other);
        simplifyWorklist.add(other);
      }
    }
  }

  function freeze():Void {
    final r = freezeWorklist.least();
    freezeWorklist.remove(r);
    simplifyWorklist.add(r);
    freezeMoves(r);
  }

  /**
   * Guess that the value with the most neighbours per use will not fit.
   *
   * Never a reload, though: those are cheap by that measure precisely because
   * they were made cheap, and choosing one would undo the last round's work
   * instead of the pressure.
   */
  function selectSpill():Void {
    final weights = Spill.costs(fn);
    var among = spillWorklist.diff(protectedRegs);
    if (among.isEmpty()) among = spillWorklist;
    inline function score(r:Reg):Float {
      return weight(r) / ((weights.exists(r) ? weights.get(r) : 0.0) + 1.0);
    }
    var chosen:Null<Reg> = null;
    for (r in among.ordered()) if (chosen == null || score(r) > score(chosen)) chosen = r;
    spillWorklist.remove(chosen);
    simplifyWorklist.add(chosen);
    freezeMoves(chosen);
  }

  /* -- handing out the colours ----------------------------------------------- */

  function assignColours():IntSet {
    final spilled = new IntSet();
    while (selectStack.length > 0) {
      final r = selectStack.shift();
      onStack.remove(r);
      final taken = new IntSet();
      for (other in neighboursOf(r).ordered()) {
        final c = colour.get(aliasOf(other));
        if (c != null) taken.add(c);
      }
      final available = machine.anywhere().filter(c -> !taken.has(c) && !barred(r).has(c));
      if (available.length == 0) {
        spilled.add(r);
        continue;
      }
      final want = preferred.get(r);
      colour.set(r, want != null && available.contains(want) ? want : available[0]);
    }
    for (r in coalesced.ordered()) {
      final c = colour.get(aliasOf(r));
      colour.set(r, c != null ? c : machine.anywhere()[0]);
    }
    return spilled;
  }

  public function run():IntSet {
    build();
    makeWorklists();
    while (true) {
      if (!simplifyWorklist.isEmpty()) simplify();
      else if (!worklistMoves.isEmpty()) coalesce();
      else if (!freezeWorklist.isEmpty()) freeze();
      else if (!spillWorklist.isEmpty()) selectSpill();
      else break;
    }
    return assignColours();
  }
}
