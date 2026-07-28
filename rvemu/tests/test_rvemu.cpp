// Unit tests.
//
// The encoder and the decoder are tested against each other, because that is the
// property the whole emulator rests on: the assembler writes what the
// interpreter reads. Everything else -- the C expansion, the float edge cases,
// the memory permissions -- is checked against the values the RISC-V manual pins
// down, and then a handful of small programs are assembled and run to confirm
// the pieces work together.

#include <stdio.h>

import std;
import rvemu;

using namespace rvemu;

namespace {

int checks = 0, failures = 0;
std::string group;

void fail(const char* expr, int line, std::string detail = {}) {
  ++failures;
  std::print(stderr, "FAIL [{}] line {}: {}{}{}\n", group, line, expr,
             detail.empty() ? "" : " -- ", detail);
}

#define CHECK(cond)                     \
  do {                                  \
    ++checks;                           \
    if (!(cond)) fail(#cond, __LINE__); \
  } while (0)

#define CHECK_EQ(a, b)                                                   \
  do {                                                                   \
    ++checks;                                                            \
    const auto lhs_ = (a);                                               \
    const auto rhs_ = (b);                                               \
    if (!(lhs_ == rhs_)) {                                               \
      fail(#a " == " #b, __LINE__, std::format("{} vs {}", lhs_, rhs_)); \
    }                                                                    \
  } while (0)

// -- decode ------------------------------------------------------------------

void test_encode_decode() {
  group = "encode/decode";

  // Every immediate format, at the extremes where sign extension goes wrong.
  {
    const Inst in = decode(enc_i(0x13, 10, 0, 11, -2048));
    CHECK(in.op == Op::Addi);
    CHECK_EQ(in.rd, 10);
    CHECK_EQ(in.rs1, 11);
    CHECK_EQ(in.imm, -2048);
  }
  CHECK_EQ(decode(enc_i(0x13, 1, 0, 2, 2047)).imm, 2047);
  {
    const Inst in = decode(enc_s(0x23, 3, 2, 8, -1));
    CHECK(in.op == Op::Sd);
    CHECK_EQ(in.rs1, 2);
    CHECK_EQ(in.rs2, 8);
    CHECK_EQ(in.imm, -1);
  }
  {
    const Inst in = decode(enc_b(0x63, 1, 5, 6, -4096));
    CHECK(in.op == Op::Bne);
    CHECK_EQ(in.imm, -4096);
  }
  CHECK_EQ(decode(enc_b(0x63, 0, 5, 6, 4094)).imm, 4094);
  {
    const Inst in = decode(enc_u(0x37, 7, static_cast<i32>(0x80000000u)));
    CHECK(in.op == Op::Lui);
    CHECK_EQ(in.imm, i64(i32(0x80000000u)));
  }
  {
    const Inst in = decode(enc_j(0x6f, 1, -1048576));
    CHECK(in.op == Op::Jal);
    CHECK_EQ(in.imm, -1048576);
  }
  CHECK_EQ(decode(enc_j(0x6f, 0, 1048574)).imm, 1048574);

  // Shifts: RV64 takes six bits of shamt, so funct6 -- not funct7 -- is the tag.
  {
    const Inst in = decode(enc_i(0x13, 1, 5, 2, (0x10 << 6) | 63));
    CHECK(in.op == Op::Srai);
    CHECK_EQ(in.imm, 63);
  }
  {
    const Inst in = decode(enc_i(0x1b, 1, 5, 2, (0x20 << 5) | 31));
    CHECK(in.op == Op::Sraiw);
    CHECK_EQ(in.imm, 31);
  }

  // The atomics carry their ordering bits alongside funct5.
  {
    const Inst in = decode(enc_r(0x2f, 5, 3, 6, 7, (0x1c << 2) | 2 | 1));
    CHECK(in.op == Op::AmomaxuD);
    CHECK(in.aq);
    CHECK(in.rl);
  }
  // lr.w with a non-zero rs2 is a reserved encoding.
  CHECK(decode(enc_r(0x2f, 5, 2, 6, 1, 0x02 << 2)).op == Op::Illegal);

  // Float: the four-register form, and the conversions picked out by rs2.
  {
    const Inst in = decode(enc_r4(0x4f, 10, RmRTZ, 11, 12, 13, 1));
    CHECK(in.op == Op::FnmaddD);
    CHECK_EQ(in.rs3, 13);
    CHECK_EQ(in.rm, u8{RmRTZ});
  }
  CHECK(decode(enc_r(0x53, 10, RmDYN, 11, 3, (0x18 << 2) | 1)).op == Op::FcvtLuD);
  CHECK(decode(enc_r(0x53, 10, 0, 11, 0, (0x1e << 2) | 1)).op == Op::FmvDX);

  // Reserved encodings must not decode to something plausible.
  CHECK(decode(0x00000000).op == Op::Illegal);
  CHECK(decode(0xffffffff).op == Op::Illegal);
  CHECK(decode(enc_r(0x33, 1, 0, 2, 3, 0x7f)).op == Op::Illegal);
}

void test_compressed() {
  group = "compressed";

  // Every expected parcel here is what GNU as emits for the instruction in the
  // comment, so this is a check against the real encoding and not against a
  // rederivation of the same table.
  CHECK_EQ(decompress(0x0028), enc_i(0x13, 10, 0, 2, 8));       // c.addi4spn a0,sp,8
  CHECK_EQ(decompress(0x557d), enc_i(0x13, 10, 0, 0, -1));      // c.li a0,-1
  CHECK_EQ(decompress(0x0505), enc_i(0x13, 10, 0, 10, 1));      // c.addi a0,1
  CHECK_EQ(decompress(0x717d), enc_i(0x13, 2, 0, 2, -16));      // c.addi16sp sp,-16
  CHECK_EQ(decompress(0x852e), enc_r(0x33, 10, 0, 0, 11, 0));   // c.mv a0,a1
  CHECK_EQ(decompress(0x952e), enc_r(0x33, 10, 0, 10, 11, 0));  // c.add a0,a1
  CHECK_EQ(decompress(0x8082), enc_i(0x67, 0, 0, 1, 0));        // c.jr ra
  CHECK_EQ(decompress(0x9082), enc_i(0x67, 1, 0, 1, 0));        // c.jalr ra
  CHECK_EQ(decompress(0x9002), 0x00100073u);                    // c.ebreak
  CHECK_EQ(decompress(0x8d0d), enc_r(0x33, 10, 0, 10, 11, 0x20));  // c.sub a0,a1
  CHECK_EQ(decompress(0x6588), enc_i(0x03, 10, 3, 11, 8));      // c.ld a0,8(a1)
  CHECK_EQ(decompress(0xe406), enc_s(0x23, 3, 2, 1, 8));        // c.sd ra,8(sp)
  CHECK_EQ(decompress(0x41c8), enc_i(0x03, 10, 2, 11, 4));      // c.lw a0,4(a1)
  CHECK_EQ(decompress(0xa001), enc_j(0x6f, 0, 0));              // c.j .
  CHECK_EQ(decompress(0xc101), enc_b(0x63, 0, 10, 0, 0));       // c.beqz a0,.
  CHECK_EQ(decompress(0x0516), enc_i(0x13, 10, 1, 10, 5));      // c.slli a0,5
  CHECK_EQ(decompress(0x810d), enc_i(0x13, 10, 5, 10, 3));      // c.srli a0,3
  CHECK_EQ(decompress(0x997d), enc_i(0x13, 10, 7, 10, -1));     // c.andi a0,-1
  CHECK_EQ(decompress(0x6505), enc_u(0x37, 10, 0x1000));        // c.lui a0,0x1
  CHECK_EQ(decompress(0x60c2), enc_i(0x03, 1, 3, 2, 16));       // c.ldsp ra,16(sp)
  CHECK_EQ(decompress(0x357d), enc_i(0x1b, 10, 0, 10, -1));     // c.addiw a0,-1
  CHECK_EQ(decompress(0x9d0d), enc_r(0x3b, 10, 0, 10, 11, 0x20));  // c.subw a0,a1
  CHECK_EQ(decompress(0x9d2d), enc_r(0x3b, 10, 0, 10, 11, 0));  // c.addw a0,a1

  // The all-zero parcel is not an instruction.
  CHECK_EQ(decompress(0x0000), 0u);
  CHECK(!is_compressed(0x0013));
  CHECK(is_compressed(0x0505));

  // A reserved parcel decodes as illegal rather than as noise, and still
  // reports the length so the caller can move on.
  const Inst in = decode_at(0x0000, 0);
  CHECK(in.op == Op::Illegal);
  CHECK_EQ(in.len, 2);
}

// -- memory ------------------------------------------------------------------

void test_memory() {
  group = "memory";
  Memory m;
  m.map(0x1000, kPageSize * 2, PermRW);

  CHECK(m.store<u64>(0x1000, 0x0123456789abcdefull));
  u64 v = 0;
  CHECK(m.load<u64>(0x1000, v));
  CHECK_EQ(v, 0x0123456789abcdefull);

  // A load that straddles a page boundary has to walk both pages.
  CHECK(m.store<u64>(0x1000 + kPageSize - 4, 0xdeadbeefcafebabeull));
  CHECK(m.load<u64>(0x1000 + kPageSize - 4, v));
  CHECK_EQ(v, 0xdeadbeefcafebabeull);

  // Unmapped memory faults, and says where.
  u32 word = 0;
  CHECK(!m.load<u32>(0x900000, word));
  CHECK_EQ(m.fault_addr, 0x900000ull);

  // Permissions bind the guest and not the loader.
  m.protect(0x1000, kPageSize, PermR);
  CHECK(!m.store<u32>(0x1000, 1));
  CHECK(m.fault_access == Access::Store);
  const u32 fortytwo = 42;
  CHECK(m.poke(0x1000, &fortytwo, 4));
  CHECK(m.load<u32>(0x1000, word));
  CHECK_EQ(word, 42u);

  // Execute permission is separate from read.
  u16 parcel = 0;
  CHECK(!m.load<u16>(0x1000, parcel, Access::Fetch));

  m.unmap(0x1000, kPageSize * 2);
  CHECK(!m.mapped(0x1000));
  CHECK(m.range_free(0x1000, kPageSize));
}

// -- float -------------------------------------------------------------------

void test_float_helpers() {
  group = "float";

  // A single that is not NaN-boxed reads back as the canonical NaN.
  CHECK(std::isnan(unbox_f32(0x0000'0000'3f80'0000ull)));
  CHECK_EQ(std::bit_cast<u32>(unbox_f32(box_f32(1.0f))), 0x3f800000u);
  CHECK_EQ(box_f32(1.0f), 0xffffffff3f800000ull);

  // fclass is one-hot, and separates the two zeroes and the two NaNs.
  CHECK_EQ(fclass_bits(-std::numeric_limits<double>::infinity()), 1ull << 0);
  CHECK_EQ(fclass_bits(-1.0), 1ull << 1);
  CHECK_EQ(fclass_bits(-0.0), 1ull << 3);
  CHECK_EQ(fclass_bits(0.0), 1ull << 4);
  CHECK_EQ(fclass_bits(1.0f), 1ull << 6);
  CHECK_EQ(fclass_bits(std::numeric_limits<float>::infinity()), 1ull << 7);
  CHECK_EQ(fclass_bits(std::bit_cast<double>(kCanonicalNanF64)), 1ull << 9);
  CHECK_EQ(fclass_bits(std::bit_cast<float>(0x7f800001u)), 1ull << 8);  // signalling
  CHECK_EQ(fclass_bits(std::numeric_limits<double>::denorm_min()), 1ull << 5);

  // Canonicalisation drops the payload, which is what RISC-V requires.
  CHECK_EQ(std::bit_cast<u32>(canon(std::bit_cast<float>(0x7fc00042u))),
           kCanonicalNanF32);
  CHECK_EQ(std::bit_cast<u64>(canon(1.5)), std::bit_cast<u64>(1.5));

  // RMM rounds halves away from zero; RNE rounds them to even.
  CHECK_EQ(round_to_integral(2.5, RmRMM), 3.0);
  CHECK_EQ(round_to_integral(-2.5, RmRMM), -3.0);
  CHECK_EQ(round_to_integral(2.5, RmRNE), 2.0);
  CHECK_EQ(round_to_integral(-1.5, RmRTZ), -1.0);
  CHECK_EQ(round_to_integral(-1.5, RmRDN), -2.0);
  CHECK_EQ(round_to_integral(1.5, RmRUP), 2.0);
}

// -- assembling and running --------------------------------------------------

// Assemble `src` and run it to completion. Register state is left in `m` for the
// caller to inspect. Returns the exit status, or -1 if it would not assemble.
int run(Machine& m, std::string_view src, Diag& d) {
  Assembler a;
  if (!a.assemble(src, "<test>", m.cpu.mem, m.image, d)) return -1;
  m.kernel.set_brk_start(m.image.brk);
  m.opts.argv = {"test"};
  m.opts.max_insns = 1 << 20;  // a runaway test should fail, not hang
  if (!m.start(d)) return -1;
  return m.run();
}

void test_assembler_encoding() {
  group = "assembler";
  Memory mem;
  Image img;
  Diag d;
  Assembler a;

  const bool ok = a.assemble(R"(
        .text
_start: addi    a0, zero, -1
        slli    a0, a0, 40
        lw      t0, -4(sp)
        sd      ra, 8(sp)
        beq     a0, a1, _start
        jal     ra, _start
        ecall
)",
                             "<test>", mem, img, d);
  CHECK(ok);
  if (!ok) {
    std::print(stderr, "  {}\n", d.message);
    return;
  }

  auto word = [&](unsigned i) {
    u32 w = 0;
    mem.peek(kAsmTextBase + i * 4, &w, 4);
    return w;
  };
  CHECK_EQ(word(0), enc_i(0x13, 10, 0, 0, -1));
  CHECK_EQ(word(1), enc_i(0x13, 10, 1, 10, 40));
  CHECK_EQ(word(2), enc_i(0x03, 5, 2, 2, -4));
  CHECK_EQ(word(3), enc_s(0x23, 3, 2, 1, 8));
  CHECK_EQ(word(4), enc_b(0x63, 0, 10, 11, -16));
  CHECK_EQ(word(5), enc_j(0x6f, 1, -20));
  CHECK_EQ(word(6), 0x00000073u);
  CHECK_EQ(img.entry, kAsmTextBase);
}

void test_li_expansion() {
  group = "li";
  // li must reproduce every constant exactly, whatever the expansion costs.
  for (i64 value : {i64{0}, i64{1}, i64{-1}, i64{2047}, i64{-2048}, i64{2048},
                    i64{0x7fffffff}, i64{-0x80000000LL}, i64{0x123456789abcdefLL},
                    i64{-0x123456789abcdefLL}, i64(0x8000000000000000ull),
                    i64(0xffffffffffff0000ull)}) {
    Machine m;
    Diag d;
    const int status = run(m, std::format(R"(
        .text
_start: li      a0, {}
        li      a1, {}
        sub     a2, a0, a1
        li      a7, 93
        ecall
)",
                                          value, value),
                           d);
    if (status < 0) {
      fail("li program assembles", __LINE__, d.message);
      continue;
    }
    ++checks;
    if (m.cpu.hart.x[10] != u64(value)) {
      fail("li loads the exact value", __LINE__,
           std::format("{:#x}, wanted {:#x}", m.cpu.hart.x[10], u64(value)));
    }
    CHECK_EQ(m.cpu.hart.x[12], 0ull);  // both spellings agree
  }
}

void test_arithmetic() {
  group = "arithmetic";
  Machine m;
  Diag d;
  // The cases the spec calls out: division by zero, the signed overflow corner,
  // and the sign extension of the *w forms. Results land in the saved registers
  // so that the exit status stays free to be zero.
  const int status = run(m, R"(
        .text
_start: li      t0, 1
        li      t1, 0
        div     s2, t0, t1              # -> all ones
        rem     s3, t0, t1              # -> the dividend
        divu    s4, t0, t1              # -> all ones
        li      t2, -1
        li      t3, 1
        slli    t3, t3, 63              # t3 = INT64_MIN
        div     s5, t3, t2              # -> INT64_MIN, and no trap
        rem     s6, t3, t2              # -> 0
        li      t4, 0x7fffffff
        addiw   s7, t4, 1               # -> sign-extended INT32_MIN
        li      t5, -1
        srliw   s8, t5, 4               # -> a 32-bit shift, sign-extended
        li      a0, 0
        li      a7, 93
        ecall
)",
                         d);
  CHECK_EQ(status, 0);
  if (status < 0) {
    std::print(stderr, "  {}\n", d.message);
    return;
  }
  const auto& x = m.cpu.hart.x;
  CHECK_EQ(x[18], ~u64{0});
  CHECK_EQ(x[19], 1ull);
  CHECK_EQ(x[20], ~u64{0});
  CHECK_EQ(x[21], u64{1} << 63);
  CHECK_EQ(x[22], 0ull);
  CHECK_EQ(x[23], u64(i64(std::numeric_limits<i32>::min())));
  CHECK_EQ(x[24], 0x0fffffffull);
}
void test_float_execution() {
  group = "float exec";
  Machine m;
  Diag d;
  // fcvt saturates rather than wrapping, and says so through fflags.
  const int status = run(m, R"(
        .text
_start: li      t0, 0x7ff8000000000000   # a quiet NaN
        fmv.d.x ft0, t0
        fcvt.w.d s2, ft0, rtz            # NaN -> INT32_MAX, and NV
        csrr    s3, fflags
        csrrci  zero, fflags, 31

        li      t1, 1000000000
        fcvt.d.l ft1, t1
        fmul.d  ft3, ft1, ft1            # 1e18, well past INT32_MAX
        fcvt.w.d s4, ft3, rtz            # -> INT32_MAX, and NV
        fcvt.l.d s5, ft3, rtz            # -> exactly 1e18, no flag
        csrr    s6, fflags
        csrrci  zero, fflags, 31

        fcvt.d.w ft4, zero
        li      t2, 1
        fcvt.d.w ft5, t2
        fdiv.d  ft6, ft5, ft4            # 1.0 / 0.0
        fclass.d s7, ft6                 # -> +infinity
        csrr    s8, fflags               # -> DZ

        li      a0, 0
        li      a7, 93
        ecall
)",
                         d);
  CHECK_EQ(status, 0);
  if (status < 0) {
    std::print(stderr, "  {}\n", d.message);
    return;
  }
  const auto& x = m.cpu.hart.x;
  CHECK_EQ(x[18], u64(i64(std::numeric_limits<i32>::max())));
  CHECK_EQ(x[19], u64{FFlagNV});
  CHECK_EQ(x[20], u64(i64(std::numeric_limits<i32>::max())));
  CHECK_EQ(x[21], 1000000000000000000ull);
  CHECK_EQ(x[22], u64{FFlagNV});
  CHECK_EQ(x[23], 1ull << 7);  // +infinity
  CHECK_EQ(x[24], u64{FFlagDZ});
}
void test_atomics() {
  group = "atomics";
  Machine m;
  Diag d;
  const int status = run(m, R"(
        .data
cell:   .dword  100

        .text
_start: la      s0, cell
        li      t0, 5
        amoadd.d s2, t0, (s0)           # returns the old value
        ld      s3, 0(s0)               # 105

        lr.d    s4, (s0)
        li      t1, 7
        sc.d    s5, t1, (s0)            # holds a reservation -> 0
        ld      s6, 0(s0)               # 7

        li      t2, 9
        sc.d    s7, t2, (s0)            # the reservation is gone -> 1
        ld      s8, 0(s0)               # still 7

        li      a0, 0
        li      a7, 93
        ecall
)",
                         d);
  CHECK_EQ(status, 0);
  if (status < 0) {
    std::print(stderr, "  {}\n", d.message);
    return;
  }
  const auto& x = m.cpu.hart.x;
  CHECK_EQ(x[18], 100ull);
  CHECK_EQ(x[19], 105ull);
  CHECK_EQ(x[20], 105ull);
  CHECK_EQ(x[21], 0ull);
  CHECK_EQ(x[22], 7ull);
  CHECK_EQ(x[23], 1ull);
  CHECK_EQ(x[24], 7ull);
}
void test_directives_and_labels() {
  group = "directives";
  Machine m;
  Diag d;
  // The data directives, .equ arithmetic over `.`, and a numeric local label.
  const int status = run(m, R"(
        .data
        .align  3
bytes:  .byte   1, 2, 3, 4
        .half   0x1234
        .word   0xdeadbeef
        .dword  0x0123456789abcdef
text:   .string "abc"
        .equ    textlen, . - text - 1

        .text
_start: la      s0, bytes
        lbu     s2, 2(s0)               # 3
        lhu     s3, 4(s0)               # 0x1234
        lwu     s4, 6(s0)               # 0xdeadbeef
        ld      s5, 10(s0)
        li      s6, textlen             # 3

        li      t0, 0
        li      t1, 5
1:      addi    t0, t0, 1
        addi    t1, t1, -1
        bnez    t1, 1b
        mv      s7, t0                  # 5

        li      a0, 0
        li      a7, 93
        ecall
)",
                         d);
  CHECK_EQ(status, 0);
  if (status < 0) {
    std::print(stderr, "  {}\n", d.message);
    return;
  }
  const auto& x = m.cpu.hart.x;
  CHECK_EQ(x[18], 3ull);
  CHECK_EQ(x[19], 0x1234ull);
  CHECK_EQ(x[20], 0xdeadbeefull);
  CHECK_EQ(x[21], 0x0123456789abcdefull);
  CHECK_EQ(x[22], 3ull);
  CHECK_EQ(x[23], 5ull);
}
void test_assembler_errors() {
  group = "assembler errors";
  auto rejects = [](std::string_view src, std::string_view because, int line) {
    Memory mem;
    Image img;
    Diag d;
    Assembler a;
    ++checks;
    if (a.assemble(src, "<test>", mem, img, d)) {
      fail("should not assemble", line, std::string(because));
    }
  };

  rejects(".text\n_start: li a0, _start\n", "li of an address", __LINE__);
  rejects(".text\n_start: addi a0, a1, 4096\n", "immediate too large", __LINE__);
  rejects(".text\n_start: addi a0, q9, 1\n", "not a register", __LINE__);
  rejects(".text\n_start: frobnicate a0\n", "unknown instruction", __LINE__);
  rejects(".text\n_start: .frobnicate 1\n", "unknown directive", __LINE__);
  rejects(".text\n_start: addi a0, a1\n", "too few operands", __LINE__);
  rejects(".text\n_start: jal missing_label\n", "undefined symbol", __LINE__);
  rejects(".text\n_start: slli a0, a1, 64\n", "shift out of range", __LINE__);
}

