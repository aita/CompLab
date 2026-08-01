// Register allocation by graph colouring, with iterated coalescing.
//
// The idea is Chaitin's: build a graph whose nodes are values and whose edges join
// values that are live at the same time, then colour it with as many colours as the
// machine has registers.  Colouring a graph is hard in general, but Kempe's
// observation makes it practical: a node with fewer than K neighbours can always be
// coloured whatever happens to the rest of the graph.  So remove such nodes one at a
// time and push them on a stack; when the graph is empty, pop the stack and give
// each node a colour its neighbours have not taken.  If every remaining node has K
// or more neighbours, guess that one of them will not get a colour and carry on — if
// the guess was wrong the value is rewritten to live in memory and the whole thing
// runs again (Briggs' optimistic colouring).
//
// On top of that sits coalescing, which is why leaving SSA first costs nothing.
// Leaving SSA fills the predecessors of every join with copies; coalescing merges
// the two ends of a copy so that it disappears.  Merging aggressively can make a
// graph uncolourable, so a merge only happens when Briggs' test proves it cannot:
// the merged node must have fewer than K neighbours of significant degree.  That
// test is only exact enough to be useful if degrees are up to date, and simplifying
// lowers degrees while merging raises them — so the two run interleaved, with
// freezing (giving up on a copy so its nodes can be simplified) as the way out when
// neither applies.  Hence "iterated" (George and Appel, 1996).
//
// This machine has no fixed registers to colour against, so the calling convention
// is carried as a set of colours each node may not take: a value live across a call
// may not take a caller-saved one.  A node with `f` forbidden colours and `d`
// neighbours needs `d + f < K` to be trivially colourable, so that sum is what
// stands in for the degree everywhere below.

import * as ir from "./ir.ts";
import * as liveness from "./liveness.ts";
import { preferences } from "./hints.ts";
import { isCalleeSaved, type Registers } from "./registers.ts";
import { costs, OutOfRegisters, spill } from "./spill.ts";

const ascending = (a: number, b: number): number => a - b;
const sorted = (set: Set<number>): number[] => [...set].sort(ascending);

class Move {
  readonly dst: ir.Reg;
  readonly src: ir.Reg;
  constructor(dst: ir.Reg, src: ir.Reg) { this.dst = dst; this.src = src; }
}

class Colouring {
  private readonly fn: ir.Func;
  private readonly machine: Registers;
  /**
   * Values a previous round produced by reloading something.  Their live ranges
   * are a load and its one use, so spilling one again would only make another of
   * the same, and the rewriting would never end.
   */
  private readonly protected_: Set<ir.Reg>;

  private readonly adjacent = new Map<ir.Reg, Set<ir.Reg>>();
  private readonly degree = new Map<ir.Reg, number>();
  private readonly forbidden = new Map<ir.Reg, Set<number>>();
  private preferred = new Map<ir.Reg, number>();

  private readonly moves: Move[] = [];
  private readonly movesOf = new Map<ir.Reg, Set<number>>();
  private readonly worklistMoves = new Set<number>();
  private readonly activeMoves = new Set<number>();

  private readonly simplifyWorklist = new Set<ir.Reg>();
  private readonly freezeWorklist = new Set<ir.Reg>();
  private readonly spillWorklist = new Set<ir.Reg>();
  private readonly selectStack: ir.Reg[] = [];
  private readonly onStack = new Set<ir.Reg>();
  private readonly coalesced = new Set<ir.Reg>();
  private readonly alias = new Map<ir.Reg, ir.Reg>();
  readonly colour = new Map<ir.Reg, number>();

  constructor(fn: ir.Func, machine: Registers, protected_: Set<ir.Reg>) {
    this.fn = fn; this.machine = machine; this.protected_ = protected_;
  }

  private get k(): number { return this.machine.count(); }

  run(): Set<ir.Reg> {
    this.build();
    this.makeWorklists();
    while (
      this.simplifyWorklist.size > 0 || this.worklistMoves.size > 0
      || this.freezeWorklist.size > 0 || this.spillWorklist.size > 0
    ) {
      if (this.simplifyWorklist.size > 0) this.simplify();
      else if (this.worklistMoves.size > 0) this.coalesce();
      else if (this.freezeWorklist.size > 0) this.freeze();
      else this.selectSpill();
    }
    return this.assignColours();
  }

  // -- the graph ----------------------------------------------------------

  private node(r: ir.Reg): void {
    if (!this.adjacent.has(r)) {
      this.adjacent.set(r, new Set());
      this.degree.set(r, 0);
      this.forbidden.set(r, new Set());
    }
  }

  private addEdge(a: ir.Reg, b: ir.Reg): void {
    if (a === b || this.adjacent.get(a)!.has(b)) return;
    this.adjacent.get(a)!.add(b);
    this.adjacent.get(b)!.add(a);
    this.degree.set(a, this.degree.get(a)! + 1);
    this.degree.set(b, this.degree.get(b)! + 1);
  }

