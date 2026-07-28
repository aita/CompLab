// Assembler partition — a RISC-V assembler, so a `.s` file is directly runnable.
//
// The point of this file is that `rvemu prog.s` needs no toolchain. It accepts
// the GNU as dialect that hand-written and compiler-emitted RISC-V assembly
// actually uses: the RV64GC mnemonics, the pseudo-instructions, the usual
// directives, `%hi`/`%lo`/`%pcrel_hi`/`%pcrel_lo`, and numeric local labels.
//
// It assembles without relaxation, and that is what keeps it small. Every
// instruction's size follows from its *syntax* rather than from any symbol
// value -- `call` is always eight bytes, `la` is always eight, and `li` expands
// from a literal already in hand -- so the layout can be fixed before a single
// symbol is known. The one rule this imposes on the input is that `li` takes an
// absolute expression: `li a0, some_label` would change size once the label had
// a value, so it is an error rather than a silent mislayout. (`la` is the
// instruction for that, and it is what you wanted anyway.)
//
// Three walks, not two. The first measures the sections, the second re-runs with
// the section bases assigned so that every label -- including the ones referred
// to before they are defined -- ends up with its final address, and the third
// emits for real with a complete symbol table. Only the third reports errors.
//
// Sections are laid out back to back from 0x10000, where a linked RISC-V ELF's
// text conventionally starts, each on its own page so permissions are
// per-section and `.align` means the same thing in every pass.
export module rvemu:assembler;

import std;
import :common;
import :memory;
import :cpu;
import :decode;
import :elf;

export namespace rvemu {

inline constexpr u64 kAsmTextBase = 0x10000;

namespace as {

// -- statements --------------------------------------------------------------

// The labels that precede a statement, and either a directive or an instruction
// with its operands already split on top-level commas.
struct Stmt {
  unsigned line = 0;
  std::vector<std::string> labels;
  std::string op;
  std::vector<std::string> operands;
};

inline bool ident_start(char c) {
  return std::isalpha(static_cast<unsigned char>(c)) || c == '_' || c == '.' || c == '$';
}
inline bool ident_char(char c) {
  return std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '.' || c == '$';
}

inline void trim(std::string& t) {
  const auto b = t.find_first_not_of(" \t");
  const auto e = t.find_last_not_of(" \t");
  t = (b == std::string::npos) ? std::string{} : t.substr(b, e - b + 1);
}

// Split on commas that are not inside parentheses or quotes.
inline std::vector<std::string> split_operands(std::string_view s) {
  std::vector<std::string> out;
  int depth = 0;
  bool in_str = false, in_chr = false;
  std::string cur;
  for (std::size_t i = 0; i < s.size(); ++i) {
    const char c = s[i];
    if (in_str || in_chr) {
      cur.push_back(c);
      if (c == '\\' && i + 1 < s.size()) cur.push_back(s[++i]);
      else if (in_str && c == '"') in_str = false;
      else if (in_chr && c == '\'') in_chr = false;
      continue;
    }
    if (c == '"') { in_str = true; cur.push_back(c); continue; }
    if (c == '\'') { in_chr = true; cur.push_back(c); continue; }
    if (c == '(') ++depth;
    if (c == ')') --depth;
    if (c == ',' && depth == 0) {
      out.push_back(cur);
      cur.clear();
      continue;
    }
    cur.push_back(c);
  }
  if (!cur.empty() || !out.empty()) out.push_back(cur);
  for (std::string& t : out) trim(t);
  if (out.size() == 1 && out[0].empty()) out.clear();
  return out;
}

// Strip comments, honour `;` as a statement separator, peel labels off the
// front, and split what is left into a mnemonic and its operands.
inline std::vector<Stmt> tokenize(std::string_view src, Diag& d) {
  std::vector<Stmt> stmts;
  unsigned line = 1, stmt_line = 1;
  std::size_t i = 0;
  std::string cur;
  std::vector<std::string> pending;

  auto flush = [&]() {
    std::string body = cur;
    trim(body);
    cur.clear();
    if (body.empty()) {
      if (!pending.empty()) {
        stmts.push_back(Stmt{stmt_line, std::move(pending), {}, {}});
        pending.clear();
      }
      return;
    }
    std::size_t k = 0;
    while (k < body.size() && !std::isspace(static_cast<unsigned char>(body[k]))) ++k;
    Stmt s;
    s.line = stmt_line;
    s.labels = std::move(pending);
    pending.clear();
    s.op = body.substr(0, k);
    s.operands = split_operands(std::string_view(body).substr(k));
    stmts.push_back(std::move(s));
  };

  while (i < src.size()) {
    const char c = src[i];
    if (c == '\n') {
      flush();
      stmt_line = ++line;
      ++i;
      continue;
    }
    if (c == '#' || (c == '/' && i + 1 < src.size() && src[i + 1] == '/')) {
      while (i < src.size() && src[i] != '\n') ++i;
      continue;
    }
    if (c == '/' && i + 1 < src.size() && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) {
        if (src[i] == '\n') ++line;
        ++i;
      }
      i = std::min(i + 2, src.size());
      continue;
    }
    if (c == ';') {
      flush();
      stmt_line = line;
      ++i;
      continue;
    }
    if (c == '"' || c == '\'') {  // copy string and char literals through whole
      const char quote = c;
      cur.push_back(src[i++]);
      while (i < src.size() && src[i] != quote) {
        if (src[i] == '\\' && i + 1 < src.size()) cur.push_back(src[i++]);
        cur.push_back(src[i++]);
      }
      if (i < src.size()) cur.push_back(src[i++]);
      continue;
    }
    if (c == ':') {
      std::string name = cur;
      trim(name);
      if (name.empty()) {
        d.fail_at(line, "empty label");
        return stmts;
      }
      pending.push_back(name);
      stmt_line = line;
      cur.clear();
      ++i;
      continue;
    }
    cur.push_back(c);
    ++i;
  }
  flush();
  return stmts;
}

// -- expressions -------------------------------------------------------------

// The relocation wrappers an operand can carry.
enum class Reloc : u8 { None, Hi, Lo, PcrelHi, PcrelLo };

struct Operand {
  Reloc reloc = Reloc::None;
  i64 value = 0;
};

// Recursive-descent evaluator. Symbols come from `lookup`, which returns false
// for a name it does not know; during the layout walks that is normal and the
// value stands in as zero, since nothing about layout depends on it.
class Eval {
 public:
  using Lookup = std::function<bool(std::string_view, i64&)>;

  Eval(std::string_view s, Lookup lookup, Diag& d, unsigned line)
      : s_(s), lookup_(std::move(lookup)), d_(d), line_(line) {}

  Operand parse() {
    skip();
    if (peek() == '%') {
      const std::size_t save = i_;
      ++i_;
      std::string name;
      while (i_ < s_.size() && ident_char(s_[i_])) name.push_back(s_[i_++]);
      skip();
      Reloc r = Reloc::None;
      if (name == "hi") r = Reloc::Hi;
      else if (name == "lo") r = Reloc::Lo;
      else if (name == "pcrel_hi") r = Reloc::PcrelHi;
      else if (name == "pcrel_lo") r = Reloc::PcrelLo;
      if (r != Reloc::None) {
        if (peek() != '(') {
          d_.fail_at(line_, std::format("%{} needs a parenthesised operand", name));
          return {};
        }
        ++i_;
        const i64 v = expr();
        skip();
        if (peek() != ')') {
          d_.fail_at(line_, "missing ')'");
          return {};
        }
        ++i_;
        skip();
        if (i_ != s_.size()) {
          d_.fail_at(line_, "trailing text after relocation");
          return {};
        }
        return Operand{r, v};
      }
      if (!name.empty()) {
        d_.fail_at(line_, std::format("unknown relocation %{}", name));
        return {};
      }
      i_ = save;  // a bare '%' is the modulo operator; let expr() have it
    }
    const i64 v = expr();
    skip();
    if (i_ != s_.size()) {
      d_.fail_at(line_, std::format("cannot parse expression '{}'", s_));
      return {};
    }
    return Operand{Reloc::None, v};
  }

 private:
  std::string_view s_;
  Lookup lookup_;
  Diag& d_;
  unsigned line_;
  std::size_t i_ = 0;

  void skip() {
    while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\t')) ++i_;
  }
  char peek() const { return i_ < s_.size() ? s_[i_] : '\0'; }
  bool eat(std::string_view t) {
    skip();
    if (s_.substr(i_, t.size()) == t) {
      i_ += t.size();
      return true;
    }
    return false;
  }

