// Exec partition — the interpreter: one decoded instruction at a time.
//
// `Cpu` is hart state plus an address space plus a stop reason. It knows how to
// fetch, decode and retire exactly one instruction, and nothing at all about
// syscalls, ELF files or debuggers -- when it reaches an `ecall` it stops and
// says so, and the Machine above it decides what that means. Keeping the trap
// boundary here rather than inside the switch is what lets the gdb stub single
// step a guest that is halfway through a write().
//
// On a fault the pc is deliberately left pointing at the faulting instruction,
// which is what a debugger wants to show and what a re-execute after mapping the
// page would need. `ecall` is the exception: the pc is advanced past it first,
// so the syscall handler only has to write a0.
export module rvemu:exec;

import std;
import :common;
import :memory;
import :cpu;
import :decode;

export namespace rvemu {

// Why the interpreter handed control back.
enum class Stop : u8 {
  None,      // stepped normally
  Ecall,     // environment call; pc already past it
  Ebreak,    // breakpoint; pc still on it
  Illegal,   // undecodable or reserved encoding
  Fault,     // memory access violation
  Exited,    // the guest called exit(); Machine sets this, not step()
};

inline const char* stop_name(Stop s) {
  switch (s) {
    case Stop::None: return "none";
    case Stop::Ecall: return "ecall";
    case Stop::Ebreak: return "breakpoint";
    case Stop::Illegal: return "illegal instruction";
    case Stop::Fault: return "memory fault";
    case Stop::Exited: return "exited";
  }
  return "?";
}

class Cpu {
 public:
  Hart hart;
  Memory mem;

  // Set alongside a Fault / Illegal stop.
  u64 fault_addr = 0;
  Access fault_access = Access::Load;
  u32 bad_word = 0;

  // Wall-clock origin for the `time` CSR. Machine seeds it at startup.
  u64 time_base = 0;

  // Read the instruction at `pc` without executing it. The disassembler and the
  // gdb stub both need this; so does step().
  bool fetch(u64 pc, Inst& out) {
    u16 lo = 0;
    if (!mem.load<u16>(pc, lo, Access::Fetch)) return false;
    if (is_compressed(lo)) {
      out = decode_at(lo, 0);
      return true;
    }
    u16 hi = 0;
    if (!mem.load<u16>(pc + 2, hi, Access::Fetch)) return false;
    out = decode(static_cast<u32>(lo) | (static_cast<u32>(hi) << 16));
    return true;
  }

  // Execute one instruction. Returns the reason control came back.
  Stop step() {
    Inst in;
    if (!fetch(hart.pc, in)) return fault(Access::Fetch);
    if (in.op == Op::Illegal) {
      bad_word = in.raw;
      return Stop::Illegal;
    }

    const u64 pc = hart.pc;
    u64 next = pc + in.len;
    const Stop s = run(in, pc, next);
    if (s == Stop::None || s == Stop::Ecall) {
      hart.pc = next;
      ++hart.instret;
    }
    return s;
  }

 private:
  Stop fault(Access how) {
    fault_addr = mem.fault_addr;
    fault_access = how;
    return Stop::Fault;
  }

