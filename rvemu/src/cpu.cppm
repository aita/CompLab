// CPU partition — hart architectural state, and the FPU bridge.
//
// The integer half is unremarkable: 32 registers with x0 hardwired to zero, a
// pc, and the LR/SC reservation. The float half is where the decisions are.
//
// rvemu does *not* vendor a soft-float library. F and D are implemented on the
// host FPU, which on x86-64 is IEEE-754 binary32/binary64 with the same
// arithmetic RISC-V mandates, and the two places where the ISAs disagree are
// patched up explicitly:
//
//   * NaN results.  x86 propagates a quieted input payload; RISC-V requires the
//     canonical NaN (0x7fc00000 / 0x7ff8000000000000) out of every arithmetic
//     operation. `canon` does that on the way out.
//   * NaN inputs to fmin/fmax and the sign-injection ops, which RISC-V defines
//     differently from the host instructions and which are done in integer code
//     here anyway.
//   * fcvt out of range, which is undefined behaviour in C++ and saturating in
//     RISC-V. Every conversion is range-checked before the cast.
//
// Rounding mode and the accrued exception flags ride on the host FPU's control
// and status word: FpGuard sets the mode for one instruction and folds whatever
// the host raised back into fflags. The one gap is RMM (round to nearest, ties
// away from zero), which x86 has no mode for -- conversions implement it by
// hand, arithmetic falls back to RNE. See the README.
module;

// `import std;` brings the functions but not the macros: FE_TONEAREST and
// FP_SUBNORMAL have to come from the headers, in the global module fragment.
#include <cfenv>
#include <cmath>

export module rvemu:cpu;

import std;
import :common;

export namespace rvemu {

inline constexpr unsigned kRegCount = 32;

// ABI names. The disassembler prints these, the assembler accepts them (and the
// x0..x31 forms), and gdb's target description lists them in this order.
inline constexpr std::array<const char*, 32> kXRegNames = {
    "zero", "ra", "sp", "gp", "tp",  "t0",  "t1", "t2", "s0", "s1", "a0",
    "a1",   "a2", "a3", "a4", "a5",  "a6",  "a7", "s2", "s3", "s4", "s5",
    "s6",   "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"};

inline constexpr std::array<const char*, 32> kFRegNames = {
    "ft0", "ft1", "ft2",  "ft3",  "ft4", "ft5", "ft6",  "ft7",
    "fs0", "fs1", "fa0",  "fa1",  "fa2", "fa3", "fa4",  "fa5",
    "fa6", "fa7", "fs2",  "fs3",  "fs4", "fs5", "fs6",  "fs7",
    "fs8", "fs9", "fs10", "fs11", "ft8", "ft9", "ft10", "ft11"};

// fcsr accrued-exception bits.
enum FFlag : u32 {
  FFlagNX = 1,   // inexact
  FFlagUF = 2,   // underflow
  FFlagOF = 4,   // overflow
  FFlagDZ = 8,   // divide by zero
  FFlagNV = 16,  // invalid operation
};

// The rounding-mode field, in `rm` of an instruction and in fcsr[7:5].
enum RoundMode : u8 {
  RmRNE = 0,  // to nearest, ties to even
  RmRTZ = 1,  // toward zero
  RmRDN = 2,  // down (toward -inf)
  RmRUP = 3,  // up (toward +inf)
  RmRMM = 4,  // to nearest, ties away from zero (no host equivalent)
  RmDYN = 7,  // take the mode from fcsr
};

// CSR addresses rvemu answers to. A user-mode emulator needs the float CSRs
// (glibc's fenv touches them) and the counters; everything else traps.
enum Csr : u32 {
  CsrFflags = 0x001,
  CsrFrm = 0x002,
  CsrFcsr = 0x003,
  CsrCycle = 0xc00,
  CsrTime = 0xc01,
  CsrInstret = 0xc02,
};

inline constexpr u32 kCanonicalNanF32 = 0x7fc00000u;
inline constexpr u64 kCanonicalNanF64 = 0x7ff8000000000000ull;
inline constexpr u64 kNanBoxMask = 0xffffffff00000000ull;

struct Hart {
  std::array<u64, kRegCount> x{};
  std::array<u64, kRegCount> f{};  // raw bits; binary32 values are NaN-boxed
  u64 pc = 0;
  u32 fcsr = 0;
  u64 instret = 0;

  // The LR/SC reservation. One hart means the only thing that can break a
  // reservation is another LR, an SC, or a trap -- there is no other agent.
  bool resv_valid = false;
  u64 resv_addr = 0;

  u64 getx(unsigned r) const { return r ? x[r] : 0; }
  void setx(unsigned r, u64 v) {
    if (r) x[r] = v;
  }

  u8 frm() const { return static_cast<u8>((fcsr >> 5) & 7); }
  u32 fflags() const { return fcsr & 0x1f; }
  void raise(u32 flags) { fcsr |= flags & 0x1f; }

