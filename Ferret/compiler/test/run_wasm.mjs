// Instantiates the modules the rules above compiled and checks what they
// compute.  Run by `dune test`; the .wasm files sit next to this script in
// the build directory.
import { readFileSync } from "node:fs";

let failures = 0;

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
check("sum(0)", sum.main(0), 0);
check("sum(1)", sum.main(1), 1);
check("sum(10)", sum.main(10), 55);
check("sum(100)", sum.main(100), 5050);
// Past 2^31: the whole-number path is i64, so this is exact rather than
// wrapped, and past 2^53 it would still be exact where an f64 would not.
check("sum(100000)", sum.main(100000), 5000050000);
check("sum logs nothing", sum.logged, []);

const collatz = await load("collatz.wasm");
check("collatz(1)", collatz.main(1), 0);
check("collatz(6)", collatz.main(6), 8);
check("collatz(27)", collatz.main(27), 111);

// The trace comes from the log node in the loop body, which runs before the
// next values are applied, so it also pins down that the import is called
// once per iteration and sees the state as it was at the top of it.
const traced = await load("collatz.wasm");
check("collatz(7)", traced.main(7), 16);
check("collatz(7) trace", traced.logged, [
  7, 22, 11, 34, 17, 52, 26, 13, 40, 20, 10, 5, 16, 8, 4, 2,
]);

// A fixed source stands in for Math.random, so the arithmetic around the draw
// is checked rather than the draw itself.
const dice = await load("random.wasm", () => 0.25);
check("random(0,1) doubled plus random(0,10)", dice.main(), 3);
check("one draw per node, not per reader", dice.draws(), 2);

// Watch 0 is the loop's slot at the top of each iteration, watch 1 is the
// value the increment works out; the last iteration checks the condition and
// leaves, so the loop reports once more than the increment does.
const stepped = await load("breakpoints.wasm");
check("loop with breakpoints returns", stepped.main(3), 3);
check("breakpoints report in order", stepped.hits, [
  [0, 1], [1, 1], [0, 1], [1, 2], [0, 1], [1, 3], [0, 0],
]);

const typed = await load("typing.wasm");
check("i64 loop returns", typed.main(), 5);
check("i64 remainder", typed.logged, [0, 1, 2, 0, 1, 2, 0, 1, 2, 0]);

if (failures > 0) process.exit(1);
console.log("ok");
