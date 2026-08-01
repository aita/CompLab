// Lowering: the typed syntax tree becomes a control flow graph.
//
// Two things are worth knowing about this pass.
//
// It never builds a phi.  A variable written in two branches is written to the
// same register twice, and `ssa.ts` is what turns those two writes into one phi.
// Lowering only has to make sure a definition reaches every use, which structured
// control flow does for free.
//
// It decides where a variable lives.  A variable the checker did not mark as
// escaping becomes a register; one that escaped becomes a frame slot, reached
// through `LoadSlot`/`StoreSlot` in its own function and through a chain of
// static links from a nested one.

import * as ast from "./ast.ts";
import * as ir from "./ir.ts";
import { FunSym, RecordT, StringT, UnitT, VarSym } from "./types.ts";

export class Options {
  readonly checks: boolean;
  constructor(checks = true) { this.checks = checks; }
}

/** Owns what the whole module shares: string literals and the function list. */
class Lowerer {
  readonly opts: Options;
  readonly mod = new ir.Module();
  private readonly symbols = new Map<string, string>();

  constructor(opts: Options) { this.opts = opts; }

  string(text: string): string {
    const seen = this.symbols.get(text);
    if (seen !== undefined) return seen;
    const symbol = `.Lstr${this.symbols.size}`;
    this.symbols.set(text, symbol);
    this.mod.strings.set(symbol, text);
    return symbol;
  }

  program(prog: ast.Program): ir.Module {
    const main = new FuncLowerer(this, "wol_main", "main", 0);
    main.topLevel(prog.decls);
    return this.mod;
  }

  function(bind: ast.FunBind): void {
    const sym = bind.sym!;
    new FuncLowerer(this, sym.label, sym.name, sym.depth).functionBody(bind, sym);
  }
}

class FuncLowerer {
  private readonly up: Lowerer;
  private readonly opts: Options;
  readonly func: ir.Func;
  private cur: ir.Block;
  private readonly breaks: string[] = [];
  private counter = 0;
  private hasChildren = false;

  constructor(up: Lowerer, label: string, name: string, depth: number) {
    this.up = up;
    this.opts = up.opts;
    this.func = new ir.Func(label, name, depth);
    this.cur = this.func.addBlock("entry");
    if (depth > 0) this.func.staticLinkSlot = this.func.newSlot();
    up.mod.funcs.push(this.func);
  }

  // -- block plumbing -----------------------------------------------------

  private fresh(hint: string): ir.Block {
    this.counter += 1;
    return this.func.addBlock(`${hint}${this.counter}`);
  }

  private emit(instr: ir.Instr): void { this.cur.instrs.push(instr); }

  private terminate(term: ir.Terminator): void {
    this.emit(term);
    this.cur = this.fresh("dead");
  }

  private jump(b: ir.Block): void { this.terminate(new ir.Jmp(b.label)); }

  private branch(cond: ir.Reg, yes: ir.Block, no: ir.Block): void {
    this.terminate(new ir.CBr(cond, yes.label, no.label));
  }

  private reg(): ir.Reg { return this.func.newReg(); }

  private constant(value: bigint): ir.Reg {
    const r = this.reg();
    this.emit(new ir.Const(r, value));
    return r;
  }

  // -- function bodies ----------------------------------------------------

  topLevel(decls: ast.Decl[]): void {
    this.decls(decls);
    this.terminate(new ir.Ret(null));
    this.finish();
  }

  functionBody(bind: ast.FunBind, sym: FunSym): void {
    if (this.func.depth > 0) {
      const link = this.reg();
      this.func.params.push(link);
      this.emit(new ir.StoreSlot(this.func.staticLinkSlot, link));
    }
    const first = this.func.params.length;
    sym.params.forEach((psym, offset) => {
      const index = first + offset;
      if (index >= ir.ARGUMENT_REGISTERS) {
        psym.escapes = true;
        psym.slot = -(index - ir.ARGUMENT_REGISTERS + 1);
        return;
      }
      const r = this.reg();
      this.func.params.push(r);
      if (psym.escapes) {
        psym.slot = this.func.newSlot();
        this.emit(new ir.StoreSlot(psym.slot, r));
      } else {
        psym.reg = r;
      }
    });
    const value = this.exp(bind.body);
    const returns = !(sym.result instanceof UnitT);
    this.terminate(new ir.Ret(returns ? value : null));
    this.finish();
  }

  private finish(): void {
    ir.dropUnreachable(this.func);
    this.dropUnusedStaticLink();
  }