  i64 expr() { return bit_or(); }
  i64 bit_or() {
    i64 v = bit_xor();
    while (peek_op('|')) { ++i_; v |= bit_xor(); }
    return v;
  }
  i64 bit_xor() {
    i64 v = bit_and();
    while (eat("^")) v ^= bit_and();
    return v;
  }
  i64 bit_and() {
    i64 v = shift();
    while (peek_op('&')) { ++i_; v &= shift(); }
    return v;
  }
  // A single '|' or '&', not the doubled logical form.
  bool peek_op(char c) {
    skip();
    return peek() == c && !(i_ + 1 < s_.size() && s_[i_ + 1] == c);
  }
  i64 shift() {
    i64 v = additive();
    for (;;) {
      if (eat("<<")) v = i64(u64(v) << (additive() & 63));
      else if (eat(">>")) v >>= (additive() & 63);
      else break;
    }
    return v;
  }
  i64 additive() {
    i64 v = multiplicative();
    for (;;) {
      skip();
      if (peek() == '+') { ++i_; v += multiplicative(); }
      else if (peek() == '-') { ++i_; v -= multiplicative(); }
      else break;
    }
    return v;
  }
  i64 multiplicative() {
    i64 v = unary();
    for (;;) {
      skip();
      if (peek() == '*') { ++i_; v *= unary(); }
      else if (peek() == '/') {
        ++i_;
        const i64 r = unary();
        v = r ? v / r : 0;
      } else if (peek() == '%') {
        ++i_;
        const i64 r = unary();
        v = r ? v % r : 0;
      } else break;
    }
    return v;
  }
  i64 unary() {
    skip();
    if (peek() == '-') { ++i_; return -unary(); }
    if (peek() == '+') { ++i_; return unary(); }
    if (peek() == '~') { ++i_; return ~unary(); }
    return primary();
  }
  i64 primary() {
    skip();
    if (peek() == '(') {
      ++i_;
      const i64 v = expr();
      skip();
      if (peek() == ')') ++i_;
      else d_.fail_at(line_, "missing ')'");
      return v;
    }
    if (peek() == '\'') return char_literal();
    if (std::isdigit(static_cast<unsigned char>(peek()))) return number();
    if (ident_start(peek())) {
      std::string name;
      while (i_ < s_.size() && ident_char(s_[i_])) name.push_back(s_[i_++]);
      i64 v = 0;
      if (!lookup_(name, v)) {
        d_.fail_at(line_, std::format("undefined symbol '{}'", name));
        return 0;
      }
      return v;
    }
    d_.fail_at(line_, std::format("cannot parse expression '{}'", s_));
    return 0;
  }

  // A digit starts either a number or a local label reference like `1f`.
  i64 number() {
    const std::size_t start = i_;
    if (s_[i_] == '0' && i_ + 1 < s_.size() && (s_[i_ + 1] | 32) == 'x') {
      i_ += 2;
      u64 v = 0;
      while (i_ < s_.size() && std::isxdigit(static_cast<unsigned char>(s_[i_]))) {
        const char c = s_[i_++];
        v = v * 16 + u64(std::isdigit(static_cast<unsigned char>(c))
                             ? c - '0'
                             : (c | 32) - 'a' + 10);
      }
      return i64(v);
    }
    if (s_[i_] == '0' && i_ + 2 < s_.size() && (s_[i_ + 1] | 32) == 'b' &&
        (s_[i_ + 2] == '0' || s_[i_ + 2] == '1')) {
      i_ += 2;
      u64 v = 0;
      while (i_ < s_.size() && (s_[i_] == '0' || s_[i_] == '1')) {
        v = v * 2 + u64(s_[i_++] - '0');
      }
      return i64(v);
    }
    u64 dec = 0;
    while (i_ < s_.size() && std::isdigit(static_cast<unsigned char>(s_[i_]))) {
      dec = dec * 10 + u64(s_[i_++] - '0');
    }
    if (i_ < s_.size() && (s_[i_] == 'f' || s_[i_] == 'b') &&
        (i_ + 1 == s_.size() || !ident_char(s_[i_ + 1]))) {
      const std::string ref(s_.substr(start, i_ + 1 - start));
      ++i_;
      i64 out = 0;
      if (!lookup_(ref, out)) {
        d_.fail_at(line_, std::format("no local label '{}'", ref));
        return 0;
      }
      return out;
    }
    if (start + 1 < i_ && s_[start] == '0') {  // octal
      u64 o = 0;
      for (std::size_t k = start + 1; k < i_; ++k) o = o * 8 + u64(s_[k] - '0');
      return i64(o);
    }
    return i64(dec);
  }

  i64 char_literal() {
    ++i_;
    if (i_ >= s_.size()) return 0;
    char c = s_[i_++];
    if (c == '\\' && i_ < s_.size()) c = unescape(s_[i_++]);
    if (i_ < s_.size() && s_[i_] == '\'') ++i_;
    return i64(static_cast<unsigned char>(c));
  }

