// Machine partition — a loaded program, a running process, and the loop.
//
// Machine owns the Cpu, the Image and the Kernel, and is the only thing that
// knows how to turn a file on disk into a process: map the stack, build the
// argv/envp/auxv block the C runtime expects to find at sp, and then step.
//
// The auxiliary vector is the fussy part and the part that has to be right. A
// static glibc reads AT_PHDR to find its own program headers, walks them to
// locate PT_TLS, and sets up thread-local storage from that; get AT_PHDR wrong
// and the failure surfaces thousands of instructions later inside
// __libc_setup_tls with nothing to point at the cause.
//
// `resume` is the interface the gdb stub drives. It is the same loop `run` uses,
// with breakpoint checks and a single-step mode, so a program behaves the same
// whether or not a debugger is attached.
module;

// `stderr` is a macro-adjacent extern that `import std;` does not bring in.
#include <stdio.h>

export module rvemu:machine;

import std;
import :common;
import :memory;
import :cpu;
import :decode;
import :disasm;
import :exec;
import :elf;
import :syscall;

export namespace rvemu {

// Why `resume` came back.
enum class Event : u8 {
  Exited,       // the guest called exit
  Breakpoint,   // hit a breakpoint, or executed ebreak
  Stepped,      // single-step finished
  Fault,        // memory access violation
  Illegal,      // undecodable instruction
  Interrupted,  // the host asked us to stop (^C over the gdb link)
  Limit,        // --max-insns reached
};

struct RunOptions {
  std::vector<std::string> argv;  // argv[0] onwards, as the guest will see them
  std::vector<std::string> envp;
  bool trace = false;
  bool trace_syscalls = false;
  u64 max_insns = 0;  // 0 means no limit
};

// The auxv keys the C runtime actually reads.
enum Auxv : u64 {
  AtNull = 0, AtPhdr = 3, AtPhent = 4, AtPhnum = 5, AtPagesz = 6, AtBase = 7,
  AtFlags = 8, AtEntry = 9, AtUid = 11, AtEuid = 12, AtGid = 13, AtEgid = 14,
  AtPlatform = 15, AtHwcap = 16, AtClktck = 17, AtSecure = 23, AtRandom = 25,
  AtExecfn = 31,
};

// RISC-V AT_HWCAP is a bitmap over the extension letters: bit (letter - 'a').
// rvemu implements I, M, A, F, D and C.
inline constexpr u64 kHwcap = (u64{1} << ('a' - 'a')) | (u64{1} << ('c' - 'a')) |
                              (u64{1} << ('d' - 'a')) | (u64{1} << ('f' - 'a')) |
                              (u64{1} << ('i' - 'a')) | (u64{1} << ('m' - 'a'));

class Machine {
 public:
  Cpu cpu;
  Image image;
  Kernel kernel{cpu, image};

  RunOptions opts;
  std::set<u64> breakpoints;

  // Set to break out of a long `continue`: either by the ^C handler, or by the
  // gdb stub when the debugger sends its interrupt byte.
  std::atomic<bool> interrupt{false};

  // Called every `kPollInterval` instructions while running. The gdb stub uses
  // it to notice a ^C on the wire without a second thread; the cost is one
  // predictable branch per instruction and a poll() every few million.
  std::function<void()> poll_hook;
  static constexpr u64 kPollInterval = 1 << 16;

  u64 executed = 0;

  // Set alongside Event::Fault / Event::Illegal, for the report.
  std::string last_error;

  // Load an already-read ELF image, or an assembled one. `load_elf` fills
  // `image`; the caller sets it directly for the assembler path.
  bool load_elf_file(const std::string& path, Diag& d) {
    std::vector<u8> bytes;
    if (!read_file(path, bytes, d)) return false;
    if (!load_elf(bytes, path, cpu.mem, image, d)) return false;
    kernel.set_brk_start(image.brk);
    return true;
  }

  // Map the stack and lay out argc/argv/envp/auxv the way the kernel does.
  // Leaves pc at the entry point and sp at the block, ready to run.
  bool start(Diag& d) {
    cpu.mem.map(kStackTop - kStackSize, kStackSize, PermRW);
    cpu.hart.pc = image.entry;
    cpu.time_base = static_cast<u64>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count());
    kernel.trace = opts.trace_syscalls;

    u64 p = kStackTop;
    // Strings live at the very top, and everything below points up at them.
    auto push_string = [&](std::string_view s) {
      p -= s.size() + 1;
      cpu.mem.poke(p, s.data(), s.size());
      const u8 nul = 0;
      cpu.mem.poke(p + s.size(), &nul, 1);
      return p;
    };

    std::vector<u64> argv_ptrs, envp_ptrs;
    for (const std::string& s : opts.argv) argv_ptrs.push_back(push_string(s));
    for (const std::string& s : opts.envp) envp_ptrs.push_back(push_string(s));
    const u64 platform_ptr = push_string("riscv64");
    const u64 execfn_ptr =
        opts.argv.empty() ? platform_ptr : push_string(opts.argv.front());

    // AT_RANDOM points at 16 bytes the runtime uses to seed stack canaries and
    // hash tables. Real randomness, so a guest that prints it looks right.
    p = align_down(p - 16, 16);
    const u64 random_ptr = p;
    {
      std::array<u8, 16> seed{};
      std::random_device rd;
      for (std::size_t i = 0; i + 4 <= seed.size(); i += 4) {
        const u32 v = rd();
        std::memcpy(seed.data() + i, &v, 4);
      }
      cpu.mem.poke(random_ptr, seed.data(), seed.size());
    }

