// Decode partition — RV64GC instruction words in, `Inst` out.
//
// Two things live here, and they are two halves of the same table.
//
// `decode` turns a 32-bit word into an `Inst`: an opcode enum plus already
// extracted register numbers and a sign-extended immediate. Compressed (16-bit)
// instructions never reach it directly -- `decompress` expands them into the
// equivalent 32-bit encoding first, so there is exactly one decoder to get right
// and the C extension costs one table instead of a second interpreter.
//
// `enc_*` go the other way, building instruction words from fields. The
// assembler is their only user, but they belong next to the decoder: an encoder
// and a decoder that disagree are a bug you find at three in the morning, and
// keeping them in one file is what lets the round-trip test in tests/ be
// written as `decode(enc_i(...))`.
export module rvemu:decode;

import std;
import :common;
import :cpu;

export namespace rvemu {

enum class Op : u16 {
  Illegal = 0,

  // RV64I
  Lui, Auipc, Jal, Jalr,
  Beq, Bne, Blt, Bge, Bltu, Bgeu,
  Lb, Lh, Lw, Lbu, Lhu, Lwu, Ld,
  Sb, Sh, Sw, Sd,
  Addi, Slti, Sltiu, Xori, Ori, Andi, Slli, Srli, Srai,
  Add, Sub, Sll, Slt, Sltu, Xor, Srl, Sra, Or, And,
  Addiw, Slliw, Srliw, Sraiw, Addw, Subw, Sllw, Srlw, Sraw,
  Fence, FenceI, Ecall, Ebreak,

  // Zicsr
  Csrrw, Csrrs, Csrrc, Csrrwi, Csrrsi, Csrrci,

  // M
  Mul, Mulh, Mulhsu, Mulhu, Div, Divu, Rem, Remu,
  Mulw, Divw, Divuw, Remw, Remuw,

  // A
  LrW, ScW, AmoswapW, AmoaddW, AmoxorW, AmoandW, AmoorW,
  AmominW, AmomaxW, AmominuW, AmomaxuW,
  LrD, ScD, AmoswapD, AmoaddD, AmoxorD, AmoandD, AmoorD,
  AmominD, AmomaxD, AmominuD, AmomaxuD,

  // F
  Flw, Fsw,
  FmaddS, FmsubS, FnmsubS, FnmaddS,
  FaddS, FsubS, FmulS, FdivS, FsqrtS,
  FsgnjS, FsgnjnS, FsgnjxS, FminS, FmaxS,
  FcvtWS, FcvtWuS, FmvXW, FeqS, FltS, FleS, FclassS,
  FcvtSW, FcvtSWu, FmvWX, FcvtLS, FcvtLuS, FcvtSL, FcvtSLu,