 public:
  static char unescape(char e) {
    switch (e) {
      case 'n': return '\n';
      case 't': return '\t';
      case 'r': return '\r';
      case '0': return '\0';
      case 'a': return '\a';
      case 'b': return '\b';
      case 'f': return '\f';
      case 'v': return '\v';
      default: return e;
    }
  }
};

// Unescape a "..." literal from .string / .ascii.
inline std::string unquote(std::string_view s, Diag& d, unsigned line) {
  if (s.size() < 2 || s.front() != '"' || s.back() != '"') {
    d.fail_at(line, "expected a quoted string");
    return {};
  }
  std::string out;
  const std::size_t last = s.size() - 1;
  for (std::size_t i = 1; i < last; ++i) {
    if (s[i] != '\\') {
      out.push_back(s[i]);
      continue;
    }
    if (++i >= last) break;
    if (s[i] == 'x') {
      int v = 0, n = 0;
      while (i + 1 < last && n < 2 && std::isxdigit(static_cast<unsigned char>(s[i + 1]))) {
        const char h = s[++i];
        v = v * 16 + (std::isdigit(static_cast<unsigned char>(h)) ? h - '0'
                                                                 : (h | 32) - 'a' + 10);
        ++n;
      }
      out.push_back(static_cast<char>(v));
      continue;
    }
    out.push_back(Eval::unescape(s[i]));
  }
  return out;
}

// -- registers ---------------------------------------------------------------

inline bool parse_xreg(std::string_view s, u8& out) {
  if (s.size() >= 2 && s[0] == 'x' && std::isdigit(static_cast<unsigned char>(s[1]))) {
    unsigned v = 0;
    if (std::from_chars(s.data() + 1, s.data() + s.size(), v).ec == std::errc{} && v < 32) {
      out = static_cast<u8>(v);
      return true;
    }
  }
  if (s == "fp") {  // the usual alias for s0
    out = 8;
    return true;
  }
  for (unsigned i = 0; i < 32; ++i) {
    if (s == kXRegNames[i]) {
      out = static_cast<u8>(i);
      return true;
    }
  }
  return false;
}

inline bool parse_freg(std::string_view s, u8& out) {
  if (s.size() >= 2 && s[0] == 'f' && std::isdigit(static_cast<unsigned char>(s[1]))) {
    unsigned v = 0;
    if (std::from_chars(s.data() + 1, s.data() + s.size(), v).ec == std::errc{} && v < 32) {
      out = static_cast<u8>(v);
      return true;
    }
  }
  for (unsigned i = 0; i < 32; ++i) {
    if (s == kFRegNames[i]) {
      out = static_cast<u8>(i);
      return true;
    }
  }
  return false;
}

inline bool parse_rm(std::string_view s, u8& out) {
  if (s == "rne") { out = RmRNE; return true; }
  if (s == "rtz") { out = RmRTZ; return true; }
  if (s == "rdn") { out = RmRDN; return true; }
  if (s == "rup") { out = RmRUP; return true; }
  if (s == "rmm") { out = RmRMM; return true; }
  if (s == "dyn") { out = RmDYN; return true; }
  return false;
}

// -- the mnemonic table ------------------------------------------------------

enum class Fmt : u8 {
  R,       // rd, rs1, rs2
  Shift,   // rd, rs1, shamt (6-bit, funct6)
  ShiftW,  // rd, rs1, shamt (5-bit, funct7)
  I,       // rd, rs1, imm
  Load,    // rd, imm(rs1) -- or `rd, symbol`, which becomes auipc + load
  Store,   // rs2, imm(rs1) -- or `rs2, symbol, rt`
  Branch,  // rs1, rs2, target
  U,       // rd, imm20
  Jal,     // [rd,] target
  Jalr,    // rd, imm(rs1) / rd, rs1[, imm] / rs1
  Fence,
  System,  // ecall / ebreak
  Csr,     // rd, csr, rs1
  Csri,    // rd, csr, zimm
  Amo,     // rd, rs2, (rs1)
  Lr,      // rd, (rs1)
  FLoad,   // fd, imm(rs1)
  FStore,  // fs2, imm(rs1)
  FpR3,    // fd, fs1, fs2 [,rm]
  FpR2,    // fd, fs1 [,rm]      (rs2 fixed by the table)
  FpR4,    // fd, fs1, fs2, fs3 [,rm]
  FpCmp,   // rd, fs1, fs2
  FpF2X,   // rd, fs1 [,rm]
  FpX2F,   // fd, rs1 [,rm]
};

struct Enc {
  Fmt fmt;
  u32 opcode;
  u32 f3;
  u32 f7;       // funct7; for AMO the bare funct5; for FpR4 the format bit
  u32 rs2 = 0;      // the fixed rs2 field of the single-operand FP encodings
  bool rm = false;  // does f3 carry the rounding mode?
  // The mode to encode when the source names none. Widening conversions that
  // can never round are RNE rather than dynamic, matching GNU as.
  u8 drm = RmDYN;
};

// OP-FP packs funct5 and the format into funct7.
constexpr u32 fp7(u32 funct5, u32 fmt) { return (funct5 << 2) | fmt; }

inline const std::unordered_map<std::string, Enc>& table() {
  static const std::unordered_map<std::string, Enc> t = {
      {"lui", {Fmt::U, 0x37, 0, 0}},
      {"auipc", {Fmt::U, 0x17, 0, 0}},
      {"jal", {Fmt::Jal, 0x6f, 0, 0}},
      {"jalr", {Fmt::Jalr, 0x67, 0, 0}},
      {"beq", {Fmt::Branch, 0x63, 0, 0}},
      {"bne", {Fmt::Branch, 0x63, 1, 0}},
      {"blt", {Fmt::Branch, 0x63, 4, 0}},
      {"bge", {Fmt::Branch, 0x63, 5, 0}},
      {"bltu", {Fmt::Branch, 0x63, 6, 0}},
      {"bgeu", {Fmt::Branch, 0x63, 7, 0}},
      {"lb", {Fmt::Load, 0x03, 0, 0}},
      {"lh", {Fmt::Load, 0x03, 1, 0}},
      {"lw", {Fmt::Load, 0x03, 2, 0}},
      {"ld", {Fmt::Load, 0x03, 3, 0}},
      {"lbu", {Fmt::Load, 0x03, 4, 0}},
      {"lhu", {Fmt::Load, 0x03, 5, 0}},
      {"lwu", {Fmt::Load, 0x03, 6, 0}},
      {"sb", {Fmt::Store, 0x23, 0, 0}},
      {"sh", {Fmt::Store, 0x23, 1, 0}},
      {"sw", {Fmt::Store, 0x23, 2, 0}},
      {"sd", {Fmt::Store, 0x23, 3, 0}},
      {"addi", {Fmt::I, 0x13, 0, 0}},
      {"slti", {Fmt::I, 0x13, 2, 0}},
      {"sltiu", {Fmt::I, 0x13, 3, 0}},
      {"xori", {Fmt::I, 0x13, 4, 0}},
      {"ori", {Fmt::I, 0x13, 6, 0}},
      {"andi", {Fmt::I, 0x13, 7, 0}},
      {"slli", {Fmt::Shift, 0x13, 1, 0x00}},
      {"srli", {Fmt::Shift, 0x13, 5, 0x00}},
      {"srai", {Fmt::Shift, 0x13, 5, 0x10}},
      {"add", {Fmt::R, 0x33, 0, 0x00}},
      {"sub", {Fmt::R, 0x33, 0, 0x20}},
      {"sll", {Fmt::R, 0x33, 1, 0x00}},
      {"slt", {Fmt::R, 0x33, 2, 0x00}},
      {"sltu", {Fmt::R, 0x33, 3, 0x00}},
      {"xor", {Fmt::R, 0x33, 4, 0x00}},
      {"srl", {Fmt::R, 0x33, 5, 0x00}},
      {"sra", {Fmt::R, 0x33, 5, 0x20}},
      {"or", {Fmt::R, 0x33, 6, 0x00}},
      {"and", {Fmt::R, 0x33, 7, 0x00}},
      {"addiw", {Fmt::I, 0x1b, 0, 0}},
      {"slliw", {Fmt::ShiftW, 0x1b, 1, 0x00}},
      {"srliw", {Fmt::ShiftW, 0x1b, 5, 0x00}},
      {"sraiw", {Fmt::ShiftW, 0x1b, 5, 0x20}},
      {"addw", {Fmt::R, 0x3b, 0, 0x00}},
      {"subw", {Fmt::R, 0x3b, 0, 0x20}},
      {"sllw", {Fmt::R, 0x3b, 1, 0x00}},
      {"srlw", {Fmt::R, 0x3b, 5, 0x00}},
      {"sraw", {Fmt::R, 0x3b, 5, 0x20}},
      {"fence", {Fmt::Fence, 0x0f, 0, 0}},
      {"fence.i", {Fmt::Fence, 0x0f, 1, 0}},
      {"ecall", {Fmt::System, 0x73, 0, 0}},
      {"ebreak", {Fmt::System, 0x73, 0, 1}},

      {"csrrw", {Fmt::Csr, 0x73, 1, 0}},
      {"csrrs", {Fmt::Csr, 0x73, 2, 0}},
      {"csrrc", {Fmt::Csr, 0x73, 3, 0}},
      {"csrrwi", {Fmt::Csri, 0x73, 5, 0}},
      {"csrrsi", {Fmt::Csri, 0x73, 6, 0}},
      {"csrrci", {Fmt::Csri, 0x73, 7, 0}},

      {"mul", {Fmt::R, 0x33, 0, 0x01}},
      {"mulh", {Fmt::R, 0x33, 1, 0x01}},
      {"mulhsu", {Fmt::R, 0x33, 2, 0x01}},
      {"mulhu", {Fmt::R, 0x33, 3, 0x01}},
      {"div", {Fmt::R, 0x33, 4, 0x01}},
      {"divu", {Fmt::R, 0x33, 5, 0x01}},
      {"rem", {Fmt::R, 0x33, 6, 0x01}},
      {"remu", {Fmt::R, 0x33, 7, 0x01}},
      {"mulw", {Fmt::R, 0x3b, 0, 0x01}},
      {"divw", {Fmt::R, 0x3b, 4, 0x01}},
      {"divuw", {Fmt::R, 0x3b, 5, 0x01}},
      {"remw", {Fmt::R, 0x3b, 6, 0x01}},
      {"remuw", {Fmt::R, 0x3b, 7, 0x01}},

      // A. f7 holds the bare funct5; the aq/rl bits are added at emit time.
      {"lr.w", {Fmt::Lr, 0x2f, 2, 0x02}},
      {"lr.d", {Fmt::Lr, 0x2f, 3, 0x02}},
      {"sc.w", {Fmt::Amo, 0x2f, 2, 0x03}},
      {"sc.d", {Fmt::Amo, 0x2f, 3, 0x03}},
      {"amoswap.w", {Fmt::Amo, 0x2f, 2, 0x01}},
      {"amoadd.w", {Fmt::Amo, 0x2f, 2, 0x00}},
      {"amoxor.w", {Fmt::Amo, 0x2f, 2, 0x04}},
      {"amoand.w", {Fmt::Amo, 0x2f, 2, 0x0c}},
      {"amoor.w", {Fmt::Amo, 0x2f, 2, 0x08}},
      {"amomin.w", {Fmt::Amo, 0x2f, 2, 0x10}},
      {"amomax.w", {Fmt::Amo, 0x2f, 2, 0x14}},
      {"amominu.w", {Fmt::Amo, 0x2f, 2, 0x18}},
      {"amomaxu.w", {Fmt::Amo, 0x2f, 2, 0x1c}},
      {"amoswap.d", {Fmt::Amo, 0x2f, 3, 0x01}},
      {"amoadd.d", {Fmt::Amo, 0x2f, 3, 0x00}},
      {"amoxor.d", {Fmt::Amo, 0x2f, 3, 0x04}},
      {"amoand.d", {Fmt::Amo, 0x2f, 3, 0x0c}},
      {"amoor.d", {Fmt::Amo, 0x2f, 3, 0x08}},
      {"amomin.d", {Fmt::Amo, 0x2f, 3, 0x10}},
      {"amomax.d", {Fmt::Amo, 0x2f, 3, 0x14}},
      {"amominu.d", {Fmt::Amo, 0x2f, 3, 0x18}},
      {"amomaxu.d", {Fmt::Amo, 0x2f, 3, 0x1c}},

      {"flw", {Fmt::FLoad, 0x07, 2, 0}},
      {"fld", {Fmt::FLoad, 0x07, 3, 0}},
      {"fsw", {Fmt::FStore, 0x27, 2, 0}},
      {"fsd", {Fmt::FStore, 0x27, 3, 0}},

      {"fadd.s", {Fmt::FpR3, 0x53, 0, fp7(0x00, 0), 0, true}},
      {"fsub.s", {Fmt::FpR3, 0x53, 0, fp7(0x01, 0), 0, true}},
      {"fmul.s", {Fmt::FpR3, 0x53, 0, fp7(0x02, 0), 0, true}},
      {"fdiv.s", {Fmt::FpR3, 0x53, 0, fp7(0x03, 0), 0, true}},
      {"fsqrt.s", {Fmt::FpR2, 0x53, 0, fp7(0x0b, 0), 0, true}},
      {"fadd.d", {Fmt::FpR3, 0x53, 0, fp7(0x00, 1), 0, true}},
      {"fsub.d", {Fmt::FpR3, 0x53, 0, fp7(0x01, 1), 0, true}},
      {"fmul.d", {Fmt::FpR3, 0x53, 0, fp7(0x02, 1), 0, true}},
      {"fdiv.d", {Fmt::FpR3, 0x53, 0, fp7(0x03, 1), 0, true}},
      {"fsqrt.d", {Fmt::FpR2, 0x53, 0, fp7(0x0b, 1), 0, true}},
      {"fsgnj.s", {Fmt::FpR3, 0x53, 0, fp7(0x04, 0)}},
      {"fsgnjn.s", {Fmt::FpR3, 0x53, 1, fp7(0x04, 0)}},
      {"fsgnjx.s", {Fmt::FpR3, 0x53, 2, fp7(0x04, 0)}},
      {"fsgnj.d", {Fmt::FpR3, 0x53, 0, fp7(0x04, 1)}},
      {"fsgnjn.d", {Fmt::FpR3, 0x53, 1, fp7(0x04, 1)}},
      {"fsgnjx.d", {Fmt::FpR3, 0x53, 2, fp7(0x04, 1)}},
      {"fmin.s", {Fmt::FpR3, 0x53, 0, fp7(0x05, 0)}},
      {"fmax.s", {Fmt::FpR3, 0x53, 1, fp7(0x05, 0)}},
      {"fmin.d", {Fmt::FpR3, 0x53, 0, fp7(0x05, 1)}},
      {"fmax.d", {Fmt::FpR3, 0x53, 1, fp7(0x05, 1)}},

      {"fmadd.s", {Fmt::FpR4, 0x43, 0, 0, 0, true}},
      {"fmsub.s", {Fmt::FpR4, 0x47, 0, 0, 0, true}},
      {"fnmsub.s", {Fmt::FpR4, 0x4b, 0, 0, 0, true}},
      {"fnmadd.s", {Fmt::FpR4, 0x4f, 0, 0, 0, true}},
      {"fmadd.d", {Fmt::FpR4, 0x43, 0, 1, 0, true}},
      {"fmsub.d", {Fmt::FpR4, 0x47, 0, 1, 0, true}},
      {"fnmsub.d", {Fmt::FpR4, 0x4b, 0, 1, 0, true}},
      {"fnmadd.d", {Fmt::FpR4, 0x4f, 0, 1, 0, true}},

      {"fle.s", {Fmt::FpCmp, 0x53, 0, fp7(0x14, 0)}},
      {"flt.s", {Fmt::FpCmp, 0x53, 1, fp7(0x14, 0)}},
      {"feq.s", {Fmt::FpCmp, 0x53, 2, fp7(0x14, 0)}},
      {"fle.d", {Fmt::FpCmp, 0x53, 0, fp7(0x14, 1)}},
      {"flt.d", {Fmt::FpCmp, 0x53, 1, fp7(0x14, 1)}},
      {"feq.d", {Fmt::FpCmp, 0x53, 2, fp7(0x14, 1)}},

      {"fmv.x.w", {Fmt::FpF2X, 0x53, 0, fp7(0x1c, 0)}},
      {"fclass.s", {Fmt::FpF2X, 0x53, 1, fp7(0x1c, 0)}},
      {"fmv.x.d", {Fmt::FpF2X, 0x53, 0, fp7(0x1c, 1)}},
      {"fclass.d", {Fmt::FpF2X, 0x53, 1, fp7(0x1c, 1)}},
      {"fmv.w.x", {Fmt::FpX2F, 0x53, 0, fp7(0x1e, 0)}},
      {"fmv.d.x", {Fmt::FpX2F, 0x53, 0, fp7(0x1e, 1)}},

      {"fcvt.w.s", {Fmt::FpF2X, 0x53, 0, fp7(0x18, 0), 0, true}},
      {"fcvt.wu.s", {Fmt::FpF2X, 0x53, 0, fp7(0x18, 0), 1, true}},
      {"fcvt.l.s", {Fmt::FpF2X, 0x53, 0, fp7(0x18, 0), 2, true}},
      {"fcvt.lu.s", {Fmt::FpF2X, 0x53, 0, fp7(0x18, 0), 3, true}},
      {"fcvt.w.d", {Fmt::FpF2X, 0x53, 0, fp7(0x18, 1), 0, true}},
      {"fcvt.wu.d", {Fmt::FpF2X, 0x53, 0, fp7(0x18, 1), 1, true}},
      {"fcvt.l.d", {Fmt::FpF2X, 0x53, 0, fp7(0x18, 1), 2, true}},
      {"fcvt.lu.d", {Fmt::FpF2X, 0x53, 0, fp7(0x18, 1), 3, true}},
      {"fcvt.s.w", {Fmt::FpX2F, 0x53, 0, fp7(0x1a, 0), 0, true}},
      {"fcvt.s.wu", {Fmt::FpX2F, 0x53, 0, fp7(0x1a, 0), 1, true}},
      {"fcvt.s.l", {Fmt::FpX2F, 0x53, 0, fp7(0x1a, 0), 2, true}},
      {"fcvt.s.lu", {Fmt::FpX2F, 0x53, 0, fp7(0x1a, 0), 3, true}},
      {"fcvt.d.w", {Fmt::FpX2F, 0x53, 0, fp7(0x1a, 1), 0, true, RmRNE}},
      {"fcvt.d.wu", {Fmt::FpX2F, 0x53, 0, fp7(0x1a, 1), 1, true, RmRNE}},
      {"fcvt.d.l", {Fmt::FpX2F, 0x53, 0, fp7(0x1a, 1), 2, true}},
      {"fcvt.d.lu", {Fmt::FpX2F, 0x53, 0, fp7(0x1a, 1), 3, true}},
      {"fcvt.s.d", {Fmt::FpR2, 0x53, 0, fp7(0x08, 0), 1, true}},
      {"fcvt.d.s", {Fmt::FpR2, 0x53, 0, fp7(0x08, 1), 0, true, RmRNE}},
  };
  return t;
}

}  // namespace as