    const std::vector<std::pair<u64, u64>> auxv = {
        {AtPhdr, image.phdr},   {AtPhent, image.phent},
        {AtPhnum, image.phnum}, {AtPagesz, kPageSize},
        {AtBase, 0},            {AtFlags, 0},
        {AtEntry, image.entry}, {AtUid, 0},
        {AtEuid, 0},            {AtGid, 0},
        {AtEgid, 0},            {AtSecure, 0},
        {AtClktck, 100},        {AtHwcap, kHwcap},
        {AtRandom, random_ptr}, {AtPlatform, platform_ptr},
        {AtExecfn, execfn_ptr}, {AtNull, 0},
    };

    // argc, argv[], NULL, envp[], NULL, auxv pairs -- one contiguous block whose
    // base is sp, and which the ABI requires to be 16-byte aligned.
    const u64 words = 1 + argv_ptrs.size() + 1 + envp_ptrs.size() + 1 + auxv.size() * 2;
    u64 sp = align_down(p - words * 8, 16);
    if (sp < kStackTop - kStackSize) {
      d.fail("initial environment does not fit in the guest stack");
      return false;
    }
    cpu.hart.x[2] = sp;

    auto put = [&](u64 v) {
      cpu.mem.poke(sp, &v, 8);
      sp += 8;
    };
    put(argv_ptrs.size());
    for (u64 a : argv_ptrs) put(a);
    put(0);
    for (u64 a : envp_ptrs) put(a);
    put(0);
    for (auto [k, v] : auxv) {
      put(k);
      put(v);
    }
    return true;
  }

  // Step until something interesting happens. `single` retires exactly one
  // instruction (plus its syscall, if it was an ecall).
  Event resume(bool single) {
    // A breakpoint fires *before* the instruction at that address runs -- but
    // not on the very first one, or resuming from a stop would report the
    // breakpoint we are already sitting on, forever.
    bool first = true;
    for (;;) {
      if (poll_hook && (executed % kPollInterval) == 0) poll_hook();
      if (interrupt.exchange(false)) return Event::Interrupted;
      if (!single && !first && breakpoints.contains(cpu.hart.pc)) {
        return Event::Breakpoint;
      }
      first = false;

      if (opts.trace) trace_one();

      const Stop s = cpu.step();
      ++executed;

      switch (s) {
        case Stop::None:
          break;
        case Stop::Ecall:
          kernel.handle();
          if (kernel.exited) return Event::Exited;
          break;
        case Stop::Ebreak:
          return Event::Breakpoint;
        case Stop::Illegal:
          last_error = std::format("illegal instruction {:#010x} at {}", cpu.bad_word,
                                   where(cpu.hart.pc));
          return Event::Illegal;
        case Stop::Fault:
          last_error = std::format("{} fault at {} (pc {})",
                                   access_name(cpu.fault_access), hex(cpu.fault_addr),
                                   where(cpu.hart.pc));
          return Event::Fault;
        case Stop::Exited:
          return Event::Exited;
      }

      if (single) return Event::Stepped;
      if (opts.max_insns && executed >= opts.max_insns) return Event::Limit;
    }
  }

  // Run to completion. Returns the process exit status.
  int run() {
    for (;;) {
      const Event e = resume(false);
      switch (e) {
        case Event::Exited: return kernel.exit_code;
        case Event::Limit:
          std::print(stderr, "rvemu: stopped after {} instructions\n", executed);
          return 1;
        case Event::Breakpoint:
          std::print(stderr, "rvemu: ebreak at {}\n", where(cpu.hart.pc));
          dump_registers(stderr);
          return 133;  // 128 + SIGTRAP
        case Event::Illegal:
        case Event::Fault:
          std::print(stderr, "rvemu: {}\n", last_error);
          dump_registers(stderr);
          return 139;  // 128 + SIGSEGV
        case Event::Interrupted:
          std::print(stderr, "rvemu: interrupted\n");
          return 130;
        case Event::Stepped:
          break;
      }
    }
  }

  // "0x104a2 <main+0x12>", or just the address when nothing is known.
  std::string where(u64 addr) const {
    const std::string sym = image.describe(addr);
    return sym.empty() ? hex(addr) : std::format("{} <{}>", hex(addr), sym);
  }

  void dump_registers(std::FILE* out) {
    std::print(out, "pc  {}\n", where(cpu.hart.pc));
    for (unsigned i = 0; i < kRegCount; i += 4) {
      std::string line;
      for (unsigned j = i; j < i + 4; ++j) {
        line += std::format("{:>4} {:016x}  ", kXRegNames[j], cpu.hart.x[j]);
      }
      std::print(out, "{}\n", line);
    }
  }

  // One line of `--trace`, before the instruction runs.
  void trace_one() {
    Inst in;
    if (!cpu.fetch(cpu.hart.pc, in)) {
      std::print(stderr, "{:>12}: <unreadable>\n", hex(cpu.hart.pc));
      return;
    }
    std::print(stderr, "{:>12}  {:<24} {}\n", hex(cpu.hart.pc),
               disasm(in, cpu.hart.pc), image.describe(cpu.hart.pc));
  }
};

}  // namespace rvemu
