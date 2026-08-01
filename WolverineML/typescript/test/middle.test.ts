import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import * as ast from "../src/ast.ts";
import { WolvError } from "../src/diag.ts";
import * as dag from "../src/dag.ts";
import * as driver from "../src/driver.ts";
import * as ir from "../src/ir.ts";
import * as liveness from "../src/liveness.ts";
import * as lower from "../src/lower.ts";
import { Mach } from "../src/mach.ts";
import * as opt from "../src/opt.ts";
import { parse } from "../src/parser.ts";
import * as select from "../src/select.ts";
import * as ssa from "../src/ssa.ts";
import { check } from "../src/typecheck.ts";

// -- the checker ---------------------------------------------------------------

const accepts = (source: string): ast.Program => {
  const prog = parse(source);
  check(prog);
  return prog;
};

const rejects = (source: string, want: string): void => {
  assert.throws(() => accepts(source), (e: unknown) => {
    assert.ok(e instanceof WolvError, `${e} should be a WolvError`);
    assert.ok(e.detail.includes(want), `${e.detail} should mention ${want}`);
    return true;
  });
};

test("arithmetic is on ints", () => {
  accepts("val x = 1 + 2");
  rejects('val x = 1 + "a"', "expected `int`, found `string`");
  rejects("val x = true + 1", "expected `int`, found `bool`");
});

test("concatenation is on strings", () => {
  accepts('val s = "a" ^ "b"');
  rejects('val s = "a" ^ 1', "expected `string`, found `int`");
});

test("comparison gives bool", () => {
  accepts("val b = 1 < 2 andalso 3 >= 4");
  rejects('val b = "a" < 1', "expected `string`, found `int`");
  rejects("val b = true < false", "compares int or string");
});

test("equality needs one type", () => {
  accepts("val b = 1 = 2");
  rejects("val b = 1 = true", "compares `int` with `bool`");
});

test("conditions are bool", () => {
  accepts("val x = if true then 1 else 2");
  rejects("val x = if 1 then 1 else 2", "expected `bool`, found `int`");
  rejects('val x = if true then 1 else "a"', "the branches differ");
  rejects("val () = if true then 1", "in an `if` with no `else`");
});

test("a val cannot be assigned", () => {
  accepts("var x = 1 val () = x := 2");
  rejects("val x = 1 val () = x := 2", "is a `val`");
});

test("functions check their arguments", () => {
  accepts("fun f (a : int) : int = a\nval x = f (1)");
  rejects("fun f (a : int) : int = a\nval x = f (1, 2)", "takes 1 argument");
});

test("a fun without a result is a procedure", () => {
  accepts('fun f () = print ("x")\nval () = f ()');
  rejects("fun f () = 1", "expected `unit`, found `int`");
});

test("functions are not values", () => {
  rejects("fun f () : int = 1\nval x = f", "functions are not values");
});

test("records are nominal", () => {
  accepts("type p = { x : int }\nval a = p { x = 1 }\nval b = a.x");
  rejects(
    "type p = { x : int } and q = { x : int }\n"
    + "fun f (r : p) : int = r.x\nval x = f (q { x = 1 })",
    "expected `p`, found `q`",
  );
  rejects("type p = { x : int }\nval a = p { y = 1 }", "has no field `y`");
  rejects("type p = { x : int, y : int }\nval a = p { x = 1 }", "field `y` is missing");
});

test("nil is a record of any type", () => {
  accepts("type p = { x : int }\nval a : p = nil\nval b = a = nil");
  rejects("val a = nil", "needs a type annotation");
});

test("arrays know their element", () => {
  accepts("val a = array (3, 0)\nval x = a[0] + 1");
  accepts("type ints = int array\nval a : ints = array (3, 0)");
  rejects("val a = array (3, 0)\nval x = a[true]", "as an array index");
  rejects("val x = length (1)", "`length` wants an array");
});

test("break is inside a loop", () => {
  accepts("val () = while true do break");
  accepts("val () = for i = 0 to 3 do break");
  rejects("val () = break", "outside any loop");
  rejects("val () = while true do let fun f () = break in f () end", "outside any loop");
});

test("recursive types", () => {
  accepts(
    "type list = { head : int, tail : list }\n"
    + "fun sum (l : list) : int = if l = nil then 0 else l.head + sum (l.tail)\n",
  );
  accepts("type a = b array and b = { next : a }");
});

test("unbound names", () => {
  rejects("val x = y", "`y` is not bound");
  rejects("val x : t = 1", "`t` is not a type");
});

