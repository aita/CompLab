// A Pratt parser.
//
// Every expression form is either a prefix form (`nud`, in `atom`) or an infix
// one (`led`, in `exp`), and the table below is the whole of the precedence.
// The prefix forms that end in an expression — `if`, `while`, `for`, `:=` — take
// their tail at binding power 0, so `if c then x := 1 else x := 2` reads the way
// it looks.

import * as ast from "./ast.ts";
import { parseError } from "./diag.ts";
import { lex, TEXT, Token, type Tok } from "./lexer.ts";

const BP = new Map<Tok, [number, number]>([
  ["ASSIGN", [2, 1]], // right associative
  ["ORELSE", [4, 5]],
  ["ANDALSO", [6, 7]],
  ["EQ", [8, 9]],
  ["NE", [8, 9]],
  ["LT", [8, 9]],
  ["LE", [8, 9]],
  ["GT", [8, 9]],
  ["GE", [8, 9]],
  ["CARET", [10, 11]],
  ["PLUS", [12, 13]],
  ["MINUS", [12, 13]],
  ["STAR", [14, 15]],
  ["SLASH", [14, 15]],
  ["MOD", [14, 15]],
]);

const UNARY_BP = 16;

const BINOPS = new Map<Tok, string>([
  ["PLUS", "+"], ["MINUS", "-"], ["STAR", "*"], ["SLASH", "/"], ["MOD", "mod"],
  ["CARET", "^"], ["EQ", "="], ["NE", "<>"], ["LT", "<"], ["LE", "<="],
  ["GT", ">"], ["GE", ">="],
]);

const DECL_STARTERS = new Set<Tok>(["VAL", "VAR", "FUN", "TYPE"]);

class Parser {
  private readonly toks: Token[];
  private pos = 0;

  constructor(toks: Token[]) {
    this.toks = toks;
  }

  // -- token plumbing -----------------------------------------------------

  get cur(): Token {
    return this.toks[this.pos]!;
  }

  at(kind: Tok): boolean {
    return this.cur.kind === kind;
  }

  take(kind: Tok): Token | null {
    if (this.cur.kind !== kind) return null;
    const tok = this.cur;
    this.pos += 1;
    return tok;
  }

  took(kind: Tok): boolean {
    return this.take(kind) !== null;
  }

  expect(kind: Tok): Token {
    const tok = this.take(kind);
    if (tok === null) {
      throw parseError(this.cur.span, `expected \`${TEXT[kind]}\`, found ${this.cur}`);
    }
    return tok;
  }

  expectIdent(): Token {
    const tok = this.take("IDENT");
    if (tok === null) throw parseError(this.cur.span, `expected a name, found ${this.cur}`);
    return tok;
  }

  // -- programs and declarations ------------------------------------------

  program(): ast.Program {
    const decls: ast.Decl[] = [];
    while (!this.at("EOF")) decls.push(this.decl());
    return new ast.Program(decls);
  }

  decl(): ast.Decl {
    switch (this.cur.kind) {
      case "TYPE": return this.typeDecl();
      case "VAL": case "VAR": return this.valDecl();
      case "FUN": return this.funDecl();
      default:
        throw parseError(
          this.cur.span,
          `expected a declaration (\`val\`, \`var\`, \`fun\`, \`type\`), found ${this.cur}`,
        );
    }
  }

  typeDecl(): ast.TypeDecl {
    const span = this.expect("TYPE").span;
    const binds = [this.typeBind()];
    while (this.took("AND")) binds.push(this.typeBind());
    return new ast.TypeDecl(span, binds);
  }

  typeBind(): ast.TypeBind {
    const name = this.expectIdent();
    this.expect("EQ");
    return new ast.TypeBind(name.text, this.ty(), name.span);
  }

  valDecl(): ast.ValDecl {
    const mutable = this.cur.kind === "VAR";
    const span = this.cur.span;
    this.pos += 1;
    let name: string | null = null;
    if (this.took("LPAREN")) this.expect("RPAREN");
    else name = this.expectIdent().text;
    const ty = this.took("COLON") ? this.ty() : null;
    this.expect("EQ");
    return new ast.ValDecl(span, name, ty, this.exp(0), mutable);
  }

