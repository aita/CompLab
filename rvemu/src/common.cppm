// Common partition — the vocabulary every other partition speaks.
//
// Nothing here knows about RISC-V; it is the integer aliases, the latched error
// channel, and the small formatting helpers that the rest of the emulator uses
// in place of exceptions and printf.
export module rvemu:common;

import std;

export namespace rvemu {

using u8 = std::uint8_t;
using u16 = std::uint16_t;
using u32 = std::uint32_t;
using u64 = std::uint64_t;
using i8 = std::int8_t;
using i16 = std::int16_t;
using i32 = std::int32_t;
using i64 = std::int64_t;

// A latched error, used instead of exceptions (this project builds with
// -fno-exceptions, matching the sibling minpython-cpp). The first failure wins
// and later passes bail early on it, so a caller can run a whole pipeline and
// check once at the end.
struct Diag {
  bool failed = false;
  std::string message;

  void fail(std::string m) {
    if (!failed) {
      failed = true;
      message = std::move(m);
    }
  }
  // Convenience for the assembler, which wants a line number on everything.
  void fail_at(unsigned line, std::string m) {
    fail(std::format("{}: {}", line, std::move(m)));
  }
  void clear() {
    failed = false;
    message.clear();
  }
  explicit operator bool() const { return !failed; }
};

// Sign-extend the low `bits` of `v`. `bits` must be in 1..64.
constexpr i64 sext(u64 v, unsigned bits) {
  const unsigned shift = 64 - bits;
  return static_cast<i64>(v << shift) >> shift;
}

// Round `v` up to the next multiple of `align` (a power of two).
constexpr u64 align_up(u64 v, u64 align) { return (v + align - 1) & ~(align - 1); }
constexpr u64 align_down(u64 v, u64 align) { return v & ~(align - 1); }

// 0x-prefixed hex, the way addresses are printed everywhere in this codebase.
inline std::string hex(u64 v) { return std::format("{:#x}", v); }

}  // namespace rvemu