// The assembler proper.
class Assembler {
 public:
  // Assemble `src` into `mem`, filling `img` with the entry point, the initial
  // break and a symbol table. Returns false with `d` set on the first error.
  bool assemble(std::string_view src, const std::string& path, Memory& mem, Image& img,
                Diag& d) {
    stmts_ = as::tokenize(src, d);
    if (d.failed) return false;
    collect_local_labels();

    // Walk once to measure, assign the section bases, walk again so every label
    // -- forward references included -- has its final address, then emit.
    if (!walk(false, d)) return false;
    assign_bases();
    if (!walk(false, d)) return false;
    if (!walk(true, d)) return false;

    for (const Section& s : sections_) {
      if (s.data.empty()) continue;
      mem.map_merge(s.base, s.data.size(), s.perm);
      mem.poke(s.base, s.data.data(), s.data.size());
      if (s.perm & PermX) img.text.push_back({s.base, s.data.size()});
    }

    img.path = path;
    img.brk = brk_;
    img.load_bias = 0;
    if (!pick_entry(img.entry, d)) return false;
    for (const auto& [name, sym] : symbols_) {
      if (sym.absolute || name.starts_with(".L")) continue;
      img.symbols.push_back(Sym{sym.value, 0, name});
    }
    img.sort_symbols();
    return true;
  }

 private:
  struct Section {
    std::string name;
    u8 perm = PermRW;
    u64 base = 0;
    std::vector<u8> data;
  };
  struct Symbol {
    u64 value = 0;
    bool absolute = false;  // from .equ, so it is not an address
    bool defined = false;
  };

  std::vector<as::Stmt> stmts_;
  std::vector<Section> sections_;
  std::map<std::string, Symbol> symbols_;
  // Numeric local labels: per digit, the statement indices that define it and
  // the unique name generated for each.
  std::map<int, std::vector<std::pair<std::size_t, std::string>>> locals_;
  // auipc address -> the target it was computed against, so %pcrel_lo can find
  // its partner.
  std::unordered_map<u64, u64> pcrel_targets_;

  // Set by lookup() when an expression touched a symbol that is an address
  // rather than an .equ constant. `li` refuses those: an address is not known
  // during the layout walks, so the expansion's size could change under it.
  bool used_address_ = false;

  std::size_t cur_sec_ = 0;
  std::size_t stmt_index_ = 0;
  bool emitting_ = false;
  u64 brk_ = 0;

  // -- sections --------------------------------------------------------------

  std::size_t section_for(std::string_view name) {
    for (std::size_t i = 0; i < sections_.size(); ++i) {
      if (sections_[i].name == name) return i;
    }
    u8 perm = PermRW;
    if (name == ".text") perm = PermRX;
    else if (name == ".rodata") perm = PermR;
    sections_.push_back(Section{std::string(name), perm, 0, {}});
    return sections_.size() - 1;
  }

