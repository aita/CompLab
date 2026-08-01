// The three-address IR, and the control flow graph both IRs are written in.
//
// There are two instruction sets in this compiler.  This file has the first:
// three-address code over virtual registers, which is what lowering produces,
// what `ssa.ts` puts into SSA and what `opt.ts` rewrites.  The second is in
// `mach.ts`, and instruction selection replaces the arithmetic of this one with
// it.
//
// What they share is everything else — the registers, the blocks, the graph, the
// frame — so the passes that only care about the shape of a function (liveness,
// dominance, the register allocator, the verifiers) work on either, and neither
// has to know what the other's instructions mean.  That is what the methods on
// `Instr` are for: an instruction says which register it writes and which it
// reads, and nothing outside it has to ask what it is.
//
// Nothing here is ARM-specific except that a register holds exactly one 64-bit
// word, and the frame layout at the top, which the emitter and the nested
// functions have to agree about.

export type Reg = number;

/** How a register is written in a dump. */
export type Name = (r: Reg) => string;

/** How a register is renamed. */
export type Rewrite = (r: Reg) => Reg;

export const WORD = 8;

/**
 * How many arguments AAPCS64 passes in registers.  The rest go on the stack, and
 * the frame layout below knows where.
 */
export const ARGUMENT_REGISTERS = 8;

/**
 * Where a frame slot sits, relative to the frame pointer.
 *
 * Slot 0 of every nested function holds its static link, so a frame chain can be
 * walked without knowing whose frame it is.  Negative slots are the arguments the
 * caller had to pass on the stack: they are already in the frame, above the saved
 * frame record, so nothing has to be copied for them and they never take a
 * register at entry.
 */
export function slotOffset(slot: number): number {
  return slot < 0 ? 16 + WORD * (-slot - 1) : -WORD * (slot + 1);
}

// -- what every instruction of either set can be asked ------------------------

/**
 * The base of both instruction sets.
 *
 * A pass that walks a function asks these six questions and no others, which is
 * why one liveness analysis and one register allocator serve both levels.
 */
export abstract class Instr {
  /** The register it writes, if it writes one. */
  defs(): Reg | null { return null; }

  /**
   * The registers it reads.  A phi's arguments are read on the edges, not here,
   * so they are not among them.
   */
  uses(): Reg[] { return []; }

  /** Rewrite the registers it reads, in place. */
  mapUses(_f: Rewrite): void {}

  setDef(_r: Reg): void {
    throw new Error(`${this.constructor.name} defines nothing`);
  }

  /** True when it has to be kept even if its result is dead. */
  hasEffect(): boolean { return false; }

  show(_name: Name): string { return "?"; }
}

// -- the three-address instructions -------------------------------------------

export class Const extends Instr {
  dst: Reg;
  readonly value: bigint;
  constructor(dst: Reg, value: bigint) { super(); this.dst = dst; this.value = value; }
  override defs(): Reg { return this.dst; }
  override setDef(r: Reg): void { this.dst = r; }
  override show(name: Name): string { return `${name(this.dst)} = ${this.value}`; }
}

export class StrConst extends Instr {
  dst: Reg;
  readonly symbol: string;
  constructor(dst: Reg, symbol: string) { super(); this.dst = dst; this.symbol = symbol; }
  override defs(): Reg { return this.dst; }
  override setDef(r: Reg): void { this.dst = r; }
  override show(name: Name): string { return `${name(this.dst)} = &${this.symbol}`; }
}

export class Move extends Instr {
  dst: Reg;
  src: Reg;
  constructor(dst: Reg, src: Reg) { super(); this.dst = dst; this.src = src; }
  override defs(): Reg { return this.dst; }
  override uses(): Reg[] { return [this.src]; }
  override mapUses(f: Rewrite): void { this.src = f(this.src); }
  override setDef(r: Reg): void { this.dst = r; }
  override show(name: Name): string { return `${name(this.dst)} = ${name(this.src)}`; }
}

