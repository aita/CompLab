import wolv.Diag.WolvError;
import wolv.Driver.Options;
import wolv.Driver.ToolchainError;

/* The command line. */

class Wolv {
  static final USAGE = "usage: wolv <command> <file.wol> [options]

  build   compile and link an executable
  run     compile, link, and run it
  emit    dump one stage of the pipeline
  check   typecheck only

  -o, --out PATH    where `build` writes the executable
  -s, --stage NAME  which stage `emit` shows: {stages}
  --no-checks       leave out the nil, bounds and divide-by-zero checks
  --no-opt          do not optimise the SSA
  --max-regs N      pretend the machine has this many registers, to force spilling
";

  static function main() {
    Sys.exit(run(Sys.args()));
  }

  static function run(argv:Array<String>):Int {
    var args:Arguments;
    try {
      args = parseArguments(argv);
    } catch (usage:Usage) {
      Sys.stderr().writeString(StringTools.replace(USAGE, "{stages}", wolv.Driver.STAGES.join(", ")));
      if (usage.detail != "") Sys.stderr().writeString("wolv: " + usage.detail + "\n");
      return 1;
    }

    final opts = new Options(!args.noChecks, !args.noOpt, args.maxRegs);
    var source:String;
    try {
      source = sys.io.File.getContent(args.file);
    } catch (_:Dynamic) {
      Sys.stderr().writeString('wolv: cannot read ${args.file}\n');
      return 1;
    }

    try {
      switch args.command {
        case "check":
          wolv.Driver.toIr(source, opts);
          return 0;
        case "emit":
          Sys.print(wolv.Driver.stage(source, args.stage, opts));
          return 0;
        case "build":
          wolv.Driver.build(source, args.out != "" ? args.out : withoutExtension(args.file), opts);
          return 0;
        case _:
          final done = wolv.Driver.run(source, opts);
          Sys.print(done.stdout);
          Sys.stderr().writeString(done.stderr);
          return done.exitCode;
      }
    } catch (error:WolvError) {
      Sys.stderr().writeString('${args.file}:$error\n');
      return 1;
    } catch (error:ToolchainError) {
      Sys.stderr().writeString("wolv: " + error.detail + "\n");
      return 1;
    } catch (error:wolv.Spill.OutOfRegisters) {
      Sys.stderr().writeString("wolv: " + error.detail + "\n");
      return 1;
    }
  }

  static function withoutExtension(path:String):String {
    final dot = path.lastIndexOf(".");
    final slash = path.lastIndexOf("/");
    return dot > slash && dot > 0 ? path.substr(0, dot) : path;
  }

  static function parseArguments(argv:Array<String>):Arguments {
    final args = new Arguments();
    final positional = [];

    inline function value(at:Int, flag:String):String {
      if (at >= argv.length) throw new Usage('`$flag` wants a value');
      return argv[at];
    }

    var at = 0;
    while (at < argv.length) {
      final arg = argv[at];
      at += 1;
      switch arg {
        case "-o" | "--out":
          args.out = value(at, arg);
          at += 1;
        case "-s" | "--stage":
          args.stage = value(at, arg);
          at += 1;
        case "--no-checks":
          args.noChecks = true;
        case "--no-opt":
          args.noOpt = true;
        case "--max-regs":
          final n = Std.parseInt(value(at, arg));
          if (n == null) throw new Usage("`--max-regs` wants a number");
          args.maxRegs = n;
          at += 1;
        case "-h" | "--help":
          throw new Usage("");
        case _:
          if (arg.length > 0 && arg.charAt(0) == "-") throw new Usage('no such option as `$arg`');
          positional.push(arg);
      }
    }

    if (positional.length != 2) throw new Usage("a command and a file, and nothing else");
    args.command = positional[0];
    args.file = positional[1];
    if (!["build", "run", "emit", "check"].contains(args.command)) {
      throw new Usage('no such command as `${args.command}`');
    }
    if (!wolv.Driver.STAGES.contains(args.stage)) {
      throw new Usage('no such stage as `${args.stage}`');
    }
    return args;
  }
}

private class Usage {
  public final detail:String;

  public function new(detail:String) {
    this.detail = detail;
  }
}

private class Arguments {
  public var command = "";
  public var file = "";
  public var out = "";
  public var stage = "asm";
  public var noChecks = false;
  public var noOpt = false;
  public var maxRegs = 0;

  public function new() {}
}