  // Shorthands. `next` is the fall-through pc, which branches overwrite.
  Stop run(const Inst& in, u64 pc, u64& next) {
    auto& h = hart;
    const u64 a = h.getx(in.rs1);
    const u64 b = h.getx(in.rs2);
    const u64 imm = static_cast<u64>(in.imm);

    switch (in.op) {
      // -- RV64I ------------------------------------------------------------
      case Op::Lui: h.setx(in.rd, imm); return Stop::None;
      case Op::Auipc: h.setx(in.rd, pc + imm); return Stop::None;
      case Op::Jal:
        h.setx(in.rd, next);
        next = pc + imm;
        return Stop::None;
      case Op::Jalr: {
        const u64 target = (a + imm) & ~u64{1};
        h.setx(in.rd, next);
        next = target;
        return Stop::None;
      }

      case Op::Beq: if (a == b) next = pc + imm; return Stop::None;
      case Op::Bne: if (a != b) next = pc + imm; return Stop::None;
      case Op::Blt: if (i64(a) < i64(b)) next = pc + imm; return Stop::None;
      case Op::Bge: if (i64(a) >= i64(b)) next = pc + imm; return Stop::None;
      case Op::Bltu: if (a < b) next = pc + imm; return Stop::None;
      case Op::Bgeu: if (a >= b) next = pc + imm; return Stop::None;

      case Op::Lb: return load_into<i8>(in, a + imm);
      case Op::Lh: return load_into<i16>(in, a + imm);
      case Op::Lw: return load_into<i32>(in, a + imm);
      case Op::Ld: return load_into<i64>(in, a + imm);
      case Op::Lbu: return load_into<u8>(in, a + imm);
      case Op::Lhu: return load_into<u16>(in, a + imm);
      case Op::Lwu: return load_into<u32>(in, a + imm);

      case Op::Sb: return store_from<u8>(a + imm, static_cast<u8>(b));
      case Op::Sh: return store_from<u16>(a + imm, static_cast<u16>(b));
      case Op::Sw: return store_from<u32>(a + imm, static_cast<u32>(b));
      case Op::Sd: return store_from<u64>(a + imm, b);

      case Op::Addi: h.setx(in.rd, a + imm); return Stop::None;
      case Op::Slti: h.setx(in.rd, i64(a) < in.imm); return Stop::None;
      case Op::Sltiu: h.setx(in.rd, a < imm); return Stop::None;
      case Op::Xori: h.setx(in.rd, a ^ imm); return Stop::None;
      case Op::Ori: h.setx(in.rd, a | imm); return Stop::None;
      case Op::Andi: h.setx(in.rd, a & imm); return Stop::None;
      case Op::Slli: h.setx(in.rd, a << (imm & 63)); return Stop::None;
      case Op::Srli: h.setx(in.rd, a >> (imm & 63)); return Stop::None;
      case Op::Srai: h.setx(in.rd, u64(i64(a) >> (imm & 63))); return Stop::None;

      case Op::Add: h.setx(in.rd, a + b); return Stop::None;
      case Op::Sub: h.setx(in.rd, a - b); return Stop::None;
      case Op::Sll: h.setx(in.rd, a << (b & 63)); return Stop::None;
      case Op::Slt: h.setx(in.rd, i64(a) < i64(b)); return Stop::None;
      case Op::Sltu: h.setx(in.rd, a < b); return Stop::None;
      case Op::Xor: h.setx(in.rd, a ^ b); return Stop::None;
      case Op::Srl: h.setx(in.rd, a >> (b & 63)); return Stop::None;
      case Op::Sra: h.setx(in.rd, u64(i64(a) >> (b & 63))); return Stop::None;
      case Op::Or: h.setx(in.rd, a | b); return Stop::None;
      case Op::And: h.setx(in.rd, a & b); return Stop::None;

      case Op::Addiw: h.setx(in.rd, sext32(u32(a) + u32(imm))); return Stop::None;
      case Op::Slliw: h.setx(in.rd, sext32(u32(a) << (imm & 31))); return Stop::None;
      case Op::Srliw: h.setx(in.rd, sext32(u32(a) >> (imm & 31))); return Stop::None;
      case Op::Sraiw:
        h.setx(in.rd, sext32(u32(i32(u32(a)) >> (imm & 31))));
        return Stop::None;
      case Op::Addw: h.setx(in.rd, sext32(u32(a) + u32(b))); return Stop::None;
      case Op::Subw: h.setx(in.rd, sext32(u32(a) - u32(b))); return Stop::None;
      case Op::Sllw: h.setx(in.rd, sext32(u32(a) << (b & 31))); return Stop::None;
      case Op::Srlw: h.setx(in.rd, sext32(u32(a) >> (b & 31))); return Stop::None;
      case Op::Sraw:
        h.setx(in.rd, sext32(u32(i32(u32(a)) >> (b & 31))));
        return Stop::None;

      // A single hart with no device model has nothing to order or invalidate.
      case Op::Fence:
      case Op::FenceI:
        return Stop::None;

      case Op::Ecall: return Stop::Ecall;
      case Op::Ebreak: return Stop::Ebreak;

      // -- Zicsr ------------------------------------------------------------
      case Op::Csrrw:
      case Op::Csrrs:
      case Op::Csrrc:
      case Op::Csrrwi:
      case Op::Csrrsi:
      case Op::Csrrci:
        return csr(in, a);

      // -- M ----------------------------------------------------------------
      case Op::Mul: h.setx(in.rd, a * b); return Stop::None;
      case Op::Mulh:
        h.setx(in.rd, u64((__int128(i64(a)) * __int128(i64(b))) >> 64));
        return Stop::None;
      case Op::Mulhsu:
        h.setx(in.rd,
               u64(u64((__int128(i64(a)) * (unsigned __int128)(b)) >> 64)));
        return Stop::None;
      case Op::Mulhu:
        h.setx(in.rd,
               u64(((unsigned __int128)(a) * (unsigned __int128)(b)) >> 64));
        return Stop::None;

      // Division never traps on RISC-V: the spec pins down every degenerate
      // case, so the guest's own code is responsible for checking.
      case Op::Div:
        if (b == 0) h.setx(in.rd, ~u64{0});
        else if (i64(a) == std::numeric_limits<i64>::min() && i64(b) == -1) h.setx(in.rd, a);
        else h.setx(in.rd, u64(i64(a) / i64(b)));
        return Stop::None;
      case Op::Divu: h.setx(in.rd, b == 0 ? ~u64{0} : a / b); return Stop::None;
      case Op::Rem:
        if (b == 0) h.setx(in.rd, a);
        else if (i64(a) == std::numeric_limits<i64>::min() && i64(b) == -1) h.setx(in.rd, 0);
        else h.setx(in.rd, u64(i64(a) % i64(b)));
        return Stop::None;
      case Op::Remu: h.setx(in.rd, b == 0 ? a : a % b); return Stop::None;

      case Op::Mulw: h.setx(in.rd, sext32(u32(a) * u32(b))); return Stop::None;
      case Op::Divw: {
        const i32 x = i32(u32(a)), y = i32(u32(b));
        if (y == 0) h.setx(in.rd, ~u64{0});
        else if (x == std::numeric_limits<i32>::min() && y == -1) h.setx(in.rd, sext32(u32(x)));
        else h.setx(in.rd, sext32(u32(x / y)));
        return Stop::None;
      }
      case Op::Divuw: {
        const u32 x = u32(a), y = u32(b);
        h.setx(in.rd, y == 0 ? ~u64{0} : sext32(x / y));
        return Stop::None;
      }
      case Op::Remw: {
        const i32 x = i32(u32(a)), y = i32(u32(b));
        if (y == 0) h.setx(in.rd, sext32(u32(x)));
        else if (x == std::numeric_limits<i32>::min() && y == -1) h.setx(in.rd, 0);
        else h.setx(in.rd, sext32(u32(x % y)));
        return Stop::None;
      }
      case Op::Remuw: {
        const u32 x = u32(a), y = u32(b);
        h.setx(in.rd, y == 0 ? sext32(x) : sext32(x % y));
        return Stop::None;
      }

      // -- A ----------------------------------------------------------------
      case Op::LrW: return lr<i32>(in, a);
      case Op::LrD: return lr<i64>(in, a);
      case Op::ScW: return sc<u32>(in, a, u32(b));
      case Op::ScD: return sc<u64>(in, a, b);

      case Op::AmoswapW: return amo<i32>(in, a, [&](i32) { return i32(u32(b)); });
      case Op::AmoaddW: return amo<i32>(in, a, [&](i32 o) { return i32(u32(o) + u32(b)); });
      case Op::AmoxorW: return amo<i32>(in, a, [&](i32 o) { return i32(u32(o) ^ u32(b)); });
      case Op::AmoandW: return amo<i32>(in, a, [&](i32 o) { return i32(u32(o) & u32(b)); });
      case Op::AmoorW: return amo<i32>(in, a, [&](i32 o) { return i32(u32(o) | u32(b)); });
      case Op::AmominW: return amo<i32>(in, a, [&](i32 o) { return std::min(o, i32(u32(b))); });
      case Op::AmomaxW: return amo<i32>(in, a, [&](i32 o) { return std::max(o, i32(u32(b))); });
      case Op::AmominuW:
        return amo<i32>(in, a, [&](i32 o) { return i32(std::min(u32(o), u32(b))); });
      case Op::AmomaxuW:
        return amo<i32>(in, a, [&](i32 o) { return i32(std::max(u32(o), u32(b))); });

      case Op::AmoswapD: return amo<i64>(in, a, [&](i64) { return i64(b); });
      case Op::AmoaddD: return amo<i64>(in, a, [&](i64 o) { return i64(u64(o) + b); });
      case Op::AmoxorD: return amo<i64>(in, a, [&](i64 o) { return i64(u64(o) ^ b); });
      case Op::AmoandD: return amo<i64>(in, a, [&](i64 o) { return i64(u64(o) & b); });
      case Op::AmoorD: return amo<i64>(in, a, [&](i64 o) { return i64(u64(o) | b); });
      case Op::AmominD: return amo<i64>(in, a, [&](i64 o) { return std::min(o, i64(b)); });
      case Op::AmomaxD: return amo<i64>(in, a, [&](i64 o) { return std::max(o, i64(b)); });
      case Op::AmominuD:
        return amo<i64>(in, a, [&](i64 o) { return i64(std::min(u64(o), b)); });
      case Op::AmomaxuD:
        return amo<i64>(in, a, [&](i64 o) { return i64(std::max(u64(o), b)); });

      // -- F and D ----------------------------------------------------------
      default: return fp(in, a);
    }
  }

