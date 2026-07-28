// Instantiates the modules the rules above compiled and checks what they
// compute.  Run by `dune test`; the .wasm files sit next to this script in
// the build directory.
import { readFileSync } from "node:fs";

let failures = 0;

// A fixed clock, so a program that reads the start node's time is as
// repeatable as any other.
const CLOCK = 1_700_000_000_000;

async function load(file, random = () => 0) {
  const logged = [];
  const hits = [];
  let draws = 0;
  const { instance } = await WebAssembly.instantiate(readFileSync(file), {
    env: {
      log: (x) => logged.push(x),
      random: () => {
        draws++;
        return random();
      },
      watch: (id, v) => {
        hits.push([id, v]);
        return v;
      },
      now: () => CLOCK,
    },
  });
  return { main: instance.exports.main, logged, hits, draws: () => draws };
}

function check(what, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) {
    failures++;
    console.error(
      `FAIL ${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`,
    );
  }
}

const sum = await load("sum.wasm");
check("sum of 1 to 100", sum.main(), 5050);
check("sum logs nothing", sum.logged, []);

// The trace comes from the log node in the loop body, which runs before the
// next values are applied, so it also pins down that the import is called
// once per iteration and sees the state as it was at the top of it.
const collatz = await load("collatz.wasm");
check("collatz from 27", collatz.main(), 111);
check("collatz trace starts", collatz.logged.slice(0, 8), [
  27, 82, 41, 124, 62, 31, 94, 47,
]);
check("collatz trace ends", collatz.logged.slice(-4), [16, 8, 4, 2]);

// A fixed source stands in for Math.random, so the arithmetic around the draw
// is checked rather than the draw itself.
const dice = await load("random.wasm", () => 0.25);
check("random(0,1) doubled plus random(0,10)", dice.main(), 3);
check("one draw per node, not per reader", dice.draws(), 2);

// Watch 0 is the loop's slot at the top of each iteration, watch 1 is the
// value the increment works out; the last iteration checks the condition and
// leaves, so the loop reports once more than the increment does.
const stepped = await load("breakpoints.wasm");
check("loop with breakpoints returns", stepped.main(), 3);
check("breakpoints report in order", stepped.hits, [
  [0, 1], [1, 1], [0, 1], [1, 2], [0, 1], [1, 3], [0, 0],
]);

const typed = await load("typing.wasm");
check("i64 loop returns", typed.main(), 5);
check("i64 remainder", typed.logged, [0, 1, 2, 0, 1, 2, 0, 1, 2, 0]);

// min(n*n+1, 100)/2 logged, and n>3 && n<10 returned as 1 or 0: precedence,
// a call, and the two connectives, all from one line of text.
const formula = await load("formula.wasm");
check("in the band", formula.main(), 1);
check("the expression logged", formula.logged, [13]);

// Rows of a multiplication triangle: the inner loop counts up to the outer
// one's index, which only works if it starts again on every outer pass.
const nested = await load("nested.wasm");
check("nested loops", nested.main(), 0);
check("triangle", nested.logged, [1, 2, 4, 3, 6, 9, 4, 8, 12, 16]);

// Row sums of the triangle: the running total is put back to zero at the top
// of each outer pass, which is what the reset way through a State is for.
const state = await load("state.wasm");
check("reset per pass", state.main(), 0);
check("row sums", state.logged, [1, 3, 6, 10, 15]);

// The start node hands out whatever the host says the time is, once: two
// readers of it see the same moment.
const clock = await load("time.wasm");
check("the start node's time", clock.main(), CLOCK);
check("one moment, read twice", clock.logged, [0]);

if (failures > 0) process.exit(1);
console.log("ok");
