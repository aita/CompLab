// ARMv8 assembly, in AAPCS64.
//
// The frame is the ordinary one.  `x29` points at the saved frame record, the slots
// an escaping variable or a spill lives in are below it, the callee-saved registers
// this function actually used are below those, and outgoing stack arguments sit at
// the bottom, at `sp`, where the callee expects them.
//
//     x29 -> | saved x29, x30 |
//            | slot 0         |   x29 - 8      also where a static link points
//            | slot 1         |   x29 - 16
//            | ...            |
//            | saved x19...   |
//     sp  -> | outgoing args  |
//
// The phis are gone before this point — the allocator left SSA to colour the
// interference graph — so what is left to do all at once is the arguments of a call
// and the parameters at the top of a function: the values are read before any is
// written, which is what `copies.sequentialize` arranges.  When the copies form a
// cycle it borrows a register the function never used, and when there is none it
// swaps the two ends with three `eor`s, so no register has to be reserved for it.

import * as copies from "./copies.ts";
import * as ir from "./ir.ts";
import { FORMS, Mach, OPPOSITE } from "./mach.ts";
import { ARGUMENT_REGS, CALLER_SAVED, SCRATCH } from "./registers.ts";

const UNSCALED = new Map([["ldr", "ldur"], ["str", "stur"]]);

/**
 * The one register kept back.  A frame big enough to put a slot out of reach of
 * `ldur` is only discovered after allocation has added its spill slots, so the
 * address has to be computed somewhere the allocator does not know about.
 */
const SPARE = SCRATCH[0]!;

/**
 * Nothing of ours is live at the top of the prologue except the incoming
 * arguments, so a caller-saved register that is not one of them is free there.
 */
const PROLOGUE_TEMP = 9;

class Frame {
  readonly slots: number;
  readonly saved: number[];
  readonly size: number;

  constructor(slots: number, saved: number[], stackArgs: number) {
    this.slots = slots;
    this.saved = saved;
    this.size = (ir.WORD * (slots + saved.length + stackArgs) + 15) & ~15;
  }

  savedOffset(index: number): number { return -ir.WORD * (this.slots + index + 1); }
}

function frameOf(f: ir.Func): Frame {
  let stackArgs = 0;
  for (const b of f.walk()) {
    for (const instr of b.instrs) {
      if (instr instanceof ir.Call) {
        stackArgs = Math.max(stackArgs, instr.args.length - ARGUMENT_REGS.length);
      }
    }
  }
  return new Frame(f.nslots, f.saved, Math.max(stackArgs, 0));
}

/** One character of a literal is one byte; write the ones `.ascii` cannot. */
export function escape(text: string): string {
  const out: string[] = [];
  for (const ch of [...text].map((c) => c.charCodeAt(0))) {
    if (ch === 0x22) out.push('\\"');
    else if (ch === 0x5c) out.push("\\\\");
    else if (ch >= 0x20 && ch < 0x7f) out.push(String.fromCharCode(ch));
    else out.push("\\" + ch.toString(8).padStart(3, "0"));
  }
  return out.join("");
}

function registersRead(f: ir.Func): Set<ir.Reg> {
  const read = new Set<ir.Reg>();
  for (const b of f.walk()) for (const instr of b.instrs) for (const r of instr.uses()) read.add(r);
  return read;
}

export class FuncEmitter {
  readonly func: ir.Func;
  private readonly frame: Frame;
  private readonly out: string[] = [];
  private readonly epilogue: string;
  private readonly read: Set<ir.Reg>;
  private readonly taken: Set<number>;

  constructor(func: ir.Func) {
    this.func = func;
    this.frame = frameOf(func);
    this.epilogue = `.Lepi_${func.label}`;
    this.read = registersRead(func);
    this.taken = new Set(func.colours.values());
  }

  // -- helpers ------------------------------------------------------------

  private line(text: string): void { this.out.push(`\t${text}`); }
  private label(text: string): void { this.out.push(`${text}:`); }

  private colour(r: ir.Reg): number {
    const colour = this.func.colours.get(r);
    if (colour === undefined) throw new Error(`%${r} was never coloured`);
    return colour;
  }

  private mov(dst: number, src: number): void {
    if (dst !== src) this.line(`mov x${dst}, x${src}`);
  }

