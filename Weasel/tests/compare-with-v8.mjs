// Run the same `.wat` files, with the same expectations, on V8.
//
// The `;;=` lines in `tests/wat/` are what `weasel_tests` checks Weasel against.
// On their own they would only prove Weasel is consistent with itself. This
// script hands each file to `wat2wasm` and then to node's own WebAssembly
// implementation, and checks the same lines there. Anything both engines agree
// on is a fact about wasm; anything they disagree on is a bug in one of them,
// and the message says which expectation it was.
//
//   node tests/compare-with-v8.mjs
//
// Needs `wat2wasm` on the path. Files that import WASI are given the same tiny
// `fd_write` the runtime has.

import { readFileSync, readdirSync, unlinkSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";

const dir = join(import.meta.dirname, "wat");
let checks = 0;
let failures = 0;

function fail(where, message) {
  failures++;
  console.error(`FAIL ${where}: ${message}`);
}

// The comparable spelling of a result, matching `canon` in test_weasel.cpp:
// integers in decimal, floats as their bit pattern.
function canon(type, value) {
  switch (type) {
    case "i32":
      return String(value | 0);
    case "i64":
      return String(BigInt.asIntN(64, BigInt(value)));
    case "f32": {
      const b = new DataView(new ArrayBuffer(4));
      b.setFloat32(0, Math.fround(value));
      return "0x" + b.getUint32(0).toString(16).padStart(8, "0");
    }
    case "f64": {
      const b = new DataView(new ArrayBuffer(8));
      b.setFloat64(0, value);
      return "0x" + b.getBigUint64(0).toString(16).padStart(16, "0");
    }
    default:
      return value === null ? "null" : "ref";
  }
}

function parseLiteral(type, text) {
  switch (type) {
    case "i32":
      return text.startsWith("0x") ? Number.parseInt(text, 16) | 0 : Number(text) | 0;
    case "i64":
      return BigInt.asIntN(64, BigInt(text));
    case "f32":
    case "f64":
      if (text === "nan" || text === "-nan") return NaN;
      if (text === "inf") return Infinity;
      if (text === "-inf") return -Infinity;
      return Number(text);
    default:
      return null;
  }
}

// The signature of an exported function. `WebAssembly` does not expose one, so
// it is read off the `.wat` — from the declaration line only, which is where the
// test files put it, and which keeps a `(loop (param i32))` inside the body from
// being mistaken for the function's own.
function signatures(source) {
  const out = new Map();
  const re = /\(func[^\n]*?\(export\s+"([^"]+)"\)([^\n]*)/g;
  let m;
  while ((m = re.exec(source)) !== null) {
    const params = [];
    for (const p of m[2].matchAll(/\(param([^)]*)\)/g))
      for (const t of p[1].trim().split(/\s+/))
        if (t && !t.startsWith("$")) params.push(t);
    const r = m[2].match(/\(result([^)]*)\)/);
    out.set(m[1], {
      params,
      results: r ? r[1].trim().split(/\s+/).filter(Boolean) : [],
    });
  }
  return out;
}

const wasiShim = (memoryRef, stdout) => ({
  wasi_snapshot_preview1: {
    fd_write(fd, iovs, count, written) {
      const mem = new DataView(memoryRef.value.buffer);
      const bytes = new Uint8Array(memoryRef.value.buffer);
      let total = 0;
      for (let i = 0; i < count; i++) {
        const ptr = mem.getUint32(iovs + i * 8, true);
        const len = mem.getUint32(iovs + i * 8 + 4, true);
        stdout.push(new TextDecoder().decode(bytes.subarray(ptr, ptr + len)));
        total += len;
      }
      mem.setUint32(written, total, true);
      return 0;
    },
    proc_exit() {},
    fd_close: () => 0,
    fd_seek: () => 70,
    fd_read: () => 0,
    args_sizes_get: () => 0,
    args_get: () => 0,
    environ_sizes_get: () => 0,
    environ_get: () => 0,
    random_get: () => 0,
    clock_time_get: () => 0,
    fd_fdstat_get: () => 0,
    fd_prestat_get: () => 8,
    fd_prestat_dir_name: () => 8,
  },
});

for (const file of readdirSync(dir).filter((f) => f.endsWith(".wat")).sort()) {
  const where = basename(file);
  const path = join(dir, file);
  const source = readFileSync(path, "utf8");
  const tmp = join(tmpdir(), `v8-${where}.wasm`);
  try {
    execFileSync("wat2wasm", [path, "-o", tmp]);
  } catch {
    fail(where, "wat2wasm rejected the file");
    continue;
  }
  const bytes = readFileSync(tmp);
  unlinkSync(tmp);

  const sigs = signatures(source);
  const memoryRef = { value: null };
  const stdout = [];
  let instance;
  try {
    const mod = new WebAssembly.Module(bytes);
    instance = new WebAssembly.Instance(mod, wasiShim(memoryRef, stdout));
    memoryRef.value = instance.exports.memory ?? instance.exports.mem ?? null;
  } catch (e) {
    fail(where, `V8 refused the module: ${e.message}`);
    continue;
  }

  for (const line of source.split("\n")) {
    const at = line.indexOf(";;=");
    if (at < 0) continue;
    const rest = line.slice(at + 3).trim();
    if (rest.startsWith("stdout ")) {
      checks++;
      const want = rest.slice(7);
      const got = stdout.join("").replace(/\n$/, "");
      if (got !== want) fail(where, `stdout: expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
      continue;
    }
    const [lhs, rhs = ""] = rest.split("=>");
    const parts = lhs.trim().split(/\s+/);
    const kind = parts[0];
    const name = parts[1];
    if (kind !== "invoke" && kind !== "trap") continue;
    const sig = sigs.get(name) ?? { params: [], results: [] };
    const fn = instance.exports[name];
    if (typeof fn !== "function") {
      fail(where, `V8 exports no function ${name}`);
      continue;
    }
    const args = parts.slice(2).map((t, i) => parseLiteral(sig.params[i] ?? "i32", t));

    checks++;
    let result, threw = null;
    try {
      result = fn(...args);
    } catch (e) {
      threw = e;
    }
    if (kind === "trap") {
      if (!threw) fail(where, `${name} was expected to trap on V8 and did not`);
      continue;
    }
    if (threw) {
      fail(where, `${name} trapped on V8: ${threw.message}`);
      continue;
    }
    const wanted = rhs.trim().split(/\s+/).filter(Boolean);
    const got = sig.results.length === 0 ? [] : [result];
    if (got.length !== wanted.length) {
      fail(where, `${name} returned ${got.length} values, ${wanted.length} expected`);
      continue;
    }
    for (let i = 0; i < got.length; i++) {
      const t = sig.results[i];
      const a = canon(t, got[i]);
      const b = canon(t, parseLiteral(t, wanted[i]));
      if (a !== b) fail(where, `${name}(${parts.slice(2).join(", ")}): V8 says ${a}, the file says ${b}`);
    }
  }
}

console.log(`${checks} checks on V8, ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
