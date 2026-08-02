// Common partition — the vocabulary every other partition speaks.
//
// Nothing here knows what an instruction is; it is the integer aliases, the two
// latched error channels (Diag for anything found before the module runs, Trap
// for anything found while it runs), the untyped 64-bit value, and the LEB128
// reader that the binary format is made of.
export module weasel:common;

import std;

export namespace weasel {

using u8 = std::uint8_t;
using u16 = std::uint16_t;
using u32 = std::uint32_t;
using u64 = std::uint64_t;
using i8 = std::int8_t;
using i16 = std::int16_t;
using i32 = std::int32_t;
using i64 = std::int64_t;
using f32 = float;
using f64 = double;

// A latched error, used instead of exceptions (this project builds with
// -fno-exceptions, matching the sibling rvemu). The first failure wins and later
// passes bail early on it, so a caller can run decode -> validate -> instantiate
// and check once at the end.
struct Diag {
  bool failed = false;
  std::string message;

  void fail(std::string m) {
    if (!failed) {
      failed = true;
      message = std::move(m);
    }
  }
  // The text parser wants a line and column on everything.
  void fail_at(unsigned line, unsigned col, std::string m) {
    fail(std::format("{}:{}: {}", line, col, std::move(m)));
  }
  void clear() {
    failed = false;
    message.clear();
  }
  explicit operator bool() const { return !failed; }
};

// The ways a well-formed, validated module can still stop. `Trap::None` is the
// only value that means the machine is still running; everything else is
// terminal for the current call into the machine.
enum class Trap : u8 {
  None = 0,
  Unreachable,
  OutOfBoundsMemory,
  OutOfBoundsTable,
  OutOfBoundsData,
  IndirectCallTypeMismatch,
  UninitializedElement,
  DivideByZero,
  IntegerOverflow,
  InvalidConversion,
  NullReference,
  StackExhausted,
  HostError,
  Exit,  // proc_exit: not a failure, but it does end the call
};

inline std::string_view trap_name(Trap t) {
  switch (t) {
    case Trap::None: return "no trap";
    case Trap::Unreachable: return "unreachable";
    case Trap::OutOfBoundsMemory: return "out of bounds memory access";
    case Trap::OutOfBoundsTable: return "out of bounds table access";
    case Trap::OutOfBoundsData: return "out of bounds data segment access";
    case Trap::IndirectCallTypeMismatch: return "indirect call type mismatch";
    case Trap::UninitializedElement: return "uninitialized element";
    case Trap::DivideByZero: return "integer divide by zero";
    case Trap::IntegerOverflow: return "integer overflow";
    case Trap::InvalidConversion: return "invalid conversion to integer";
    case Trap::NullReference: return "null reference";
    case Trap::StackExhausted: return "call stack exhausted";
    case Trap::HostError: return "host error";
    case Trap::Exit: return "exit";
  }
  return "?";
}

// A wasm value is 64 bits and nothing else. There is no tag: validation already
// decided what every instruction will find on the stack, so the type is a fact
// about the program text rather than about the datum. `Value` therefore stores
// the bit pattern and offers the four readings of it.
//
// A reference is stored as `addr + 1`, so that a null reference is all-zero and
// a zeroed table or local is a table of nulls.
struct Value {
  u64 bits = 0;

  static Value of_i32(u32 v) { return Value{v}; }
  static Value of_i64(u64 v) { return Value{v}; }
  static Value of_f32(f32 v) { return Value{std::bit_cast<u32>(v)}; }
  static Value of_f64(f64 v) { return Value{std::bit_cast<u64>(v)}; }
  static Value null_ref() { return Value{0}; }
  static Value of_ref(u32 addr) { return Value{u64{addr} + 1}; }

  u32 i32() const { return static_cast<u32>(bits); }
  u64 i64() const { return bits; }
  f32 f32v() const { return std::bit_cast<f32>(static_cast<u32>(bits)); }
  f64 f64v() const { return std::bit_cast<f64>(bits); }
  bool is_null() const { return bits == 0; }
  u32 ref_addr() const { return static_cast<u32>(bits - 1); }