  Section& sec() { return sections_[cur_sec_]; }
  u64 here() { return sec().base + sec().data.size(); }

  void assign_bases() {
    u64 addr = kAsmTextBase;
    for (Section& s : sections_) {
      s.base = addr;
      addr = align_up(addr + std::max<u64>(s.data.size(), 1), kPageSize);
    }
    brk_ = addr;
  }

  // -- symbols ---------------------------------------------------------------

  void collect_local_labels() {
    for (std::size_t i = 0; i < stmts_.size(); ++i) {
      for (const std::string& l : stmts_[i].labels) {
        if (l.size() == 1 && std::isdigit(static_cast<unsigned char>(l[0]))) {
          const int n = l[0] - '0';
          locals_[n].push_back({i, std::format(".Lnum{}_{}", n, locals_[n].size())});
        }
      }
    }
  }

  // `1f` is the next definition after this statement; `1b` the nearest at or
  // before it, which is what puts a label on the same line into `b`'s reach.
  bool resolve_local(std::string_view ref, i64& out) {
    const int n = ref[0] - '0';
    const bool forward = ref.back() == 'f';
    auto it = locals_.find(n);
    if (it == locals_.end()) return false;
    const std::string* pick = nullptr;
    for (const auto& [idx, name] : it->second) {
      if (forward) {
        if (idx > stmt_index_) { pick = &name; break; }
      } else if (idx <= stmt_index_) {
        pick = &name;
      }
    }
    if (!pick) return false;
    auto s = symbols_.find(*pick);
    if (s == symbols_.end() || !s->second.defined) {
      out = 0;
      return !emitting_;
    }
    out = i64(s->second.value);
    return true;
  }

  void define(const std::string& name, u64 value, bool absolute = false) {
    Symbol& s = symbols_[name];
    s.value = value;
    s.absolute = absolute;
    s.defined = true;
  }

  as::Eval::Lookup lookup() {
    return [this](std::string_view name, i64& out) -> bool {
      if (name.size() >= 2 && std::isdigit(static_cast<unsigned char>(name[0])) &&
          (name.back() == 'f' || name.back() == 'b')) {
        used_address_ = true;
        return resolve_local(name, out);
      }
      if (name == ".") {
        used_address_ = true;
        out = i64(here());
        return true;
      }
      auto it = symbols_.find(std::string(name));
      if (it != symbols_.end() && it->second.defined) {
        if (!it->second.absolute) used_address_ = true;
        out = i64(it->second.value);
        return true;
      }
      used_address_ = true;  // an unresolved name can only be a label
      // A layout walk has not seen forward references yet; zero stands in,
      // because no size depends on a symbol's value.
      out = 0;
      return !emitting_;
    };
  }

  bool pick_entry(u64& out, Diag& d) {
    for (std::string_view name : {"_start", "main", "start"}) {
      auto it = symbols_.find(std::string(name));
      if (it != symbols_.end() && it->second.defined && !it->second.absolute) {
        out = it->second.value;
        return true;
      }
    }
    if (sections_.empty()) {
      d.fail("the program is empty");
      return false;
    }
    out = sections_[section_for(".text")].base;
    return true;
  }

  // -- evaluation ------------------------------------------------------------

  as::Operand eval(std::string_view text, Diag& d, unsigned line) {
    used_address_ = false;
    as::Eval e(text, lookup(), d, line);
    return e.parse();
  }

  bool eval_int(std::string_view text, i64& out, Diag& d, unsigned line) {
    const as::Operand o = eval(text, d, line);
    if (d.failed) return false;
    if (o.reloc != as::Reloc::None) {
      d.fail_at(line, "a relocation is not allowed here");
      return false;
    }
    out = o.value;
    return true;
  }

  // Turn a parsed operand into the number the encoder wants. %hi/%pcrel_hi
  // produce the 20-bit field (not shifted); %lo/%pcrel_lo the sign-extended 12.
  bool relocate(const as::Operand& o, u64 pc, i64& out, Diag& d, unsigned line) {
    switch (o.reloc) {
      case as::Reloc::None:
        out = o.value;
        return true;
      // The +0x800 is what makes a following sign-extending %lo add up to the
      // address you asked for.
      case as::Reloc::Hi:
        out = i64((u64(o.value) + 0x800) >> 12) & 0xfffff;
        return true;
      case as::Reloc::Lo:
        out = sext(u64(o.value), 12);
        return true;
      case as::Reloc::PcrelHi: {
        pcrel_targets_[pc] = u64(o.value);
        const i64 delta = o.value - i64(pc);
        out = i64(((u64(delta) + 0x800) >> 12) & 0xfffff);
        return true;
      }
      case as::Reloc::PcrelLo: {
        // The operand names the auipc; the offset is measured from there.
        const u64 auipc_at = u64(o.value);
        auto it = pcrel_targets_.find(auipc_at);
        if (it == pcrel_targets_.end()) {
          if (!emitting_) {
            out = 0;
            return true;
          }
          d.fail_at(line,
                    std::format("%pcrel_lo({}) does not name an auipc", hex(auipc_at)));
          return false;
        }
        out = sext(u64(i64(it->second) - i64(auipc_at)), 12);
        return true;
      }
    }
    return false;
  }

  // -- output ----------------------------------------------------------------

  void put_bytes(const void* p, u64 n) {
    const u8* b = static_cast<const u8*>(p);
    sec().data.insert(sec().data.end(), b, b + n);
  }
  void put_zeros(u64 n) { sec().data.insert(sec().data.end(), n, u8{0}); }
  void put_u32(u32 w) { put_bytes(&w, 4); }

  void pad_to(u64 align) {
    if (align < 2) return;
    const u64 off = sec().data.size();
    put_zeros(align_up(off, align) - off);
  }

  // -- the walks -------------------------------------------------------------

  bool walk(bool emit, Diag& d) {
    emitting_ = emit;
    pcrel_targets_.clear();
    for (Section& s : sections_) s.data.clear();
    cur_sec_ = section_for(".text");

    for (stmt_index_ = 0; stmt_index_ < stmts_.size(); ++stmt_index_) {
      const as::Stmt& st = stmts_[stmt_index_];
      for (const std::string& l : st.labels) {
        if (l.size() == 1 && std::isdigit(static_cast<unsigned char>(l[0]))) {
          for (const auto& [idx, name] : locals_[l[0] - '0']) {
            if (idx == stmt_index_) define(name, here());
          }
        } else {
          define(l, here());
        }
      }
      if (st.op.empty()) continue;
      const bool ok = (st.op[0] == '.') ? directive(st, d) : instruction(st, d);
      if (!ok || d.failed) return false;
    }
    return true;
  }

  // -- directives ------------------------------------------------------------

  bool directive(const as::Stmt& st, Diag& d) {
    const std::string& op = st.op;
    const unsigned line = st.line;

    auto ints = [&](unsigned width) {
      for (const std::string& o : st.operands) {
        i64 v = 0;
        if (!eval_int(o, v, d, line)) return false;
        const u64 uv = u64(v);
        put_bytes(&uv, width);
      }
      return true;
    };

    if (op == ".text" || op == ".data" || op == ".rodata" || op == ".bss") {
      cur_sec_ = section_for(op);
      return true;
    }
    if (op == ".section") {
      if (st.operands.empty()) {
        d.fail_at(line, ".section needs a name");
        return false;
      }
      std::string name = st.operands[0];
      // ".rodata.str1.8" and friends fold into the section they belong to.
      for (std::string_view known : {".text", ".rodata", ".data", ".bss"}) {
        if (name.starts_with(known)) {
          name = std::string(known);
          break;
        }
      }
      cur_sec_ = section_for(name);
      return true;
    }
    if (op == ".byte") return ints(1);
    if (op == ".half" || op == ".short" || op == ".2byte") return ints(2);
    if (op == ".word" || op == ".long" || op == ".4byte") return ints(4);
    if (op == ".dword" || op == ".quad" || op == ".8byte") return ints(8);
    if (op == ".string" || op == ".asciz" || op == ".ascii") {
      for (const std::string& o : st.operands) {
        const std::string s = as::unquote(o, d, line);
        if (d.failed) return false;
        put_bytes(s.data(), s.size());
        if (op != ".ascii") put_zeros(1);
      }
      return true;
    }
    if (op == ".zero" || op == ".space" || op == ".skip") {
      i64 n = 0;
      if (st.operands.empty() || !eval_int(st.operands[0], n, d, line)) {
        if (!d.failed) d.fail_at(line, std::format("{} needs a size", op));
        return false;
      }
      i64 fill = 0;
      if (st.operands.size() > 1 && !eval_int(st.operands[1], fill, d, line)) return false;
      sec().data.insert(sec().data.end(), std::size_t(std::max<i64>(n, 0)), u8(fill));
      return true;
    }
    if (op == ".align" || op == ".p2align") {
      i64 n = 0;
      if (st.operands.empty() || !eval_int(st.operands[0], n, d, line)) return false;
      pad_to(u64{1} << std::clamp<i64>(n, 0, 12));
      return true;
    }
    if (op == ".balign") {
      i64 n = 0;
      if (st.operands.empty() || !eval_int(st.operands[0], n, d, line)) return false;
      pad_to(u64(std::clamp<i64>(n, 1, 4096)));
      return true;
    }
    if (op == ".equ" || op == ".set") {
      if (st.operands.size() < 2) {
        d.fail_at(line, std::format("{} needs a name and a value", op));
        return false;
      }
      i64 v = 0;
      if (!eval_int(st.operands[1], v, d, line)) return false;
      define(st.operands[0], u64(v), /*absolute=*/true);
      return true;
    }
    // Metadata a linker would want, and we are not one.
    if (op == ".globl" || op == ".global" || op == ".local" || op == ".weak" ||
        op == ".hidden" || op == ".type" || op == ".size" || op == ".file" ||
        op == ".ident" || op == ".option" || op == ".attribute" || op == ".addrsig" ||
        op == ".addrsig_sym" || op == ".comm" || op.starts_with(".cfi_")) {
      return true;
    }
    d.fail_at(line, std::format("unknown directive {}", op));
    return false;
  }

