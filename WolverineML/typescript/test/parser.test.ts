import { test } from "node:test";
import assert from "node:assert/strict";

import * as ast from "../src/ast.ts";
import { WolvError } from "../src/diag.ts";
import { parse, parseExp } from "../src/parser.ts";

/** A parenthesised sketch of the tree, so precedence is easy to assert. */
function shape(e: ast.Exp): string {
  if (e instanceof ast.IntLit) return String(e.value);
  if (e instanceof ast.StrLit) return `"${e.value}"`;
  if (e instanceof ast.BoolLit) return e.value ? "true" : "false";
  if (e instanceof ast.NilLit) return "nil";
  if (e instanceof ast.UnitLit) return "()";
  if (e instanceof ast.Var) return e.name;
  if (e instanceof ast.Neg) return `(~ ${shape(e.operand)})`;
  if (e instanceof ast.Bin || e instanceof ast.Logic) {
    return `(${e.op} ${shape(e.lhs)} ${shape(e.rhs)})`;
  }
  if (e instanceof ast.Assign) return `(:= ${shape(e.target)} ${shape(e.value)})`;
  if (e instanceof ast.If) {
    return `(if ${shape(e.cond)} ${shape(e.then)}${e.els === null ? "" : " " + shape(e.els)})`;
  }
  if (e instanceof ast.While) return `(while ${shape(e.cond)} ${shape(e.body)})`;
  if (e instanceof ast.For) {
    return `(for ${e.name} ${shape(e.lo)} ${shape(e.hi)} ${shape(e.body)})`;
  }
  if (e instanceof ast.Break) return "break";
  if (e instanceof ast.Seq) return `(seq ${e.items.map(shape).join(" ")})`;
  if (e instanceof ast.Call) return `(${e.name} ${e.args.map(shape).join(" ")})`;
  if (e instanceof ast.Index) return `(index ${shape(e.array)} ${shape(e.index)})`;
  if (e instanceof ast.Field) return `(field ${shape(e.record)} ${e.name})`;
  if (e instanceof ast.RecordLit) {
    const inner = e.fields.map((f) => `${f.name}=${shape(f.value)}`).join(" ");
    return `(record ${e.tyname} ${inner})`;
  }
  return `(let ${e.decls.length} ${shape(e.body)})`;
}

const parses = (source: string, want: string): void => {
  assert.equal(shape(parseExp(source)), want, source);
};

const refuses = (source: string, want: string): void => {
  assert.throws(() => parseExp(source), (e: unknown) => {
    assert.ok(e instanceof WolvError);
    assert.ok(e.detail.includes(want), `${e.detail} should mention ${want}`);
    return true;
  });
};

test("arithmetic precedence", () => {
  parses("1 + 2 * 3", "(+ 1 (* 2 3))");
  parses("1 * 2 + 3", "(+ (* 1 2) 3)");
  parses("1 - 2 - 3", "(- (- 1 2) 3)");
  parses("1 + 2 = 3", "(= (+ 1 2) 3)");
});

test("logic binds looser than comparison", () => {
  parses("a < b andalso c > d", "(andalso (< a b) (> c d))");
  parses("a orelse b andalso c", "(orelse a (andalso b c))");
});

test("assignment is right associative and loosest", () => {
  parses("x := y + 1", "(:= x (+ y 1))");
  parses("a := b := c", "(:= a (:= b c))");
});

test("a branch swallows what follows it", () => {
  parses("if c then x := 1 else x := 2", "(if c (:= x 1) (:= x 2))");
  parses("if c then a else b + 1", "(if c a (+ b 1))");
});

test("postfix chains", () => {
  parses("a[i].f[j]", "(index (field (index a i) f) j)");
  parses("f(1, 2).g", "(field (f 1 2) g)");
  parses("(if c then a else b).f", "(field (if c a b) f)");
  refuses("nil.f", "unexpected");
});

test("sequences and unit", () => {
  parses("()", "()");
  parses("(a; b; c)", "(seq a b c)");
  parses("(a; b;)", "(seq a b)");
  parses("(a)", "a");
});

test("negation is a tilde", () => {
  parses("~x + 1", "(+ (~ x) 1)");
  parses("~x * y", "(* (~ x) y)");
  refuses("-x", "negation is written");
});

test("the largest literal is the one that wraps", () => {
  parses("~9223372036854775808", "(~ -9223372036854775808)");
  refuses("18446744073709551616", "does not fit in 64 bits");
});

test("record literal versus call", () => {
  parses("point { x = 1, y = 2 }", "(record point x=1 y=2)");
  parses("point (1, 2)", "(point 1 2)");
});

test("let with declarations", () => {
  parses("let val x = 1 var y = 2 in x + y end", "(let 2 (+ x y))");
  parses("let val x = 1 in end", "(let 1 ())");
});

test("a program is declarations", () => {
  const prog = parse("type t = int\nval x = 1\nfun f (a : int) : int = a\n");
  assert.ok(prog.decls[0] instanceof ast.TypeDecl);
  assert.ok(prog.decls[1] instanceof ast.ValDecl);
  assert.ok(prog.decls[2] instanceof ast.FunDecl);
});

test("mutual recursion is one declaration", () => {
  const prog = parse("fun f () : int = g ()\nand g () : int = 1\n");
  const decl = prog.decls[0];
  assert.ok(decl instanceof ast.FunDecl);
  assert.deepEqual(decl.binds.map((b) => b.name), ["f", "g"]);
});

test("only a place can be assigned", () => refuses("1 + 2 := 3", "not assignable"));

test("errors name what was found", () => refuses("if a do b", "expected `then`"));