  bool operator==(const Value&) const = default;
};

// Sign-extend the low `bits` of `v`. `bits` must be in 1..64.
constexpr i64 sext(u64 v, unsigned bits) {
  const unsigned shift = 64 - bits;
  return static_cast<i64>(v << shift) >> shift;
}

// A cursor over the bytes of a module, with the LEB128 readers the binary format
// is written in. Every reader checks the bound and latches into `d`, so the
// decoder can read a whole section and test once.
struct Reader {
  std::span<const u8> bytes;
  std::size_t pos = 0;
  Diag* d = nullptr;

  bool eof() const { return pos >= bytes.size(); }
  std::size_t left() const { return bytes.size() - pos; }

  void fail(std::string m) {
    if (d) d->fail(std::format("offset {:#x}: {}", pos, std::move(m)));
  }
  bool ok() const { return !d || !d->failed; }

  u8 byte() {
    if (!ok()) return 0;
    if (eof()) {
      fail("unexpected end of section");
      return 0;
    }
    return bytes[pos++];
  }
  u8 peek() const { return (pos < bytes.size()) ? bytes[pos] : 0; }

  std::span<const u8> take(std::size_t n) {
    if (!ok()) return {};
    if (n > left()) {
      fail("unexpected end of section");
      return {};
    }
    auto s = bytes.subspan(pos, n);
    pos += n;
    return s;
  }

  // Unsigned LEB128, at most `max_bits` wide. The spec bounds the encoding
  // length as well as the value, so a padded-to-ten-bytes u32 is malformed even
  // when the value fits.
  u64 uleb(unsigned max_bits) {
    u64 result = 0;
    unsigned shift = 0;
    for (;;) {
      if (!ok()) return 0;
      const u8 b = byte();
      if (!ok()) return 0;
      const u64 low = b & 0x7fu;
      if (shift >= max_bits || (shift + 7 > max_bits && (low >> (max_bits - shift)) != 0)) {
        fail("integer too large");
        return 0;
      }
      result |= low << shift;
      if ((b & 0x80u) == 0) break;
      shift += 7;
    }
    return result;
  }

  // Signed LEB128, at most `max_bits` wide.
  i64 sleb(unsigned max_bits) {
    i64 result = 0;
    unsigned shift = 0;
    u8 b = 0;
    for (;;) {
      if (!ok()) return 0;
      b = byte();
      if (!ok()) return 0;
      if (shift >= max_bits) {
        fail("integer too large");
        return 0;
      }
      result |= static_cast<i64>(u64{b & 0x7fu} << shift);
      shift += 7;
      if ((b & 0x80u) == 0) break;
    }
    if (shift < 64 && (b & 0x40u) != 0) result |= -(i64{1} << shift);
    // The final byte's unused bits must be a sign extension of the value.
    if (shift > max_bits) {
      const unsigned used = 7 - (shift - max_bits);
      const u8 tail = b & 0x7fu;
      const u8 expect = (result < 0) ? static_cast<u8>((0x7fu << used) & 0x7fu) : 0;
      if ((tail & ~((1u << used) - 1u)) != expect) {
        fail("integer too large");
        return 0;
      }
    }
    return result;
  }

  u32 u32leb() { return static_cast<u32>(uleb(32)); }
  i32 i32leb() { return static_cast<i32>(sleb(32)); }
  i64 i64leb() { return sleb(64); }

  u32 f32bits() {
    auto s = take(4);
    if (!ok()) return 0;
    return u32{s[0]} | (u32{s[1]} << 8) | (u32{s[2]} << 16) | (u32{s[3]} << 24);
  }
  u64 f64bits() {
    auto s = take(8);
    if (!ok()) return 0;
    u64 v = 0;
    for (int i = 7; i >= 0; --i) v = (v << 8) | s[static_cast<std::size_t>(i)];
    return v;
  }

  std::string name() {
    const u32 n = u32leb();
    auto s = take(n);
    if (!ok()) return {};
    return std::string(reinterpret_cast<const char*>(s.data()), s.size());
  }
};

}  // namespace weasel
