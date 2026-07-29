// What the page and the worker running a module agree on.  The flags live in
// a SharedArrayBuffer because stopping at a breakpoint has to hold the worker
// inside a synchronous wasm call, which only Atomics.wait can do.

export const RUNNING = 0;
export const CONTINUE = 1;

/** Flag 0 is the breakpoint's. */
export const AT_BREAKPOINT = 0;
/** Flag 1 says which watch points to stop at, and the page can change it
 *  while the worker is held at one: that is what stepping is. */
export const MODE = 1;
export const AT_MARKED = 0; /* only the nodes with a breakpoint on them */
export const AT_EVERY = 1; /* the next one, whatever it is: one step */

export interface RunRequest {
  wasm: Uint8Array;
  /** Globals to write before the first cook: the numbers the panel asked for. */
  inputs?: Record<string, number>;
  /** Per watch point: is there a breakpoint on the node it belongs to? */
  stopAt?: boolean[];
  /** Stop at every node, not just the marked ones.  The flag in the shared
   *  buffer says the same thing and can be changed mid-cook; this is what
   *  the worker falls back on when there is no shared buffer to read. */
  step?: boolean;
  /** Absent when the page is not cross-origin isolated. */
  flags?: Int32Array;
}

/** Cook the graph once more, on the instance the last cook left behind. */
export interface CookRequest {
  cook: true;
  step?: boolean;
}
