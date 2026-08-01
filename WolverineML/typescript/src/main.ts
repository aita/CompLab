#!/usr/bin/env node
// The command line.

import { WolvError } from "./diag.ts";
import * as driver from "./driver.ts";
import { OutOfRegisters } from "./spill.ts";

const usage = (): string => `usage: wolv <command> <file.wol> [options]

  build   compile and link an executable
  run     compile, link, and run it
  emit    dump one stage of the pipeline
  check   typecheck only

  -o, --out PATH    where \`build\` writes the executable
  -s, --stage NAME  which stage \`emit\` shows: ${driver.STAGES.join(", ")}
  --no-checks       leave out the nil, bounds and divide-by-zero checks
  --no-opt          do not optimise the SSA
  --max-regs N      pretend the machine has this many registers, to force spilling
`;

class UsageError extends Error {}

class Arguments {
  command = "";
  file = "";
  out: string | null = null;
  stage = "asm";
  noChecks = false;
  noOpt = false;
  maxRegs: number | null = null;

  constructor(argv: string[]) {
    const positional: string[] = [];
    const value = (at: number, flag: string): string => {
      const got = argv[at];
      if (got === undefined) throw new UsageError(`\`${flag}\` wants a value`);
      return got;
    };
    for (let at = 0; at < argv.length; at++) {
      const arg = argv[at]!;
      switch (arg) {
        case "-o": case "--out": this.out = value(++at, arg); break;
        case "-s": case "--stage": this.stage = value(++at, arg); break;
        case "--no-checks": this.noChecks = true; break;
        case "--no-opt": this.noOpt = true; break;
        case "--max-regs": {
          const text = value(++at, arg);
          if (!/^-?\d+$/.test(text)) throw new UsageError("`--max-regs` wants a number");
          this.maxRegs = Number(text);
          break;
        }
        case "-h": case "--help": throw new UsageError("");
        default:
          if (arg.startsWith("-")) throw new UsageError(`no such option as \`${arg}\``);
          positional.push(arg);
      }
    }
    if (positional.length !== 2) throw new UsageError("a command and a file, and nothing else");
    this.command = positional[0]!;
    this.file = positional[1]!;
    if (!["build", "run", "emit", "check"].includes(this.command)) {
      throw new UsageError(`no such command as \`${this.command}\``);
    }
    if (!driver.STAGES.includes(this.stage)) {
      throw new UsageError(`no such stage as \`${this.stage}\``);
    }
  }
}

function wolv(argv: string[]): number {
  let args: Arguments;
  try {
    args = new Arguments(argv);
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    process.stderr.write(usage());
    if (error.message !== "") process.stderr.write(`wolv: ${error.message}\n`);
    return 1;
  }

  const opts = new driver.Options(!args.noChecks, !args.noOpt, args.maxRegs);
  let source: string;
  try {
    source = driver.readSource(args.file);
  } catch (error) {
    process.stderr.write(`wolv: ${(error as Error).message}\n`);
    return 1;
  }

  try {
    switch (args.command) {
      case "check":
        driver.toIR(source, opts);
        break;
      case "emit":
        process.stdout.write(driver.stage(source, args.stage, opts));
        break;
      case "build": {
        const out = args.out ?? args.file.replace(/\.wol$/, "");
        driver.build(source, out, opts);
        break;
      }
      default: {
        const done = driver.run(source, opts);
        process.stdout.write(done.stdout);
        process.stderr.write(done.stderr);
        return done.exitCode;
      }
    }
  } catch (error) {
    if (error instanceof WolvError) {
      process.stderr.write(`${args.file}:${error.span}: ${error.detail}\n`);
      return 1;
    }
    if (error instanceof driver.ToolchainError || error instanceof OutOfRegisters) {
      process.stderr.write(`wolv: ${error.message}\n`);
      return 1;
    }
    throw error;
  }
  return 0;
}

process.exitCode = wolv(process.argv.slice(2));