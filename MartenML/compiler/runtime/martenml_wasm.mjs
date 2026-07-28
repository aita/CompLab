// Run a compiled MartenML module under WASI.
//
// The module the wasm back end emits is a WASI command: it exports `_start`
// and imports fd_write, fd_read and proc_exit, which is everything it needs
// from the outside world.  Node is the host here only because it is the one
// that is usually already installed; wasmtime, wasmer or any other preview1
// runtime will run the same file.
//
//   node --no-warnings --stack-size=6000 martenml_wasm.mjs program.wasm
//
// `--stack-size` is in kilobytes and is what bounds how deep recursion that is
// not a tail call may go.  V8's default leaves room for only a few thousand
// wasm frames, which a MartenML program reaches easily; 6000 is most of the
// 8 MB thread stack the operating system usually hands out, and buys tens of
// thousands.  Nothing above this line depends on it -- a tail call costs no
// stack on either target.

import { readFileSync } from "node:fs";
import { WASI } from "node:wasi";

const path = process.argv[2];
if (!path) {
  process.stderr.write("usage: martenml_wasm.mjs <program.wasm>\n");
  process.exit(2);
}

const wasi = new WASI({ version: "preview1", args: [], env: {}, returnOnExit: true });
const module = await WebAssembly.compile(readFileSync(path));
const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
process.exitCode = wasi.start(instance);