  static constexpr u64 sext32(u32 v) { return u64(i64(i32(v))); }

  template <class T>
  Stop load_into(const Inst& in, u64 addr) {
    T v{};
    if (!mem.load<T>(addr, v)) return fault(Access::Load);
    if constexpr (std::is_signed_v<T>) hart.setx(in.rd, u64(i64(v)));
    else hart.setx(in.rd, u64(v));
    return Stop::None;
  }

  template <class T>
  Stop store_from(u64 addr, T v) {
    if (!mem.store<T>(addr, v)) return fault(Access::Store);
    return Stop::None;
  }

  template <class T>
  Stop lr(const Inst& in, u64 addr) {
    T v{};
    if (!mem.load<T>(addr, v)) return fault(Access::Load);
    hart.setx(in.rd, u64(i64(v)));
    hart.resv_valid = true;
    hart.resv_addr = addr;
    return Stop::None;
  }

  template <class T>
  Stop sc(const Inst& in, u64 addr, T v) {
    // One hart: the reservation can only be broken by another LR/SC, so a
    // matching address is enough. Failure writes 1 and leaves memory alone.
    if (!hart.resv_valid || hart.resv_addr != addr) {
      hart.resv_valid = false;
      hart.setx(in.rd, 1);
      return Stop::None;
    }
    if (!mem.store<T>(addr, v)) return fault(Access::Store);
    hart.resv_valid = false;
    hart.setx(in.rd, 0);
    return Stop::None;
  }

