package wolv;

import sys.FileSystem;
import sys.io.File;
import wolv.Ir;

/* The pipeline, and the toolchain that turns what comes out of it into a program.
 *
 *     source ─lex─▶ tokens ─parse─▶ tree ─check─▶ typed tree ─lower─▶ CFG
 *       ─ssa─▶ SSA ─opt─▶ SSA ─select─▶ machine IR ─out-of-ssa─▶ flat
 *       ─allocate─▶ coloured ─emit─▶ ARMv8 assembly ─cc─▶ executable */

class ToolchainError {
  public final detail:String;

  public function new(detail:String) {
    this.detail = detail;
  }

  public function toString():String return detail;
}

final STAGES = ["tokens", "ast", "ir", "ssa", "opt", "dag", "mach", "flat", "ra", "asm"];

class Options {
  public final checks:Bool;
  public final optimise:Bool;

  /** 0 means the whole machine. */
  public final maxRegs:Int;

  public function new(checks = true, optimise = true, maxRegs = 0) {
    this.checks = checks;
    this.optimise = optimise;
    this.maxRegs = maxRegs;
  }

  public function registers():Registers.Machine {
    return maxRegs == 0 ? Registers.all() : Registers.limited(maxRegs);
  }
}

function toIr(source:String, opts:Options):{prog:Ast.Program, modul:Module} {
  final prog = Parser.parse(source);
  Typecheck.check(prog);
  return {prog: prog, modul: Lower.lower(prog, new Lower.Lowering(opts.checks))};
}

/**
 * The pipeline, stopped as soon as `upto` has something to show.
 *
 * There is one of these and not two: a dump is the pipeline halted, not a second
 * description of it that has to be kept in step.
 */
function compileModule(source:String, opts:Options, upto = "asm"):Module {
  final m = toIr(source, opts).modul;
  if (upto == "ir") return m;
  Ssa.constructModule(m);
  if (upto == "ssa") return m;
  if (opts.optimise) Opt.optimise(m);
  if (upto == "opt") return m;
  for (f in m.funcs) Ssa.splitCriticalEdges(f);
  // The DAGs are a view of this, taken without changing it.
  if (upto == "dag") return m;
  Select.selectModule(m);
  Mach.verifyModule(m);
  if (upto == "mach") return m;
  OutOfSsa.destructModule(m);
  if (upto == "flat") return m;
  Allocator.allocateModule(m, opts.registers());
  return m;
}

function compileToAsm(source:String, opts:Options, noBorrow = false):String {
  return Emit.emitModule(compileModule(source, opts, "asm"), noBorrow);
}

function showDags(m:Module):String {
  return m.funcs.map(f -> "fun " + f.label + "\n"
    + Select.graphs(f).map(g -> g.label + ":\n" + Dag.show(g.graph)).join("\n")).join("\n\n")
    + "\n";
}

/** Run the pipeline as far as `name`, and show what it has by then. */
function stage(source:String, name:String, opts:Options):String {
  return switch name {
    case "tokens": Lexer.dump(Lexer.lex(source));
    case "ast":
      final prog = Parser.parse(source);
      Typecheck.check(prog);
      AstShow.showProgram(prog);
    case _:
      final m = compileModule(source, opts, name);
      switch name {
        case "dag": showDags(m);
        case "asm": Emit.emitModule(m);
        case _: Ir.showModule(m);
      }
  }
}

/* -- the toolchain ---------------------------------------------------------- */

function which(name:String):Null<String> {
  final path = Sys.getEnv("PATH");
  if (path == null) return null;
  for (dir in path.split(":")) {
    final full = dir + "/" + name;
    if (FileSystem.exists(full) && !FileSystem.isDirectory(full)) return full;
  }
  return null;
}

private function onArm():Bool {
  try {
    final p = new sys.io.Process("uname", ["-m"]);
    final machine = StringTools.trim(p.stdout.readAll().toString());
    p.close();
    return machine == "aarch64" || machine == "arm64";
  } catch (_:Dynamic) {
    return false;
  }
}

