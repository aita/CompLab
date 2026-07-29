// The bridge to the OCaml compiler.  `public/ferret.js` is ferretc built with
// js_of_ocaml, loaded by a script tag in index.html, so this file only has to
// unwrap what it returns -- and to drive the worker the module runs in.

import {
  AT_BREAKPOINT,
  AT_EVERY,
  AT_MARKED,
  CONTINUE,
  MODE,
} from "./protocol";

export interface CompileError {
  node: string | null;
  message: string;
}

/** A number the panel asks for before a run, and writes into a global. */
export interface Input {
  export: string;
  label: string;
  value: number;
}

/** Where a breakpoint sits: the node, and which of its values this one is. */
export interface Watch {
  node: string;
  label: string;
}

export type CompileResult =
  | {
      ok: true;
      wasm: Uint8Array;
      wat: string;
      ir: string;
      watches: Watch[];
      inputs: Input[];
    }
  | { ok: false; errors: CompileError[] };

interface RawResult {
  ok: boolean;
  wasm?: number[];
  wat?: string;
  ir?: string;
  watches?: Watch[];
  inputs?: Input[];
  errors?: { node: string | null; message: string }[];
}

interface FerretApi {
  compile(source: string): RawResult;
  /** The node catalogue, as JSON text. */
  specs(): string;
  /** What one node of a kind looks like, given its settings, as JSON text. */
  describe(kind: string, data: string): string;
}

function loaded(): FerretApi | undefined {
  return (globalThis as { ferret?: FerretApi }).ferret;
}

// The catalogue and the per-node answers are handed over as JSON text rather
// than reached into as an OCaml value; `spec.ts` gives them their types.
export function rawSpecs(): string | undefined {
  return loaded()?.specs();
}

export function rawDescribe(kind: string, data: string): string | undefined {
  return loaded()?.describe(kind, data);
}

export function compile(graph: unknown): CompileResult {
  const api = loaded();
  if (!api) {
    return {
      ok: false,
      errors: [
        {
          node: null,
          message:
            "The compiler is not loaded: run `npm run compiler` to build public/ferret.js",
        },
      ],
    };
  }
  const raw = api.compile(JSON.stringify(graph));
  if (!raw.ok) return { ok: false, errors: raw.errors ?? [] };
  return {
    ok: true,
    wasm: new Uint8Array(raw.wasm ?? []),
    wat: raw.wat ?? "",
    ir: raw.ir ?? "",
    watches: raw.watches ?? [],
    inputs: raw.inputs ?? [],
  };
}

export interface Hit {
  watch: number;
  value: number;
}

/** One of the graph's globals, as it stands right now. */
export interface Held {
  name: string;
  value: number;
}

export interface Paused extends Hit {
  hit: number;
  /** Which cook this is, counting from one. */
  cook: number;
  /** Everything the graph is holding, read out of its globals. */
  state: Held[];
}

export interface RunResult {
  value: number | null;
  /** How many cooks the module has had, counting from one. */
  cook: number;
  logs: number[];
  /** What the graph said, in the order it said it. */
  said: string[];
  hits: Hit[];
  /** What the graph was holding when it came back. */
  state: Held[];
  ms: number;
  truncated: boolean;
  stopped: boolean;
}

export interface Run {
  /** The first cook, which starting the run does straight away. */
  done: Promise<RunResult>;
  /** Cook the graph once more, on what the last cook left behind.  Stepping
   *  starts the cook stopped at its first node rather than running it. */
  again: (step?: boolean) => Promise<RunResult>;
  /** Carry on to the next breakpoint, or -- stepping -- to the next node. */
  resume: (step?: boolean) => void;
  stop: () => void;
  /** False when the page is not cross-origin isolated: breakpoints still
   *  report, but the run cannot be held at one. */
  canPause: boolean;
}

// Blocking the worker needs a buffer both threads can see, and that needs the
// page to be cross-origin isolated.  Vite sends the headers for it; a build
// served without them still runs, it just cannot stop.
export function canPause(): boolean {
  return (
    typeof SharedArrayBuffer !== "undefined" && !!globalThis.crossOriginIsolated
  );
}