  // -- instruction helpers ---------------------------------------------------

  // "imm(reg)" -> the two halves. False when there is no parenthesis, which is
  // how `lw a0, symbol` is told apart from `lw a0, 8(sp)`.
  static bool split_mem(const std::string& s, std::string& imm, std::string& reg) {
    if (s.empty() || s.back() != ')') return false;
    const auto open = s.rfind('(');
    if (open == std::string::npos) return false;
    imm = s.substr(0, open);
    reg = s.substr(open + 1, s.size() - open - 2);
    as::trim(imm);
    as::trim(reg);
    return true;
  }

  bool need_xreg(const std::string& s, u8& out, Diag& d, unsigned line) {
    if (as::parse_xreg(s, out)) return true;
    d.fail_at(line, std::format("'{}' is not an integer register", s));
    return false;
  }
  bool need_freg(const std::string& s, u8& out, Diag& d, unsigned line) {
    if (as::parse_freg(s, out)) return true;
    d.fail_at(line, std::format("'{}' is not a float register", s));
    return false;
  }
  bool need_args(const as::Stmt& st, std::size_t n, Diag& d) {
    if (st.operands.size() >= n) return true;
    d.fail_at(st.line,
              std::format("{} needs {} operands, got {}", st.op, n, st.operands.size()));
    return false;
  }

  // A CSR operand is a name or a number.
  bool eval_csr(const std::string& s, i64& out, Diag& d, unsigned line) {
    if (s == "fflags") { out = CsrFflags; return true; }
    if (s == "frm") { out = CsrFrm; return true; }
    if (s == "fcsr") { out = CsrFcsr; return true; }
    if (s == "cycle") { out = CsrCycle; return true; }
    if (s == "time") { out = CsrTime; return true; }
    if (s == "instret") { out = CsrInstret; return true; }
    return eval_int(s, out, d, line);
  }

  // `li` for RV64: peel the low 12 bits off, recurse on the rest, and fold
  // trailing zeros into the shift so the common constants stay short.
  void emit_li(u8 rd, i64 value) {
    if (value >= -2048 && value < 2048) {
      put_u32(enc_i(0x13, rd, 0, 0, i32(value)));
      return;
    }
    if (value == i64(i32(value))) {
      const i32 hi = i32(u32((u64(value) + 0x800) >> 12) & 0xfffff);
      const i32 lo = i32(sext(u64(value), 12));
      put_u32(enc_u(0x37, rd, hi << 12));
      // addiw, not addi: the pair has to stay a 32-bit computation.
      if (lo) put_u32(enc_i(0x1b, rd, 0, rd, lo));
      return;
    }
    const i64 lo12 = sext(u64(value), 12);
    i64 hi = (value - lo12) >> 12;
    unsigned shift = 12;
    while ((hi & 1) == 0) {
      hi >>= 1;
      ++shift;
    }
    emit_li(rd, hi);
    put_u32(enc_i(0x13, rd, 1, rd, i32(shift)));  // slli
    if (lo12) put_u32(enc_i(0x13, rd, 0, rd, i32(lo12)));
  }

  // The auipc half of every pc-relative pair. Returns the low 12 bits for the
  // instruction that follows.
  i32 emit_auipc_for(u8 rd, u64 pc, i64 target) {
    const i64 delta = target - i64(pc);
    const u32 hi = u32(((u64(delta) + 0x800) >> 12) & 0xfffff);
    put_u32(enc_u(0x17, rd, i32(hi << 12)));
    return i32(sext(u64(delta), 12));
  }

  // -- instructions ----------------------------------------------------------

  bool instruction(const as::Stmt& st, Diag& d) {
    bool handled = false;
    if (!pseudo(st, d, handled)) return false;
    if (handled) return true;

    std::string m = st.op;
    // The AMO ordering suffixes are not part of the mnemonic in the table.
    bool aq = false, rl = false;
    if (m.ends_with(".aqrl")) { aq = rl = true; m.resize(m.size() - 5); }
    else if (m.ends_with(".aq")) { aq = true; m.resize(m.size() - 3); }
    else if (m.ends_with(".rl")) { rl = true; m.resize(m.size() - 3); }

    const auto& t = as::table();
    auto it = t.find(m);
    if (it == t.end()) {
      d.fail_at(st.line, std::format("unknown instruction '{}'", st.op));
      return false;
    }
    return encode(st, it->second, aq, rl, d);
  }

