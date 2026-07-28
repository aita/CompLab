// Disasm partition — an `Inst` back into text.
//
// This exists for `--trace`, for the `-d` dump, and for the error message you
// get when the guest jumps into the weeds. gdb has its own disassembler and
// never asks for this one.
//
// Branch and jump targets print as absolute addresses rather than offsets,
// because every caller already knows the pc and nobody reading a trace wants to
// do the arithmetic. The common pseudo-instructions (`nop`, `mv`, `li`, `j`,
// `ret`, ...) are recognised on the way out, the same way objdump does it: a
// trace full of `addi a0,zero,1` is harder to read than one full of `li a0,1`.
export module rvemu:disasm;

import std;
import :common;
import :cpu;
import :decode;

export namespace rvemu {

inline std::string xreg(unsigned r) { return kXRegNames[r & 31]; }
inline std::string freg(unsigned r) { return kFRegNames[r & 31]; }

// The rounding-mode suffix objdump prints; the default mode prints nothing.
inline std::string rm_suffix(u8 rm) {
  switch (rm) {
    case RmRNE: return ",rne";
    case RmRTZ: return ",rtz";
    case RmRDN: return ",rdn";
    case RmRUP: return ",rup";
    case RmRMM: return ",rmm";
    default: return "";
  }
}

inline std::string csr_name(u32 n) {
  switch (n) {
    case CsrFflags: return "fflags";
    case CsrFrm: return "frm";
    case CsrFcsr: return "fcsr";
    case CsrCycle: return "cycle";
    case CsrTime: return "time";
    case CsrInstret: return "instret";
    default: return std::format("{:#x}", n);
  }
}

inline std::string disasm(const Inst& in, u64 pc) {
  const std::string rd = xreg(in.rd), rs1 = xreg(in.rs1), rs2 = xreg(in.rs2);
  const std::string fd = freg(in.rd), fs1 = freg(in.rs1), fs2 = freg(in.rs2),
                    fs3 = freg(in.rs3);
  const i64 imm = in.imm;

  auto rrr = [&](const char* m) { return std::format("{} {},{},{}", m, rd, rs1, rs2); };
  auto rri = [&](const char* m) { return std::format("{} {},{},{}", m, rd, rs1, imm); };
  auto ld = [&](const char* m) { return std::format("{} {},{}({})", m, rd, imm, rs1); };
  auto st = [&](const char* m) { return std::format("{} {},{}({})", m, rs2, imm, rs1); };
  auto fld_ = [&](const char* m) { return std::format("{} {},{}({})", m, fd, imm, rs1); };
  auto fst = [&](const char* m) { return std::format("{} {},{}({})", m, fs2, imm, rs1); };
  auto br = [&](const char* m) {
    return std::format("{} {},{},{:#x}", m, rs1, rs2, pc + u64(imm));
  };
  auto fp3 = [&](const char* m) {
    return std::format("{} {},{},{}{}", m, fd, fs1, fs2, rm_suffix(in.rm));
  };
  auto fp2 = [&](const char* m) {
    return std::format("{} {},{}{}", m, fd, fs1, rm_suffix(in.rm));
  };
  auto fp4 = [&](const char* m) {
    return std::format("{} {},{},{},{}{}", m, fd, fs1, fs2, fs3, rm_suffix(in.rm));
  };
  auto fcmp = [&](const char* m) { return std::format("{} {},{},{}", m, rd, fs1, fs2); };
  auto amo = [&](const char* m) {
    const char* ord = in.aq ? (in.rl ? ".aqrl" : ".aq") : (in.rl ? ".rl" : "");
    return std::format("{}{} {},{},({})", m, ord, rd, rs2, rs1);
  };
  auto csr_rr = [&](const char* m) {
    return std::format("{} {},{},{}", m, rd, csr_name(u32(imm)), rs1);
  };
  auto csr_ri = [&](const char* m) {
    return std::format("{} {},{},{}", m, rd, csr_name(u32(imm)), in.rs1);
  };

  switch (in.op) {
    case Op::Illegal: return std::format(".word {:#010x}", in.raw);

    // The operand of lui/auipc is the 20-bit field, not the value it stands
    // for, which is how objdump prints it and how the assembler reads it back.
    case Op::Lui: return std::format("lui {},{:#x}", rd, (u64(imm) >> 12) & 0xfffff);
    case Op::Auipc: return std::format("auipc {},{:#x}", rd, (u64(imm) >> 12) & 0xfffff);

    case Op::Jal:
      if (in.rd == 0) return std::format("j {:#x}", pc + u64(imm));
      if (in.rd == 1) return std::format("jal {:#x}", pc + u64(imm));
      return std::format("jal {},{:#x}", rd, pc + u64(imm));
    case Op::Jalr:
      if (in.rd == 0 && in.rs1 == 1 && imm == 0) return "ret";
      if (in.rd == 0 && imm == 0) return std::format("jr {}", rs1);
      if (in.rd == 1 && imm == 0) return std::format("jalr {}", rs1);
      return std::format("jalr {},{}({})", rd, imm, rs1);

    case Op::Beq:
      if (in.rs2 == 0) return std::format("beqz {},{:#x}", rs1, pc + u64(imm));
      return br("beq");
    case Op::Bne:
      if (in.rs2 == 0) return std::format("bnez {},{:#x}", rs1, pc + u64(imm));
      return br("bne");
    case Op::Blt: return br("blt");
    case Op::Bge: return br("bge");
    case Op::Bltu: return br("bltu");
    case Op::Bgeu: return br("bgeu");

    case Op::Lb: return ld("lb");
    case Op::Lh: return ld("lh");
    case Op::Lw: return ld("lw");
    case Op::Ld: return ld("ld");
    case Op::Lbu: return ld("lbu");
    case Op::Lhu: return ld("lhu");
    case Op::Lwu: return ld("lwu");
    case Op::Sb: return st("sb");
    case Op::Sh: return st("sh");
    case Op::Sw: return st("sw");
    case Op::Sd: return st("sd");

    case Op::Addi:
      if (in.rd == 0 && in.rs1 == 0 && imm == 0) return "nop";
      if (in.rs1 == 0) return std::format("li {},{}", rd, imm);
      if (imm == 0) return std::format("mv {},{}", rd, rs1);
      return rri("addi");
    case Op::Slti: return rri("slti");
    case Op::Sltiu:
      if (imm == 1) return std::format("seqz {},{}", rd, rs1);
      return rri("sltiu");
    case Op::Xori:
      if (imm == -1) return std::format("not {},{}", rd, rs1);
      return rri("xori");
    case Op::Ori: return rri("ori");
    case Op::Andi: return rri("andi");
    case Op::Slli: return rri("slli");
    case Op::Srli: return rri("srli");
    case Op::Srai: return rri("srai");

    case Op::Add: return rrr("add");
    case Op::Sub:
      if (in.rs1 == 0) return std::format("neg {},{}", rd, rs2);
      return rrr("sub");
    case Op::Sll: return rrr("sll");
    case Op::Slt:
      if (in.rs2 == 0) return std::format("sltz {},{}", rd, rs1);
      if (in.rs1 == 0) return std::format("sgtz {},{}", rd, rs2);
      return rrr("slt");
    case Op::Sltu:
      if (in.rs1 == 0) return std::format("snez {},{}", rd, rs2);
      return rrr("sltu");
    case Op::Xor: return rrr("xor");
    case Op::Srl: return rrr("srl");
    case Op::Sra: return rrr("sra");
    case Op::Or: return rrr("or");
    case Op::And: return rrr("and");

    case Op::Addiw:
      if (imm == 0) return std::format("sext.w {},{}", rd, rs1);
      return rri("addiw");
    case Op::Slliw: return rri("slliw");
    case Op::Srliw: return rri("srliw");
    case Op::Sraiw: return rri("sraiw");
    case Op::Addw: return rrr("addw");
    case Op::Subw:
      if (in.rs1 == 0) return std::format("negw {},{}", rd, rs2);
      return rrr("subw");
    case Op::Sllw: return rrr("sllw");
    case Op::Srlw: return rrr("srlw");
    case Op::Sraw: return rrr("sraw");

    case Op::Fence: return "fence";
    case Op::FenceI: return "fence.i";
    case Op::Ecall: return "ecall";
    case Op::Ebreak: return "ebreak";

    case Op::Csrrw: return csr_rr("csrrw");
    case Op::Csrrs:
      if (in.rs1 == 0) return std::format("csrr {},{}", rd, csr_name(u32(imm)));
      return csr_rr("csrrs");
    case Op::Csrrc: return csr_rr("csrrc");
    case Op::Csrrwi: return csr_ri("csrrwi");
    case Op::Csrrsi: return csr_ri("csrrsi");
    case Op::Csrrci: return csr_ri("csrrci");

    case Op::Mul: return rrr("mul");
    case Op::Mulh: return rrr("mulh");
    case Op::Mulhsu: return rrr("mulhsu");
    case Op::Mulhu: return rrr("mulhu");
    case Op::Div: return rrr("div");
    case Op::Divu: return rrr("divu");
    case Op::Rem: return rrr("rem");
    case Op::Remu: return rrr("remu");
    case Op::Mulw: return rrr("mulw");
    case Op::Divw: return rrr("divw");
    case Op::Divuw: return rrr("divuw");
    case Op::Remw: return rrr("remw");
    case Op::Remuw: return rrr("remuw");

    case Op::LrW: return std::format("lr.w {},({})", rd, rs1);
    case Op::LrD: return std::format("lr.d {},({})", rd, rs1);
    case Op::ScW: return amo("sc.w");
    case Op::ScD: return amo("sc.d");
    case Op::AmoswapW: return amo("amoswap.w");
    case Op::AmoaddW: return amo("amoadd.w");
    case Op::AmoxorW: return amo("amoxor.w");
    case Op::AmoandW: return amo("amoand.w");
    case Op::AmoorW: return amo("amoor.w");
    case Op::AmominW: return amo("amomin.w");
    case Op::AmomaxW: return amo("amomax.w");
    case Op::AmominuW: return amo("amominu.w");
    case Op::AmomaxuW: return amo("amomaxu.w");
    case Op::AmoswapD: return amo("amoswap.d");
    case Op::AmoaddD: return amo("amoadd.d");
    case Op::AmoxorD: return amo("amoxor.d");
    case Op::AmoandD: return amo("amoand.d");
    case Op::AmoorD: return amo("amoor.d");
    case Op::AmominD: return amo("amomin.d");
    case Op::AmomaxD: return amo("amomax.d");
    case Op::AmominuD: return amo("amominu.d");
    case Op::AmomaxuD: return amo("amomaxu.d");

    case Op::Flw: return fld_("flw");
    case Op::Fld: return fld_("fld");
    case Op::Fsw: return fst("fsw");
    case Op::Fsd: return fst("fsd");

    case Op::FaddS: return fp3("fadd.s");
    case Op::FsubS: return fp3("fsub.s");
    case Op::FmulS: return fp3("fmul.s");
    case Op::FdivS: return fp3("fdiv.s");
    case Op::FsqrtS: return fp2("fsqrt.s");
    case Op::FaddD: return fp3("fadd.d");
    case Op::FsubD: return fp3("fsub.d");
    case Op::FmulD: return fp3("fmul.d");
    case Op::FdivD: return fp3("fdiv.d");
    case Op::FsqrtD: return fp2("fsqrt.d");

    case Op::FmaddS: return fp4("fmadd.s");
    case Op::FmsubS: return fp4("fmsub.s");
    case Op::FnmsubS: return fp4("fnmsub.s");
    case Op::FnmaddS: return fp4("fnmadd.s");
    case Op::FmaddD: return fp4("fmadd.d");
    case Op::FmsubD: return fp4("fmsub.d");
    case Op::FnmsubD: return fp4("fnmsub.d");
    case Op::FnmaddD: return fp4("fnmadd.d");

    case Op::FsgnjS:
      if (in.rs1 == in.rs2) return std::format("fmv.s {},{}", fd, fs1);
      return std::format("fsgnj.s {},{},{}", fd, fs1, fs2);
    case Op::FsgnjnS:
      if (in.rs1 == in.rs2) return std::format("fneg.s {},{}", fd, fs1);
      return std::format("fsgnjn.s {},{},{}", fd, fs1, fs2);
    case Op::FsgnjxS:
      if (in.rs1 == in.rs2) return std::format("fabs.s {},{}", fd, fs1);
      return std::format("fsgnjx.s {},{},{}", fd, fs1, fs2);
    case Op::FsgnjD:
      if (in.rs1 == in.rs2) return std::format("fmv.d {},{}", fd, fs1);
      return std::format("fsgnj.d {},{},{}", fd, fs1, fs2);
    case Op::FsgnjnD:
      if (in.rs1 == in.rs2) return std::format("fneg.d {},{}", fd, fs1);
      return std::format("fsgnjn.d {},{},{}", fd, fs1, fs2);
    case Op::FsgnjxD:
      if (in.rs1 == in.rs2) return std::format("fabs.d {},{}", fd, fs1);
      return std::format("fsgnjx.d {},{},{}", fd, fs1, fs2);

    case Op::FminS: return std::format("fmin.s {},{},{}", fd, fs1, fs2);
    case Op::FmaxS: return std::format("fmax.s {},{},{}", fd, fs1, fs2);
    case Op::FminD: return std::format("fmin.d {},{},{}", fd, fs1, fs2);
    case Op::FmaxD: return std::format("fmax.d {},{},{}", fd, fs1, fs2);

    case Op::FeqS: return fcmp("feq.s");
    case Op::FltS: return fcmp("flt.s");
    case Op::FleS: return fcmp("fle.s");
    case Op::FeqD: return fcmp("feq.d");
    case Op::FltD: return fcmp("flt.d");
    case Op::FleD: return fcmp("fle.d");

    case Op::FclassS: return std::format("fclass.s {},{}", rd, fs1);
    case Op::FclassD: return std::format("fclass.d {},{}", rd, fs1);
    case Op::FmvXW: return std::format("fmv.x.w {},{}", rd, fs1);
    case Op::FmvXD: return std::format("fmv.x.d {},{}", rd, fs1);
    case Op::FmvWX: return std::format("fmv.w.x {},{}", fd, rs1);
    case Op::FmvDX: return std::format("fmv.d.x {},{}", fd, rs1);

    case Op::FcvtSD: return fp2("fcvt.s.d");
    case Op::FcvtDS: return fp2("fcvt.d.s");

    case Op::FcvtWS: return std::format("fcvt.w.s {},{}{}", rd, fs1, rm_suffix(in.rm));
    case Op::FcvtWuS: return std::format("fcvt.wu.s {},{}{}", rd, fs1, rm_suffix(in.rm));
    case Op::FcvtLS: return std::format("fcvt.l.s {},{}{}", rd, fs1, rm_suffix(in.rm));
    case Op::FcvtLuS: return std::format("fcvt.lu.s {},{}{}", rd, fs1, rm_suffix(in.rm));
    case Op::FcvtWD: return std::format("fcvt.w.d {},{}{}", rd, fs1, rm_suffix(in.rm));
    case Op::FcvtWuD: return std::format("fcvt.wu.d {},{}{}", rd, fs1, rm_suffix(in.rm));
    case Op::FcvtLD: return std::format("fcvt.l.d {},{}{}", rd, fs1, rm_suffix(in.rm));
    case Op::FcvtLuD: return std::format("fcvt.lu.d {},{}{}", rd, fs1, rm_suffix(in.rm));

    case Op::FcvtSW: return std::format("fcvt.s.w {},{}{}", fd, rs1, rm_suffix(in.rm));
    case Op::FcvtSWu: return std::format("fcvt.s.wu {},{}{}", fd, rs1, rm_suffix(in.rm));
    case Op::FcvtSL: return std::format("fcvt.s.l {},{}{}", fd, rs1, rm_suffix(in.rm));
    case Op::FcvtSLu: return std::format("fcvt.s.lu {},{}{}", fd, rs1, rm_suffix(in.rm));
    case Op::FcvtDW: return std::format("fcvt.d.w {},{}{}", fd, rs1, rm_suffix(in.rm));
    case Op::FcvtDWu: return std::format("fcvt.d.wu {},{}{}", fd, rs1, rm_suffix(in.rm));
    case Op::FcvtDL: return std::format("fcvt.d.l {},{}{}", fd, rs1, rm_suffix(in.rm));
    case Op::FcvtDLu: return std::format("fcvt.d.lu {},{}{}", fd, rs1, rm_suffix(in.rm));
  }
  return "???";
}

}  // namespace rvemu