  /**
   * A function nobody nests inside, and that never looks outward, keeps no static
   * link: the slot goes, and every later slot moves down one.
   */
  private dropUnusedStaticLink(): void {
    const slot = this.func.staticLinkSlot;
    if (slot < 0 || this.hasChildren) return;
    const reads = this.func.walk().some((b) =>
      b.instrs.some((i) => i instanceof ir.LoadSlot && i.slot === slot),
    );
    if (reads) return;
    for (const b of this.func.walk()) {
      const kept: ir.Instr[] = [];
      for (const instr of b.instrs) {
        if (instr instanceof ir.StoreSlot) {
          if (instr.slot === slot) continue;
          if (instr.slot > slot) instr.slot -= 1;
        } else if (instr instanceof ir.LoadSlot) {
          if (instr.slot > slot) instr.slot -= 1;
        }
        kept.push(instr);
      }
      b.instrs = kept;
    }
    this.func.nslots -= 1;
    this.func.staticLinkSlot = -1;
  }

  // -- declarations -------------------------------------------------------

  private decls(decls: ast.Decl[]): void {
    for (const decl of decls) {
      if (decl instanceof ast.TypeDecl) continue;
      if (decl instanceof ast.ValDecl) { this.valDecl(decl); continue; }
      this.hasChildren = true;
      for (const bind of decl.binds) this.up.function(bind);
    }
  }

  private valDecl(decl: ast.ValDecl): void {
    const value = this.exp(decl.init);
    const sym = decl.sym;
    if (sym === null) return;
    if (sym.ty instanceof UnitT) return;
    this.bind(sym, value!);
  }

  /** Give a variable its home, and put the initial value in it. */
  private bind(sym: VarSym, value: ir.Reg): void {
    if (sym.escapes) {
      sym.slot = this.func.newSlot();
      this.emit(new ir.StoreSlot(sym.slot, value));
      return;
    }
    sym.reg = this.reg();
    this.emit(new ir.Move(sym.reg, value));
  }

  // -- reaching variables and frames --------------------------------------

  /** A register holding the frame pointer of the function at `depth`. */
  private frameAt(depth: number): ir.Reg {
    let r = this.reg();
    if (depth === this.func.depth) {
      this.emit(new ir.FrameAddr(r));
      return r;
    }
    this.emit(new ir.LoadSlot(r, this.func.staticLinkSlot));
    for (let here = this.func.depth - 1; here > depth; here--) {
      const next = this.reg();
      this.emit(new ir.Load(next, r, ir.slotOffset(0)));
      r = next;
    }
    return r;
  }

  private readVar(sym: VarSym): ir.Reg {
    if (!sym.escapes) return sym.reg;
    if (sym.depth === this.func.depth) {
      const r = this.reg();
      this.emit(new ir.LoadSlot(r, sym.slot));
      return r;
    }
    const base = this.frameAt(sym.depth);
    const r = this.reg();
    this.emit(new ir.Load(r, base, ir.slotOffset(sym.slot)));
    return r;
  }

  private writeVar(sym: VarSym, value: ir.Reg): void {
    if (!sym.escapes) { this.emit(new ir.Move(sym.reg, value)); return; }
    if (sym.depth === this.func.depth) { this.emit(new ir.StoreSlot(sym.slot, value)); return; }
    const base = this.frameAt(sym.depth);
    this.emit(new ir.Store(base, ir.slotOffset(sym.slot), value));
  }

  // -- expressions --------------------------------------------------------

  private value(e: ast.Exp): ir.Reg {
    const r = this.exp(e);
    if (r === null) throw new Error(`expected a value from ${e.constructor.name}`);
    return r;
  }

  private exp(e: ast.Exp): ir.Reg | null {
    if (e instanceof ast.IntLit) return this.constant(e.value);
    if (e instanceof ast.BoolLit) return this.constant(e.value ? 1n : 0n);
    if (e instanceof ast.NilLit) return this.constant(0n);
    if (e instanceof ast.UnitLit) return null;
    if (e instanceof ast.StrLit) {
      const r = this.reg();
      this.emit(new ir.StrConst(r, this.up.string(e.value)));
      return r;
    }
    if (e instanceof ast.Var) return this.readVar(e.sym!);
    if (e instanceof ast.Call) return this.call(e);
    if (e instanceof ast.RecordLit) return this.record(e);
    if (e instanceof ast.Index) {
      const addr = this.elementAddress(e);
      const r = this.reg();
      this.emit(new ir.Load(r, addr, ir.WORD));
      return r;
    }
    if (e instanceof ast.Field) {
      const base = this.value(e.record);
      this.checkNotNil(base);
      const r = this.reg();
      this.emit(new ir.Load(r, base, ir.WORD * e.offset));
      return r;
    }
    if (e instanceof ast.Neg) {
      const zero = this.constant(0n);
      return this.binop("-", zero, this.value(e.operand));
    }
    if (e instanceof ast.Bin) return this.bin(e);
    if (e instanceof ast.Logic) return this.logic(e);
    if (e instanceof ast.Assign) { this.assign(e); return null; }
    if (e instanceof ast.If) return this.ifExp(e);
    if (e instanceof ast.While) { this.whileExp(e); return null; }
    if (e instanceof ast.For) { this.forExp(e); return null; }
    if (e instanceof ast.Break) {
      this.terminate(new ir.Jmp(this.breaks[this.breaks.length - 1]!));
      return null;
    }
    if (e instanceof ast.Seq) {
      let last: ir.Reg | null = null;
      for (const item of e.items) last = this.exp(item);
      return last;
    }
    this.decls(e.decls);
    return this.exp(e.body);
  }