export class Bin extends Instr {
  dst: Reg;
  readonly op: string;
  lhs: Reg;
  rhs: Reg;
  constructor(dst: Reg, op: string, lhs: Reg, rhs: Reg) {
    super(); this.dst = dst; this.op = op; this.lhs = lhs; this.rhs = rhs;
  }
  override defs(): Reg { return this.dst; }
  override uses(): Reg[] { return [this.lhs, this.rhs]; }
  override mapUses(f: Rewrite): void { this.lhs = f(this.lhs); this.rhs = f(this.rhs); }
  override setDef(r: Reg): void { this.dst = r; }
  override show(name: Name): string {
    return `${name(this.dst)} = ${name(this.lhs)} ${this.op} ${name(this.rhs)}`;
  }
}

export class Cmp extends Instr {
  dst: Reg;
  readonly op: string;
  lhs: Reg;
  rhs: Reg;
  constructor(dst: Reg, op: string, lhs: Reg, rhs: Reg) {
    super(); this.dst = dst; this.op = op; this.lhs = lhs; this.rhs = rhs;
  }
  override defs(): Reg { return this.dst; }
  override uses(): Reg[] { return [this.lhs, this.rhs]; }
  override mapUses(f: Rewrite): void { this.lhs = f(this.lhs); this.rhs = f(this.rhs); }
  override setDef(r: Reg): void { this.dst = r; }
  override show(name: Name): string {
    return `${name(this.dst)} = ${name(this.lhs)} ${this.op} ${name(this.rhs)}`;
  }
}

export class Load extends Instr {
  dst: Reg;
  base: Reg;
  readonly offset: number;
  constructor(dst: Reg, base: Reg, offset: number) {
    super(); this.dst = dst; this.base = base; this.offset = offset;
  }
  override defs(): Reg { return this.dst; }
  override uses(): Reg[] { return [this.base]; }
  override mapUses(f: Rewrite): void { this.base = f(this.base); }
  override setDef(r: Reg): void { this.dst = r; }
  override show(name: Name): string {
    return `${name(this.dst)} = [${name(this.base)} + ${this.offset}]`;
  }
}

export class Store extends Instr {
  base: Reg;
  readonly offset: number;
  src: Reg;
  constructor(base: Reg, offset: number, src: Reg) {
    super(); this.base = base; this.offset = offset; this.src = src;
  }
  override uses(): Reg[] { return [this.base, this.src]; }
  override mapUses(f: Rewrite): void { this.base = f(this.base); this.src = f(this.src); }
  override hasEffect(): boolean { return true; }
  override show(name: Name): string {
    return `[${name(this.base)} + ${this.offset}] = ${name(this.src)}`;
  }
}

// -- the frame, calls and joins, which both instruction sets keep -------------

/** Read a frame slot of this function — an escaping variable, or a spill. */
export class LoadSlot extends Instr {
  dst: Reg;
  slot: number;
  constructor(dst: Reg, slot: number) { super(); this.dst = dst; this.slot = slot; }
  override defs(): Reg { return this.dst; }
  override setDef(r: Reg): void { this.dst = r; }
  override show(name: Name): string { return `${name(this.dst)} = slot${this.slot}`; }
}

export class StoreSlot extends Instr {
  slot: number;
  src: Reg;
  constructor(slot: number, src: Reg) { super(); this.slot = slot; this.src = src; }
  override uses(): Reg[] { return [this.src]; }
  override mapUses(f: Rewrite): void { this.src = f(this.src); }
  override hasEffect(): boolean { return true; }
  override show(name: Name): string { return `slot${this.slot} = ${name(this.src)}`; }
}

/** The frame pointer itself, which is what a static link points at. */
export class FrameAddr extends Instr {
  dst: Reg;
  constructor(dst: Reg) { super(); this.dst = dst; }
  override defs(): Reg { return this.dst; }
  override setDef(r: Reg): void { this.dst = r; }
  override show(name: Name): string { return `${name(this.dst)} = frame`; }
}