  template <class T, class F>
  Stop amo(const Inst& in, u64 addr, F&& f) {
    T old{};
    if (!mem.load<T>(addr, old)) return fault(Access::Load);
    const T updated = f(old);
    if (!mem.store<T>(addr, updated)) return fault(Access::Store);
    hart.setx(in.rd, u64(i64(old)));
    return Stop::None;
  }

  // -- CSRs ------------------------------------------------------------------

  Stop csr(const Inst& in, u64 rs1val) {
    const u32 num = static_cast<u32>(in.imm);
    const bool immediate = (in.op == Op::Csrrwi || in.op == Op::Csrrsi || in.op == Op::Csrrci);
    const u64 src = immediate ? u64(in.rs1) : rs1val;
    // csrrs/csrrc with rs1 == x0 (or a zero immediate) must not write at all --
    // that is how a read-only counter is read.
    const bool writes = (in.op == Op::Csrrw || in.op == Op::Csrrwi) || in.rs1 != 0;

    u64 old = 0;
    if (!csr_read(num, old)) return illegal(in);
    if (writes) {
      u64 v = old;
      switch (in.op) {
        case Op::Csrrw:
        case Op::Csrrwi: v = src; break;
        case Op::Csrrs:
        case Op::Csrrsi: v = old | src; break;
        default: v = old & ~src; break;
      }
      if (!csr_write(num, v)) return illegal(in);
    }
    hart.setx(in.rd, old);
    return Stop::None;
  }

