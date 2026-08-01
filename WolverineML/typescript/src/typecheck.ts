// The type checker, which also decides which variables escape.
//
// Types are monomorphic and there is nothing to infer but the type of a `val`.
// A `fun` without a result type is a procedure and returns `unit`, which is what
// makes recursion checkable without inference: every function's signature is
// known before any body is.
//
// The pass has a second job.  A variable read from inside a function nested more
// deeply than the one that binds it cannot live in a register, because the inner
// function reaches it through a static link at run time.  Every lookup that
// crosses a function boundary marks the variable as escaping, and the lowering
// pass gives those a frame slot instead.

import * as ast from "./ast.ts";
import { type Span, typeError } from "./diag.ts";
import * as types from "./types.ts";
import { ArrayT, BOOL, FunSym, INT, NIL, NilT, RecordT, STRING, UNIT, UnitT, VarSym } from "./types.ts";

const BUILTIN_SIGS: [string, types.Type[], types.Type, string][] = [
  ["print", [STRING], UNIT, "wol_print"],
  ["println", [STRING], UNIT, "wol_println"],
  ["printInt", [INT], UNIT, "wol_print_int"],
  ["flush", [], UNIT, "wol_flush"],
  ["getChar", [], STRING, "wol_getchar"],
  ["ord", [STRING], INT, "wol_ord"],
  ["chr", [INT], STRING, "wol_chr"],
  ["size", [STRING], INT, "wol_size"],
  ["substring", [STRING, INT, INT], STRING, "wol_substring"],
  ["concat", [STRING, STRING], STRING, "wol_concat"],
  ["intToString", [INT], STRING, "wol_int_to_string"],
  ["stringToInt", [STRING], INT, "wol_string_to_int"],
  ["exit", [INT], UNIT, "wol_exit"],
];

const ARITHMETIC = new Set(["+", "-", "*", "/", "mod"]);
const ORDERINGS = new Set(["<", "<=", ">", ">="]);
const EQUALITIES = new Set(["=", "<>"]);

class Scope {
  readonly types = new Map<string, types.Type>();
  readonly vals = new Map<string, types.Sym>();
}

class Checker {
  private readonly scopes: Scope[] = [this.prelude()];
  private depth = 0;
  private loops = 0;
  private readonly labels = new Map<string, number>();

  private prelude(): Scope {
    const scope = new Scope();
    scope.types.set("int", INT);
    scope.types.set("string", STRING);
    scope.types.set("bool", BOOL);
    scope.types.set("unit", UNIT);
    for (const [name, params, result, symbol] of BUILTIN_SIGS) {
      scope.vals.set(
        name,
        new FunSym(
          name, symbol,
          params.map((t, i) => new VarSym(`a${i}`, t, false, 0)),
          result, 0, symbol,
        ),
      );
    }
    for (const name of ["array", "length", "not"]) {
      scope.vals.set(name, new FunSym(name, name, [], UNIT, 0, name));
    }
    return scope;
  }

  // -- scopes -------------------------------------------------------------

  private push(): void { this.scopes.push(new Scope()); }
  private pop(): void { this.scopes.pop(); }

  private bindVal(name: string, sym: types.Sym): void {
    this.scopes[this.scopes.length - 1]!.vals.set(name, sym);
  }

  private bindType(name: string, ty: types.Type): void {
    this.scopes[this.scopes.length - 1]!.types.set(name, ty);
  }

  private lookupVal(name: string, span: Span): types.Sym {
    for (let i = this.scopes.length - 1; i >= 0; i--) {
      const sym = this.scopes[i]!.vals.get(name);
      if (sym !== undefined) return sym;
    }
    throw typeError(span, `\`${name}\` is not bound`);
  }

  private lookupType(name: string, span: Span): types.Type {
    for (let i = this.scopes.length - 1; i >= 0; i--) {
      const ty = this.scopes[i]!.types.get(name);
      if (ty !== undefined) return ty;
    }
    throw typeError(span, `\`${name}\` is not a type`);
  }

  private uniqueLabel(name: string): string {
    const n = this.labels.get(name) ?? 0;
    this.labels.set(name, n + 1);
    return n === 0 ? `wol_${name}` : `wol_${name}.${n}`;
  }

  // -- programs -----------------------------------------------------------

