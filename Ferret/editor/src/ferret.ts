// The bridge to the OCaml compiler.  `public/ferret.js` is ferretc built with
// js_of_ocaml, loaded by a script tag in index.html, so this file only has to
// unwrap what it returns.

export interface CompileError {
  node: string | null;
  message: string;
}

export type CompileResult =
  | {
      ok: true;
      wasm: Uint8Array;
      wat: string;
      ir: string;
      params: string[];
    }
  | { ok: false; errors: CompileError[] };

interface RawResult {
  ok: boolean;
  wasm?: number[];
  wat?: string;
  ir?: string;
  params?: string[];
  errors?: { node: string | null; message: string }[];
}

interface FerretApi {
  compile(source: string): RawResult;
}

export function compilerReady(): boolean {
  return typeof (globalThis as { ferret?: FerretApi }).ferret !== "undefined";
}

export function compile(graph: unknown): CompileResult {
  const api = (globalThis as { ferret?: FerretApi }).ferret;
  if (!api) {
    return {
      ok: false,
      errors: [
        {
          node: null,
          message:
            "コンパイラが読み込まれていません。`npm run compiler` で public/ferret.js を作ってください",
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
    params: raw.params ?? [],
  };
}

export interface RunResult {
  value: number;
  logs: number[];
  ms: number;
  truncated: boolean;
}

// The graph can describe a loop that never ends, so the module runs in a
// worker that can be killed rather than on the UI thread.
export function run(
  wasm: Uint8Array,
  args: number[],
  timeoutMs = 3000,
): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL("./runner.ts", import.meta.url), {
      type: "module",
    });
    const timer = setTimeout(() => {
      worker.terminate();
      reject(
        new Error(
          `${timeoutMs} ms を過ぎても終わりませんでした（止まらないループかもしれません）`,
        ),
      );
    }, timeoutMs);
    worker.onmessage = (e: MessageEvent) => {
      clearTimeout(timer);
      worker.terminate();
      if (e.data.error) reject(new Error(e.data.error));
      else resolve(e.data as RunResult);
    };
    worker.onerror = (e) => {
      clearTimeout(timer);
      worker.terminate();
      reject(new Error(e.message));
    };
    // The bytes are copied rather than transferred: the caller keeps them for
    // the hex dump.
    worker.postMessage({ wasm, args });
  });
}
