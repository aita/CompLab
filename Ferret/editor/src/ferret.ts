// The bridge to the OCaml compiler.  `public/ferret.js` is ferretc built with
// js_of_ocaml, loaded by a script tag in index.html, so this file only has to
// unwrap what it returns -- and to drive the worker the module runs in.

import { CONTINUE, STOP } from "./protocol";

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

function sharedFlag(): Int32Array | undefined {
  return canPause() ? new Int32Array(new SharedArrayBuffer(4)) : undefined;
}

// The graph can describe a loop that never ends, so the module runs in a
// worker that can be killed rather than on the UI thread.  The clock is
// stopped while a breakpoint holds the run, or thinking at one would count as
// hanging.
export function start(
  wasm: Uint8Array,
  onPause: (p: Paused) => void,
  timeoutMs = 3000,
): Run {
  const worker = new Worker(new URL("./runner.ts", import.meta.url), {
    type: "module",
  });
  const resume = sharedFlag();
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

  const wake = (how: number) => {
    if (!resume) return;
    Atomics.store(resume, 0, how);
    Atomics.notify(resume, 0);
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
  worker.postMessage({ wasm, resume });

  return {
    done,
    resume: () => wake(CONTINUE),
    stop: () => {
      if (resume) wake(STOP);
      else {
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
    canPause: resume !== undefined,
  };
}
