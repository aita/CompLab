// The bridge to the OCaml compiler.  `public/ferret.js` is ferretc built with
// js_of_ocaml, loaded by a script tag in index.html, so this file only has to
// unwrap what it returns -- and to drive the worker the module runs in.

import { AT_BREAKPOINT, AT_EVENT, CONTINUE, SENT, STOP } from "./protocol";

export interface CompileError {
  node: string | null;
  message: string;
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
    }
  | { ok: false; errors: CompileError[] };

interface RawResult {
  ok: boolean;
  wasm?: number[];
  wat?: string;
  ir?: string;
  watches?: Watch[];
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
  };
}

export interface Hit {
  watch: number;
  value: number;
}

export interface Paused extends Hit {
  hit: number;
}

export interface RunResult {
  value: number | null;
  logs: number[];
  hits: Hit[];
  ms: number;
  truncated: boolean;
  stopped: boolean;
}

export interface Run {
  done: Promise<RunResult>;
  resume: () => void;
  /** Hand an event to a program stopped in a Wait node. */
  send: (value: number) => void;
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

// One buffer, two flags and a payload: [0] is the breakpoint's, [1] is the
// event's, and the number an event carries sits after them, aligned for an
// f64.
function sharedState() {
  if (!canPause()) return {};
  const buffer = new SharedArrayBuffer(16);
  return {
    flags: new Int32Array(buffer, 0, 2),
    payload: new Float64Array(buffer, 8, 1),
  };
}

// The graph can describe a loop that never ends, so the module runs in a
// worker that can be killed rather than on the UI thread.  The clock is
// stopped while a breakpoint holds the run, or thinking at one would count as
// hanging.
export function start(
  wasm: Uint8Array,
  onPause: (p: Paused) => void,
  onWait: () => void,
  timeoutMs = 3000,
): Run {
  const worker = new Worker(new URL("./runner.ts", import.meta.url), {
    type: "module",
  });
  const { flags, payload } = sharedState();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let settle: (r: RunResult) => void = () => {};
  let fail: (e: Error) => void = () => {};

  const done = new Promise<RunResult>((resolve, reject) => {
    settle = resolve;
    fail = reject;
  });

  const disarm = () => clearTimeout(timer);
  const arm = () => {
    disarm();
    timer = setTimeout(() => {
      worker.terminate();
      fail(new Error(`Still running after ${timeoutMs} ms — the loop may never end`));
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
    // Waiting for an event is not hanging, so the clock stops here too.
    if (m.type === "waiting") {
      disarm();
      onWait();
      return;
    }
    disarm();
    worker.terminate();
    if (m.type === "error") fail(new Error(m.error));
    else
      settle({
        value: m.type === "done" ? m.value : null,
        logs: m.logs ?? [],
        hits: m.hits ?? [],
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
  worker.postMessage({ wasm, flags, payload });

  return {
    done,
    resume: () => wake(AT_BREAKPOINT, CONTINUE),
    send: (value: number) => {
      if (!flags || !payload) return;
      payload[0] = value;
      wake(AT_EVENT, SENT);
    },
    stop: () => {
      if (flags) {
        wake(AT_BREAKPOINT, STOP);
        wake(AT_EVENT, STOP);
      } else {
        disarm();
        worker.terminate();
        settle({
          value: null,
          logs: [],
          hits: [],
          ms: 0,
          truncated: false,
          stopped: true,
        });
      }
    },
    canPause: flags !== undefined,
  };
}