test("escape analysis marks what a nested function reads", () => {
  const prog = accepts(
    "fun outer () : int =\n"
    + "  let var kept = 1\n"
    + "      val plain = 2\n"
    + "      fun inner () : int = kept\n"
    + "  in inner () + plain end\n",
  );
  const decl = prog.decls[0];
  assert.ok(decl instanceof ast.FunDecl);
  const body = decl.binds[0]!.body;
  assert.ok(body instanceof ast.Let);
  const kept = body.decls[0];
  const plain = body.decls[1];
  assert.ok(kept instanceof ast.ValDecl && plain instanceof ast.ValDecl);
  assert.ok(kept.sym!.escapes);
  assert.ok(!plain.sym!.escapes);
});

test("a parameter escapes too", () => {
  const prog = accepts(
    "fun outer (n : int) : int =\n  let fun inner () : int = n in inner () end\n",
  );
  const decl = prog.decls[0];
  assert.ok(decl instanceof ast.FunDecl);
  assert.ok(decl.binds[0]!.params[0]!.sym!.escapes);
});

// -- SSA and the optimiser -----------------------------------------------------

const LOOP = `
fun count (n : int) : int =
  let var i = 0
      var total = 0
  in
    while i < n do (total := total + i; i := i + 1);
    total
  end
val () = printInt (count (10))
`;

const lowered = (source: string, checks = false): ir.Module =>
  lower.lower(accepts(source), new lower.Options(checks));

const inSSA = (source: string, checks = false): ir.Module => {
  const mod = lowered(source, checks);
  ssa.constructModule(mod);
  return mod;
};

test("lowering writes a variable more than once and builds no phi", () => {
  const f = lowered(LOOP).funcs[1]!;
  const written = new Map<number, number>();
  for (const b of f.walk()) {
    for (const instr of b.instrs) {
      const d = instr.defs();
      if (d !== null) written.set(d, (written.get(d) ?? 0) + 1);
    }
    assert.equal(b.phis.length, 0);
  }
  assert.ok([...written.values()].some((n) => n > 1));
});

test("construction gives one definition and phis", () => {
  const f = inSSA(LOOP).funcs[1]!;
  ssa.verify(f);
  assert.ok(f.walk().some((b) => b.phis.length > 0), "a loop needs phis");
});

test("every function of the tour verifies", () => {
  const source = readFileSync("examples/tour.wol", "utf8");
  for (const f of inSSA(source, true).funcs) ssa.verify(f);
});

test("dominance of a diamond", () => {
  const f = inSSA(
    "fun f (c : bool) : int = if c then 1 else 2\nval () = printInt (f (true))",
  ).funcs[1]!;
  const dom = ssa.dominance(f);
  for (const label of f.blocks.keys()) assert.ok(dom.dominates(f.entry, label));
  const joins = f.walk().filter((b) => b.preds.length > 1);
  assert.ok(joins.length > 0, "a diamond has a join");
  for (const join of joins) assert.equal(dom.idom.get(join.label), f.entry);
});

test("a phi names exactly its predecessors", () => {
  for (const f of inSSA(LOOP).funcs) {
    for (const b of f.walk()) {
      for (const phi of b.phis) {
        assert.deepEqual([...phi.args.keys()].sort(), [...b.preds].sort());
      }
    }
  }
});

test("optimisation keeps it in ssa", () => {
  const mod = inSSA(LOOP);
  opt.optimise(mod);
  for (const f of mod.funcs) ssa.verify(f);
});

test("constants fold", () => {
  const mod = inSSA("val () = printInt (2 * 3 + 4)");
  opt.optimise(mod);
  const values = mod.funcs[0]!.walk()
    .flatMap((b) => b.instrs)
    .filter((i) => i instanceof ir.Const)
    .map((i) => i.value);
  assert.deepEqual(values, [10n]);
});

test("dead code goes", () => {
  const mod = inSSA(
    "fun f (n : int) : int = let val unused = n * n in n + 1 end\nval () = printInt (f (2))",
  );
  opt.optimise(mod);
  const survived = mod.funcs[1]!.walk()
    .flatMap((b) => b.instrs)
    .some((i) => i instanceof ir.Bin && i.op === "*");
  assert.ok(!survived);
});

test("unreachable blocks go", () => {
  const mod = inSSA('val () = if true then print ("a") else print ("b")');
  opt.optimise(mod);
  const calls = mod.funcs[0]!.walk()
    .flatMap((b) => b.instrs)
    .filter((i) => i instanceof ir.Call)
    .map((i) => i.callee);
  assert.deepEqual(calls, ["wol_print"]);
});

test("splitting leaves phis only after a jump", () => {
  const mod = inSSA(LOOP, true);
  opt.optimise(mod);
  for (const f of mod.funcs) {
    ssa.splitCriticalEdges(f);
    ssa.verify(f);
    for (const b of f.walk()) {
      if (b.succs.length <= 1) continue;
      for (const succ of b.succs) assert.equal(f.block(succ).phis.length, 0);
    }
  }
});

// -- instruction selection -----------------------------------------------------

const selected = (source: string, checks = false): ir.Module => {
  const mod = inSSA(source, checks);
  opt.optimise(mod);
  for (const f of mod.funcs) ssa.splitCriticalEdges(f);
  select.selectModule(mod);
  return mod;
};

