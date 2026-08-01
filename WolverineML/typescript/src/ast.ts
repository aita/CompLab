// The syntax tree.
//
// The tree the parser builds is untyped; the checker fills in the `ty` and `sym`
// fields as it goes, and everything after it reads them.

import type { Span } from "./diag.ts";
import type { FunSym, Type, VarSym } from "./types.ts";

// -- types as they are written ------------------------------------------------

export class TyName {
  readonly span: Span;
  readonly name: string;
  constructor(span: Span, name: string) { this.span = span; this.name = name; }
}

export class TyArray {
  readonly span: Span;
  readonly elem: TyExp;
  constructor(span: Span, elem: TyExp) { this.span = span; this.elem = elem; }
}

export class TyField {
  readonly name: string;
  readonly ty: TyExp;
  readonly span: Span;
  constructor(name: string, ty: TyExp, span: Span) {
    this.name = name; this.ty = ty; this.span = span;
  }
}

export class TyRecord {
  readonly span: Span;
  readonly fields: TyField[];
  constructor(span: Span, fields: TyField[]) { this.span = span; this.fields = fields; }
}

export type TyExp = TyName | TyArray | TyRecord;

// -- expressions --------------------------------------------------------------

/** What every expression carries: where it was written, and what it is. */
export abstract class Node {
  readonly span: Span;
  ty: Type | null = null;
  constructor(span: Span) { this.span = span; }
}

export class IntLit extends Node {
  readonly value: bigint;
  constructor(span: Span, value: bigint) { super(span); this.value = value; }
}

export class StrLit extends Node {
  readonly value: string;
  constructor(span: Span, value: string) { super(span); this.value = value; }
}

export class BoolLit extends Node {
  readonly value: boolean;
  constructor(span: Span, value: boolean) { super(span); this.value = value; }
}

export class NilLit extends Node {}

export class UnitLit extends Node {}

export class Var extends Node {
  readonly name: string;
  sym: VarSym | null = null;
  constructor(span: Span, name: string) { super(span); this.name = name; }
}

export class Call extends Node {
  readonly name: string;
  readonly args: Exp[];
  sym: FunSym | null = null;
  constructor(span: Span, name: string, args: Exp[]) {
    super(span); this.name = name; this.args = args;
  }
}

export class FieldInit {
  readonly name: string;
  readonly value: Exp;
  readonly span: Span;
  constructor(name: string, value: Exp, span: Span) {
    this.name = name; this.value = value; this.span = span;
  }
}

export class RecordLit extends Node {
  readonly tyname: string;
  fields: FieldInit[];
  constructor(span: Span, tyname: string, fields: FieldInit[]) {
    super(span); this.tyname = tyname; this.fields = fields;
  }
}

export class Index extends Node {
  readonly array: Exp;
  readonly index: Exp;
  constructor(span: Span, array: Exp, index: Exp) {
    super(span); this.array = array; this.index = index;
  }
}

export class Field extends Node {
  readonly record: Exp;
  readonly name: string;
  offset = -1;
  constructor(span: Span, record: Exp, name: string) {
    super(span); this.record = record; this.name = name;
  }
}

export class Neg extends Node {
  readonly operand: Exp;
  constructor(span: Span, operand: Exp) { super(span); this.operand = operand; }
}

export class Bin extends Node {
  readonly op: string;
  readonly lhs: Exp;
  readonly rhs: Exp;
  constructor(span: Span, op: string, lhs: Exp, rhs: Exp) {
    super(span); this.op = op; this.lhs = lhs; this.rhs = rhs;
  }
}

/** `andalso` and `orelse`, which are control flow, not operators. */
export class Logic extends Node {
  readonly op: string;
  readonly lhs: Exp;
  readonly rhs: Exp;
  constructor(span: Span, op: string, lhs: Exp, rhs: Exp) {
    super(span); this.op = op; this.lhs = lhs; this.rhs = rhs;
  }
}

export class Assign extends Node {
  readonly target: Exp;
  readonly value: Exp;
  constructor(span: Span, target: Exp, value: Exp) {
    super(span); this.target = target; this.value = value;
  }
}

export class If extends Node {
  readonly cond: Exp;
  readonly then: Exp;
  readonly els: Exp | null;
  constructor(span: Span, cond: Exp, then: Exp, els: Exp | null) {
    super(span); this.cond = cond; this.then = then; this.els = els;
  }
}

export class While extends Node {
  readonly cond: Exp;
  readonly body: Exp;
  constructor(span: Span, cond: Exp, body: Exp) {
    super(span); this.cond = cond; this.body = body;
  }
}

export class For extends Node {
  readonly name: string;
  readonly lo: Exp;
  readonly hi: Exp;
  readonly body: Exp;
  sym: VarSym | null = null;
  constructor(span: Span, name: string, lo: Exp, hi: Exp, body: Exp) {
    super(span); this.name = name; this.lo = lo; this.hi = hi; this.body = body;
  }
}

export class Break extends Node {}

export class Seq extends Node {
  readonly items: Exp[];
  constructor(span: Span, items: Exp[]) { super(span); this.items = items; }
}

export class Let extends Node {
  readonly decls: Decl[];
  readonly body: Exp;
  constructor(span: Span, decls: Decl[], body: Exp) {
    super(span); this.decls = decls; this.body = body;
  }
}

export type Exp =
  | IntLit | StrLit | BoolLit | NilLit | UnitLit | Var | Call | RecordLit
  | Index | Field | Neg | Bin | Logic | Assign | If | While | For | Break
  | Seq | Let;

// -- declarations -------------------------------------------------------------

export class TypeBind {
  readonly name: string;
  readonly ty: TyExp;
  readonly span: Span;
  constructor(name: string, ty: TyExp, span: Span) {
    this.name = name; this.ty = ty; this.span = span;
  }
}

export class TypeDecl {
  readonly span: Span;
  readonly binds: TypeBind[];
  constructor(span: Span, binds: TypeBind[]) { this.span = span; this.binds = binds; }
}

export class ValDecl {
  readonly span: Span;
  readonly name: string | null;
  readonly ty: TyExp | null;
  readonly init: Exp;
  readonly mutable: boolean;
  sym: VarSym | null = null;
  constructor(span: Span, name: string | null, ty: TyExp | null, init: Exp, mutable: boolean) {
    this.span = span; this.name = name; this.ty = ty; this.init = init; this.mutable = mutable;
  }
}

export class Param {
  readonly name: string;
  readonly ty: TyExp;
  readonly span: Span;
  sym: VarSym | null = null;
  constructor(name: string, ty: TyExp, span: Span) {
    this.name = name; this.ty = ty; this.span = span;
  }
}

export class FunBind {
  readonly name: string;
  readonly params: Param[];
  readonly result: TyExp | null;
  readonly body: Exp;
  readonly span: Span;
  sym: FunSym | null = null;
  constructor(name: string, params: Param[], result: TyExp | null, body: Exp, span: Span) {
    this.name = name; this.params = params; this.result = result;
    this.body = body; this.span = span;
  }
}

export class FunDecl {
  readonly span: Span;
  readonly binds: FunBind[];
  constructor(span: Span, binds: FunBind[]) { this.span = span; this.binds = binds; }
}

export type Decl = TypeDecl | ValDecl | FunDecl;

export class Program {
  readonly decls: Decl[];
  constructor(decls: Decl[]) { this.decls = decls; }
}