// One buffer, two flags: [0] is what the worker waits on at a breakpoint, [1]
// is what the page sets to say where to stop next.
function sharedState() {
  if (!canPause()) return {};
  return { flags: new Int32Array(new SharedArrayBuffer(8), 0, 2) };
}

// A run is the module instantiated and then cooked, once or over and over.
// It runs in a worker rather than on the UI thread so that a breakpoint can
// hold it, and so a cook that will not come back costs a terminate() rather
// than the page.  The clock is stopped while a breakpoint holds the run, or
// thinking at one would count as hanging.
export function start(
  wasm: Uint8Array,
  inputs: Record<string, number>,
  /** Per watch point: does the node it belongs to have a breakpoint on it? */
  stopAt: boolean[],
  /** Start by stopping at the first node, rather than at a breakpoint. */
  stepping: boolean,
  onPause: (p: Paused) => void,
  timeoutMs = 3000,
): Run {
  const worker = new Worker(new URL("./runner.ts", import.meta.url), {
    type: "module",
  });
  const { flags } = sharedState();
  if (flags) Atomics.store(flags, MODE, stepping ? AT_EVERY : AT_MARKED);
  let timer: ReturnType<typeof setTimeout> | undefined;
  let settle: (r: RunResult) => void = () => {};
  let fail: (e: Error) => void = () => {};

  // One cook is in flight at a time: the first, and then another each time
  // the panel asks for one.
  const answered = () =>
    new Promise<RunResult>((resolve, reject) => {
      settle = resolve;
      fail = reject;
    });

  const done = answered();

  const disarm = () => clearTimeout(timer);
  const arm = () => {
    disarm();
    timer = setTimeout(() => {
      worker.terminate();
      fail(new Error(`Still cooking after ${timeoutMs} ms`));
    }, timeoutMs);
  };

  const wake = (which: number, how: number) => {
    if (!flags) return;
    Atomics.store(flags, which, how);
    Atomics.notify(flags, which);
    arm();
  };

  worker.onmessage = (e: MessageEvent) => {
    const m = e.data;
    if (m.type === "paused") {
      disarm();
      onPause(m as Paused);
      return;
    }
    disarm();
    if (m.type === "error") {
      worker.terminate();
      fail(new Error(m.error));
    } else
      settle({
        value: m.type === "done" ? m.value : null,
        cook: m.cook ?? 0,
        logs: m.logs ?? [],
        said: m.said ?? [],
        hits: m.hits ?? [],
        state: m.state ?? [],
        ms: m.ms ?? 0,
        truncated: !!m.truncated,
        stopped: m.type === "stopped",
      });
  };
  worker.onerror = (e) => {
    disarm();
    worker.terminate();
    fail(new Error(e.message));
  };

  arm();
  // The bytes are copied rather than transferred: the caller keeps them for
  // the hex dump.
  worker.postMessage({ wasm, inputs, stopAt, step: stepping, flags });

  return {
    done,
    again: (step = false) => {
      const answer = answered();
      // Say where this cook should stop before it starts, rather than leaving
      // it on whatever the last Continue or Next set.
      if (flags) Atomics.store(flags, MODE, step ? AT_EVERY : AT_MARKED);
      arm();
      worker.postMessage({ cook: true, step });
      return answer;
    },
    resume: (step = false) => {
      if (flags) Atomics.store(flags, MODE, step ? AT_EVERY : AT_MARKED);
      wake(AT_BREAKPOINT, CONTINUE);
    },
    stop: () => {
      // Nothing to unwind: the instance and everything it holds go with the
      // worker, whether it was running, idle, or held at a breakpoint.
      disarm();
      worker.terminate();
      settle({
        value: null,
        cook: 0,
        logs: [],
        said: [],
        hits: [],
        state: [],
        ms: 0,
        truncated: false,
        stopped: true,
      });
    },
    canPause: flags !== undefined,
  };
}
