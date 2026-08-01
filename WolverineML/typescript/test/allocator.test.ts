import { test } from "node:test";
import assert from "node:assert/strict";

import * as allocator from "../src/allocator.ts";
import * as copies from "../src/copies.ts";
import * as ir from "../src/ir.ts";
import * as liveness from "../src/liveness.ts";
import * as lower from "../src/lower.ts";
import * as opt from "../src/opt.ts";
import * as outofssa from "../src/outofssa.ts";
import { parse } from "../src/parser.ts";
import * as registers from "../src/registers.ts";
import * as select from "../src/select.ts";
import * as ssa from "../src/ssa.ts";
import { OutOfRegisters } from "../src/spill.ts";
import { check } from "../src/typecheck.ts";

const SOURCE = `
type point = { x : int, y : int }

fun busy (n : int) : int =
  let
    var a = n + 1
    var b = n + 2
    var c = n + 3
    var d = n + 4
    var total = 0
  in
    while a < n * 10 do (
      total := total + a * b + c * d;
      a := a + 1;
      b := b + 2;
      c := c + 3;
      d := d + 4
    );
    total
  end

fun caller (n : int) : int = busy (n) + busy (n + 1) + busy (n + 2)

val p = point { x = 1, y = 2 }
val () = printInt (caller (3) + p.x)
`;

/** The pipeline up to the point where the allocator takes over. */
function prepared(source = SOURCE): ir.Module {
  const prog = parse(source);
  check(prog);
  const mod = lower.lower(prog, new lower.Options(true));
  ssa.constructModule(mod);
  opt.optimise(mod);
  for (const f of mod.funcs) ssa.splitCriticalEdges(f);
  select.selectModule(mod);
  outofssa.destructModule(mod);
  return mod;
}

function allocated(machine = new registers.Registers(), source = SOURCE): ir.Module {
  const mod = prepared(source);
  allocator.allocateModule(mod, machine);
  return mod;
}

test("every value gets a colour", () => {
  for (const f of allocated().funcs) {
    for (const b of f.walk()) {
      for (const instr of b.instrs) {
        for (const r of instr.uses()) assert.ok(f.colours.has(r), `%${r}`);
        const d = instr.defs();
        if (d !== null) assert.ok(f.colours.has(d), `%${d}`);
      }
    }
  }
});

test("values live together differ", () => {
  for (const f of allocated().funcs) allocator.verify(f);
});

// Without the optimiser the copies survive to the allocator, and coalescing gives
// both ends of one copy the same register.  That is right, and it is what a
// verifier reading whole live sets would reject.
test("they differ without the optimiser too", () => {
  const prog = parse(SOURCE);
  check(prog);
  const mod = lower.lower(prog, new lower.Options(true));
  ssa.constructModule(mod);
  for (const f of mod.funcs) ssa.splitCriticalEdges(f);
  select.selectModule(mod);
  outofssa.destructModule(mod);
  allocator.allocateModule(mod, new registers.Registers());
  for (const f of mod.funcs) allocator.verify(f);
});

// Both ends of a copy hold the same value, so one register for the two is right.
test("a coalesced copy is not a clash", () => {
  const f = new ir.Func("f", "f", 0);
  const entry = f.addBlock("entry");
  const a = f.newReg();
  const b = f.newReg();
  entry.instrs.push(new ir.Const(a, 1n));
  entry.instrs.push(new ir.Move(b, a));
  entry.instrs.push(new ir.Call(null, "wol_print_int", [a]));
  entry.instrs.push(new ir.Ret(b));
  f.colours = new Map([[a, 9], [b, 9]]);
  allocator.verify(f);
});

// So the case above did not simply stop the verifier saying anything.
test("one colour for everything is rejected", () => {
  for (const f of allocated().funcs) {
    if (new Set(f.colours.values()).size < 2) continue;
    f.colours = new Map([...f.colours.keys()].map((r) => [r, 0]));
    assert.throws(() => allocator.verify(f), /at once/);
  }
});

test("a value live across a call is callee-saved", () => {
  for (const f of allocated().funcs) {
    for (const r of liveness.acrossCalls(f, liveness.analyse(f))) {
      assert.ok(registers.isCalleeSaved(f.colours.get(r)!));
    }
  }
});

test("only the callee-saved it used are saved", () => {
  for (const f of allocated().funcs) {
    const used = [...new Set(f.colours.values())].filter(registers.isCalleeSaved).sort((a, b) => a - b);
    assert.deepEqual(f.saved, used);
  }
});