  private binop(op: string, lhs: ir.Reg, rhs: ir.Reg): ir.Reg {
    const r = this.reg();
    this.emit(new ir.Bin(r, op, lhs, rhs));
    return r;
  }

  private compare(op: string, lhs: ir.Reg, rhs: ir.Reg): ir.Reg {
    const r = this.reg();
    this.emit(new ir.Cmp(r, op, lhs, rhs));
    return r;
  }

  private callRuntime(name: string, args: ir.Reg[]): ir.Reg {
    const r = this.reg();
    this.emit(new ir.Call(r, name, args));
    return r;
  }

  private bin(e: ast.Bin): ir.Reg {
    const lhs = this.value(e.lhs);
    const rhs = this.value(e.rhs);
    if (e.op === "^") return this.callRuntime("wol_concat", [lhs, rhs]);
    if (e.op === "/" || e.op === "mod") {
      this.checkNonzero(rhs);
      if (e.op === "/") return this.binop("/", lhs, rhs);
      // The remainder is spelled out rather than left to the emitter: the
      // quotient it needs in between is a value like any other, and the
      // allocator can find it a register.  The emitter fuses the last two back
      // into one `msub`.
      const quotient = this.binop("/", lhs, rhs);
      const product = this.binop("*", quotient, rhs);
      return this.binop("-", lhs, product);
    }
    if (e.op === "+" || e.op === "-" || e.op === "*") return this.binop(e.op, lhs, rhs);
    if (e.lhs.ty instanceof StringT) {
      const order = this.callRuntime("wol_string_cmp", [lhs, rhs]);
      return this.compare(e.op, order, this.constant(0n));
    }
    return this.compare(e.op, lhs, rhs);
  }

  /** `andalso` and `orelse` are branches, so the result needs a register. */
  private logic(e: ast.Logic): ir.Reg {
    const result = this.reg();
    const rhsBlock = this.fresh("logic");
    const join = this.fresh("logicjoin");
    const lhs = this.value(e.lhs);
    this.emit(new ir.Move(result, lhs));
    if (e.op === "andalso") this.branch(lhs, rhsBlock, join);
    else this.branch(lhs, join, rhsBlock);
    this.cur = rhsBlock;
    this.emit(new ir.Move(result, this.value(e.rhs)));
    this.jump(join);
    this.cur = join;
    return result;
  }

  private call(e: ast.Call): ir.Reg | null {
    const sym = e.sym!;
    if (sym.builtin === "not") {
      return this.binop("xor", this.value(e.args[0]!), this.constant(1n));
    }
    if (sym.builtin === "array") {
      const n = this.value(e.args[0]!);
      const init = this.value(e.args[1]!);
      return this.callRuntime("wol_array", [n, init]);
    }
    if (sym.builtin === "length") {
      const arr = this.value(e.args[0]!);
      this.checkNotNil(arr);
      const r = this.reg();
      this.emit(new ir.Load(r, arr, 0));
      return r;
    }
    let args = e.args.map((a) => this.value(a));
    if (sym.builtin === null) args = [this.frameAt(sym.depth - 1), ...args];
    if (sym.result instanceof UnitT) {
      this.emit(new ir.Call(null, sym.label, args));
      return null;
    }
    return this.callRuntime(sym.label, args);
  }

  private record(e: ast.RecordLit): ir.Reg {
    const rec = e.ty as RecordT;
    const size = this.constant(BigInt(ir.WORD * Math.max(rec.fields.length, 1)));
    const base = this.callRuntime("wol_alloc", [size]);
    e.fields.forEach((f, at) => {
      this.emit(new ir.Store(base, ir.WORD * at, this.value(f.value)));
    });
    return base;
  }