  program(prog: ast.Program): void {
    this.push();
    this.decls(prog.decls);
    this.pop();
  }

  private decls(decls: ast.Decl[]): void {
    for (const decl of decls) {
      if (decl instanceof ast.TypeDecl) this.typeDecl(decl);
      else if (decl instanceof ast.ValDecl) this.valDecl(decl);
      else this.funDecl(decl);
    }
  }

  private typeDecl(decl: ast.TypeDecl): void {
    const records: [RecordT, ast.TyRecord][] = [];
    for (const bind of decl.binds) {
      if (bind.ty instanceof ast.TyRecord) {
        const rec = new RecordT(bind.name);
        this.bindType(bind.name, rec);
        records.push([rec, bind.ty]);
      }
    }
    for (const bind of decl.binds) {
      if (!(bind.ty instanceof ast.TyRecord)) this.bindType(bind.name, this.resolve(bind.ty));
    }
    for (const [rec, syntax] of records) {
      const seen = new Set<string>();
      for (const f of syntax.fields) {
        if (seen.has(f.name)) throw typeError(f.span, `duplicate field \`${f.name}\``);
        seen.add(f.name);
        rec.fields.push([f.name, this.resolve(f.ty)]);
      }
    }
  }

  private resolve(ty: ast.TyExp): types.Type {
    if (ty instanceof ast.TyName) return this.lookupType(ty.name, ty.span);
    if (ty instanceof ast.TyArray) return new ArrayT(this.resolve(ty.elem));
    throw typeError(ty.span, "a record type has to be given a name by `type`");
  }

  private valDecl(decl: ast.ValDecl): void {
    let got = this.exp(decl.init);
    if (decl.ty !== null) {
      const want = this.resolve(decl.ty);
      this.unify(want, got, decl.init.span, "in this binding");
      got = want;
    }
    if (decl.name === null) {
      this.unify(UNIT, got, decl.init.span, "in `val () =`");
      return;
    }
    if (got instanceof NilT) {
      throw typeError(decl.span, `\`${decl.name}\` needs a type annotation to hold \`nil\``);
    }
    decl.sym = new VarSym(decl.name, got, decl.mutable, this.depth);
    this.bindVal(decl.name, decl.sym);
  }

  private funDecl(decl: ast.FunDecl): void {
    for (const bind of decl.binds) {
      const params: VarSym[] = [];
      const seen = new Set<string>();
      for (const p of bind.params) {
        if (seen.has(p.name)) throw typeError(p.span, `duplicate parameter \`${p.name}\``);
        seen.add(p.name);
        p.sym = new VarSym(p.name, this.resolve(p.ty), false, this.depth + 1);
        params.push(p.sym);
      }
      const result = bind.result === null ? UNIT : this.resolve(bind.result);
      bind.sym = new FunSym(
        bind.name, this.uniqueLabel(bind.name), params, result, this.depth + 1,
      );
      this.bindVal(bind.name, bind.sym);
    }
    for (const bind of decl.binds) {
      const signature = bind.sym!;
      this.depth += 1;
      const outer = this.loops;
      this.loops = 0;
      this.push();
      for (const p of bind.params) this.bindVal(p.name, p.sym!);
      const got = this.exp(bind.body);
      this.unify(signature.result, got, bind.body.span, `in the body of \`${bind.name}\``);
      this.pop();
      this.loops = outer;
      this.depth -= 1;
    }
  }

  // -- expressions --------------------------------------------------------

  private unify(want: types.Type, got: types.Type, span: Span, where: string): void {
    if (!types.compatible(want, got)) {
      throw typeError(span, `expected \`${want}\`, found \`${got}\` ${where}`);
    }
  }

  private exp(e: ast.Exp): types.Type {
    const ty = this.infer(e);
    e.ty = ty;
    return ty;
  }