function crossCc():String {
  final set = Sys.getEnv("WOLV_CC");
  if (set != null && set != "") return set;
  for (name in ["aarch64-linux-gnu-gcc", "aarch64-linux-gnu-cc", "aarch64-none-linux-gnu-gcc"]) {
    final found = which(name);
    if (found != null) return found;
  }
  if (onArm()) {
    for (name in ["cc", "gcc"]) {
      final found = which(name);
      if (found != null) return found;
    }
  }
  throw new ToolchainError("no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC");
}

function emulator():Array<String> {
  if (onArm()) return [];
  for (name in ["qemu-aarch64", "qemu-aarch64-static"]) {
    final found = which(name);
    if (found != null) return [found];
  }
  throw new ToolchainError("no qemu-aarch64 found, and this machine is not an ARM");
}

class Completed {
  public final exitCode:Int;
  public final stdout:String;
  public final stderr:String;

  public function new(exitCode:Int, stdout:String, stderr:String) {
    this.exitCode = exitCode;
    this.stdout = stdout;
    this.stderr = stderr;
  }
}

private var tempCount = 0;

private function tempDir():String {
  tempCount += 1;
  final path = '/tmp/wolv-${Std.int(Sys.time() * 1000)}-$tempCount';
  FileSystem.createDirectory(path);
  return path;
}

private function removeDir(path:String):Void {
  if (!FileSystem.exists(path)) return;
  if (FileSystem.isDirectory(path)) {
    for (entry in FileSystem.readDirectory(path)) removeDir(path + "/" + entry);
    FileSystem.deleteDirectory(path);
  } else {
    FileSystem.deleteFile(path);
  }
}

/**
 * Both pipes go to files and the input comes from one, so that a program which
 * fills a pipe cannot wait for a reader that is itself waiting.
 */
private function execute(command:String, args:Array<String>, stdinText:Null<String>):Completed {
  final dir = tempDir();
  final outPath = dir + "/out";
  final errPath = dir + "/err";
  var shell = escapeShell(command);
  for (a in args) shell += " " + escapeShell(a);
  if (stdinText != null) {
    File.saveContent(dir + "/in", stdinText);
    shell += " < " + escapeShell(dir + "/in");
  }
  shell += " > " + escapeShell(outPath) + " 2> " + escapeShell(errPath);
  final code = Sys.command("/bin/sh", ["-c", shell]);
  final stdout = FileSystem.exists(outPath) ? File.getContent(outPath) : "";
  final stderr = FileSystem.exists(errPath) ? File.getContent(errPath) : "";
  removeDir(dir);
  return new Completed(code, stdout, stderr);
}

private function escapeShell(text:String):String {
  return "'" + StringTools.replace(text, "'", "'\\''") + "'";
}

function build(source:String, out:String, opts:Options, noBorrow = false):Void {
  final asm = compileToAsm(source, opts, noBorrow);
  final cc = crossCc();
  final dir = tempDir();
  final assembly = dir + "/program.s";
  File.saveContent(assembly, asm);
  // The run-time system travels inside the compiler, as an embedded resource, and
  // is unpacked to compile.
  final csource = dir + "/runtime.c";
  File.saveContent(csource, haxe.Resource.getString("runtime.c"));
  final done = execute(cc, ["-static", "-O2", "-o", out, assembly, csource], "");
  removeDir(dir);
  if (done.exitCode != 0) throw new ToolchainError("the assembler refused it:\n" + done.stderr);
}

/** `stdinText` of null hands the program the standard input this process was given. */
function run(source:String, opts:Options, ?stdinText:String, noBorrow = false):Completed {
  final dir = tempDir();
  final binary = dir + "/program";
  build(source, binary, opts, noBorrow);
  final prefix = emulator();
  final done = prefix.length == 0 ? execute(binary, [], stdinText)
    : execute(prefix[0], prefix.slice(1).concat([binary]), stdinText);
  removeDir(dir);
  return done;
}
