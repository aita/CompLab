// Runs one compiled module and reports back.  Lives in a worker so a runaway
// loop costs a terminate() rather than the whole page, and so that a
// breakpoint can block: the wasm call is synchronous, so the only way to stop
// in the middle of one is to stop the thread it is running on.

// The project's lib is the DOM one, so reach for the worker globals through a
// narrow view of them rather than pulling in a second, conflicting lib.
import { RUNNING, STOP, type RunRequest } from "./protocol";

const ctx = self as unknown as {
  onmessage: ((e: MessageEvent) => void) | null;
  postMessage: (message: unknown) => void;
};

const LOG_LIMIT = 2000;
const HIT_LIMIT = 5000;

class Stopped extends Error {}

ctx.onmessage = async (e: MessageEvent<RunRequest>) => {
  const { wasm, resume } = e.data;
  const logs: number[] = [];
  const hits: { watch: number; value: number }[] = [];
  let truncated = false;

  try {
    const source = await WebAssembly.instantiate(wasm as BufferSource, {
      env: {
        log: (x: number) => {
          if (logs.length < LOG_LIMIT) logs.push(x);
          else truncated = true;
        },
        random: () => Math.random(),
        // What the start node hands out.  A wall-clock millisecond count,
        // which is what a graph would want it for.
        now: () => Date.now(),
        watch: (watch: number, value: number) => {
          if (hits.length < HIT_LIMIT) hits.push({ watch, value });
          // Without a shared buffer to wait on -- the page is not
          // cross-origin isolated -- the hit is still recorded, the run just
          // does not stop for it.
          if (resume) {
            ctx.postMessage({ type: "paused", watch, value, hit: hits.length });
            Atomics.store(resume, 0, RUNNING);
            Atomics.wait(resume, 0, RUNNING);
            if (Atomics.load(resume, 0) === STOP) throw new Stopped();
          }
          return value;
        },
      },
    });
    const main = source.instance.exports.main as (...xs: number[]) => number;
    const started = performance.now();
    const value = main();
    ctx.postMessage({
      type: "done",
      value,
      logs,
      hits,
      truncated,
      ms: performance.now() - started,
    });
  } catch (err) {
    if (err instanceof Stopped)
      ctx.postMessage({ type: "stopped", logs, hits, truncated });
    else ctx.postMessage({ type: "error", error: String(err) });
  }
};