  bool encode(const as::Stmt& st, const as::Enc& e, bool aq, bool rl, Diag& d) {
    const unsigned line = st.line;
    const u64 pc = here();
    const auto& ops = st.operands;
    u8 rd = 0, rs1 = 0, rs2 = 0, rs3 = 0;

    // The trailing rounding mode, when the instruction takes one.
    u8 rm = e.drm;
    std::size_t nops = ops.size();
    if (e.rm && nops) {
      u8 parsed = 0;
      if (as::parse_rm(ops[nops - 1], parsed)) {
        rm = parsed;
        --nops;
      }
    }

    switch (e.fmt) {
      case as::Fmt::R: {
        if (!need_args(st, 3, d)) return false;
        if (!need_xreg(ops[0], rd, d, line) || !need_xreg(ops[1], rs1, d, line) ||
            !need_xreg(ops[2], rs2, d, line))
          return false;
        put_u32(enc_r(e.opcode, rd, e.f3, rs1, rs2, e.f7));
        return true;
      }
      case as::Fmt::Shift:
      case as::Fmt::ShiftW: {
        if (!need_args(st, 3, d)) return false;
        i64 sh = 0;
        if (!need_xreg(ops[0], rd, d, line) || !need_xreg(ops[1], rs1, d, line) ||
            !eval_int(ops[2], sh, d, line))
          return false;
        const bool wide = (e.fmt == as::Fmt::Shift);
        const u64 limit = wide ? 63 : 31;
        if (sh < 0 || u64(sh) > limit) {
          d.fail_at(line, std::format("shift amount {} out of range", sh));
          return false;
        }
        // The funct field sits just above the shift amount: six bits of it on
        // RV64's doubleword shifts, seven on the word forms.
        const i32 imm = i32(wide ? (e.f7 << 6) | u64(sh) : (e.f7 << 5) | u64(sh));
        put_u32(enc_i(e.opcode, rd, e.f3, rs1, imm));
        return true;
      }
      case as::Fmt::I: {
        if (!need_args(st, 3, d)) return false;
        if (!need_xreg(ops[0], rd, d, line) || !need_xreg(ops[1], rs1, d, line))
          return false;
        const as::Operand o = eval(ops[2], d, line);
        if (d.failed) return false;
        i64 v = 0;
        if (!relocate(o, pc, v, d, line)) return false;
        if (!check_imm12(v, line, d)) return false;
        put_u32(enc_i(e.opcode, rd, e.f3, rs1, i32(v)));
        return true;
      }
      case as::Fmt::U: {
        if (!need_args(st, 2, d)) return false;
        if (!need_xreg(ops[0], rd, d, line)) return false;
        const as::Operand o = eval(ops[1], d, line);
        if (d.failed) return false;
        i64 v = 0;
        if (!relocate(o, pc, v, d, line)) return false;
        // The operand is the 20-bit field, as in `lui a0, 0x10` meaning 0x10000.
        put_u32(enc_u(e.opcode, rd, i32(u32(v) << 12)));
        return true;
      }
      case as::Fmt::Load:
      case as::Fmt::FLoad: {
        if (!need_args(st, 2, d)) return false;
        const bool fp = (e.fmt == as::Fmt::FLoad);
        if (fp ? !need_freg(ops[0], rd, d, line) : !need_xreg(ops[0], rd, d, line))
          return false;
        std::string imm, reg;
        if (split_mem(ops[1], imm, reg)) {
          if (!need_xreg(reg, rs1, d, line)) return false;
          i64 v = 0;
          const as::Operand o = eval(imm.empty() ? "0" : imm, d, line);
          if (d.failed || !relocate(o, pc, v, d, line)) return false;
          if (!check_imm12(v, line, d)) return false;
          put_u32(enc_i(e.opcode, rd, e.f3, rs1, i32(v)));
          return true;
        }
        // `lw a0, symbol`: auipc into the destination, then load off it. For a
        // float load the address needs an integer register, and there is none
        // to borrow, so that form is rejected rather than quietly wrong.
        if (fp) {
          d.fail_at(line, "a float load from a symbol needs an explicit base "
                          "register: use `la rt, sym` then `fld fd, 0(rt)`");
          return false;
        }
        i64 target = 0;
        if (!eval_int(ops[1], target, d, line)) return false;
        const i32 lo = emit_auipc_for(rd, pc, target);
        put_u32(enc_i(e.opcode, rd, e.f3, rd, lo));
        return true;
      }
      case as::Fmt::Store:
      case as::Fmt::FStore: {
        if (!need_args(st, 2, d)) return false;
        const bool fp = (e.fmt == as::Fmt::FStore);
        if (fp ? !need_freg(ops[0], rs2, d, line) : !need_xreg(ops[0], rs2, d, line))
          return false;
        std::string imm, reg;
        if (split_mem(ops[1], imm, reg)) {
          if (!need_xreg(reg, rs1, d, line)) return false;
          i64 v = 0;
          const as::Operand o = eval(imm.empty() ? "0" : imm, d, line);
          if (d.failed || !relocate(o, pc, v, d, line)) return false;
          if (!check_imm12(v, line, d)) return false;
          put_u32(enc_s(e.opcode, e.f3, rs1, rs2, i32(v)));
          return true;
        }
        // `sw a0, symbol, t0`: the third operand is the scratch register that
        // holds the address, exactly as GNU as spells it.
        if (!need_args(st, 3, d)) return false;
        u8 tmp = 0;
        if (!need_xreg(ops[2], tmp, d, line)) return false;
        i64 target = 0;
        if (!eval_int(ops[1], target, d, line)) return false;
        const i32 lo = emit_auipc_for(tmp, pc, target);
        put_u32(enc_s(e.opcode, e.f3, tmp, rs2, lo));
        return true;
      }
      case as::Fmt::Branch: {
        if (!need_args(st, 3, d)) return false;
        if (!need_xreg(ops[0], rs1, d, line) || !need_xreg(ops[1], rs2, d, line))
          return false;
        i64 target = 0;
        if (!eval_int(ops[2], target, d, line)) return false;
        const i64 delta = target - i64(pc);
        if (emitting_ && (delta < -4096 || delta > 4094 || (delta & 1))) {
          d.fail_at(line, std::format("branch to {} is {} bytes away, out of range",
                                      hex(u64(target)), delta));
          return false;
        }
        put_u32(enc_b(e.opcode, e.f3, rs1, rs2, i32(delta)));
        return true;
      }
      case as::Fmt::Jal: {
        if (ops.empty()) {
          d.fail_at(line, "jal needs a target");
          return false;
        }
        std::size_t ti = 0;
        rd = 1;  // `jal target` links through ra
        if (ops.size() >= 2) {
          if (!need_xreg(ops[0], rd, d, line)) return false;
          ti = 1;
        }
        i64 target = 0;
        if (!eval_int(ops[ti], target, d, line)) return false;
        const i64 delta = target - i64(pc);
        if (emitting_ && (delta < -1048576 || delta > 1048574 || (delta & 1))) {
          d.fail_at(line, std::format("jal to {} is {} bytes away, out of range",
                                      hex(u64(target)), delta));
          return false;
        }
        put_u32(enc_j(e.opcode, rd, i32(delta)));
        return true;
      }
      case as::Fmt::Jalr: {
        if (ops.empty()) {
          d.fail_at(line, "jalr needs an operand");
          return false;
        }
        if (ops.size() == 1) {  // jalr rs1
          if (!need_xreg(ops[0], rs1, d, line)) return false;
          put_u32(enc_i(e.opcode, 1, 0, rs1, 0));
          return true;
        }
        if (!need_xreg(ops[0], rd, d, line)) return false;
        std::string imm, reg;
        if (split_mem(ops[1], imm, reg)) {  // jalr rd, imm(rs1)
          if (!need_xreg(reg, rs1, d, line)) return false;
          i64 v = 0;
          const as::Operand o = eval(imm.empty() ? "0" : imm, d, line);
          if (d.failed || !relocate(o, pc, v, d, line)) return false;
          put_u32(enc_i(e.opcode, rd, 0, rs1, i32(v)));
          return true;
        }
        if (!need_xreg(ops[1], rs1, d, line)) return false;  // jalr rd, rs1[, imm]
        i64 v = 0;
        if (ops.size() >= 3 && !eval_int(ops[2], v, d, line)) return false;
        put_u32(enc_i(e.opcode, rd, 0, rs1, i32(v)));
        return true;
      }
      case as::Fmt::Fence:
        // The predecessor/successor sets are accepted and ignored: one hart has
        // nothing to order against.
        if (e.f3 == 1) put_u32(enc_i(0x0f, 0, 1, 0, 0));
        else put_u32(0x0ff0000f);
        return true;
      case as::Fmt::System:
        put_u32(enc_i(0x73, 0, 0, 0, i32(e.f7)));
        return true;
      case as::Fmt::Csr: {
        if (!need_args(st, 3, d)) return false;
        i64 csr = 0;
        if (!need_xreg(ops[0], rd, d, line) || !eval_csr(ops[1], csr, d, line) ||
            !need_xreg(ops[2], rs1, d, line))
          return false;
        put_u32(enc_i(e.opcode, rd, e.f3, rs1, i32(csr)));
        return true;
      }
      case as::Fmt::Csri: {
        if (!need_args(st, 3, d)) return false;
        i64 csr = 0, zimm = 0;
        if (!need_xreg(ops[0], rd, d, line) || !eval_csr(ops[1], csr, d, line) ||
            !eval_int(ops[2], zimm, d, line))
          return false;
        put_u32(enc_i(e.opcode, rd, e.f3, u8(zimm & 31), i32(csr)));
        return true;
      }
      case as::Fmt::Amo: {
        if (!need_args(st, 3, d)) return false;
        std::string imm, reg;
        if (!need_xreg(ops[0], rd, d, line) || !need_xreg(ops[1], rs2, d, line))
          return false;
        if (!split_mem(ops[2], imm, reg) || !need_xreg(reg, rs1, d, line)) {
          if (!d.failed) d.fail_at(line, "an atomic's address operand is (rs1)");
          return false;
        }
        const u32 f7 = (e.f7 << 2) | (aq ? 2u : 0u) | (rl ? 1u : 0u);
        put_u32(enc_r(e.opcode, rd, e.f3, rs1, rs2, f7));
        return true;
      }
      case as::Fmt::Lr: {
        if (!need_args(st, 2, d)) return false;
        std::string imm, reg;
        if (!need_xreg(ops[0], rd, d, line)) return false;
        if (!split_mem(ops[1], imm, reg) || !need_xreg(reg, rs1, d, line)) {
          if (!d.failed) d.fail_at(line, "lr's address operand is (rs1)");
          return false;
        }
        const u32 f7 = (e.f7 << 2) | (aq ? 2u : 0u) | (rl ? 1u : 0u);
        put_u32(enc_r(e.opcode, rd, e.f3, rs1, 0, f7));
        return true;
      }
      case as::Fmt::FpR3: {
        if (nops < 3) return need_args(st, 3, d);
        if (!need_freg(ops[0], rd, d, line) || !need_freg(ops[1], rs1, d, line) ||
            !need_freg(ops[2], rs2, d, line))
          return false;
        put_u32(enc_r(e.opcode, rd, e.rm ? rm : e.f3, rs1, rs2, e.f7));
        return true;
      }
      case as::Fmt::FpR2: {
        if (nops < 2) return need_args(st, 2, d);
        if (!need_freg(ops[0], rd, d, line) || !need_freg(ops[1], rs1, d, line))
          return false;
        put_u32(enc_r(e.opcode, rd, e.rm ? rm : e.f3, rs1, u8(e.rs2), e.f7));
        return true;
      }
      case as::Fmt::FpR4: {
        if (nops < 4) return need_args(st, 4, d);
        if (!need_freg(ops[0], rd, d, line) || !need_freg(ops[1], rs1, d, line) ||
            !need_freg(ops[2], rs2, d, line) || !need_freg(ops[3], rs3, d, line))
          return false;
        put_u32(enc_r4(e.opcode, rd, rm, rs1, rs2, rs3, e.f7));
        return true;
      }
      case as::Fmt::FpCmp: {
        if (!need_args(st, 3, d)) return false;
        if (!need_xreg(ops[0], rd, d, line) || !need_freg(ops[1], rs1, d, line) ||
            !need_freg(ops[2], rs2, d, line))
          return false;
        put_u32(enc_r(e.opcode, rd, e.f3, rs1, rs2, e.f7));
        return true;
      }
      case as::Fmt::FpF2X: {
        if (nops < 2) return need_args(st, 2, d);
        if (!need_xreg(ops[0], rd, d, line) || !need_freg(ops[1], rs1, d, line))
          return false;
        put_u32(enc_r(e.opcode, rd, e.rm ? rm : e.f3, rs1, u8(e.rs2), e.f7));
        return true;
      }
      case as::Fmt::FpX2F: {
        if (nops < 2) return need_args(st, 2, d);
        if (!need_freg(ops[0], rd, d, line) || !need_xreg(ops[1], rs1, d, line))
          return false;
        put_u32(enc_r(e.opcode, rd, e.rm ? rm : e.f3, rs1, u8(e.rs2), e.f7));
        return true;
      }
    }
    d.fail_at(line, "unhandled instruction format");
    return false;
  }

