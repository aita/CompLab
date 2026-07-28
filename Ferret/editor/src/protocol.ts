// What the page and the worker running a module agree on.  The resume flag
// lives in a SharedArrayBuffer because a breakpoint has to stop the worker
// inside a synchronous wasm call, which only Atomics.wait can do.

export const RUNNING = 0;
export const CONTINUE = 1;
export const STOP = 2;
export interface RunRequest {
  wasm: Uint8Array;
  args: number[];
  /** Absent when the page is not cross-origin isolated. */
  resume?: Int32Array;
}
