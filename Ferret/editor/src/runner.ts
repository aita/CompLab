// Runs one compiled module and reports back.  Lives in a worker so a runaway
// loop costs a terminate() rather than the whole page.

// The project's lib is the DOM one, so reach for the worker globals through a
// narrow view of them rather than pulling in a second, conflicting lib.
const ctx = self as unknown as {
  onmessage: ((e: MessageEvent) => void) | null;
  postMessage: (message: unknown) => void;
};

const LOG_LIMIT = 2000;

ctx.onmessage = async (e: MessageEvent<{ wasm: Uint8Array; args: number[] }>) => {
  const logs: number[] = [];
  let truncated = false;
  try {
    const source = await WebAssembly.instantiate(e.data.wasm as BufferSource, {
      env: {
        log: (x: number) => {
          if (logs.length < LOG_LIMIT) logs.push(x);
          else truncated = true;
        },
      },
    });
    const main = source.instance.exports.main as (...xs: number[]) => number;
    const started = performance.now();
    const value = main(...e.data.args);
    ctx.postMessage({
      value,
      logs,
      truncated,
      ms: performance.now() - started,
    });
  } catch (err) {
    ctx.postMessage({ error: String(err) });
  }
};