export class Call extends Instr {
  dst: Reg | null;
  readonly callee: string;
  args: Reg[];
  constructor(dst: Reg | null, callee: string, args: Reg[]) {
    super(); this.dst = dst; this.callee = callee; this.args = args;
  }
  override defs(): Reg | null { return this.dst; }
  override uses(): Reg[] { return [...this.args]; }
  override mapUses(f: Rewrite): void { this.args = this.args.map(f); }
  override setDef(r: Reg): void { this.dst = r; }
  override hasEffect(): boolean { return true; }
  override show(name: Name): string {
    const call = `${this.callee}(${this.args.map(name).join(", ")})`;
    return this.dst === null ? call : `${name(this.dst)} = ${call}`;
  }
}

export class Phi extends Instr {
  dst: Reg;
  /** A Map, because the order the arguments were placed in is what a dump prints. */
  args: Map<string, Reg>;
  constructor(dst: Reg, args: Map<string, Reg>) { super(); this.dst = dst; this.args = args; }
  override defs(): Reg { return this.dst; }
  override setDef(r: Reg): void { this.dst = r; }
  override show(name: Name): string {
    const parts = [...this.args].map(([pred, r]) => `${pred}: ${name(r)}`);
    return `${name(this.dst)} = phi [${parts.join(", ")}]`;
  }
}

// -- control flow -------------------------------------------------------------

export abstract class Terminator extends Instr {
  override hasEffect(): boolean { return true; }
}

export class Jmp extends Terminator {
  target: string;
  constructor(target: string) { super(); this.target = target; }
  override show(_name: Name): string { return `jmp ${this.target}`; }
}

export class CBr extends Terminator {
  cond: Reg;
  then: string;
  els: string;
  /**
   * After selection a branch may read the flags a comparison just set instead of
   * testing a register, and then it reads no register at all.
   */
  code: string;
  constructor(cond: Reg, then: string, els: string, code = "") {
    super(); this.cond = cond; this.then = then; this.els = els; this.code = code;
  }
  override uses(): Reg[] { return this.code !== "" ? [] : [this.cond]; }
  override mapUses(f: Rewrite): void { if (this.code === "") this.cond = f(this.cond); }
  override show(name: Name): string {
    const test = this.code !== "" ? `${this.code}?` : `${name(this.cond)} ?`;
    return `br ${test} ${this.then} : ${this.els}`;
  }
}

export class Ret extends Terminator {
  value: Reg | null;
  constructor(value: Reg | null) { super(); this.value = value; }
  override uses(): Reg[] { return this.value === null ? [] : [this.value]; }
  override mapUses(f: Rewrite): void { if (this.value !== null) this.value = f(this.value); }
  override show(name: Name): string {
    return this.value === null ? "ret" : `ret ${name(this.value)}`;
  }
}

// -- the graph ----------------------------------------------------------------

export class Block {
  readonly label: string;
  phis: Phi[] = [];
  instrs: Instr[] = [];
  preds: string[] = [];

  constructor(label: string) { this.label = label; }

  get terminator(): Terminator {
    if (this.instrs.length === 0) throw new Error(`block ${this.label} is unterminated`);
    const last = this.instrs[this.instrs.length - 1]!;
    if (!(last instanceof Terminator)) throw new Error(`block ${this.label} falls through`);
    return last;
  }

  get succs(): string[] {
    const t = this.terminator;
    if (t instanceof Jmp) return [t.target];
    if (t instanceof CBr) return t.then !== t.els ? [t.then, t.els] : [t.then];
    return [];
  }
}

/** One function: a frame, a set of parameters, and a graph of blocks. */
export class Func {
  readonly label: string;
  readonly name: string;
  readonly params: Reg[] = [];
  readonly depth: number;
  readonly entry = "entry";
  readonly blocks = new Map<string, Block>();
  order: string[] = [];
  nregs = 0;
  nslots = 0;
  staticLinkSlot = -1;
  colours = new Map<Reg, number>();
  readonly spillSlots = new Map<Reg, number>();
  saved: number[] = [];

  constructor(label: string, name: string, depth: number) {
    this.label = label; this.name = name; this.depth = depth;
  }