  private immediate(dst: number, value: bigint): void {
    const bits = BigInt.asUintN(64, value);
    if (bits === 0n) { this.line(`mov x${dst}, #0`); return; }
    let first = true;
    for (let i = 0; i < 4; i++) {
      const chunk = (bits >> BigInt(i * 16)) & 0xffffn;
      if (chunk === 0n) continue;
      const shift = i !== 0 ? `, lsl #${i * 16}` : "";
      this.line(`${first ? "movz" : "movk"} x${dst}, #${chunk}${shift}`);
      first = false;
    }
  }

  /** `ldr`/`str`, in whichever addressing mode reaches this far. */
  private access(op: string, reg: number, base: number, offset: bigint): void {
    const where = base === 31 ? "sp" : `x${base}`;
    if (offset >= 0n && offset <= 32760n && offset % BigInt(ir.WORD) === 0n) {
      this.line(`${op} x${reg}, [${where}, #${offset}]`);
    } else if (offset >= -256n && offset <= 255n) {
      this.line(`${UNSCALED.get(op)!} x${reg}, [${where}, #${offset}]`);
    } else {
      this.immediate(SPARE, offset);
      this.line(`${op} x${reg}, [${where}, x${SPARE}]`);
    }
  }

  // -- whole functions ----------------------------------------------------

  emit(): string[] {
    this.out.push(`\t.globl ${this.func.label}`);
    this.out.push(`\t.type ${this.func.label}, %function`);
    this.label(this.func.label);
    this.prologue();
    const order = this.func.order;
    order.forEach((name, at) => {
      this.label(`.L${this.func.label}_${name}`);
      this.block(this.func.block(name), at + 1 < order.length ? order[at + 1]! : null);
    });
    this.label(this.epilogue);
    this.restore();
    this.line("mov sp, x29");
    this.line("ldp x29, x30, [sp], #16");
    this.line("ret");
    this.out.push(`\t.size ${this.func.label}, .-${this.func.label}`);
    return this.out;
  }

  private prologue(): void {
    this.line("stp x29, x30, [sp, #-16]!");
    this.line("mov x29, sp");
    if (this.frame.size !== 0) {
      if (this.frame.size <= 4095) this.line(`sub sp, sp, #${this.frame.size}`);
      else {
        this.immediate(PROLOGUE_TEMP, BigInt(this.frame.size));
        this.line(`sub sp, sp, x${PROLOGUE_TEMP}`);
      }
    }
    this.frame.saved.forEach((reg, at) => {
      this.access("str", reg, 29, BigInt(this.frame.savedOffset(at)));
    });
    const moves: [number, number][] = [];
    this.func.params.forEach((p, at) => {
      if (this.read.has(p)) moves.push([this.colour(p), ARGUMENT_REGS[at]!]);
    });
    this.copies(moves);
  }

  private restore(): void {
    this.frame.saved.forEach((reg, at) => {
      this.access("ldr", reg, 29, BigInt(this.frame.savedOffset(at)));
    });
  }

  private block(b: ir.Block, next: string | null): void {
    for (const instr of b.instrs.slice(0, -1)) this.instruction(instr);
    this.terminator(b, next);
  }

  private terminator(b: ir.Block, next: string | null): void {
    const term = b.terminator;
    const l = this.func.label;
    if (term instanceof ir.Jmp) {
      if (term.target !== next) this.line(`b .L${l}_${term.target}`);
      return;
    }
    if (term instanceof ir.CBr) {
      const thenLabel = `.L${l}_${term.then}`;
      const elseLabel = `.L${l}_${term.els}`;
      if (term.code !== "") {
        if (term.then === next) this.line(`b.${OPPOSITE.get(term.code)!} ${elseLabel}`);
        else {
          this.line(`b.${term.code} ${thenLabel}`);
          if (term.els !== next) this.line(`b ${elseLabel}`);
        }
      } else if (term.then === next) {
        this.line(`cbz x${this.colour(term.cond)}, ${elseLabel}`);
      } else {
        this.line(`cbnz x${this.colour(term.cond)}, ${thenLabel}`);
        if (term.els !== next) this.line(`b ${elseLabel}`);
      }
      return;
    }
    const ret = term as ir.Ret;
    if (ret.value !== null) this.mov(ARGUMENT_REGS[0]!, this.colour(ret.value));
    if (next !== null) this.line(`b ${this.epilogue}`); // the epilogue follows the last block
  }

