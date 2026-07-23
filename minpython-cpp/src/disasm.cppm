// Disasm partition — a debug aid for looking at what the JITs actually emit.
//
// Generated code is otherwise invisible: when it goes wrong you get a segfault
// inside an anonymous mapping and a backtrace that is useless (worse still once
// rbp holds a value rather than a frame pointer). This writes the bytes out and
// runs objdump over them.
//
// Off unless MINPYTHON_JIT_DUMP is set, so it costs nothing in normal runs.
module;
#include <cstdio>

export module minpython:disasm;

import std;

export namespace minpython {

inline bool jit_dump_enabled() {
  static const bool on = [] {
    const char* e = std::getenv("MINPYTHON_JIT_DUMP");
    return e && *e && *e != '0';
  }();
  return on;
}

// `notes` is free-form: the register assignment, entry offsets, whatever helps
// correlate the disassembly with the compiler's decisions.
inline void jit_dump(const std::string& what, const void* code,
                     std::size_t size, const std::string& notes = "") {
  if (!jit_dump_enabled()) return;
  const std::string path = "/tmp/minpython-jit.bin";
  {
    std::ofstream f(path, std::ios::binary);
    f.write(static_cast<const char*>(code), static_cast<std::streamsize>(size));
  }
  std::println(stderr, "===== jit: {} ({} bytes) =====", what, size);
  if (!notes.empty()) std::println(stderr, "  {}", notes);
  std::string cmd = "objdump -D -b binary -m i386:x86-64 -M intel --no-show-raw-insn " +
                    path + " | tail -n +7 1>&2";
  int rc = std::system(cmd.c_str());
  if (rc != 0) std::println(stderr, "  (objdump unavailable)");
}

}  // namespace minpython
