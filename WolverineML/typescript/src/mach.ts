// The machine IR: what instruction selection replaces the arithmetic with.
//
// One class, because on this machine an instruction is a form, a register it
// writes and some it reads.  The form names an entry in the table below, and the
// table is the whole instruction set the compiler can choose from.
//
// The machine IR is this plus the part of `ir.ts` that was already machine-level:
// a call, a move, a frame slot, a phi and the three terminators.  What it may no
// longer contain is the arithmetic — `Const`, `Bin`, `Cmp`, `Load`, `Store`,
// `StrConst` — and `verify` is what says so, because a compiler that quietly kept
// an abstract instruction until the emitter would only find out there.
//
// Four forms are not one instruction each, and the emitter expands them:
//
//     const   a constant, which is a `mov` or up to four `movz`/`movk`
//     adr     the address of a string, which is `adrp` and an `add`
//     ldr     a load, whose addressing mode depends on how far the offset reaches
//     str     a store, likewise

import * as ir from "./ir.ts";

/**
 * How each form is written down, once the registers have their colours.  `d` is
 * the register written and `s0`, `s1`, `s2` the ones read.
 */
export const FORMS = new Map<string, string>([
  ["add", "add {d}, {s0}, {s1}"],
  ["addi", "add {d}, {s0}, #{imm}"],
  ["adds", "add {d}, {s0}, {s1}, lsl #{imm}"],
  ["sub", "sub {d}, {s0}, {s1}"],
  ["subi", "sub {d}, {s0}, #{imm}"],
  ["subs", "sub {d}, {s0}, {s1}, lsl #{imm}"],
  ["mul", "mul {d}, {s0}, {s1}"],
  ["madd", "madd {d}, {s0}, {s1}, {s2}"],
  ["msub", "msub {d}, {s0}, {s1}, {s2}"],
  ["sdiv", "sdiv {d}, {s0}, {s1}"],
  ["and", "and {d}, {s0}, {s1}"],
  ["orr", "orr {d}, {s0}, {s1}"],
  ["eor", "eor {d}, {s0}, {s1}"],
  ["eori", "eor {d}, {s0}, #{imm}"],
  ["lsl", "lsl {d}, {s0}, {s1}"],
  ["lsli", "lsl {d}, {s0}, #{imm}"],
  ["asr", "asr {d}, {s0}, {s1}"],
  ["asri", "asr {d}, {s0}, #{imm}"],
  ["cmp", "cmp {s0}, {s1}"],
  ["cmpi", "cmp {s0}, #{imm}"],
  ["cset", "cset {d}, {sym}"],
]);

/**
 * Which condition code each comparison sets, and which one says the opposite —
 * the emitter needs the opposite when the branch it is writing falls through to
 * the block the comparison was true for.
 */
export const CONDITION = new Map<string, string>([
  ["=", "eq"], ["<>", "ne"], ["<", "lt"], ["<=", "le"],
  [">", "gt"], [">=", "ge"], ["u<", "lo"], ["u>=", "hs"],
]);

export const OPPOSITE = new Map<string, string>([
  ["eq", "ne"], ["ne", "eq"], ["lt", "ge"], ["ge", "lt"],
  ["gt", "le"], ["le", "gt"], ["lo", "hs"], ["hs", "lo"],
]);

/** The ones the emitter writes itself, because they are not one instruction. */
export const EXPANDED = new Set(["const", "adr", "ldr", "str"]);

export class Mach extends ir.Instr {
  readonly form: string;
  dst: ir.Reg | null;
  srcs: ir.Reg[];
  readonly imm: bigint;
  readonly symbol: string;
  readonly effect: boolean;

  constructor(
    form: string, dst: ir.Reg | null, srcs: ir.Reg[],
    imm = 0n, symbol = "", effect = false,
  ) {
    super();
    this.form = form; this.dst = dst; this.srcs = srcs;
    this.imm = imm; this.symbol = symbol; this.effect = effect;
  }

  override defs(): ir.Reg | null { return this.dst; }
  override uses(): ir.Reg[] { return [...this.srcs]; }
  override mapUses(f: ir.Rewrite): void { this.srcs = this.srcs.map(f); }
  override setDef(r: ir.Reg): void { this.dst = r; }
  override hasEffect(): boolean { return this.effect; }

  override show(name: ir.Name): string {
    const operands = this.srcs.map(name);
    if (this.symbol !== "") operands.push(this.symbol);
    else if (this.imm !== 0n || this.form === "const") operands.push(`#${this.imm}`);
    const written = `${this.form} ${operands.join(", ")}`.trimEnd();
    return this.dst === null ? written : `${name(this.dst)} = ${written}`;
  }
}

const isAbstract = (instr: ir.Instr): boolean =>
  instr instanceof ir.Const || instr instanceof ir.StrConst || instr instanceof ir.Bin
  || instr instanceof ir.Cmp || instr instanceof ir.Load || instr instanceof ir.Store;

/** Insist that selection left nothing of the three-address IR behind. */
export function verify(f: ir.Func): void {
  for (const b of f.walk()) {
    for (const instr of b.instrs) {
      if (isAbstract(instr)) {
        throw new Error(
          `${instr.constructor.name} survived selection in ${f.name}:${b.label}`,
        );
      }
      if (instr instanceof Mach && !FORMS.has(instr.form) && !EXPANDED.has(instr.form)) {
        throw new Error(`no such instruction as \`${instr.form}\``);
      }
    }
  }
}

export function verifyModule(mod: ir.Module): void {
  for (const f of mod.funcs) verify(f);
}