void test_faults() {
  group = "faults";
  // These drive resume() rather than run(), so a deliberate fault does not
  // print a register dump into the middle of the test output.
  auto fault_of = [](std::string_view src, Machine& m, Diag& d) {
    Assembler a;
    if (!a.assemble(src, "<test>", m.cpu.mem, m.image, d)) return Event::Exited;
    m.kernel.set_brk_start(m.image.brk);
    m.opts.argv = {"test"};
    m.opts.max_insns = 1 << 16;
    if (!m.start(d)) return Event::Exited;
    return m.resume(false);
  };

  {
    Machine m;
    Diag d;
    // A load from an unmapped address is a fault, not a wrong answer.
    const Event e = fault_of(".text\n_start: li t0, 0x40\n ld a0, 0(t0)\n", m, d);
    CHECK(e == Event::Fault);
    CHECK(m.last_error.find("load fault") != std::string::npos);
    CHECK(m.cpu.fault_access == Access::Load);
    CHECK_EQ(m.cpu.fault_addr, 0x40ull);
  }
  {
    Machine m;
    Diag d;
    // Text is not writable.
    const Event e =
        fault_of(".text\n_start: la t0, _start\n sd zero, 0(t0)\n", m, d);
    CHECK(e == Event::Fault);
    CHECK(m.cpu.fault_access == Access::Store);
    CHECK_EQ(m.cpu.fault_addr, kAsmTextBase);
  }
  {
    Machine m;
    Diag d;
    // An all-zero word is a reserved encoding, and the pc stays on it.
    const Event e = fault_of(".text\n_start: unimp\n", m, d);
    CHECK(e == Event::Illegal);
    CHECK_EQ(m.cpu.hart.pc, kAsmTextBase);
    CHECK(m.last_error.find("illegal instruction") != std::string::npos);
  }
}
void test_breakpoints() {
  group = "breakpoints";
  Machine m;
  Diag d;
  Assembler a;
  const bool ok = a.assemble(R"(
        .text
_start: li      a0, 1
stop:   li      a0, 2
        li      a0, 3
        li      a7, 93
        li      a0, 0
        ecall
)",
                             "<test>", m.cpu.mem, m.image, d);
  CHECK(ok);
  if (!ok) return;
  m.kernel.set_brk_start(m.image.brk);
  m.opts.argv = {"test"};
  CHECK(m.start(d));

  // The breakpoint fires before the instruction at that address runs.
  m.breakpoints.insert(kAsmTextBase + 4);
  CHECK(m.resume(false) == Event::Breakpoint);
  CHECK_EQ(m.cpu.hart.pc, kAsmTextBase + 4);
  CHECK_EQ(m.cpu.hart.x[10], 1ull);

  // Resuming from a breakpoint must not immediately retrigger it.
  CHECK(m.resume(true) == Event::Stepped);
  CHECK_EQ(m.cpu.hart.x[10], 2ull);
  m.breakpoints.clear();
  CHECK(m.resume(false) == Event::Exited);
  CHECK_EQ(m.kernel.exit_code, 0);
}

