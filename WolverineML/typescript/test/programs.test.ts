// End to end: compile to ARMv8, assemble, link, and run it.
//
// These are the only tests that need a toolchain.  Without a cross `gcc` and
// `qemu-aarch64` they skip rather than fail, so the rest of the suite still runs on
// a machine that has neither.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";

import * as driver from "../src/driver.ts";
import { FuncEmitter } from "../src/emit.ts";
import type * as ir from "../src/ir.ts";
import * as oracle from "./oracle.ts";

const noToolchain = ((): string | null => {
  try {
    driver.crossCC();
    driver.emulator();
    return null;
  } catch (e) {
    return (e as Error).message;
  }
})();

const skip = noToolchain === null ? false : noToolchain;

const CONFIGURATIONS: [string, driver.Options][] = [
  ["default", new driver.Options()],
  ["no-opt", new driver.Options(true, false)],
  ["no-checks", new driver.Options(false)],
  ["spilling", new driver.Options(true, true, 12)],
  ["spilling-no-opt", new driver.Options(true, false, 12)],
];

const wolFiles = (dir: string): string[] =>
  readdirSync(dir).filter((n) => n.endsWith(".wol")).sort().map((n) => join(dir, n));

function mustRun(source: string, opts: driver.Options, stdin: string | null = null): string {
  const done = driver.run(source, opts, stdin);
  assert.equal(done.exitCode, 0, done.stderr);
  return done.stdout;
}

for (const program of wolFiles("test/programs")) {
  const name = basename(program, ".wol");
  const source = readFileSync(program, "utf8");
  const expected = readFileSync(program.replace(/\.wol$/, ".out"), "utf8");
  for (const [configuration, opts] of CONFIGURATIONS) {
    // Every option gives the same answer; only the code differs.
    test(`${name} [${configuration}]`, { skip }, () => {
      assert.equal(mustRun(source, opts), expected);
    });
  }
}

for (const example of wolFiles("examples")) {
  const name = basename(example, ".wol");
  // No expected output on file: what matters is that the stages agree.
  test(`${name} agrees with itself`, { skip }, () => {
    const source = readFileSync(example, "utf8");
    const baseline = mustRun(source, CONFIGURATIONS[0]![1]);
    assert.notEqual(baseline, "");
    for (const [configuration, opts] of CONFIGURATIONS.slice(1)) {
      assert.equal(mustRun(source, opts), baseline, configuration);
    }
  });
}

test("the checks catch what they are for", { skip }, () => {
  const cases: [string, string][] = [
    ["val a = array (3, 0)\nval () = printInt (a[5])", "outside an array"],
    ["type t = { x : int }\nval n : t = nil\nval () = printInt (n.x)", "field of nil"],
    ["var z = 0\nval () = printInt (7 / z)", "division by zero"],
  ];
  for (const [source, message] of cases) {
    const done = driver.run(source, new driver.Options(), "");
    assert.equal(done.exitCode, 1);
    assert.ok(done.stderr.includes(message), done.stderr);
  }
});

test("a check can be turned off", { skip }, () => {
  const source = "val a = array (3, 0)\nval () = printInt (a[1])\n";
  assert.equal(mustRun(source, new driver.Options(false), ""), "0");
});

test("standard input", { skip }, () => {
  const source = `
var line = ""
var c = getChar ()
val () = while c <> "" andalso c <> "\\n" do (line := line ^ c; c := getChar ())
val () = print ("read: " ^ line ^ " (" ^ intToString (size (line)) ^ ")\\n")
`;
  assert.equal(mustRun(source, new driver.Options(), "hello\n"), "read: hello (5)\n");
});

test("exit code", { skip }, () => {
  const done = driver.run('val () = (print ("bye\\n"); exit (3))', new driver.Options(), "");
  assert.equal(done.exitCode, 3);
  assert.equal(done.stdout, "bye\n");
});

// -- the oracle ----------------------------------------------------------------

const ORACLE_CONFIGURATIONS: [string, driver.Options][] = [
  ["default", new driver.Options()],
  ["no-opt", new driver.Options(true, false)],
  ["no-checks", new driver.Options(false)],
  ["spilling", new driver.Options(true, true, 10)],
];

function checkAgainstOracle(source: string, expected: string, opts: driver.Options): void {
  const done = driver.run(source, opts, "");
  assert.equal(done.exitCode, 0, done.stderr);
  if (done.stdout === expected) return;
  const got = done.stdout.split("\n");
  const want = expected.split("\n");
  for (let at = 0; at < Math.min(got.length, want.length); at++) {
    assert.equal(got[at], want[at], `line ${at}`);
  }
  assert.fail(`${got.length} lines, want ${want.length}`);
}

for (const seed of [1, 2]) {
  const [arithSource, arithExpected] = oracle.arithmetic(seed, 25);
  const [imperSource, imperExpected] = oracle.imperative(seed, 8);
  for (const [name, opts] of ORACLE_CONFIGURATIONS) {
    test(`oracle arithmetic seed ${seed} [${name}]`, { skip }, () => {
      checkAgainstOracle(arithSource, arithExpected, opts);
    });
    test(`oracle arrays seed ${seed} [${name}]`, { skip }, () => {
      checkAgainstOracle(imperSource, imperExpected, opts);
    });
  }
}

/** Force the swap: the borrowed register is what usually hides that path. */
class NoBorrow extends FuncEmitter {
  override borrowed(_moves: [number, number][]): number | null { return null; }
}

test("a cycle of copies needs no scratch register", { skip }, () => {
  const source = "fun swap (a : int, b : int) : int =\n"
    + "  if a > b then swap (b, a) else b * 10 + a\n"
    + 'val () = (printInt (swap (1, 2)); print (" "); printInt (swap (7, 3)))\n';
  const swapping = (f: ir.Func): FuncEmitter => new NoBorrow(f);
  assert.equal(driver.run(source, new driver.Options(), "").stdout, "21 73");
  assert.ok(driver.compileToAsm(source, new driver.Options(), swapping).includes("eor x"));
  assert.equal(driver.run(source, new driver.Options(), "", swapping).stdout, "21 73");
});
