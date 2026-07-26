use std::process::ExitCode;

use copypatch::bytecode::JitState;
use copypatch::{build, jit, vm::Vm};

const USAGE: &str = "\
copypatch -- a tiny VM with a copy-and-patch baseline JIT

usage: copypatch [options] <program.cp>

options:
  --jit <n>          compile a function on its nth call (default 2)
  --no-jit           stay in the interpreter
  --entry <name>     entry point (default `main`)
  --max-depth <n>    recursion limit (default 10000)
  --dump-bytecode    print the bytecode and exit
  --dump-jit         print the machine code the JIT emitted, after running
  --dump-stencils    print the clang-generated stencil table and exit
  --stats            print execution statistics
  --quiet            do not print the entry point's return value
  -h, --help         show this message
";

struct Options {
    path: Option<String>,
    entry: String,
    max_depth: usize,
    jit_threshold: Option<u32>,
    dump_bytecode: bool,
    dump_jit: bool,
    dump_stencils: bool,
    stats: bool,
    quiet: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            path: None,
            entry: "main".to_string(),
            max_depth: 10_000,
            jit_threshold: Some(2),
            dump_bytecode: false,
            dump_jit: false,
            dump_stencils: false,
            stats: false,
            quiet: false,
        }
    }
}

fn parse_args() -> Result<Options, String> {
    let mut o = Options::default();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-h" | "--help" => {
                print!("{USAGE}");
                std::process::exit(0);
            }
            "--no-jit" => o.jit_threshold = None,
            "--jit" => {
                let n = args.next().ok_or("--jit needs a number")?;
                let n: u32 = n.parse().map_err(|_| format!("`{n}` is not a number"))?;
                o.jit_threshold = Some(n.max(1));
            }
            "--entry" => o.entry = args.next().ok_or("--entry needs a name")?,
            "--max-depth" => {
                let n = args.next().ok_or("--max-depth needs a number")?;
                o.max_depth = n.parse().map_err(|_| format!("`{n}` is not a number"))?;
            }
            "--dump-bytecode" => o.dump_bytecode = true,
            "--dump-jit" => o.dump_jit = true,
            "--dump-stencils" => o.dump_stencils = true,
            "--stats" => o.stats = true,
            "--quiet" => o.quiet = true,
            other if other.starts_with('-') => return Err(format!("unknown option `{other}`")),
            other => o.path = Some(other.to_string()),
        }
    }
    Ok(o)
}

/// Both tiers use one native frame per language-level call, and an
/// unoptimised build's frames are several times fatter than a release
/// build's. Run on a thread with enough stack that `Vm::max_depth` is what
/// stops runaway recursion, in either profile.
const STACK_SIZE: usize = 64 << 20;

fn main() -> ExitCode {
    std::thread::Builder::new()
        .stack_size(STACK_SIZE)
        .spawn(run)
        .expect("could not spawn the interpreter thread")
        .join()
        .unwrap_or(ExitCode::FAILURE)
}

fn run() -> ExitCode {
    let opts = match parse_args() {
        Ok(o) => o,
        Err(e) => {
            eprintln!("copypatch: {e}\n\n{USAGE}");
            return ExitCode::FAILURE;
        }
    };

    if opts.dump_stencils {
        print!("{}", jit::dump_stencils());
        if opts.path.is_none() {
            return ExitCode::SUCCESS;
        }
    }

    let Some(path) = opts.path.clone() else {
        eprintln!("copypatch: no input file\n\n{USAGE}");
        return ExitCode::FAILURE;
    };

    let src = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("copypatch: cannot read {path}: {e}");
            return ExitCode::FAILURE;
        }
    };

    let funcs = match build(&src) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };

    if opts.dump_bytecode {
        for f in &funcs {
            print!("{}", f.disassemble());
        }
        return ExitCode::SUCCESS;
    }

    let mut vm = Vm::new(funcs);
    vm.jit_threshold = opts.jit_threshold;
    vm.max_depth = opts.max_depth;

    let result = vm.run(&opts.entry);

    if let Some(warning) = &vm.jit_warning {
        eprintln!("copypatch: jit fell back to the interpreter for {warning}");
    }

    if opts.dump_jit {
        for f in vm.functions() {
            if let JitState::Ready(code) = &*f.jit.borrow() {
                print!("{}", code.dump(f));
            }
        }
    }

    let code = match result {
        Ok(v) => {
            if !opts.quiet {
                println!("=> {}", vm.show(v));
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    };

    if opts.stats {
        let s = vm.stats;
        eprintln!(
            "stats: {} calls ({} jit / {} interpreted), {} interpreted ops, \
             {} functions jitted into {} bytes",
            s.calls,
            s.jit_calls,
            s.interpreted_calls,
            s.interpreted_ops,
            s.jit_functions,
            s.jit_bytes
        );
    }

    code
}