void test_disasm() {
  group = "disasm";
  // The pseudo-instruction spellings are what a trace shows, so pin them down.
  auto text = [](u32 w, u64 pc = 0x1000) { return disasm(decode(w), pc); };
  CHECK_EQ(text(enc_i(0x13, 0, 0, 0, 0)), "nop");
  CHECK_EQ(text(enc_i(0x13, 10, 0, 0, 5)), "li a0,5");
  CHECK_EQ(text(enc_i(0x13, 10, 0, 11, 0)), "mv a0,a1");
  CHECK_EQ(text(enc_i(0x67, 0, 0, 1, 0)), "ret");
  CHECK_EQ(text(enc_j(0x6f, 0, 0x20)), "j 0x1020");
  CHECK_EQ(text(enc_r(0x33, 10, 0, 0, 11, 0x20)), "neg a0,a1");
  CHECK_EQ(text(enc_u(0x37, 10, 0x12345000)), "lui a0,0x12345");
  CHECK_EQ(text(enc_r(0x53, 10, 0, 11, 11, (0x04 << 2) | 1)), "fmv.d fa0,fa1");
  CHECK_EQ(text(0x00000000), ".word 0x00000000");
}

}  // namespace

int main() {
  test_encode_decode();
  test_compressed();
  test_memory();
  test_float_helpers();
  test_assembler_encoding();
  test_li_expansion();
  test_arithmetic();
  test_float_execution();
  test_atomics();
  test_directives_and_labels();
  test_assembler_errors();
  test_faults();
  test_breakpoints();
  test_disasm();

  if (failures) {
    std::print(stderr, "\n{} of {} checks failed\n", failures, checks);
    return 1;
  }
  std::print("all {} checks passed\n", checks);
  return 0;
}