for (const size of [5, 6, 8, 12, 16, 26]) {
  test(`a machine of ${size} registers still works`, () => {
    const machine = registers.limited(size);
    for (const f of allocated(machine).funcs) {
      allocator.verify(f);
      for (const colour of f.colours.values()) assert.ok(machine.anywhere.includes(colour));
    }
  });
}

test("a small machine spills", () => {
  const mod = allocated(registers.limited(6));
  assert.ok(mod.funcs.some((f) => f.spillSlots.size > 0), "nothing spilled");
  for (const f of mod.funcs) {
    for (const slot of f.spillSlots.values()) assert.ok(slot < f.nslots);
  }
});

test("pressure falls to what the machine has", () => {
  const machine = registers.limited(5);
  for (const f of allocated(machine).funcs) {
    assert.ok(liveness.pressure(f, liveness.analyse(f)) <= machine.count());
  }
});

test("an impossible demand is reported", () => {
  const source = "fun ten (a : int, b : int, c : int, d : int, e : int,\n"
    + "         f : int, g : int, h : int, i : int, j : int) : int = a + j\n"
    + "val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))\n";
  const mod = prepared(source);
  assert.throws(
    () => allocator.allocateModule(mod, registers.limited(8)),
    (e: unknown) => {
      assert.ok(e instanceof OutOfRegisters);
      assert.ok(e.message.includes("more registers"));
      return true;
    },
  );
});

test("leaving ssa removes every phi", () => {
  for (const f of prepared().funcs) {
    for (const b of f.walk()) assert.equal(b.phis.length, 0);
  }
});

test("leaving ssa makes copies and coalescing eats them", () => {
  const mod = prepared();
  const before = mod.funcs
    .flatMap((f) => f.walk())
    .flatMap((b) => b.instrs)
    .filter((i) => i instanceof ir.Move).length;
  assert.ok(before > 0, "leaving SSA should have made copies");
  allocator.allocateModule(mod);
  const left = mod.funcs
    .flatMap((f) => f.walk().map((b) => [f, b] as const))
    .flatMap(([f, b]) => b.instrs.map((i) => [f, i] as const))
    .filter(([f, i]) => i instanceof ir.Move && f.colours.get(i.dst) !== f.colours.get(i.src))
    .length;
  assert.ok(left <= before / 10, `${left} of ${before} copies survived`);
});

// -- parallel copies -----------------------------------------------------------

function perform(steps: copies.Step[], registerFile: Map<number, string>): Map<number, string> {
  const state = new Map(registerFile);
  for (const step of steps) {
    if (step instanceof copies.Mov) state.set(step.dst, state.get(step.src)!);
    else {
      const a = state.get(step.a)!;
      state.set(step.a, state.get(step.b)!);
      state.set(step.b, a);
    }
  }
  return state;
}

/** Run a parallel copy on a register file and insist it did what it said. */
function runCopy(moves: [number, number][], borrowed: number | null): copies.Step[] {
  const file = new Map<number, string>();
  for (let r = 0; r < 32; r++) file.set(r, `v${r}`);
  const steps = copies.sequentialize(moves, borrowed);
  const after = perform(steps, file);
  for (const [dst, src] of moves) {
    assert.equal(after.get(dst), file.get(src), `x${dst} should hold v${src}`);
  }
  return steps;
}

test("a copy with no cycle is just moves", () => {
  const steps = runCopy([[1, 2], [3, 4], [5, 5]], 9);
  assert.ok(steps.every((s) => s instanceof copies.Mov));
  assert.equal(steps.length, 2);
});

test("a chain is ordered so nothing is lost", () => {
  runCopy([[1, 2], [2, 3], [3, 4]], 9);
});

test("a cycle borrows a register when there is one", () => {
  const steps = runCopy([[1, 2], [2, 1]], 9);
  assert.ok(steps.every((s) => s instanceof copies.Mov));
  assert.ok(steps.some((s) => s instanceof copies.Mov && s.dst === 9));
});

test("a cycle swaps when there is nothing to borrow", () => {
  const steps = runCopy([[1, 2], [2, 1]], null);
  assert.equal(steps.length, 1);
  assert.ok(steps[0] instanceof copies.Swap);
});

test("a longer cycle swaps its way round", () => {
  const steps = runCopy([[1, 2], [2, 3], [3, 1]], null);
  assert.ok(steps.every((s) => s instanceof copies.Swap));
  assert.equal(steps.length, 2);
});

test("two cycles at once", () => {
  runCopy([[1, 2], [2, 1], [3, 4], [4, 3]], null);
  runCopy([[1, 2], [2, 1], [3, 4], [4, 3]], 9);
});