  bool csr_read(u32 num, u64& out) {
    switch (num) {
      case CsrFflags: out = hart.fflags(); return true;
      case CsrFrm: out = hart.frm(); return true;
      case CsrFcsr: out = hart.fcsr & 0xff; return true;
      // No cycle-accurate model here: retired instructions stand in for cycles,
      // which is enough for the guest to see a monotonically rising counter.
      case CsrCycle:
      case CsrInstret: out = hart.instret; return true;
      case CsrTime: out = time_base + hart.instret; return true;
      default: return false;
    }
  }

  bool csr_write(u32 num, u64 v) {
    switch (num) {
      case CsrFflags: hart.fcsr = (hart.fcsr & ~0x1fu) | u32(v & 0x1f); return true;
      case CsrFrm: hart.fcsr = (hart.fcsr & 0x1fu) | (u32(v & 7) << 5); return true;
      case CsrFcsr: hart.fcsr = u32(v & 0xff); return true;
      default: return false;  // the counters are read-only
    }
  }

  Stop illegal(const Inst& in) {
    bad_word = in.raw;
    return Stop::Illegal;
  }

  // -- float -----------------------------------------------------------------

  // Range-checked float -> integer. RISC-V saturates and raises NV where C++
  // would be undefined, and the NaN result differs per signedness.
  template <class I, class F>
  I to_int(F v, u8 rm) {
    constexpr bool sgn = std::is_signed_v<I>;
    constexpr I lo = std::numeric_limits<I>::min();
    constexpr I hi = std::numeric_limits<I>::max();
    if (std::isnan(v)) {
      hart.raise(FFlagNV);
      return hi;
    }
    const F r = round_to_integral(v, rm);
    // The bounds are exact in both binary32 and binary64: 2^31, 2^32, 2^63, 2^64.
    const F hi_bound = std::ldexp(F{1}, sgn ? (sizeof(I) * 8 - 1) : (sizeof(I) * 8));
    const F lo_bound = sgn ? -hi_bound : F{0};
    if (r >= hi_bound) {
      hart.raise(FFlagNV);
      return hi;
    }
    if (r < lo_bound) {
      hart.raise(FFlagNV);
      return lo;
    }
    if (r != v) hart.raise(FFlagNX);
    return static_cast<I>(r);
  }

  // RISC-V min/max: sNaN signals, a lone NaN loses, and -0 sorts below +0.
  template <class F>
  F fminmax(F x, F y, bool want_max) {
    if (is_snan(x) || is_snan(y)) hart.raise(FFlagNV);
    if (std::isnan(x) && std::isnan(y)) return canon(x);
    if (std::isnan(x)) return canon(y);
    if (std::isnan(y)) return canon(x);
    if (x == F{0} && y == F{0}) {
      const bool xneg = std::signbit(x);
      return (want_max ? (xneg ? y : x) : (xneg ? x : y));
    }
    return want_max ? std::max(x, y) : std::min(x, y);
  }

  // feq is quiet: only a signalling NaN raises. flt/fle signal on any NaN.
  template <class F>
  bool fcompare(F x, F y, int kind) {  // 0: eq, 1: lt, 2: le
    const bool unordered = std::isnan(x) || std::isnan(y);
    if (kind == 0 ? (is_snan(x) || is_snan(y)) : unordered) hart.raise(FFlagNV);
    if (unordered) return false;
    return kind == 0 ? (x == y) : kind == 1 ? (x < y) : (x <= y);
  }