const body = (exp: string): string =>
  `fun f (a : int, b : int, c : int) : int = ${exp}\nval () = printInt (f (1, 2, 3))`;

const forms = (source: string, name = "f"): string[] =>
  selected(source).funcs.filter((f) => f.name === name)
    .flatMap((f) => f.walk())
    .flatMap((b) => b.instrs)
    .filter((i) => i instanceof Mach)
    .map((i) => i.form);

const chosen = (exp: string): string[] => forms(body(exp));
const counts = (list: string[], want: string): number => list.filter((x) => x === want).length;

test("multiply-add is one instruction", () => {
  const got = chosen("a + b * c");
  assert.ok(got.includes("madd") && !got.includes("mul"), got.join(","));
});

test("multiply-subtract is one instruction", () => {
  const got = chosen("a - b * c");
  assert.ok(got.includes("msub") && !got.includes("mul"), got.join(","));
});

test("a shifted operand beats a multiply-add", () => {
  const got = chosen("a + b * 8");
  assert.equal(counts(got, "adds"), 1);
  assert.ok(!got.includes("madd") && !got.includes("lsli"));
});

test("a small constant is an immediate", () => {
  assert.deepEqual(chosen("a + 5"), ["addi"]);
  assert.deepEqual(chosen("(a + 5) - 7"), ["addi", "subi"]);
});

test("a large constant is not", () => {
  assert.ok(chosen("a + 100000").includes("const"));
});

test("a multiply by a power of two is a shift", () => {
  const got = chosen("a * 8");
  assert.ok(got.includes("lsli") && !got.includes("mul"));
});

test("a comparison read only by its branch sets the flags", () => {
  const source = "fun f (a : int) : int = if a < 3 then 1 else 2\nval () = printInt (f (1))";
  const codes = selected(source).funcs
    .flatMap((f) => f.walk())
    .map((b) => b.terminator)
    .filter((t) => t instanceof ir.CBr)
    .map((t) => t.code);
  assert.ok(codes.includes("lt"));
  assert.ok(!forms(source).includes("cset"));
});

test("a comparison read by something else is a value", () => {
  assert.ok(forms('fun f (a : int) : bool = a < 3\nval () = print ("x")').includes("cset"));
});

test("a constant read twice is still an immediate", () => {
  const got = chosen("(a + 1) * (b + 1)");
  assert.equal(counts(got, "addi"), 2);
  assert.ok(!got.includes("const"));
});

test("a node read twice is computed once", () => {
  assert.equal(counts(chosen("let val t = a * b in t + t end"), "mul"), 1);
});

test("a chain of additions is not deferred to its last line", () => {
  const source = "fun sum (a : int, b : int, c : int, d : int, e : int, f : int) : int =\n"
    + "  a + b + c + d + e + f\nval () = printInt (sum (1, 2, 3, 4, 5, 6))\n";
  for (const f of selected(source).funcs) {
    if (f.name !== "sum") continue;
    assert.ok(liveness.pressure(f, liveness.analyse(f)) <= 8);
  }
});

test("the graph counts its readers", () => {
  for (const f of selected(body("a + b")).funcs) {
    if (f.name !== "f") continue;
    const live = liveness.analyse(f);
    for (const b of f.walk()) {
      const graph = dag.build(b, live.out(b.label));
      for (const node of graph.nodes) {
        const expected = graph.nodes
          .flatMap((other) => other.operands)
          .filter((o) => o === node.index).length;
        assert.equal(node.users, expected);
      }
    }
  }
});

test("selection keeps ssa", () => {
  for (const f of selected(body("a + b * c + 8"), true).funcs) ssa.verify(f);
});

test("the remainder is a divide and an msub", () => {
  const text = driver.compileToAsm(
    "fun f (a : int, b : int) : int = a mod b\nval () = printInt (f (7, 2))",
    new driver.Options(false),
  );
  assert.equal(text.split("sdiv").length - 1, 1);
  assert.equal(text.split("msub").length - 1, 1);
  assert.ok(!text.includes("mul"));
});

test("ordinary code keeps no register back", () => {
  const source = readFileSync("examples/tour.wol", "utf8");
  assert.ok(!driver.compileToAsm(source, new driver.Options(false)).includes("x17"));
});

test("x16 is allocatable", () => {
  const source = readFileSync("test/programs/pressure.wol", "utf8");
  assert.ok(driver.compileToAsm(source, new driver.Options(false)).includes("x16"));
});

test("an array element takes two instructions", () => {
  const text = driver.compileToAsm(
    "val a = array (4, 0)\nval () = printInt (a[2] + a[3])",
    new driver.Options(false),
  );
  const loads = text.split("\n").filter((l) => l.startsWith("\tldr ")).length;
  assert.equal(loads, 2);
});