  /**
   * The address of `a[i]`, without the length word the elements follow.
   *
   * The selector turns this into one `add` with a shifted operand, and the word
   * is the load's displacement, so the two instructions that come out are the two
   * the machine has.
   */
  private elementAddress(e: ast.Index): ir.Reg {
    const base = this.value(e.array);
    const idx = this.value(e.index);
    this.checkNotNil(base);
    this.checkBounds(base, idx);
    return this.binop("+", base, this.binop("shl", idx, this.constant(3n)));
  }

  private assign(e: ast.Assign): void {
    const target = e.target;
    if (target instanceof ast.Var) { this.writeVar(target.sym!, this.value(e.value)); return; }
    if (target instanceof ast.Index) {
      const addr = this.elementAddress(target);
      this.emit(new ir.Store(addr, ir.WORD, this.value(e.value)));
      return;
    }
    if (target instanceof ast.Field) {
      const base = this.value(target.record);
      this.checkNotNil(base);
      this.emit(new ir.Store(base, ir.WORD * target.offset, this.value(e.value)));
      return;
    }
    throw new Error("assignment to something that is not a place");
  }

  private ifExp(e: ast.If): ir.Reg | null {
    const result = e.ty instanceof UnitT ? null : this.reg();
    const yes = this.fresh("then");
    const no = this.fresh("else");
    const join = this.fresh("join");
    this.branch(this.value(e.cond), yes, no);

    this.cur = yes;
    let taken = this.exp(e.then);
    if (result !== null && taken !== null) this.emit(new ir.Move(result, taken));
    this.jump(join);

    this.cur = no;
    if (e.els !== null) {
      taken = this.exp(e.els);
      if (result !== null && taken !== null) this.emit(new ir.Move(result, taken));
    }
    this.jump(join);

    this.cur = join;
    return result;
  }

  private whileExp(e: ast.While): void {
    const test = this.fresh("test");
    const body = this.fresh("body");
    const done = this.fresh("done");
    this.jump(test);
    this.cur = test;
    this.branch(this.value(e.cond), body, done);
    this.cur = body;
    this.breaks.push(done.label);
    this.exp(e.body);
    this.breaks.pop();
    this.jump(test);
    this.cur = done;
  }

  /** `for i = lo to hi` counts up, and stops before overflowing at `hi`. */
  private forExp(e: ast.For): void {
    const sym = e.sym!;
    const lo = this.value(e.lo);
    const hiValue = this.value(e.hi);
    const hi = this.reg();
    this.emit(new ir.Move(hi, hiValue));
    this.bind(sym, lo);
    const body = this.fresh("forbody");
    const step = this.fresh("forstep");
    const done = this.fresh("fordone");
    this.branch(this.compare("<=", lo, hi), body, done);

    this.cur = body;
    this.breaks.push(done.label);
    this.exp(e.body);
    this.breaks.pop();
    const i = this.readVar(sym);
    this.branch(this.compare("<", i, hi), step, done);

    this.cur = step;
    this.writeVar(sym, this.binop("+", this.readVar(sym), this.constant(1n)));
    this.jump(body);

    this.cur = done;
  }

  // -- run-time checks ----------------------------------------------------

  private checkNotNil(base: ir.Reg): void {
    if (!this.opts.checks) return;
    const bad = this.fresh("nil");
    const ok = this.fresh("ok");
    this.branch(this.compare("=", base, this.constant(0n)), bad, ok);
    this.cur = bad;
    this.emit(new ir.Call(null, "wol_nil_error", []));
    this.jump(ok);
    this.cur = ok;
  }

  private checkBounds(base: ir.Reg, idx: ir.Reg): void {
    if (!this.opts.checks) return;
    const length = this.reg();
    this.emit(new ir.Load(length, base, 0));
    const bad = this.fresh("oob");
    const ok = this.fresh("ok");
    this.branch(this.compare("u<", idx, length), ok, bad);
    this.cur = bad;
    this.emit(new ir.Call(null, "wol_bounds_error", [idx, length]));
    this.jump(ok);
    this.cur = ok;
  }

  private checkNonzero(rhs: ir.Reg): void {
    if (!this.opts.checks) return;
    const bad = this.fresh("divzero");
    const ok = this.fresh("ok");
    this.branch(this.compare("=", rhs, this.constant(0n)), bad, ok);
    this.cur = bad;
    this.emit(new ir.Call(null, "wol_div_error", []));
    this.jump(ok);
    this.cur = ok;
  }
}

export const lower = (prog: ast.Program, opts = new Options()): ir.Module =>
  new Lowerer(opts).program(prog);
