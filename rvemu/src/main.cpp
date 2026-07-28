// rvemu — the command line.
//
// Everything after the program name belongs to the guest, the way `env` and
// `qemu-user` do it, so `rvemu ./prog -v --out x` passes `-v --out x` through
// untouched and there is never a question of who an option was meant for.

#include <signal.h>
#include <stdio.h>
#include <unistd.h>

import std;
import rvemu;

extern char** environ;

namespace {

using namespace rvemu;

// The interrupt flag has to be reachable from a signal handler, so the running
// machine's is registered here.
std::atomic<bool>* g_interrupt = nullptr;

void on_sigint(int) {
  if (g_interrupt) g_interrupt->store(true);
}

void usage(std::FILE* out) {
  std::print(out, R"(usage: rvemu [options] <program> [args...]

  <program> is a statically linked RISC-V ELF64 executable, or a .s assembly
  file, which is assembled and run directly. Everything after it is passed to
  the guest as argv.

options:
  -g, --gdb PORT        wait for gdb on 127.0.0.1:PORT before starting
  -a, --asm             assemble <program> even if it does not look like one
  -d, --disassemble     disassemble the program and exit, without running it
  -t, --trace           print each instruction as it retires
  -T, --trace-syscalls  print each ecall and its result
  -n, --max-insns N     stop after N instructions
  -s, --stats           report instructions, syscalls and pages on exit
  -e, --env NAME=VALUE  set one variable (repeatable); implies a clean environment
  -h, --help            this

examples:
  rvemu ./hello                      run a static ELF
  rvemu examples/hello.s             assemble and run
  rvemu -g 1234 ./hello              then, elsewhere: gdb -ex 'target remote :1234'
  rvemu -d examples/fib.s            disassemble
)");
}

// `--disassemble`: walk the executable ranges, print a heading wherever a symbol
// starts, and let the disassembler do the rest.
void dump(Machine& m) {
  for (auto [base, size] : m.image.text) {
    u64 pc = base;
    while (pc < base + size) {
      Inst in;
      if (!m.cpu.fetch(pc, in)) break;
      const std::string sym = m.image.describe(pc);
      if (!sym.empty() && sym.find('+') == std::string::npos) {
        std::print("\n{:016x} <{}>:\n", pc, sym);
      }
      std::print("{:>12}:\t{}\n", hex(pc), disasm(in, pc));
      pc += in.len;
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  Machine machine;
  Diag d;

  int gdb_port = 0;
  bool force_asm = false, disassemble = false, clean_env = false;
  std::vector<std::string> env_overrides;

  int i = 1;
  for (; i < argc; ++i) {
    const std::string_view a = argv[i];
    auto value = [&](const char* what) -> const char* {
      if (i + 1 >= argc) {
        std::print(stderr, "rvemu: {} needs a value\n", what);
        std::exit(2);
      }
      return argv[++i];
    };

    if (a == "-h" || a == "--help") {
      usage(stdout);
      return 0;
    }
    if (a == "-g" || a == "--gdb") {
      gdb_port = std::atoi(value("--gdb"));
      continue;
    }
    if (a == "-a" || a == "--asm") { force_asm = true; continue; }
    if (a == "-d" || a == "--disassemble") { disassemble = true; continue; }
    if (a == "-t" || a == "--trace") { machine.opts.trace = true; continue; }
    if (a == "-T" || a == "--trace-syscalls") {
      machine.opts.trace_syscalls = true;
      continue;
    }
    if (a == "-s" || a == "--stats") { machine.opts.stats = true; continue; }
    if (a == "-n" || a == "--max-insns") {
      machine.opts.max_insns = std::strtoull(value("--max-insns"), nullptr, 0);
      continue;
    }
    if (a == "-e" || a == "--env") {
      clean_env = true;
      env_overrides.push_back(value("--env"));
      continue;
    }
    if (a == "--") { ++i; break; }
    if (!a.empty() && a[0] == '-') {
      std::print(stderr, "rvemu: unknown option {}\n", a);
      return 2;
    }
    break;  // the program name; everything after it is the guest's
  }

  if (i >= argc) {
    usage(stderr);
    return 2;
  }
  const std::string program = argv[i];
  for (int k = i; k < argc; ++k) machine.opts.argv.push_back(argv[k]);

  // The guest inherits the host environment unless -e was used, which is what
  // makes locale-sensitive programs behave the same inside rvemu as outside it.
  if (clean_env) {
    machine.opts.envp = env_overrides;
  } else {
    for (char** e = environ; e && *e; ++e) machine.opts.envp.push_back(*e);
  }

  // ELF or assembly? The magic number decides unless told otherwise, so a `.s`
  // that is really an ELF, or the reverse, still does the right thing.
  std::vector<u8> bytes;
  if (!read_file(program, bytes, d)) {
    std::print(stderr, "rvemu: {}\n", d.message);
    return 1;
  }
  if (force_asm || !looks_like_elf(bytes)) {
    Assembler as;
    const std::string_view src(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    if (!as.assemble(src, program, machine.cpu.mem, machine.image, d)) {
      std::print(stderr, "rvemu: {}:{}\n", program, d.message);
      return 1;
    }
  } else if (!load_elf(bytes, program, machine.cpu.mem, machine.image, d)) {
    std::print(stderr, "rvemu: {}\n", d.message);
    return 1;
  }
  machine.kernel.set_brk_start(machine.image.brk);

  if (!machine.start(d)) {
    std::print(stderr, "rvemu: {}\n", d.message);
    return 1;
  }

  if (disassemble) {
    dump(machine);
    return 0;
  }

  g_interrupt = &machine.interrupt;
  std::signal(SIGINT, on_sigint);

  if (gdb_port) {
    GdbStub stub(machine);
    if (!stub.wait_for_debugger(gdb_port, d)) {
      std::print(stderr, "rvemu: {}\n", d.message);
      return 1;
    }
    return stub.serve();
  }
  return machine.run();
}