  // D
  Fld, Fsd,
  FmaddD, FmsubD, FnmsubD, FnmaddD,
  FaddD, FsubD, FmulD, FdivD, FsqrtD,
  FsgnjD, FsgnjnD, FsgnjxD, FminD, FmaxD,
  FcvtSD, FcvtDS, FeqD, FltD, FleD, FclassD,
  FcvtWD, FcvtWuD, FcvtDW, FcvtDWu,
  FcvtLD, FcvtLuD, FmvXD, FcvtDL, FcvtDLu, FmvDX,
};

struct Inst {
  Op op = Op::Illegal;
  u8 rd = 0, rs1 = 0, rs2 = 0, rs3 = 0;
  u8 rm = 0;    // float rounding-mode field, or funct3 for CSR-immediate zimm
  u8 len = 4;   // 2 when this came from a compressed encoding
  bool aq = false, rl = false;  // AMO ordering; one hart, so advisory only
  i64 imm = 0;  // sign-extended immediate, or the CSR number for Csrr*
  u32 raw = 0;  // the (possibly expanded) 32-bit word, for diagnostics
};

// A 16-bit parcel starts a compressed instruction unless its low two bits are 11.
constexpr bool is_compressed(u16 parcel) { return (parcel & 3) != 3; }

// -- encoding ----------------------------------------------------------------

constexpr u32 enc_r(u32 opcode, u32 rd, u32 f3, u32 rs1, u32 rs2, u32 f7) {
  return opcode | (rd << 7) | (f3 << 12) | (rs1 << 15) | (rs2 << 20) | (f7 << 25);
}
constexpr u32 enc_r4(u32 opcode, u32 rd, u32 rm, u32 rs1, u32 rs2, u32 rs3, u32 fmt) {
  return opcode | (rd << 7) | (rm << 12) | (rs1 << 15) | (rs2 << 20) | (fmt << 25) |
         (rs3 << 27);
}
constexpr u32 enc_i(u32 opcode, u32 rd, u32 f3, u32 rs1, i32 imm) {
  return opcode | (rd << 7) | (f3 << 12) | (rs1 << 15) |
         ((static_cast<u32>(imm) & 0xfff) << 20);
}
constexpr u32 enc_s(u32 opcode, u32 f3, u32 rs1, u32 rs2, i32 imm) {
  const u32 v = static_cast<u32>(imm);
  return opcode | ((v & 0x1f) << 7) | (f3 << 12) | (rs1 << 15) | (rs2 << 20) |
         (((v >> 5) & 0x7f) << 25);
}
constexpr u32 enc_b(u32 opcode, u32 f3, u32 rs1, u32 rs2, i32 imm) {
  const u32 v = static_cast<u32>(imm);
  return opcode | (((v >> 11) & 1) << 7) | (((v >> 1) & 0xf) << 8) | (f3 << 12) |
         (rs1 << 15) | (rs2 << 20) | (((v >> 5) & 0x3f) << 25) | (((v >> 12) & 1) << 31);
}
constexpr u32 enc_u(u32 opcode, u32 rd, i32 imm) {
  return opcode | (rd << 7) | (static_cast<u32>(imm) & 0xfffff000);
}
constexpr u32 enc_j(u32 opcode, u32 rd, i32 imm) {
  const u32 v = static_cast<u32>(imm);
  return opcode | (rd << 7) | (v & 0xff000) | (((v >> 11) & 1) << 20) |
         (((v >> 1) & 0x3ff) << 21) | (((v >> 20) & 1) << 31);
}

// -- immediate extraction ----------------------------------------------------

constexpr i64 imm_i(u32 w) { return sext(w >> 20, 12); }
constexpr i64 imm_s(u32 w) {
  return sext(((w >> 7) & 0x1f) | (((w >> 25) & 0x7f) << 5), 12);
}
constexpr i64 imm_b(u32 w) {
  return sext((((w >> 8) & 0xf) << 1) | (((w >> 25) & 0x3f) << 5) |
                  (((w >> 7) & 1) << 11) | (((w >> 31) & 1) << 12),
              13);
}
constexpr i64 imm_u(u32 w) { return static_cast<i32>(w & 0xfffff000); }
constexpr i64 imm_j(u32 w) {
  return sext((((w >> 21) & 0x3ff) << 1) | (((w >> 20) & 1) << 11) |
                  (((w >> 12) & 0xff) << 12) | (((w >> 31) & 1) << 20),
              21);
}

// -- the C extension ---------------------------------------------------------

// Expand a 16-bit parcel to the 32-bit instruction it stands for. Returns 0 for
// an encoding that is not a valid RV64C instruction, which decodes as Illegal.
constexpr u32 decompress(u16 c) {
  const u32 w = c;
  const u32 op = w & 3;
  const u32 f3 = (w >> 13) & 7;
  const u32 rd = (w >> 7) & 0x1f;     // full-width rd / rs1
  const u32 rs2 = (w >> 2) & 0x1f;    // full-width rs2
  const u32 rdc = 8 + ((w >> 2) & 7);  // rd' / rs2'
  const u32 rs1c = 8 + ((w >> 7) & 7);  // rs1'

  switch (op) {
    case 0: {  // quadrant 0: stack-relative-free loads and stores
      switch (f3) {
        case 0: {  // c.addi4spn
          const u32 nz = ((w >> 7) & 0x30) | ((w >> 1) & 0x3c0) | ((w >> 4) & 0x4) |
                         ((w >> 2) & 0x8);
          if (nz == 0) return 0;  // the all-zero parcel, and the reserved encodings
          return enc_i(0x13, rdc, 0, 2, static_cast<i32>(nz));  // addi rd', sp, nz
        }
        case 1: {  // c.fld
          const u32 u = ((w >> 7) & 0x38) | ((w << 1) & 0xc0);
          return enc_i(0x07, rdc, 3, rs1c, static_cast<i32>(u));
        }
        case 2: {  // c.lw
          const u32 u = ((w >> 7) & 0x38) | ((w >> 4) & 0x4) | ((w << 1) & 0x40);
          return enc_i(0x03, rdc, 2, rs1c, static_cast<i32>(u));
        }
        case 3: {  // c.ld
          const u32 u = ((w >> 7) & 0x38) | ((w << 1) & 0xc0);
          return enc_i(0x03, rdc, 3, rs1c, static_cast<i32>(u));
        }
        case 5: {  // c.fsd
          const u32 u = ((w >> 7) & 0x38) | ((w << 1) & 0xc0);
          return enc_s(0x27, 3, rs1c, rdc, static_cast<i32>(u));
        }
        case 6: {  // c.sw
          const u32 u = ((w >> 7) & 0x38) | ((w >> 4) & 0x4) | ((w << 1) & 0x40);
          return enc_s(0x23, 2, rs1c, rdc, static_cast<i32>(u));
        }
        case 7: {  // c.sd
          const u32 u = ((w >> 7) & 0x38) | ((w << 1) & 0xc0);
          return enc_s(0x23, 3, rs1c, rdc, static_cast<i32>(u));
        }
        default: return 0;  // f3 == 4 is reserved on RV64C
      }
    }

    case 1: {  // quadrant 1: immediate arithmetic and control transfer
      switch (f3) {
        case 0: {  // c.addi / c.nop
          const i64 imm = sext(((w >> 7) & 0x20) | ((w >> 2) & 0x1f), 6);
          return enc_i(0x13, rd, 0, rd, static_cast<i32>(imm));
        }
        case 1: {  // c.addiw (RV64; the RV32 c.jal slot)
          if (rd == 0) return 0;
          const i64 imm = sext(((w >> 7) & 0x20) | ((w >> 2) & 0x1f), 6);
          return enc_i(0x1b, rd, 0, rd, static_cast<i32>(imm));
        }
        case 2: {  // c.li
          const i64 imm = sext(((w >> 7) & 0x20) | ((w >> 2) & 0x1f), 6);
          return enc_i(0x13, rd, 0, 0, static_cast<i32>(imm));
        }
        case 3: {
          if (rd == 2) {  // c.addi16sp
            const i64 imm = sext(((w >> 3) & 0x200) | ((w >> 2) & 0x10) |
                                     ((w << 1) & 0x40) | ((w << 4) & 0x180) |
                                     ((w << 3) & 0x20),
                                 10);
            if (imm == 0) return 0;
            return enc_i(0x13, 2, 0, 2, static_cast<i32>(imm));
          }
          // c.lui
          const i64 imm = sext(((w >> 7) & 0x20) | ((w >> 2) & 0x1f), 6) << 12;
          if (rd == 0 || imm == 0) return 0;
          return enc_u(0x37, rd, static_cast<i32>(imm));
        }
        case 4: {  // MISC-ALU
          const u32 f2 = (w >> 10) & 3;
          const u32 shamt = ((w >> 7) & 0x20) | ((w >> 2) & 0x1f);
          if (f2 == 0) return enc_i(0x13, rs1c, 5, rs1c, static_cast<i32>(shamt));
          if (f2 == 1) return enc_i(0x13, rs1c, 5, rs1c, static_cast<i32>(shamt | 0x400));
          if (f2 == 2) {  // c.andi
            const i64 imm = sext(((w >> 7) & 0x20) | ((w >> 2) & 0x1f), 6);
            return enc_i(0x13, rs1c, 7, rs1c, static_cast<i32>(imm));
          }
          const u32 sub = (w >> 5) & 3;
          if (((w >> 12) & 1) == 0) {  // c.sub / c.xor / c.or / c.and
            switch (sub) {
              case 0: return enc_r(0x33, rs1c, 0, rs1c, rdc, 0x20);
              case 1: return enc_r(0x33, rs1c, 4, rs1c, rdc, 0x00);
              case 2: return enc_r(0x33, rs1c, 6, rs1c, rdc, 0x00);
              default: return enc_r(0x33, rs1c, 7, rs1c, rdc, 0x00);
            }
          }
          switch (sub) {  // c.subw / c.addw
            case 0: return enc_r(0x3b, rs1c, 0, rs1c, rdc, 0x20);
            case 1: return enc_r(0x3b, rs1c, 0, rs1c, rdc, 0x00);
            default: return 0;  // reserved
          }
        }
        case 5: {  // c.j
          const i64 imm = sext(((w >> 1) & 0x800) | ((w >> 7) & 0x10) |
                                   ((w >> 1) & 0x300) | ((w << 2) & 0x400) |
                                   ((w >> 1) & 0x40) | ((w << 1) & 0x80) |
                                   ((w >> 2) & 0xe) | ((w << 3) & 0x20),
                               12);
          return enc_j(0x6f, 0, static_cast<i32>(imm));
        }
        case 6:
        case 7: {  // c.beqz / c.bnez
          const i64 imm = sext(((w >> 4) & 0x100) | ((w >> 7) & 0x18) |
                                   ((w << 1) & 0xc0) | ((w >> 2) & 0x6) |
                                   ((w << 3) & 0x20),
                               9);
          return enc_b(0x63, f3 == 6 ? 0 : 1, rs1c, 0, static_cast<i32>(imm));
        }
        default: return 0;
      }
    }

    case 2: {  // quadrant 2: stack-pointer-relative, and register moves
      switch (f3) {
        case 0: {  // c.slli
          const u32 shamt = ((w >> 7) & 0x20) | ((w >> 2) & 0x1f);
          if (rd == 0) return 0;
          return enc_i(0x13, rd, 1, rd, static_cast<i32>(shamt));
        }
        case 1: {  // c.fldsp
          const u32 u = ((w >> 7) & 0x20) | ((w >> 2) & 0x18) | ((w << 4) & 0x1c0);
          return enc_i(0x07, rd, 3, 2, static_cast<i32>(u));
        }
        case 2: {  // c.lwsp
          if (rd == 0) return 0;
          const u32 u = ((w >> 7) & 0x20) | ((w >> 2) & 0x1c) | ((w << 4) & 0xc0);
          return enc_i(0x03, rd, 2, 2, static_cast<i32>(u));
        }
        case 3: {  // c.ldsp
          if (rd == 0) return 0;
          const u32 u = ((w >> 7) & 0x20) | ((w >> 2) & 0x18) | ((w << 4) & 0x1c0);
          return enc_i(0x03, rd, 3, 2, static_cast<i32>(u));
        }
        case 4: {
          if (((w >> 12) & 1) == 0) {
            if (rs2 == 0) {  // c.jr
              if (rd == 0) return 0;
              return enc_i(0x67, 0, 0, rd, 0);
            }
            if (rd == 0) return 0;  // c.mv with rd=0 is a hint, not an instruction
            return enc_r(0x33, rd, 0, 0, rs2, 0);  // c.mv
          }
          if (rs2 == 0) {
            if (rd == 0) return enc_i(0x73, 0, 0, 0, 1);  // c.ebreak
            return enc_i(0x67, 1, 0, rd, 0);              // c.jalr
          }
          if (rd == 0) return 0;  // c.add with rd=0 is a hint
          return enc_r(0x33, rd, 0, rd, rs2, 0);  // c.add
        }
        case 5: {  // c.fsdsp
          const u32 u = ((w >> 7) & 0x38) | ((w >> 1) & 0x1c0);
          return enc_s(0x27, 3, 2, rs2, static_cast<i32>(u));
        }
        case 6: {  // c.swsp
          const u32 u = ((w >> 7) & 0x3c) | ((w >> 1) & 0xc0);
          return enc_s(0x23, 2, 2, rs2, static_cast<i32>(u));
        }
        case 7: {  // c.sdsp
          const u32 u = ((w >> 7) & 0x38) | ((w >> 1) & 0x1c0);
          return enc_s(0x23, 3, 2, rs2, static_cast<i32>(u));
        }
        default: return 0;
      }
    }

    default: return 0;  // op == 3 is not compressed
  }
}

// -- the 32-bit decoder ------------------------------------------------------

namespace detail {

// The AMO family shares an encoding; only funct5 and the width differ.
constexpr Op amo_op(u32 funct5, bool is_d) {
  switch (funct5) {
    case 0x00: return is_d ? Op::AmoaddD : Op::AmoaddW;
    case 0x01: return is_d ? Op::AmoswapD : Op::AmoswapW;
    case 0x02: return is_d ? Op::LrD : Op::LrW;
    case 0x03: return is_d ? Op::ScD : Op::ScW;
    case 0x04: return is_d ? Op::AmoxorD : Op::AmoxorW;
    case 0x08: return is_d ? Op::AmoorD : Op::AmoorW;
    case 0x0c: return is_d ? Op::AmoandD : Op::AmoandW;
    case 0x10: return is_d ? Op::AmominD : Op::AmominW;
    case 0x14: return is_d ? Op::AmomaxD : Op::AmomaxW;
    case 0x18: return is_d ? Op::AmominuD : Op::AmominuW;
    case 0x1c: return is_d ? Op::AmomaxuD : Op::AmomaxuW;
    default: return Op::Illegal;
  }
}

// OP-FP (0x53). fmt is bits 26:25 -- 0 single, 1 double.
constexpr Op fp_op(u32 funct5, u32 fmt, u32 rs2, u32 rm) {
  const bool d = (fmt == 1);
  if (fmt > 1) return Op::Illegal;  // no half or quad here
  switch (funct5) {
    case 0x00: return d ? Op::FaddD : Op::FaddS;
    case 0x01: return d ? Op::FsubD : Op::FsubS;
    case 0x02: return d ? Op::FmulD : Op::FmulS;
    case 0x03: return d ? Op::FdivD : Op::FdivS;
    case 0x0b: return rs2 == 0 ? (d ? Op::FsqrtD : Op::FsqrtS) : Op::Illegal;
    case 0x04:
      switch (rm) {
        case 0: return d ? Op::FsgnjD : Op::FsgnjS;
        case 1: return d ? Op::FsgnjnD : Op::FsgnjnS;
        case 2: return d ? Op::FsgnjxD : Op::FsgnjxS;
        default: return Op::Illegal;
      }
    case 0x05:
      switch (rm) {
        case 0: return d ? Op::FminD : Op::FminS;
        case 1: return d ? Op::FmaxD : Op::FmaxS;
        default: return Op::Illegal;
      }
    case 0x08:  // fcvt between float formats
      if (!d && rs2 == 1) return Op::FcvtSD;
      if (d && rs2 == 0) return Op::FcvtDS;
      return Op::Illegal;
    case 0x14:
      switch (rm) {
        case 0: return d ? Op::FleD : Op::FleS;
        case 1: return d ? Op::FltD : Op::FltS;
        case 2: return d ? Op::FeqD : Op::FeqS;
        default: return Op::Illegal;
      }
    case 0x18:  // float -> integer
      switch (rs2) {
        case 0: return d ? Op::FcvtWD : Op::FcvtWS;
        case 1: return d ? Op::FcvtWuD : Op::FcvtWuS;
        case 2: return d ? Op::FcvtLD : Op::FcvtLS;
        case 3: return d ? Op::FcvtLuD : Op::FcvtLuS;
        default: return Op::Illegal;
      }
    case 0x1a:  // integer -> float
      switch (rs2) {
        case 0: return d ? Op::FcvtDW : Op::FcvtSW;
        case 1: return d ? Op::FcvtDWu : Op::FcvtSWu;
        case 2: return d ? Op::FcvtDL : Op::FcvtSL;
        case 3: return d ? Op::FcvtDLu : Op::FcvtSLu;
        default: return Op::Illegal;
      }
    case 0x1c:  // fmv.x.w / fmv.x.d and fclass
      if (rs2 != 0) return Op::Illegal;
      if (rm == 0) return d ? Op::FmvXD : Op::FmvXW;
      if (rm == 1) return d ? Op::FclassD : Op::FclassS;
      return Op::Illegal;
    case 0x1e:  // fmv.w.x / fmv.d.x
      if (rs2 != 0 || rm != 0) return Op::Illegal;
      return d ? Op::FmvDX : Op::FmvWX;
    default: return Op::Illegal;
  }
}

}  // namespace detail

inline Inst decode(u32 w) {
  Inst in;
  in.raw = w;
  in.rd = static_cast<u8>((w >> 7) & 0x1f);
  in.rs1 = static_cast<u8>((w >> 15) & 0x1f);
  in.rs2 = static_cast<u8>((w >> 20) & 0x1f);
  in.rs3 = static_cast<u8>((w >> 27) & 0x1f);
  in.rm = static_cast<u8>((w >> 12) & 7);

  const u32 opcode = w & 0x7f;
  const u32 f3 = (w >> 12) & 7;
  const u32 f7 = (w >> 25) & 0x7f;

  switch (opcode) {
    case 0x37: in.op = Op::Lui; in.imm = imm_u(w); return in;
    case 0x17: in.op = Op::Auipc; in.imm = imm_u(w); return in;
    case 0x6f: in.op = Op::Jal; in.imm = imm_j(w); return in;
    case 0x67:
      if (f3 != 0) return in;
      in.op = Op::Jalr;
      in.imm = imm_i(w);
      return in;

    case 0x63: {  // branches
      static constexpr Op kB[8] = {Op::Beq,  Op::Bne,     Op::Illegal, Op::Illegal,
                                   Op::Blt,  Op::Bge,     Op::Bltu,    Op::Bgeu};
      in.op = kB[f3];
      in.imm = imm_b(w);
      return in;
    }

    case 0x03: {  // loads
      static constexpr Op kL[8] = {Op::Lb,  Op::Lh,  Op::Lw,      Op::Ld,
                                   Op::Lbu, Op::Lhu, Op::Lwu,     Op::Illegal};
      in.op = kL[f3];
      in.imm = imm_i(w);
      return in;
    }

    case 0x23: {  // stores
      static constexpr Op kS[8] = {Op::Sb,      Op::Sh,      Op::Sw,      Op::Sd,
                                   Op::Illegal, Op::Illegal, Op::Illegal, Op::Illegal};
      in.op = kS[f3];
      in.imm = imm_s(w);
      return in;
    }

    case 0x13: {  // OP-IMM
      in.imm = imm_i(w);
      switch (f3) {
        case 0: in.op = Op::Addi; return in;
        case 2: in.op = Op::Slti; return in;
        case 3: in.op = Op::Sltiu; return in;
        case 4: in.op = Op::Xori; return in;
        case 6: in.op = Op::Ori; return in;
        case 7: in.op = Op::Andi; return in;
        case 1:  // slli: RV64 takes a 6-bit shamt, so funct6 is bits 31:26
          if ((w >> 26) != 0) return in;
          in.op = Op::Slli;
          in.imm = (w >> 20) & 0x3f;
          return in;
        case 5: {
          const u32 f6 = w >> 26;
          if (f6 == 0) in.op = Op::Srli;
          else if (f6 == 0x10) in.op = Op::Srai;
          else return in;
          in.imm = (w >> 20) & 0x3f;
          return in;
        }
        default: return in;
      }
    }

    case 0x1b: {  // OP-IMM-32
      in.imm = imm_i(w);
      switch (f3) {
        case 0: in.op = Op::Addiw; return in;
        case 1:
          if (f7 != 0) return in;
          in.op = Op::Slliw;
          in.imm = (w >> 20) & 0x1f;
          return in;
        case 5:
          if (f7 == 0) in.op = Op::Srliw;
          else if (f7 == 0x20) in.op = Op::Sraiw;
          else return in;
          in.imm = (w >> 20) & 0x1f;
          return in;
        default: return in;
      }
    }

    case 0x33: {  // OP
      if (f7 == 1) {  // M extension
        static constexpr Op kM[8] = {Op::Mul, Op::Mulh, Op::Mulhsu, Op::Mulhu,
                                     Op::Div, Op::Divu, Op::Rem,    Op::Remu};
        in.op = kM[f3];
        return in;
      }
      if (f7 == 0) {
        static constexpr Op kR[8] = {Op::Add, Op::Sll, Op::Slt, Op::Sltu,
                                     Op::Xor, Op::Srl, Op::Or,  Op::And};
        in.op = kR[f3];
        return in;
      }
      if (f7 == 0x20) {
        if (f3 == 0) in.op = Op::Sub;
        else if (f3 == 5) in.op = Op::Sra;
      }
      return in;
    }

    case 0x3b: {  // OP-32
      if (f7 == 1) {
        switch (f3) {
          case 0: in.op = Op::Mulw; return in;
          case 4: in.op = Op::Divw; return in;
          case 5: in.op = Op::Divuw; return in;
          case 6: in.op = Op::Remw; return in;
          case 7: in.op = Op::Remuw; return in;
          default: return in;
        }
      }
      if (f7 == 0) {
        switch (f3) {
          case 0: in.op = Op::Addw; return in;
          case 1: in.op = Op::Sllw; return in;
          case 5: in.op = Op::Srlw; return in;
          default: return in;
        }
      }
      if (f7 == 0x20) {
        if (f3 == 0) in.op = Op::Subw;
        else if (f3 == 5) in.op = Op::Sraw;
      }
      return in;
    }

    case 0x0f:  // fence / fence.i
      if (f3 == 0) in.op = Op::Fence;
      else if (f3 == 1) in.op = Op::FenceI;
      return in;

    case 0x73: {  // SYSTEM
      if (f3 == 0) {
        if (w == 0x00000073) in.op = Op::Ecall;
        else if (w == 0x00100073) in.op = Op::Ebreak;
        return in;
      }
      static constexpr Op kC[8] = {Op::Illegal, Op::Csrrw,  Op::Csrrs,  Op::Csrrc,
                                   Op::Illegal, Op::Csrrwi, Op::Csrrsi, Op::Csrrci};
      in.op = kC[f3];
      in.imm = static_cast<i64>(w >> 20);  // the CSR number, unsigned
      return in;
    }

    case 0x2f: {  // AMO
      const u32 funct5 = f7 >> 2;
      const bool is_d = (f3 == 3);
      if (f3 != 2 && f3 != 3) return in;
      in.op = detail::amo_op(funct5, is_d);
      in.aq = (f7 >> 1) & 1;
      in.rl = f7 & 1;
      // LR takes no rs2; a non-zero field there is a reserved encoding.
      if ((in.op == Op::LrW || in.op == Op::LrD) && in.rs2 != 0) in.op = Op::Illegal;
      return in;
    }

    case 0x07:  // float loads
      in.imm = imm_i(w);
      if (f3 == 2) in.op = Op::Flw;
      else if (f3 == 3) in.op = Op::Fld;
      return in;

    case 0x27:  // float stores
      in.imm = imm_s(w);
      if (f3 == 2) in.op = Op::Fsw;
      else if (f3 == 3) in.op = Op::Fsd;
      return in;

    case 0x43:  // fmadd
    case 0x47:  // fmsub
    case 0x4b:  // fnmsub
    case 0x4f: {  // fnmadd
      const u32 fmt = (w >> 25) & 3;
      if (fmt > 1) return in;
      const bool d = (fmt == 1);
      switch (opcode) {
        case 0x43: in.op = d ? Op::FmaddD : Op::FmaddS; break;
        case 0x47: in.op = d ? Op::FmsubD : Op::FmsubS; break;
        case 0x4b: in.op = d ? Op::FnmsubD : Op::FnmsubS; break;
        default: in.op = d ? Op::FnmaddD : Op::FnmaddS; break;
      }
      return in;
    }

    case 0x53:  // OP-FP
      in.op = detail::fp_op(f7 >> 2, (w >> 25) & 3, in.rs2, f3);
      return in;

    default: return in;
  }
}

// Decode at a 16-bit parcel boundary: expands the C form when needed and sets
// `len` so the caller knows how far to advance the pc.
inline Inst decode_at(u16 lo, u32 full) {
  if (is_compressed(lo)) {
    const u32 expanded = decompress(lo);
    Inst in = expanded ? decode(expanded) : Inst{};
    in.len = 2;
    in.raw = lo;
    return in;
  }
  return decode(full);
}

}  // namespace rvemu