  private copies(moves: [number, number][]): void {
    for (const step of copies.sequentialize(moves, this.borrowed(moves))) {
      if (step instanceof copies.Mov) {
        this.mov(step.dst, step.src);
      } else {
        const { a, b } = step;
        this.line(`eor x${a}, x${a}, x${b}`);
        this.line(`eor x${b}, x${a}, x${b}`);
        this.line(`eor x${a}, x${a}, x${b}`);
      }
    }
  }

  /**
   * A register free to clobber here, if the function left one over.
   *
   * A caller-saved register this function never gave to a value holds nothing of
   * ours anywhere, and one that this copy neither reads nor writes holds nothing of
   * the copy's either.  With no such register the copies swap instead, which needs
   * no scratch at all.
   */
  borrowed(moves: [number, number][]): number | null {
    const touched = new Set(moves.flat());
    return CALLER_SAVED.find((reg) => !this.taken.has(reg) && !touched.has(reg)) ?? null;
  }

  // -- one instruction ----------------------------------------------------

  private instruction(instr: ir.Instr): void {
    if (instr instanceof Mach) { this.machine(instr); return; }
    if (instr instanceof ir.Move) { this.mov(this.colour(instr.dst), this.colour(instr.src)); return; }
    if (instr instanceof ir.LoadSlot) {
      this.access("ldr", this.colour(instr.dst), 29, BigInt(ir.slotOffset(instr.slot)));
      return;
    }
    if (instr instanceof ir.StoreSlot) {
      this.access("str", this.colour(instr.src), 29, BigInt(ir.slotOffset(instr.slot)));
      return;
    }
    if (instr instanceof ir.FrameAddr) { this.mov(this.colour(instr.dst), 29); return; }
    if (instr instanceof ir.Call) { this.call(instr); return; }
    throw new Error(`cannot emit ${instr.constructor.name}`);
  }

  /** Write down one selected instruction, or the sequence it stands for. */
  private machine(instr: Mach): void {
    const srcs = instr.srcs.map((s) => this.colour(s));
    switch (instr.form) {
      case "const":
        this.immediate(this.colour(instr.dst!), instr.imm);
        return;
      case "adr": {
        const d = this.colour(instr.dst!);
        this.line(`adrp x${d}, ${instr.symbol}`);
        this.line(`add x${d}, x${d}, :lo12:${instr.symbol}`);
        return;
      }
      case "ldr":
        this.access("ldr", this.colour(instr.dst!), srcs[0]!, instr.imm);
        return;
      case "str":
        this.access("str", srcs[1]!, srcs[0]!, instr.imm);
        return;
      default: {
        let written = FORMS.get(instr.form)!;
        srcs.forEach((c, at) => { written = written.replaceAll(`{s${at}}`, `x${c}`); });
        if (instr.dst !== null) {
          written = written.replaceAll("{d}", `x${this.colour(instr.dst)}`);
        }
        written = written.replaceAll("{imm}", String(instr.imm));
        written = written.replaceAll("{sym}", instr.symbol);
        this.line(written);
      }
    }
  }

  private call(instr: ir.Call): void {
    const inRegisters: [number, number][] = instr.args
      .slice(0, ARGUMENT_REGS.length)
      .map((a, at) => [ARGUMENT_REGS[at]!, this.colour(a)]);
    instr.args.slice(ARGUMENT_REGS.length).forEach((a, at) => {
      this.access("str", this.colour(a), 31, BigInt(ir.WORD * at));
    });
    this.copies(inRegisters);
    this.line(`bl ${instr.callee}`);
    if (instr.dst !== null) this.mov(this.colour(instr.dst), ARGUMENT_REGS[0]!);
  }
}

export type NewEmitter = (f: ir.Func) => FuncEmitter;

export function emitModule(mod: ir.Module, newEmitter: NewEmitter = (f) => new FuncEmitter(f)): string {
  const out: string[] = ["\t.text"];
  for (const f of mod.funcs) {
    out.push(...newEmitter(f).emit());
    out.push("");
  }
  if (mod.strings.size > 0) {
    out.push("\t.section .rodata");
    for (const [symbol, text] of mod.strings) {
      out.push("\t.p2align 3");
      out.push(`${symbol}:`);
      out.push(`\t.quad ${text.length}`);
      out.push(`\t.ascii "${escape(text)}"`);
      out.push("\t.byte 0");
    }
  }
  out.push('\t.section .note.GNU-stack,"",%progbits');
  return out.join("\n") + "\n";
}