  private infer(e: ast.Exp): types.Type {
    if (e instanceof ast.IntLit) return INT;
    if (e instanceof ast.StrLit) return STRING;
    if (e instanceof ast.BoolLit) return BOOL;
    if (e instanceof ast.NilLit) return NIL;
    if (e instanceof ast.UnitLit) return UNIT;
    if (e instanceof ast.Var) return this.variable(e);
    if (e instanceof ast.Call) return this.call(e);
    if (e instanceof ast.RecordLit) return this.recordLit(e);
    if (e instanceof ast.Index) return this.index(e);
    if (e instanceof ast.Field) return this.field(e);
    if (e instanceof ast.Neg) {
      this.unify(INT, this.exp(e.operand), e.span, "in a negation");
      return INT;
    }
    if (e instanceof ast.Bin) return this.binop(e);
    if (e instanceof ast.Logic) {
      this.unify(BOOL, this.exp(e.lhs), e.lhs.span, `on the left of \`${e.op}\``);
      this.unify(BOOL, this.exp(e.rhs), e.rhs.span, `on the right of \`${e.op}\``);
      return BOOL;
    }
    if (e instanceof ast.Assign) return this.assign(e);
    if (e instanceof ast.If) return this.ifExp(e);
    if (e instanceof ast.While) {
      this.unify(BOOL, this.exp(e.cond), e.cond.span, "as a `while` condition");
      this.loops += 1;
      this.unify(UNIT, this.exp(e.body), e.body.span, "in a `while` body");
      this.loops -= 1;
      return UNIT;
    }
    if (e instanceof ast.For) return this.forExp(e);
    if (e instanceof ast.Break) {
      if (this.loops === 0) throw typeError(e.span, "`break` is outside any loop");
      return UNIT;
    }
    if (e instanceof ast.Seq) {
      let ty: types.Type = UNIT;
      for (const item of e.items) ty = this.exp(item);
      return ty;
    }
    // ast.Let
    this.push();
    this.decls(e.decls);
    const ty = this.exp(e.body);
    this.pop();
    return ty;
  }

  private variable(e: ast.Var): types.Type {
    const sym = this.lookupVal(e.name, e.span);
    if (sym instanceof FunSym) {
      throw typeError(e.span, `\`${e.name}\` is a function, and functions are not values`);
    }
    if (sym.depth < this.depth) sym.escapes = true;
    e.sym = sym;
    return sym.ty;
  }

  private call(e: ast.Call): types.Type {
    const sym = this.lookupVal(e.name, e.span);
    if (sym instanceof VarSym) {
      throw typeError(e.span, `\`${e.name}\` is a variable, not a function`);
    }
    e.sym = sym;
    if (sym.builtin === "array") return this.arrayCall(e);
    if (sym.builtin === "length") return this.lengthCall(e);
    if (sym.builtin === "not") {
      this.arity(e, 1);
      this.unify(BOOL, this.exp(e.args[0]!), e.span, "in a call to `not`");
      return BOOL;
    }
    this.arity(e, sym.params.length);
    e.args.forEach((arg, at) => {
      this.unify(sym.params[at]!.ty, this.exp(arg), arg.span, `in a call to \`${e.name}\``);
    });
    return sym.result;
  }

  private arity(e: ast.Call, want: number): void {
    if (e.args.length === want) return;
    const plural = want === 1 ? "" : "s";
    throw typeError(e.span, `\`${e.name}\` takes ${want} argument${plural}, given ${e.args.length}`);
  }

  private arrayCall(e: ast.Call): types.Type {
    this.arity(e, 2);
    this.unify(INT, this.exp(e.args[0]!), e.args[0]!.span, "as an array length");
    const elem = this.exp(e.args[1]!);
    if (elem instanceof NilT) {
      throw typeError(e.args[1]!.span, "`array` cannot tell which record `nil` stands for");
    }
    return new ArrayT(elem);
  }

  private lengthCall(e: ast.Call): types.Type {
    this.arity(e, 1);
    const arg = this.exp(e.args[0]!);
    if (!(arg instanceof ArrayT)) {
      throw typeError(e.args[0]!.span, `\`length\` wants an array, found \`${arg}\``);
    }
    return INT;
  }

  private recordLit(e: ast.RecordLit): types.Type {
    const rec = this.lookupType(e.tyname, e.span);
    if (!(rec instanceof RecordT)) {
      throw typeError(e.span, `\`${e.tyname}\` is not a record type`);
    }
    const given = new Map<string, ast.FieldInit>();
    for (const f of e.fields) {
      if (given.has(f.name)) throw typeError(f.span, `field \`${f.name}\` is given twice`);
      if (rec.index(f.name) < 0) {
        throw typeError(f.span, `\`${rec.name}\` has no field \`${f.name}\``);
      }
      given.set(f.name, f);
    }
    const ordered: ast.FieldInit[] = [];
    for (const [name, ty] of rec.fields) {
      const init = given.get(name);
      if (init === undefined) throw typeError(e.span, `field \`${name}\` is missing`);
      this.unify(ty, this.exp(init.value), init.span, `in field \`${name}\``);
      ordered.push(init);
    }
    e.fields = ordered;
    return rec;
  }