  funDecl(): ast.FunDecl {
    const span = this.expect("FUN").span;
    const binds = [this.funBind()];
    while (this.took("AND")) binds.push(this.funBind());
    return new ast.FunDecl(span, binds);
  }

  funBind(): ast.FunBind {
    const name = this.expectIdent();
    this.expect("LPAREN");
    const params: ast.Param[] = [];
    if (!this.took("RPAREN")) {
      for (;;) {
        const pname = this.expectIdent();
        this.expect("COLON");
        params.push(new ast.Param(pname.text, this.ty(), pname.span));
        if (!this.took("COMMA")) break;
      }
      this.expect("RPAREN");
    }
    const result = this.took("COLON") ? this.ty() : null;
    this.expect("EQ");
    return new ast.FunBind(name.text, params, result, this.exp(0), name.span);
  }

  // -- types --------------------------------------------------------------

  ty(): ast.TyExp {
    const span = this.cur.span;
    let base: ast.TyExp;
    if (this.took("LBRACE")) {
      const fields: ast.TyField[] = [];
      if (!this.took("RBRACE")) {
        for (;;) {
          const fname = this.expectIdent();
          this.expect("COLON");
          fields.push(new ast.TyField(fname.text, this.ty(), fname.span));
          if (!this.took("COMMA")) break;
        }
        this.expect("RBRACE");
      }
      base = new ast.TyRecord(span, fields);
    } else if (this.took("LPAREN")) {
      base = this.ty();
      this.expect("RPAREN");
    } else {
      base = new ast.TyName(span, this.expectIdent().text);
    }
    while (this.cur.kind === "IDENT" && this.cur.text === "array") {
      this.pos += 1;
      base = new ast.TyArray(span, base);
    }
    return base;
  }

  // -- expressions --------------------------------------------------------

  exp(minBp: number): ast.Exp {
    let left = this.atom();
    for (;;) {
      const bp = BP.get(this.cur.kind);
      if (bp === undefined || bp[0] < minBp) return left;
      const tok = this.cur;
      this.pos += 1;
      if (tok.kind === "ASSIGN") {
        this.checkLvalue(left);
        left = new ast.Assign(tok.span, left, this.exp(bp[1]));
      } else if (tok.kind === "ANDALSO" || tok.kind === "ORELSE") {
        left = new ast.Logic(tok.span, tok.text, left, this.exp(bp[1]));
      } else {
        left = new ast.Bin(tok.span, BINOPS.get(tok.kind)!, left, this.exp(bp[1]));
      }
    }
  }

  checkLvalue(e: ast.Exp): void {
    if (e instanceof ast.Var || e instanceof ast.Index || e instanceof ast.Field) return;
    throw parseError(e.span, "the left of `:=` is not assignable");
  }

  atom(): ast.Exp {
    const tok = this.cur;
    const span = tok.span;
    switch (tok.kind) {
      case "INT":
        this.pos += 1;
        return this.postfix(new ast.IntLit(span, this.integer(tok)));
      case "STRING":
        this.pos += 1;
        return this.postfix(new ast.StrLit(span, tok.text));
      case "TRUE": case "FALSE":
        this.pos += 1;
        return new ast.BoolLit(span, tok.kind === "TRUE");
      case "NIL":
        this.pos += 1;
        return new ast.NilLit(span);
      case "BREAK":
        this.pos += 1;
        return new ast.Break(span);
      case "TILDE":
        this.pos += 1;
        return new ast.Neg(span, this.exp(UNARY_BP));
      case "MINUS":
        throw parseError(span, "negation is written `~`, not `-`");
      case "LPAREN":
        return this.postfix(this.parens());
      case "IDENT":
        return this.postfix(this.named());
      case "IF": return this.ifExp();
      case "WHILE": return this.whileExp();
      case "FOR": return this.forExp();
      case "LET": return this.letExp();
      default:
        throw parseError(span, `expected an expression, found ${this.cur}`);
    }
  }

