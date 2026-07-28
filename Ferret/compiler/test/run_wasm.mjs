// Instantiates the modules the rules above compiled and checks what they
// compute.  Run by `dune test`; the .wasm files sit next to this script in
// the build directory.
import { readFileSync } from "node:fs";

let failures = 0;

async function load(file) {
  const logged = [];
  const { instance } = await WebAssembly.instantiate(readFileSync(file), {
    env: { log: (x) => logged.push(x) },
  });
  return { main: instance.exports.main, logged };
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
check("sum logs nothing", sum.logged, []);

const collatz = await load("collatz.wasm");
check("collatz(1)", collatz.main(1), 0);
check("collatz(6)", collatz.main(6), 8);
check("collatz(27)", collatz.main(27), 111);

// The trace comes from the log node in the loop body, so it also pins down
// that the import is called once per iteration and in order.
const traced = await load("collatz.wasm");
check("collatz(7)", traced.main(7), 16);
check("collatz(7) trace", traced.logged, [
  22, 11, 34, 17, 52, 26, 13, 40, 20, 10, 5, 16, 8, 4, 2, 1,
]);

if (failures > 0) process.exit(1);
console.log("ok");