  private index(e: ast.Index): types.Type {
    const arr = this.exp(e.array);
    if (!(arr instanceof ArrayT)) throw typeError(e.span, `\`${arr}\` is not an array`);
    this.unify(INT, this.exp(e.index), e.index.span, "as an array index");
    return arr.elem;
  }

  private field(e: ast.Field): types.Type {
    const rec = this.exp(e.record);
    if (!(rec instanceof RecordT)) throw typeError(e.span, `\`${rec}\` is not a record`);
    const ty = rec.fieldType(e.name);
    if (ty === null) throw typeError(e.span, `\`${rec.name}\` has no field \`${e.name}\``);
    e.offset = rec.index(e.name);
    return ty;
  }

  private binop(e: ast.Bin): types.Type {
    const lhs = this.exp(e.lhs);
    const rhs = this.exp(e.rhs);
    if (ARITHMETIC.has(e.op)) {
      this.unify(INT, lhs, e.lhs.span, `on the left of \`${e.op}\``);
      this.unify(INT, rhs, e.rhs.span, `on the right of \`${e.op}\``);
      return INT;
    }
    if (e.op === "^") {
      this.unify(STRING, lhs, e.lhs.span, "on the left of `^`");
      this.unify(STRING, rhs, e.rhs.span, "on the right of `^`");
      return STRING;
    }
    if (ORDERINGS.has(e.op)) {
      if (lhs.tag === "int" || lhs.tag === "string") {
        this.unify(lhs, rhs, e.rhs.span, `on the right of \`${e.op}\``);
        return BOOL;
      }
      throw typeError(e.span, `\`${e.op}\` compares int or string, not \`${lhs}\``);
    }
    if (EQUALITIES.has(e.op)) {
      if (lhs instanceof UnitT || rhs instanceof UnitT) {
        throw typeError(e.span, `\`${e.op}\` cannot compare \`unit\``);
      }
      if (!types.compatible(lhs, rhs)) {
        throw typeError(e.span, `\`${e.op}\` compares \`${lhs}\` with \`${rhs}\``);
      }
      return BOOL;
    }
    throw typeError(e.span, `unknown operator \`${e.op}\``);
  }

  private assign(e: ast.Assign): types.Type {
    const target = this.exp(e.target);
    if (e.target instanceof ast.Var && e.target.sym !== null && !e.target.sym.mutable) {
      throw typeError(e.span, `\`${e.target.sym.name}\` is a \`val\`, so it cannot be assigned`);
    }
    this.unify(target, this.exp(e.value), e.value.span, "in an assignment");
    return UNIT;
  }

  private ifExp(e: ast.If): types.Type {
    this.unify(BOOL, this.exp(e.cond), e.cond.span, "as an `if` condition");
    const then = this.exp(e.then);
    if (e.els === null) {
      this.unify(UNIT, then, e.then.span, "in an `if` with no `else`");
      return UNIT;
    }
    const els = this.exp(e.els);
    if (!types.compatible(then, els)) {
      throw typeError(e.span, `the branches differ: \`${then}\` and \`${els}\``);
    }
    return then instanceof NilT ? els : then;
  }

  private forExp(e: ast.For): types.Type {
    this.unify(INT, this.exp(e.lo), e.lo.span, "as a `for` bound");
    this.unify(INT, this.exp(e.hi), e.hi.span, "as a `for` bound");
    e.sym = new VarSym(e.name, INT, false, this.depth);
    this.push();
    this.bindVal(e.name, e.sym);
    this.loops += 1;
    this.unify(UNIT, this.exp(e.body), e.body.span, "in a `for` body");
    this.loops -= 1;
    this.pop();
    return UNIT;
  }
}

/** Type the program in place: every node comes back with its `ty` filled in. */
export const check = (prog: ast.Program): void => new Checker().program(prog);