  /** The degree, counting a forbidden colour as a neighbour holding it. */
  private weight(r: ir.Reg): number {
    return this.degree.get(r)! + this.forbidden.get(r)!.size;
  }

  private build(): void {
    this.preferred = preferences(this.fn);
    const live = liveness.analyse(this.fn);
    const callerSaved = this.machine.caller;
    for (const b of this.fn.walk()) {
      for (const instr of b.instrs) {
        for (const r of instr.uses()) this.node(r);
        const d = instr.defs();
        if (d !== null) this.node(d);
      }
    }
    for (const r of this.fn.params) this.node(r);

    for (const b of this.fn.walk()) {
      const alive = new Set(live.out(b.label));
      for (let at = b.instrs.length - 1; at >= 0; at--) {
        const instr = b.instrs[at]!;
        if (instr instanceof ir.Move) {
          alive.delete(instr.src);
          const index = this.moves.length;
          this.moves.push(new Move(instr.dst, instr.src));
          this.noteMove(instr.dst, index);
          this.noteMove(instr.src, index);
          this.worklistMoves.add(index);
        }
        const defined = instr.defs();
        if (defined !== null) {
          alive.add(defined);
          for (const other of alive) this.addEdge(defined, other);
        }
        if (instr instanceof ir.Call) {
          for (const r of alive) {
            if (r === defined) continue;
            for (const colour of callerSaved) this.forbidden.get(r)!.add(colour);
          }
        }
        if (defined !== null) alive.delete(defined);
        for (const r of instr.uses()) alive.add(r);
      }
      if (b.label === this.fn.entry) this.entryEdges(alive);
    }
  }

  private noteMove(r: ir.Reg, index: number): void {
    let at = this.movesOf.get(r);
    if (at === undefined) { at = new Set(); this.movesOf.set(r, at); }
    at.add(index);
  }

  /** Parameters arrive together, so they interfere with each other. */
  private entryEdges(alive: Set<ir.Reg>): void {
    this.fn.params.forEach((param, at) => {
      for (const other of alive) this.addEdge(param, other);
      for (const another of this.fn.params.slice(at + 1)) this.addEdge(param, another);
    });
  }

  // -- the worklists ------------------------------------------------------

  private makeWorklists(): void {
    for (const r of sorted(new Set(this.adjacent.keys()))) {
      if (this.weight(r) >= this.k) this.spillWorklist.add(r);
      else if (this.moveRelated(r)) this.freezeWorklist.add(r);
      else this.simplifyWorklist.add(r);
    }
  }

  private nodeMoves(r: ir.Reg): Set<number> {
    const of = this.movesOf.get(r);
    if (of === undefined) return new Set();
    return new Set([...of].filter((i) => this.activeMoves.has(i) || this.worklistMoves.has(i)));
  }

  private moveRelated(r: ir.Reg): boolean { return this.nodeMoves(r).size > 0; }

  private neighbours(r: ir.Reg): Set<ir.Reg> {
    return new Set(
      [...this.adjacent.get(r)!].filter((o) => !this.onStack.has(o) && !this.coalesced.has(o)),
    );
  }

  private simplify(): void {
    const r = Math.min(...this.simplifyWorklist);
    this.simplifyWorklist.delete(r);
    this.selectStack.push(r);
    this.onStack.add(r);
    for (const other of sorted(this.neighbours(r))) this.decrementDegree(other);
  }

  private decrementDegree(r: ir.Reg): void {
    const was = this.weight(r);
    this.degree.set(r, this.degree.get(r)! - 1);
    if (was !== this.k) return;
    // It has just become trivially colourable, so the copies around it may have
    // become safe to merge as well.
    this.enableMoves(new Set([r, ...this.neighbours(r)]));
    this.spillWorklist.delete(r);
    if (this.moveRelated(r)) this.freezeWorklist.add(r);
    else this.simplifyWorklist.add(r);
  }

  private enableMoves(nodes: Set<ir.Reg>): void {
    for (const r of nodes) {
      for (const index of this.nodeMoves(r)) {
        if (this.activeMoves.delete(index)) this.worklistMoves.add(index);
      }
    }
  }

  // -- coalescing ---------------------------------------------------------

  private getAlias(start: ir.Reg): ir.Reg {
    let r = start;
    while (this.coalesced.has(r)) r = this.alias.get(r)!;
    return r;
  }

  private coalesce(): void {
    const index = Math.min(...this.worklistMoves);
    const move = this.moves[index]!;
    this.worklistMoves.delete(index);
    const u = this.getAlias(move.dst);
    const v = this.getAlias(move.src);
    if (u === v) {
      this.addToWorklist(u);
    } else if (this.adjacent.get(u)!.has(v)) {
      this.addToWorklist(u);
      this.addToWorklist(v);
    } else if (this.conservative(u, v)) {
      this.combine(u, v);
      this.addToWorklist(u);
    } else {
      this.activeMoves.add(index);
    }
  }

  private addToWorklist(r: ir.Reg): void {
    if (this.weight(r) < this.k && !this.moveRelated(r)) {
      this.freezeWorklist.delete(r);
      this.simplifyWorklist.add(r);
    }
  }