  /** Integers are 64 bits and wrap, so the largest is `~9223372036854775808`. */
  integer(tok: Token): bigint {
    const value = BigInt(tok.text);
    if (value >= 1n << 64n) {
      throw parseError(tok.span, `\`${tok.text}\` does not fit in 64 bits`);
    }
    return BigInt.asIntN(64, value);
  }

  parens(): ast.Exp {
    const span = this.expect("LPAREN").span;
    if (this.took("RPAREN")) return new ast.UnitLit(span);
    const items = this.sequence("RPAREN");
    this.expect("RPAREN");
    return items.length === 1 ? items[0]! : new ast.Seq(span, items);
  }

  sequence(end: Tok): ast.Exp[] {
    const items = [this.exp(0)];
    while (this.took("SEMI")) {
      if (this.at(end)) break;
      items.push(this.exp(0));
    }
    return items;
  }

  named(): ast.Exp {
    const tok = this.expectIdent();
    if (this.cur.kind === "LPAREN") {
      this.pos += 1;
      const args: ast.Exp[] = [];
      if (!this.took("RPAREN")) {
        for (;;) {
          args.push(this.exp(0));
          if (!this.took("COMMA")) break;
        }
        this.expect("RPAREN");
      }
      return new ast.Call(tok.span, tok.text, args);
    }
    if (this.cur.kind === "LBRACE") {
      this.pos += 1;
      const fields: ast.FieldInit[] = [];
      if (!this.took("RBRACE")) {
        for (;;) {
          const fname = this.expectIdent();
          this.expect("EQ");
          fields.push(new ast.FieldInit(fname.text, this.exp(0), fname.span));
          if (!this.took("COMMA")) break;
        }
        this.expect("RBRACE");
      }
      return new ast.RecordLit(tok.span, tok.text, fields);
    }
    return new ast.Var(tok.span, tok.text);
  }

  postfix(start: ast.Exp): ast.Exp {
    let base = start;
    for (;;) {
      if (this.cur.kind === "LBRACK") {
        const span = this.cur.span;
        this.pos += 1;
        const index = this.exp(0);
        this.expect("RBRACK");
        base = new ast.Index(span, base, index);
      } else if (this.cur.kind === "DOT") {
        const span = this.cur.span;
        this.pos += 1;
        base = new ast.Field(span, base, this.expectIdent().text);
      } else {
        return base;
      }
    }
  }

  ifExp(): ast.Exp {
    const span = this.expect("IF").span;
    const cond = this.exp(0);
    this.expect("THEN");
    const then = this.exp(0);
    const els = this.took("ELSE") ? this.exp(0) : null;
    return new ast.If(span, cond, then, els);
  }

  whileExp(): ast.Exp {
    const span = this.expect("WHILE").span;
    const cond = this.exp(0);
    this.expect("DO");
    return new ast.While(span, cond, this.exp(0));
  }

  forExp(): ast.Exp {
    const span = this.expect("FOR").span;
    const name = this.expectIdent();
    this.expect("EQ");
    const lo = this.exp(0);
    this.expect("TO");
    const hi = this.exp(0);
    this.expect("DO");
    return new ast.For(span, name.text, lo, hi, this.exp(0));
  }

  letExp(): ast.Exp {
    const span = this.expect("LET").span;
    const decls: ast.Decl[] = [];
    while (DECL_STARTERS.has(this.cur.kind)) decls.push(this.decl());
    this.expect("IN");
    let body: ast.Exp;
    if (this.at("END")) {
      body = new ast.UnitLit(span);
    } else {
      const items = this.sequence("END");
      body = items.length === 1 ? items[0]! : new ast.Seq(span, items);
    }
    this.expect("END");
    return new ast.Let(span, decls, body);
  }
}

export const parse = (source: string): ast.Program => new Parser(lex(source)).program();

/** Parse a single expression — the tests use it, the compiler does not. */
export function parseExp(source: string): ast.Exp {
  const p = new Parser(lex(source));
  const e = p.exp(0);
  if (!p.at("EOF")) throw parseError(p.cur.span, `unexpected ${p.cur} after the expression`);
  return e;
}
