// Instantiates the modules the rules above compiled and checks what they
// compute.  Run by `dune test`; the .wasm files sit next to this script in
// the build directory.
//
// One call to main is one cook of the graph, so a program that gets anywhere
// is one that is cooked more than once.
import { readFileSync } from "node:fs";

let failures = 0;

// A fixed clock, so a graph that reads the time is as repeatable as any other.
const CLOCK = 1_700_000_000_000;

async function load(file, random = () => 0) {
  const logged = [];
  const said = [];
  const hits = [];
  let draws = 0;
  let instance;
  ({ instance } = await WebAssembly.instantiate(readFileSync(file), {
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
      say: (ptr, len) =>
        said.push(
          new TextDecoder().decode(
            new Uint8Array(instance.exports.memory.buffer, ptr, len),
          ),
        ),
    },
  }));
  const cook = instance.exports.main;
  return {
    cook,
    // What the graph comes back with over n cooks, which is how a dataflow
    // program gets anywhere at all.
    cooks: (n) => Array.from({ length: n }, () => cook()),
    exports: instance.exports,
    logged,
    said,
    hits,
    draws: () => draws,
  };
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

// A node feeding two inputs is worked out once: (2+2) then that doubled.
const sharing = await load("sharing.wasm");
check("shared once", sharing.cook(), 8);

// A random node is one draw a cook, however many readers it has -- two edges
// leaving it, or one edge into a formula that names it twice -- and two nodes
// are two draws.
const dice = await load("random.wasm", () => 0.25);
check("one draw per node", dice.cook(), 0.5 + 2.5 * 2.5);
check("two nodes, two draws", dice.draws(), 2);
dice.cook();
check("a cook draws afresh", dice.draws(), 4);

// Whole numbers stay whole: the feedback, its step and the remainder are i64,
// and a value only widens where it meets an f64 or the host.
const typed = await load("typing.wasm");
check("halves of 0, 1, 2, 3", typed.cooks(4), [0, 0.5, 1, 1.5]);
check("i64 remainder", typed.logged, [0, 1, 2, 0]);

// Two breakpoints: one on the sum, one on the feedback it feeds.  A feedback
// reports the new value it takes, not the one it hands out, so the pair says
// the same number -- and says it once per cook, in lowering order.
const stepped = await load("breakpoints.wasm");
stepped.cooks(3);
check("reported in order", stepped.hits, [
  [0, 1], [1, 1], [0, 2], [1, 2], [0, 3], [1, 3],
]);

// min(n*n+1, 100)/2 logged, and n>3 && n<10 returned as 1 or 0: precedence,
// a call, and the two connectives, all from one line of text.
const formula = await load("formula.wasm");
check("in the band", formula.cook(), 1);
check("the expression logged", formula.logged, [13]);

// The host's clock, read twice in one cook: the same moment both times.
const clock = await load("time.wasm");
check("the time", clock.cook(), CLOCK);
check("one moment, read twice", clock.logged, [0]);

// Counting is what a feedback is for: each cook hands back what it held and
// leaves one more behind.
const count = await load("count.wasm");
check("counts up", count.cooks(5), [0, 1, 2, 3, 4]);
check("and logs the same", count.logged, [0, 1, 2, 3, 4]);
check("the state is readable", count.exports.state_count.value, 5);

// A phase that wraps, worked out once and read by both the out and the log.
const wave = await load("wave.wasm");
check("quarter steps, wrapped at 4", wave.cooks(6), [0, 0.25, 0.5, 0.75, 1, 1.25]);

// A yes-or-no that flips every cook, and a piece of text said every cook.
const blink = await load("blink.wasm");
blink.cooks(4);
check("flips", blink.logged, [0, 1, 0, 1]);
check("says its piece each cook", blink.said, ["blink", "blink", "blink", "blink"]);

// The one impure node moved once a cook, from a fixed draw.
const walk = await load("walk.wasm", () => 0.75);
check("walks", walk.cooks(3), [0, 0.5, 1]);

// Two feedbacks reading each other: the position turns around at either end
// because the direction it reads is the one the last cook left.
const bounce = await load("bounce.wasm");
check("up to 10 and back", bounce.cooks(13).slice(7), [8, 9, 10, 9, 8, 7]);

// Both draws land inside the circle, so the estimate is 4 from the first cook
// on -- what is being checked is that it accumulates at all.
const pi = await load("pi.wasm", () => 0.5);
check("four quarters", pi.cooks(3), [4, 4, 4]);

if (failures > 0) process.exit(1);
console.log("ok");