  bool check_imm12(i64 v, unsigned line, Diag& d) {
    if (!emitting_ || (v >= -2048 && v < 2048)) return true;
    d.fail_at(line, std::format("immediate {} does not fit in 12 bits", v));
    return false;
  }

  // -- pseudo-instructions ---------------------------------------------------

  // Sets `handled` when it recognised the mnemonic. Returns false only on a
  // real error.
  bool pseudo(const as::Stmt& st, Diag& d, bool& handled) {
    const std::string& m = st.op;
    const unsigned line = st.line;
    const auto& ops = st.operands;
    handled = true;
    u8 a = 0;

    // Rewrite into a base instruction and hand it back to the normal path.
    auto as_real = [&](std::string op, std::vector<std::string> operands) {
      as::Stmt s = st;
      s.op = std::move(op);
      s.operands = std::move(operands);
      s.labels.clear();
      return instruction(s, d);
    };

    if (m == "nop") return as_real("addi", {"zero", "zero", "0"});
    if (m == "mv") {
      if (!need_args(st, 2, d)) return false;
      return as_real("addi", {ops[0], ops[1], "0"});
    }
    if (m == "not") {
      if (!need_args(st, 2, d)) return false;
      return as_real("xori", {ops[0], ops[1], "-1"});
    }
    if (m == "neg") {
      if (!need_args(st, 2, d)) return false;
      return as_real("sub", {ops[0], "zero", ops[1]});
    }
    if (m == "negw") {
      if (!need_args(st, 2, d)) return false;
      return as_real("subw", {ops[0], "zero", ops[1]});
    }
    if (m == "sext.w") {
      if (!need_args(st, 2, d)) return false;
      return as_real("addiw", {ops[0], ops[1], "0"});
    }
    if (m == "zext.b") {
      if (!need_args(st, 2, d)) return false;
      return as_real("andi", {ops[0], ops[1], "255"});
    }
    if (m == "seqz") {
      if (!need_args(st, 2, d)) return false;
      return as_real("sltiu", {ops[0], ops[1], "1"});
    }
    if (m == "snez") {
      if (!need_args(st, 2, d)) return false;
      return as_real("sltu", {ops[0], "zero", ops[1]});
    }
    if (m == "sltz") {
      if (!need_args(st, 2, d)) return false;
      return as_real("slt", {ops[0], ops[1], "zero"});
    }
    if (m == "sgtz") {
      if (!need_args(st, 2, d)) return false;
      return as_real("slt", {ops[0], "zero", ops[1]});
    }

    // Branch-against-zero and reversed-operand branches.
    static const std::unordered_map<std::string, std::pair<const char*, bool>> kBz = {
        {"beqz", {"beq", false}}, {"bnez", {"bne", false}},
        {"blez", {"bge", true}},  {"bgez", {"bge", false}},
        {"bltz", {"blt", false}}, {"bgtz", {"blt", true}},
    };
    if (auto it = kBz.find(m); it != kBz.end()) {
      if (!need_args(st, 2, d)) return false;
      const auto& [real, zero_first] = it->second;
      if (zero_first) return as_real(real, {"zero", ops[0], ops[1]});
      return as_real(real, {ops[0], "zero", ops[1]});
    }
    static const std::unordered_map<std::string, const char*> kSwap = {
        {"bgt", "blt"}, {"ble", "bge"}, {"bgtu", "bltu"}, {"bleu", "bgeu"}};
    if (auto it = kSwap.find(m); it != kSwap.end()) {
      if (!need_args(st, 3, d)) return false;
      return as_real(it->second, {ops[1], ops[0], ops[2]});
    }

    if (m == "j") {
      if (!need_args(st, 1, d)) return false;
      return as_real("jal", {"zero", ops[0]});
    }
    if (m == "jr") {
      if (!need_args(st, 1, d)) return false;
      return as_real("jalr", {"zero", ops[0], "0"});
    }
    if (m == "ret") return as_real("jalr", {"zero", "ra", "0"});

    if (m == "li") {
      if (!need_args(st, 2, d)) return false;
      if (!need_xreg(ops[0], a, d, line)) return false;
      const as::Operand o = eval(ops[1], d, line);
      if (d.failed) return false;
      if (o.reloc != as::Reloc::None) {
        d.fail_at(line, "li takes a plain value, not a relocation");
        return false;
      }
      // An address is not known during the layout walks, so `li` would change
      // size between them. `la` is the instruction for an address. An .equ
      // constant is fine, and is how `li a2, msglen` works.
      if (used_address_) {
        d.fail_at(line, "li needs an absolute value; use `la` to load an address");
        return false;
      }
      emit_li(a, o.value);
      return true;
    }

    if (m == "la" || m == "lla") {
      if (!need_args(st, 2, d)) return false;
      if (!need_xreg(ops[0], a, d, line)) return false;
      i64 target = 0;
      if (!eval_int(ops[1], target, d, line)) return false;
      const u64 pc = here();
      const i32 lo = emit_auipc_for(a, pc, target);
      put_u32(enc_i(0x13, a, 0, a, lo));  // addi
      return true;
    }
    if (m == "call" || m == "tail") {
      const bool tail = (m == "tail");
      if (!need_args(st, 1, d)) return false;
      // `call rd, sym` is also legal; the default link register is ra.
      u8 link = tail ? 0 : 1;
      u8 scratch = tail ? 6 : 1;  // t1 for tail, ra for call
      std::size_t ti = 0;
      if (!tail && ops.size() >= 2) {
        if (!need_xreg(ops[0], link, d, line)) return false;
        scratch = link;
        ti = 1;
      }
      i64 target = 0;
      if (!eval_int(ops[ti], target, d, line)) return false;
      const u64 pc = here();
      const i32 lo = emit_auipc_for(scratch, pc, target);
      put_u32(enc_i(0x67, link, 0, scratch, lo));  // jalr
      return true;
    }

    // Float moves are sign-injection with both sources the same register.
    static const std::unordered_map<std::string, const char*> kFmv = {
        {"fmv.s", "fsgnj.s"},  {"fneg.s", "fsgnjn.s"}, {"fabs.s", "fsgnjx.s"},
        {"fmv.d", "fsgnj.d"},  {"fneg.d", "fsgnjn.d"}, {"fabs.d", "fsgnjx.d"},
    };
    if (auto it = kFmv.find(m); it != kFmv.end()) {
      if (!need_args(st, 2, d)) return false;
      return as_real(it->second, {ops[0], ops[1], ops[1]});
    }

    // CSR shorthands.
    if (m == "csrr") {
      if (!need_args(st, 2, d)) return false;
      return as_real("csrrs", {ops[0], ops[1], "zero"});
    }
    if (m == "csrw" || m == "csrs" || m == "csrc") {
      if (!need_args(st, 2, d)) return false;
      const std::string real = std::format("csrr{}", m.substr(3));
      return as_real(real, {"zero", ops[0], ops[1]});
    }
    if (m == "csrwi" || m == "csrsi" || m == "csrci") {
      if (!need_args(st, 2, d)) return false;
      const std::string real = std::format("csrr{}", m.substr(3));
      return as_real(real, {"zero", ops[0], ops[1]});
    }
    if (m == "rdcycle" || m == "rdtime" || m == "rdinstret") {
      if (!need_args(st, 1, d)) return false;
      return as_real("csrrs", {ops[0], m.substr(2), "zero"});
    }

    if (m == "unimp") {
      put_u32(0);  // decodes as an illegal instruction, which is the point
      return true;
    }

    handled = false;
    return true;
  }
};

// Convenience: read a `.s` file and assemble it.
inline bool assemble_file(const std::string& path, Memory& mem, Image& img, Diag& d) {
  std::vector<u8> bytes;
  if (!read_file(path, bytes, d)) return false;
  Assembler a;
  return a.assemble(std::string_view(reinterpret_cast<const char*>(bytes.data()),
                                     bytes.size()),
                    path, mem, img, d);
}

}  // namespace rvemu