  // Resolve an instruction's rm field against fcsr. Returns 8 for a reserved
  // encoding, which the executor turns into an illegal-instruction trap.
  u8 effective_rm(u8 rm) const {
    if (rm == RmDYN) rm = frm();
    return (rm <= RmRMM) ? rm : u8{8};
  }
};

// -- float representation ----------------------------------------------------

// A binary32 in an f register must have all-ones in the upper half; anything
// else is "not a valid single" and reads back as the canonical NaN.
inline float unbox_f32(u64 bits) {
  const u32 w = ((bits & kNanBoxMask) == kNanBoxMask) ? static_cast<u32>(bits)
                                                     : kCanonicalNanF32;
  return std::bit_cast<float>(w);
}
inline u64 box_f32(float v) { return kNanBoxMask | std::bit_cast<u32>(v); }
inline u64 box_f32_bits(u32 bits) { return kNanBoxMask | u64{bits}; }
inline double as_f64(u64 bits) { return std::bit_cast<double>(bits); }
inline u64 from_f64(double v) { return std::bit_cast<u64>(v); }

// Every arithmetic result goes through this: RISC-V never propagates an input
// NaN payload, it produces the canonical quiet NaN.
inline float canon(float v) {
  return std::isnan(v) ? std::bit_cast<float>(kCanonicalNanF32) : v;
}
inline double canon(double v) {
  return std::isnan(v) ? std::bit_cast<double>(kCanonicalNanF64) : v;
}

inline bool is_snan(float v) {
  const u32 b = std::bit_cast<u32>(v);
  return (b & 0x7f800000u) == 0x7f800000u && (b & 0x007fffffu) != 0 &&
         (b & 0x00400000u) == 0;
}
inline bool is_snan(double v) {
  const u64 b = std::bit_cast<u64>(v);
  return (b & 0x7ff0000000000000ull) == 0x7ff0000000000000ull &&
         (b & 0x000fffffffffffffull) != 0 && (b & 0x0008000000000000ull) == 0;
}

// fclass.s / fclass.d: a one-hot classification of the operand.
template <class F>
u64 fclass_bits(F v) {
  using Bits = std::conditional_t<sizeof(F) == 4, u32, u64>;
  const Bits b = std::bit_cast<Bits>(v);
  const bool neg = (b >> (sizeof(F) * 8 - 1)) != 0;
  if (std::isinf(v)) return neg ? 1u << 0 : 1u << 7;
  if (std::isnan(v)) return is_snan(v) ? (1u << 8) : (1u << 9);
  if (v == F{0}) return neg ? 1u << 3 : 1u << 4;
  if (std::fpclassify(v) == FP_SUBNORMAL) return neg ? 1u << 2 : 1u << 5;
  return neg ? 1u << 1 : 1u << 6;
}

// -- host FPU control --------------------------------------------------------

// Set the host rounding mode for the duration of one guest instruction, and on
// the way out fold the exceptions the host raised into fcsr.
class FpGuard {
 public:
  FpGuard(Hart& h, u8 rm) : hart_(h), saved_(std::fegetround()) {
    std::feclearexcept(FE_ALL_EXCEPT);
    std::fesetround(host_round(rm));
  }
  ~FpGuard() {
    const int raised = std::fetestexcept(FE_ALL_EXCEPT);
    u32 flags = 0;
    if (raised & FE_INEXACT) flags |= FFlagNX;
    if (raised & FE_UNDERFLOW) flags |= FFlagUF;
    if (raised & FE_OVERFLOW) flags |= FFlagOF;
    if (raised & FE_DIVBYZERO) flags |= FFlagDZ;
    if (raised & FE_INVALID) flags |= FFlagNV;
    hart_.raise(flags);
    std::fesetround(saved_);
    std::feclearexcept(FE_ALL_EXCEPT);
  }

  FpGuard(const FpGuard&) = delete;
  FpGuard& operator=(const FpGuard&) = delete;

  // RMM has no x86 mode. Arithmetic in that mode rounds to nearest-even
  // instead; conversions do not use this path at all (see round_rmm below).
  static int host_round(u8 rm) {
    switch (rm) {
      case RmRTZ: return FE_TOWARDZERO;
      case RmRDN: return FE_DOWNWARD;
      case RmRUP: return FE_UPWARD;
      default: return FE_TONEAREST;
    }
  }

 private:
  Hart& hart_;
  int saved_;
};

// Round a float to an integral value in the given RISC-V mode. Conversions go
// through here rather than through the host mode, so RMM is exact.
template <class F>
F round_to_integral(F v, u8 rm) {
  switch (rm) {
    case RmRTZ: return std::trunc(v);
    case RmRDN: return std::floor(v);
    case RmRUP: return std::ceil(v);
    case RmRMM: return std::round(v);  // ties away from zero, by definition
    default: return std::nearbyint(v);  // RNE, with the host set to to-nearest
  }
}

}  // namespace rvemu