  Stop fp(const Inst& in, u64 a) {
    auto& h = hart;
    const u8 rm = h.effective_rm(in.rm);
    // Every arithmetic F/D op honours the rm field; a reserved mode is illegal
    // even before the operands are looked at.
    auto need_rm = [&]() { return rm < 8; };

    const u64 fa = h.f[in.rs1], fb = h.f[in.rs2], fc = h.f[in.rs3];
    const float sa = unbox_f32(fa), sb = unbox_f32(fb), sc_ = unbox_f32(fc);
    const double da = as_f64(fa), db = as_f64(fb), dc = as_f64(fc);

    switch (in.op) {
      case Op::Flw: {
        u32 v = 0;
        if (!mem.load<u32>(a + u64(in.imm), v)) return fault(Access::Load);
        h.f[in.rd] = box_f32_bits(v);
        return Stop::None;
      }
      case Op::Fld: {
        u64 v = 0;
        if (!mem.load<u64>(a + u64(in.imm), v)) return fault(Access::Load);
        h.f[in.rd] = v;
        return Stop::None;
      }
      case Op::Fsw: return store_from<u32>(a + u64(in.imm), u32(fb));
      case Op::Fsd: return store_from<u64>(a + u64(in.imm), fb);

      // Sign injection is defined on bits, not values: no flags, no NaN rules.
      case Op::FsgnjS: h.f[in.rd] = box_f32_bits((u32(fa) & 0x7fffffff) | (u32(fb) & 0x80000000)); return Stop::None;
      case Op::FsgnjnS: h.f[in.rd] = box_f32_bits((u32(fa) & 0x7fffffff) | (~u32(fb) & 0x80000000)); return Stop::None;
      case Op::FsgnjxS: h.f[in.rd] = box_f32_bits(u32(fa) ^ (u32(fb) & 0x80000000)); return Stop::None;
      case Op::FsgnjD: h.f[in.rd] = (fa & ~(u64{1} << 63)) | (fb & (u64{1} << 63)); return Stop::None;
      case Op::FsgnjnD: h.f[in.rd] = (fa & ~(u64{1} << 63)) | (~fb & (u64{1} << 63)); return Stop::None;
      case Op::FsgnjxD: h.f[in.rd] = fa ^ (fb & (u64{1} << 63)); return Stop::None;

      case Op::FmvXW: h.setx(in.rd, sext32(u32(fa))); return Stop::None;
      case Op::FmvXD: h.setx(in.rd, fa); return Stop::None;
      case Op::FmvWX: h.f[in.rd] = box_f32_bits(u32(a)); return Stop::None;
      case Op::FmvDX: h.f[in.rd] = a; return Stop::None;

      case Op::FclassS: h.setx(in.rd, fclass_bits(sa)); return Stop::None;
      case Op::FclassD: h.setx(in.rd, fclass_bits(da)); return Stop::None;

      case Op::FeqS: h.setx(in.rd, fcompare(sa, sb, 0)); return Stop::None;
      case Op::FltS: h.setx(in.rd, fcompare(sa, sb, 1)); return Stop::None;
      case Op::FleS: h.setx(in.rd, fcompare(sa, sb, 2)); return Stop::None;
      case Op::FeqD: h.setx(in.rd, fcompare(da, db, 0)); return Stop::None;
      case Op::FltD: h.setx(in.rd, fcompare(da, db, 1)); return Stop::None;
      case Op::FleD: h.setx(in.rd, fcompare(da, db, 2)); return Stop::None;

      case Op::FminS: h.f[in.rd] = box_f32(fminmax(sa, sb, false)); return Stop::None;
      case Op::FmaxS: h.f[in.rd] = box_f32(fminmax(sa, sb, true)); return Stop::None;
      case Op::FminD: h.f[in.rd] = from_f64(fminmax(da, db, false)); return Stop::None;
      case Op::FmaxD: h.f[in.rd] = from_f64(fminmax(da, db, true)); return Stop::None;

      default: break;
    }

    if (!need_rm()) return illegal(in);
    FpGuard guard(h, rm);

    switch (in.op) {
      case Op::FaddS: h.f[in.rd] = box_f32(canon(sa + sb)); return Stop::None;
      case Op::FsubS: h.f[in.rd] = box_f32(canon(sa - sb)); return Stop::None;
      case Op::FmulS: h.f[in.rd] = box_f32(canon(sa * sb)); return Stop::None;
      case Op::FdivS: h.f[in.rd] = box_f32(canon(sa / sb)); return Stop::None;
      case Op::FsqrtS: h.f[in.rd] = box_f32(canon(std::sqrt(sa))); return Stop::None;
      case Op::FaddD: h.f[in.rd] = from_f64(canon(da + db)); return Stop::None;
      case Op::FsubD: h.f[in.rd] = from_f64(canon(da - db)); return Stop::None;
      case Op::FmulD: h.f[in.rd] = from_f64(canon(da * db)); return Stop::None;
      case Op::FdivD: h.f[in.rd] = from_f64(canon(da / db)); return Stop::None;
      case Op::FsqrtD: h.f[in.rd] = from_f64(canon(std::sqrt(da))); return Stop::None;

      // The four fused forms differ only in which operands are negated.
      case Op::FmaddS: h.f[in.rd] = box_f32(canon(std::fma(sa, sb, sc_))); return Stop::None;
      case Op::FmsubS: h.f[in.rd] = box_f32(canon(std::fma(sa, sb, -sc_))); return Stop::None;
      case Op::FnmsubS: h.f[in.rd] = box_f32(canon(std::fma(-sa, sb, sc_))); return Stop::None;
      case Op::FnmaddS: h.f[in.rd] = box_f32(canon(std::fma(-sa, sb, -sc_))); return Stop::None;
      case Op::FmaddD: h.f[in.rd] = from_f64(canon(std::fma(da, db, dc))); return Stop::None;
      case Op::FmsubD: h.f[in.rd] = from_f64(canon(std::fma(da, db, -dc))); return Stop::None;
      case Op::FnmsubD: h.f[in.rd] = from_f64(canon(std::fma(-da, db, dc))); return Stop::None;
      case Op::FnmaddD: h.f[in.rd] = from_f64(canon(std::fma(-da, db, -dc))); return Stop::None;

      case Op::FcvtSD:
        if (is_snan(da)) h.raise(FFlagNV);
        h.f[in.rd] = box_f32(canon(static_cast<float>(da)));
        return Stop::None;
      case Op::FcvtDS:
        if (is_snan(sa)) h.raise(FFlagNV);
        h.f[in.rd] = from_f64(canon(static_cast<double>(sa)));
        return Stop::None;

      case Op::FcvtWS: h.setx(in.rd, sext32(u32(to_int<i32>(sa, rm)))); return Stop::None;
      case Op::FcvtWuS: h.setx(in.rd, sext32(to_int<u32>(sa, rm))); return Stop::None;
      case Op::FcvtLS: h.setx(in.rd, u64(to_int<i64>(sa, rm))); return Stop::None;
      case Op::FcvtLuS: h.setx(in.rd, to_int<u64>(sa, rm)); return Stop::None;
      case Op::FcvtWD: h.setx(in.rd, sext32(u32(to_int<i32>(da, rm)))); return Stop::None;
      case Op::FcvtWuD: h.setx(in.rd, sext32(to_int<u32>(da, rm))); return Stop::None;
      case Op::FcvtLD: h.setx(in.rd, u64(to_int<i64>(da, rm))); return Stop::None;
      case Op::FcvtLuD: h.setx(in.rd, to_int<u64>(da, rm)); return Stop::None;

      case Op::FcvtSW: h.f[in.rd] = box_f32(float(i32(u32(a)))); return Stop::None;
      case Op::FcvtSWu: h.f[in.rd] = box_f32(float(u32(a))); return Stop::None;
      case Op::FcvtSL: h.f[in.rd] = box_f32(float(i64(a))); return Stop::None;
      case Op::FcvtSLu: h.f[in.rd] = box_f32(float(a)); return Stop::None;
      case Op::FcvtDW: h.f[in.rd] = from_f64(double(i32(u32(a)))); return Stop::None;
      case Op::FcvtDWu: h.f[in.rd] = from_f64(double(u32(a))); return Stop::None;
      case Op::FcvtDL: h.f[in.rd] = from_f64(double(i64(a))); return Stop::None;
      case Op::FcvtDLu: h.f[in.rd] = from_f64(double(a)); return Stop::None;

      default: return illegal(in);
    }
  }
};

}  // namespace rvemu
