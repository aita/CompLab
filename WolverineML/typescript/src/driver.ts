// The pipeline, and the toolchain around it.
//
//     source ─lex─▶ tokens ─parse─▶ tree ─check─▶ typed tree ─lower─▶ CFG
//            ─ssa─▶ SSA ─opt─▶ SSA ─select─▶ machine IR ─out of SSA─▶
//            ─regalloc─▶ coloured ─emit─▶ ARMv8
//
// Assembling and linking is left to a cross `gcc`, and running to `qemu-aarch64`
// when the machine underneath is not itself an ARM.

import { spawnSync } from "node:child_process";
import { accessSync, constants, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { arch } from "node:process";

import * as allocator from "./allocator.ts";
import * as astshow from "./astshow.ts";
import * as dag from "./dag.ts";
import * as emit from "./emit.ts";
import * as ir from "./ir.ts";
import * as lexer from "./lexer.ts";
import * as lower from "./lower.ts";
import * as mach from "./mach.ts";
import * as opt from "./opt.ts";
import * as outofssa from "./outofssa.ts";
import * as parser from "./parser.ts";
import * as select from "./select.ts";
import * as ssa from "./ssa.ts";
import * as typecheck from "./typecheck.ts";
import { Registers, limited } from "./registers.ts";

const here = dirname(fileURLToPath(import.meta.url));
const RUNTIME = join(here, "..", "runtime", "runtime.c");

export const STAGES = [
  "tokens", "ast", "ir", "ssa", "opt", "dag", "mach", "flat", "ra", "asm",
];

export class ToolchainError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ToolchainError";
  }
}

export class Options {
  readonly checks: boolean;
  readonly optimise: boolean;
  readonly maxRegs: number | null;

  constructor(checks = true, optimise = true, maxRegs: number | null = null) {
    this.checks = checks;
    this.optimise = optimise;
    this.maxRegs = maxRegs;
  }

  registers(): Registers {
    return this.maxRegs === null ? new Registers() : limited(this.maxRegs);
  }
}

export function toIR(source: string, opts: Options): ir.Module {
  const program = parser.parse(source);
  typecheck.check(program);
  return lower.lower(program, new lower.Options(opts.checks));
}

/**
 * The pipeline, stopped as soon as `upto` has something to show.
 *
 * There is one of these and not two: a dump is the pipeline halted, not a second
 * description of it that has to be kept in step.
 */
export function compileModule(source: string, opts: Options, upto = "asm"): ir.Module {
  const mod = toIR(source, opts);
  if (upto === "ir") return mod;
  ssa.constructModule(mod);
  if (upto === "ssa") return mod;
  if (opts.optimise) opt.optimise(mod);
  if (upto === "opt") return mod;
  for (const f of mod.funcs) ssa.splitCriticalEdges(f);
  if (upto === "dag") return mod; // the DAGs are a view of this, taken without changing it
  select.selectModule(mod);
  mach.verifyModule(mod);
  if (upto === "mach") return mod;
  outofssa.destructModule(mod);
  if (upto === "flat") return mod;
  allocator.allocateModule(mod, opts.registers());
  return mod;
}

export function compileToAsm(
  source: string, opts: Options, newEmitter?: emit.NewEmitter,
): string {
  return emit.emitModule(compileModule(source, opts), newEmitter);
}

export function showDags(mod: ir.Module): string {
  return mod.funcs.map((f) =>
    `fun ${f.label}\n`
    + [...select.graphs(f)].map(([label, g]) => `${label}:\n${dag.show(g)}`).join("\n"),
  ).join("\n\n") + "\n";
}

/** Run the pipeline as far as `name`, and show what it has by then. */
export function stage(source: string, name: string, opts: Options): string {
  if (name === "tokens") {
    return lexer.lex(source).map((t) => `${t.span}\t${t.kind}\t${t.text}`).join("\n");
  }
  if (name === "ast") {
    const program = parser.parse(source);
    typecheck.check(program);
    return astshow.showProgram(program);
  }
  const mod = compileModule(source, opts, name);
  if (name === "dag") return showDags(mod);
  if (name === "asm") return emit.emitModule(mod);
  return ir.showModule(mod);
}

// -- the toolchain ------------------------------------------------------------

function which(name: string): string | null {
  for (const dir of (process.env["PATH"] ?? "").split(":")) {
    const path = join(dir, name);
    try {
      accessSync(path, constants.X_OK);
      return path;
    } catch { /* not here */ }
  }
  return null;
}

const onArm = (): boolean => arch === "arm64";

export function crossCC(): string {
  const override = process.env["WOLV_CC"];
  if (override !== undefined && override !== "") return override;
  for (const name of [
    "aarch64-linux-gnu-gcc", "aarch64-linux-gnu-cc", "aarch64-none-linux-gnu-gcc",
  ]) {
    const found = which(name);
    if (found !== null) return found;
  }
  if (onArm()) {
    const native = which("cc") ?? which("gcc");
    if (native !== null) return native;
  }
  throw new ToolchainError(
    "no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC",
  );
}

export function emulator(): string[] {
  if (onArm()) return [];
  for (const name of ["qemu-aarch64", "qemu-aarch64-static"]) {
    const found = which(name);
    if (found !== null) return [found];
  }
  throw new ToolchainError("no qemu-aarch64 found, and this machine is not an ARM");
}

export function build(
  source: string, out: string, opts: Options, newEmitter?: emit.NewEmitter,
): void {
  const asm = compileToAsm(source, opts, newEmitter);
  const cc = crossCC();
  const tmp = mkdtempSync(join(tmpdir(), "wolv"));
  try {
    const path = join(tmp, "program.s");
    writeFileSync(path, asm);
    const done = spawnSync(cc, ["-static", "-O2", "-o", out, path, RUNTIME], {
      encoding: "utf8",
    });
    if (done.status !== 0) {
      throw new ToolchainError(`the assembler refused it:\n${done.stderr}`);
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

export class Completed {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
  constructor(exitCode: number, stdout: string, stderr: string) {
    this.exitCode = exitCode; this.stdout = stdout; this.stderr = stderr;
  }
}

/** `stdin` of null hands the program the standard input this process was given. */
export function run(
  source: string, opts: Options, stdin: string | null = null, newEmitter?: emit.NewEmitter,
): Completed {
  const tmp = mkdtempSync(join(tmpdir(), "wolv"));
  try {
    const binary = join(tmp, "program");
    build(source, binary, opts, newEmitter);
    const command = [...emulator(), binary];
    const done = spawnSync(command[0]!, command.slice(1), {
      input: stdin ?? undefined,
      stdio: stdin === null ? ["inherit", "pipe", "pipe"] : ["pipe", "pipe", "pipe"],
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
    return new Completed(done.status ?? 1, done.stdout ?? "", done.stderr ?? "");
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

export const readSource = (path: string): string => readFileSync(path, "utf8");