  /**
   * Briggs: the merged node must have fewer than K significant neighbours.  The
   * colours the two ends may not take add up as well, and a colour the merged node
   * is barred from is one more thing standing in its way.
   */
  private conservative(u: ir.Reg, v: ir.Reg): boolean {
    const together = new Set([...this.neighbours(u), ...this.neighbours(v)]);
    const barred = new Set([...this.forbidden.get(u)!, ...this.forbidden.get(v)!]).size;
    const significant = [...together].filter((r) => this.weight(r) >= this.k).length;
    return significant + barred < this.k;
  }

  private combine(u: ir.Reg, v: ir.Reg): void {
    this.freezeWorklist.delete(v);
    this.spillWorklist.delete(v);
    this.coalesced.add(v);
    this.alias.set(v, u);
    let of = this.movesOf.get(u);
    if (of === undefined) { of = new Set(); this.movesOf.set(u, of); }
    for (const index of this.movesOf.get(v) ?? []) of.add(index);
    for (const colour of this.forbidden.get(v)!) this.forbidden.get(u)!.add(colour);
    if (this.preferred.has(v) && !this.preferred.has(u)) {
      this.preferred.set(u, this.preferred.get(v)!);
    }
    this.enableMoves(new Set([v]));
    for (const other of sorted(this.neighbours(v))) {
      this.addEdge(other, u);
      this.decrementDegree(other);
    }
    if (this.weight(u) >= this.k && this.freezeWorklist.has(u)) {
      this.freezeWorklist.delete(u);
      this.spillWorklist.add(u);
    }
  }

  // -- freezing and spilling ----------------------------------------------

  private freeze(): void {
    const r = Math.min(...this.freezeWorklist);
    this.freezeWorklist.delete(r);
    this.simplifyWorklist.add(r);
    this.freezeMoves(r);
  }

  private freezeMoves(r: ir.Reg): void {
    for (const index of [...this.nodeMoves(r)]) {
      const move = this.moves[index]!;
      this.activeMoves.delete(index);
      this.worklistMoves.delete(index);
      const end = this.getAlias(move.dst) === this.getAlias(r) ? move.src : move.dst;
      const other = this.getAlias(end);
      if (!this.moveRelated(other) && this.weight(other) < this.k) {
        this.freezeWorklist.delete(other);
        this.simplifyWorklist.add(other);
      }
    }
  }

  /**
   * Guess that the value with the most neighbours per use will not fit.
   *
   * Never a reload, though: those are cheap by that measure precisely because they
   * were made cheap, and choosing one would undo the last round's work instead of
   * the pressure.
   */
  private selectSpill(): void {
    const weights = costs(this.fn);
    let among = sorted(this.spillWorklist).filter((r) => !this.protected_.has(r));
    if (among.length === 0) among = sorted(this.spillWorklist);
    const score = (r: ir.Reg): number => this.weight(r) / ((weights.get(r) ?? 0) + 1);
    let chosen = among[0]!;
    for (const r of among.slice(1)) if (score(r) > score(chosen)) chosen = r;
    this.spillWorklist.delete(chosen);
    this.simplifyWorklist.add(chosen);
    this.freezeMoves(chosen);
  }

  // -- handing out the colours --------------------------------------------

  private assignColours(): Set<ir.Reg> {
    const spilled = new Set<ir.Reg>();
    while (this.selectStack.length > 0) {
      const r = this.selectStack.pop()!;
      this.onStack.delete(r);
      const taken = new Set<number>();
      for (const other of this.adjacent.get(r)!) {
        const colour = this.colour.get(this.getAlias(other));
        if (colour !== undefined) taken.add(colour);
      }
      const free = this.machine.anywhere.filter(
        (c) => !taken.has(c) && !this.forbidden.get(r)!.has(c),
      );
      if (free.length === 0) { spilled.add(r); continue; }
      const want = this.preferred.get(r);
      this.colour.set(r, want !== undefined && free.includes(want) ? want : free[0]!);
    }
    for (const r of sorted(this.coalesced)) {
      this.colour.set(r, this.colour.get(this.getAlias(r)) ?? this.machine.anywhere[0]!);
    }
    return spilled;
  }
}

/** Colour `f`, rewriting and starting again for as long as it spills. */
export function allocate(f: ir.Func, machine: Registers): void {
  const protected_ = new Set<ir.Reg>();
  for (;;) {
    ir.recomputePreds(f);
    const colouring = new Colouring(f, machine, protected_);
    const spilled = colouring.run();
    if (spilled.size === 0) {
      f.colours = colouring.colour;
      f.saved = [...new Set(colouring.colour.values())].filter(isCalleeSaved)
        .sort(ascending);
      return;
    }
    for (const victim of sorted(spilled)) {
      if (protected_.has(victim)) {
        throw new OutOfRegisters(
          `\`${f.name}\` needs more registers at once than the machine has`,
        );
      }
      for (const r of spill(f, victim)) protected_.add(r);
    }
  }
}