  newReg(): Reg { this.nregs += 1; return this.nregs - 1; }

  newSlot(): number { this.nslots += 1; return this.nslots - 1; }

  block(label: string): Block {
    const b = this.blocks.get(label);
    if (b === undefined) throw new Error(`no block ${label} in ${this.name}`);
    return b;
  }

  addBlock(label: string): Block {
    if (this.blocks.has(label)) throw new Error(`block ${label} already exists`);
    const b = new Block(label);
    this.blocks.set(label, b);
    this.order.push(label);
    return b;
  }

  /** Every block, in the order they were made. */
  walk(): Block[] { return this.order.map((label) => this.block(label)); }
}

/** A literal and the symbol it is emitted under, in the order first seen. */
export class Module {
  readonly funcs: Func[] = [];
  readonly strings = new Map<string, string>();
}

export function renameTarget(instr: Instr, old: string, fresh: string): void {
  if (instr instanceof Jmp) {
    if (instr.target === old) instr.target = fresh;
  } else if (instr instanceof CBr) {
    if (instr.then === old) instr.then = fresh;
    if (instr.els === old) instr.els = fresh;
  }
}

export function recomputePreds(f: Func): void {
  for (const b of f.blocks.values()) b.preds = [];
  for (const b of f.walk()) for (const s of b.succs) f.block(s).preds.push(b.label);
}

export function reachable(f: Func): Set<string> {
  const seen = new Set<string>();
  const stack = [f.entry];
  while (stack.length > 0) {
    const label = stack.pop()!;
    if (seen.has(label)) continue;
    seen.add(label);
    stack.push(...f.block(label).succs);
  }
  return seen;
}

export function dropUnreachable(f: Func): void {
  const live = reachable(f);
  for (const label of [...f.blocks.keys()]) if (!live.has(label)) f.blocks.delete(label);
  f.order = f.order.filter((label) => live.has(label));
  for (const b of f.walk()) {
    for (const phi of b.phis) {
      for (const pred of [...phi.args.keys()]) if (!live.has(pred)) phi.args.delete(pred);
    }
  }
  recomputePreds(f);
}

/** Reverse post-order, which is the order every dataflow pass walks in. */
export function rpo(f: Func): string[] {
  const order: string[] = [];
  const seen = new Set<string>();
  const stack: [string, boolean][] = [[f.entry, false]];
  while (stack.length > 0) {
    const [label, expanded] = stack.pop()!;
    if (expanded) { order.push(label); continue; }
    if (seen.has(label)) continue;
    seen.add(label);
    stack.push([label, true]);
    for (const s of [...f.block(label).succs].reverse()) {
      if (!seen.has(s)) stack.push([s, false]);
    }
  }
  return order.reverse();
}

// -- printing -----------------------------------------------------------------

export function regName(f: Func, r: Reg): string {
  const colour = f.colours.get(r);
  return colour === undefined ? `%${r}` : `%${r}:${colour}`;
}

export const naming = (f: Func): Name => (r: Reg) => regName(f, r);

export const showInstr = (f: Func, instr: Instr): string => instr.show(naming(f));

export function showFunc(f: Func): string {
  const out: string[] = [];
  const params = f.params.map((r) => regName(f, r)).join(", ");
  out.push(`fun ${f.label}(${params})  ; depth ${f.depth}, ${f.nslots} slots`);
  for (const b of f.walk()) {
    const preds = b.preds.length > 0 ? `  ; preds: ${b.preds.join(", ")}` : "";
    out.push(`${b.label}:${preds}`);
    for (const phi of b.phis) out.push(`    ${showInstr(f, phi)}`);
    for (const instr of b.instrs) out.push(`    ${showInstr(f, instr)}`);
  }
  return out.join("\n");
}

export function showModule(mod: Module): string {
  const parts = mod.funcs.map(showFunc);
  if (mod.strings.size > 0) {
    parts.push([...mod.strings].map(([sym, text]) => `${sym}: "${text}"`).join("\n"));
  }
  return parts.join("\n\n") + "\n";
}
