// Runs one compiled module and reports back.  Lives in a worker so a cook
// that takes forever costs a terminate() rather than the whole page, and so
// that a breakpoint can block: the wasm call is synchronous, so the only way
// to stop in the middle of one is to stop the thread it is running on.

// The project's lib is the DOM one, so reach for the worker globals through a
// narrow view of them rather than pulling in a second, conflicting lib.
import {
  AT_BREAKPOINT,
  AT_EVERY,
  MODE,
  RUNNING,
  type CookRequest,
  type RunRequest,
} from "./protocol";

const ctx = self as unknown as {
  onmessage: ((e: MessageEvent) => void) | null;
  postMessage: (message: unknown) => void;
};

const LOG_LIMIT = 2000;
const HIT_LIMIT = 5000;

// The module stays instantiated between cooks: what one cook leaves in the
// feedbacks is exactly what the next one reads.
let ready: WebAssembly.Instance | undefined;

// What this cook logged and stopped at.  The imports are bound once, at
// instantiate, so these are reset for each cook rather than made afresh.
let logs: number[] = [];
let said: string[] = [];
let hits: { watch: number; value: number }[] = [];
let truncated = false;
// How many cooks the instance has had, for the panel to count off.
let cooks = 0;
// What the page asked for when it sent this cook.  Only consulted when there
// is no shared buffer: with one, the page may change its mind mid-cook.
let stepAll = false;

// What the graph is holding right now.  Its state is in exported globals, so
// a debugger can read all of it without the program having to report it.
function state(): { name: string; value: number }[] {
  const out: { name: string; value: number }[] = [];
  for (const [name, value] of Object.entries(ready?.exports ?? {})) {
    if (!name.startsWith("state_")) continue;
    const g = value as WebAssembly.Global;
    const held = g.value as number | bigint;
    out.push({
      name: name.slice("state_".length),
      value: typeof held === "bigint" ? Number(held) : held,
    });
  }
  return out;
}

// One cook: main() from top to bottom, and what it came back with.
function cook() {
  const main = ready?.exports.main as (() => number) | undefined;
  if (!main) {
    ctx.postMessage({ type: "error", error: "the module has no main" });
    return;
  }
  try {
    const started = performance.now();
    const value = main();
    cooks++;
    ctx.postMessage({
      type: "done",
      value,
      cook: cooks,
      logs,
      said,
      hits,
      truncated,
      state: state(),
      ms: performance.now() - started,
    });
  } catch (err) {
    ctx.postMessage({ type: "error", error: String(err) });
  }
}

ctx.onmessage = async (e: MessageEvent<RunRequest | CookRequest>) => {
  logs = [];
  said = [];
  hits = [];
  truncated = false;

  if ("cook" in e.data) {
    stepAll = e.data.step ?? false;
    cook();
    return;
  }

  const { wasm, inputs, stopAt, step, flags } = e.data;
  cooks = 0;
  stepAll = step ?? false;

  try {
    const source = await WebAssembly.instantiate(wasm as BufferSource, {
      env: {
        log: (x: number) => {
          if (logs.length < LOG_LIMIT) logs.push(x);
          else truncated = true;
        },
        random: () => Math.random(),
        // A wall-clock millisecond count, which is what a graph would want
        // the time for.  Asked afresh every cook, once within one.
        now: () => Date.now(),
        // A graph says text by handing over a slice of its own memory.
        say: (ptr: number, len: number) => {
          const memory = ready?.exports.memory as WebAssembly.Memory | undefined;
          if (!memory) return;
          said.push(
            new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len)),
          );
        },
        // Every node reports; whether the cook stops here is the page's to
        // say, and it can change its mind while the worker is held at one.
        // Stepping is that: stop at the next report, whatever it is.
        watch: (watch: number, value: number) => {
          const stepping = flags
            ? Atomics.load(flags, MODE) === AT_EVERY
            : stepAll;
          if (!stepping && !(stopAt?.[watch] ?? false)) return value;
          if (hits.length < HIT_LIMIT) hits.push({ watch, value });
          // Without a shared buffer to wait on -- the page is not
          // cross-origin isolated -- the hit is still recorded, the cook just
          // does not stop for it.
          if (flags) {
            ctx.postMessage({
              type: "paused",
              watch,
              value,
              hit: hits.length,
              cook: cooks + 1,
              state: state(),
            });
            // Stopping a held run is the page terminating the worker, so
            // there is nothing to wake for but carrying on.
            Atomics.store(flags, AT_BREAKPOINT, RUNNING);
            Atomics.wait(flags, AT_BREAKPOINT, RUNNING);
          }
          return value;
        },
      },
    });
    ready = source.instance;
    // What the panel asked for goes in before anything runs, and stays: an
    // Input is read, never written.
    for (const [name, value] of Object.entries(inputs ?? {})) {
      const g = source.instance.exports[name] as WebAssembly.Global | undefined;
      if (g) g.value = value;
    }
    cook();
  } catch (err) {
    ctx.postMessage({ type: "error", error: String(err) });
  }
};
