// What the page and the worker running a module agree on.  The flags live in
// a SharedArrayBuffer because both stopping at a breakpoint and waiting for
// an event have to hold the worker inside a synchronous wasm call, which only
// Atomics.wait can do.

export const RUNNING = 0;
export const CONTINUE = 1;
export const STOP = 2;
/** An event has been left in [payload] for a waiting worker to take. */
export const SENT = 3;

/** Flag 0 is the breakpoint's, flag 1 is the event's. */
export const AT_BREAKPOINT = 0;
export const AT_EVENT = 1;

export interface RunRequest {
  wasm: Uint8Array;
  /** Absent when the page is not cross-origin isolated. */
  flags?: Int32Array;
  /** The number an event carries, written before the flag is set. */
  payload?: Float64Array;
}
