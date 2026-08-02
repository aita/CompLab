// Text partition — `.wat` source into the same Module the binary decoder makes.
//
// This is the built-in assembler, and it exists for the same reason rvemu has
// one: a test you can read. Everything the tests exercise is written in the text
// format and parsed here, and the same file is also handed to `wat2wasm` and
// read back through :binary, so the two front ends are checked against each
// other on every run.
//
// Two things make the text format harder than it looks, and both are handled
// here rather than anywhere later:
//
//   * **Names.** `$fib` has to become an index, and a call may name a function
//     defined later in the file. So there are two passes: the first walks the
//     top-level fields and assigns every `$name` its index, the second parses
//     for real. Labels and locals are the exception — they nest, so they are
//     resolved on a stack while the body is read.
//
//   * **Abbreviations.** `(func (export "f") (param i32) ...)` is shorthand for
//     a function, an export and possibly a new entry in the type section. Each
//     abbreviation is expanded here, so that :module never sees one.
export module weasel:text;

import std;
import :common;
import :opcode;
import :types;

namespace weasel {

enum class Tok : u8 { LPar, RPar, Id, Keyword, String, Eof };

struct Token {
  Tok kind = Tok::Eof;
  std::string text;   // keyword or id, `$` included
  std::string str;    // decoded bytes of a string literal
  unsigned line = 1;
  unsigned col = 1;
};

bool is_idchar(char c) {
  if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) return true;
  switch (c) {
    case '!': case '#': case '$': case '%': case '&': case '\'': case '*':
    case '+': case '-': case '.': case '/': case ':': case '<': case '=':
    case '>': case '?': case '@': case '\\': case '^': case '_': case '`':
    case '|': case '~':
      return true;
    default:
      return false;
  }
}

struct Lexer {
  std::string_view src;
  std::size_t p = 0;
  unsigned line = 1;
  unsigned col = 1;
  Diag* d = nullptr;

  void advance() {
    if (src[p] == '\n') {
      ++line;
      col = 1;
    } else {
      ++col;
    }
    ++p;
  }

  // Whitespace, `;;` to end of line, and `(; ;)` which nests.
  void skip() {
    for (;;) {
      if (p >= src.size()) return;
      const char c = src[p];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        advance();
      } else if (c == ';' && p + 1 < src.size() && src[p + 1] == ';') {
        while (p < src.size() && src[p] != '\n') advance();
      } else if (c == '(' && p + 1 < src.size() && src[p + 1] == ';') {
        int depth = 0;
        do {
          if (p + 1 < src.size() && src[p] == '(' && src[p + 1] == ';') {
            ++depth;
            advance();
            advance();
          } else if (p + 1 < src.size() && src[p] == ';' && src[p + 1] == ')') {
            --depth;
            advance();
            advance();
          } else if (p < src.size()) {
            advance();
          } else {
            d->fail("unterminated block comment");
            return;
          }
        } while (depth > 0 && p < src.size());
      } else {
        return;
      }
    }
  }

  bool hexval(char c, unsigned& out) {
    if (c >= '0' && c <= '9') { out = static_cast<unsigned>(c - '0'); return true; }
    if (c >= 'a' && c <= 'f') { out = static_cast<unsigned>(c - 'a' + 10); return true; }
    if (c >= 'A' && c <= 'F') { out = static_cast<unsigned>(c - 'A' + 10); return true; }
    return false;
  }

  // A string literal holds bytes, not characters: `\6a` is one byte and `\u{3b1}`
  // is however many bytes UTF-8 needs. Data segments are written this way.
  std::string string_literal() {
    std::string out;
    advance();  // the opening quote
    while (p < src.size() && src[p] != '"') {
      char c = src[p];
      if (c != '\\') {
        out.push_back(c);
        advance();
        continue;
      }
      advance();
      if (p >= src.size()) break;
      const char e = src[p];
      switch (e) {
        case 'n': out.push_back('\n'); advance(); break;
        case 't': out.push_back('\t'); advance(); break;
        case 'r': out.push_back('\r'); advance(); break;
        case '"': out.push_back('"'); advance(); break;
        case '\'': out.push_back('\''); advance(); break;
        case '\\': out.push_back('\\'); advance(); break;
        case 'u': {
          advance();
          if (p >= src.size() || src[p] != '{') { d->fail_at(line, col, "bad \\u escape"); return out; }
          advance();
          u32 cp = 0;
          unsigned v = 0;
          while (p < src.size() && hexval(src[p], v)) { cp = cp * 16 + v; advance(); }
          if (p >= src.size() || src[p] != '}') { d->fail_at(line, col, "bad \\u escape"); return out; }
          advance();
          if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
          } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xc0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
          } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xe0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
          } else {
            out.push_back(static_cast<char>(0xf0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3f)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
          }
          break;
        }
        default: {
          unsigned hi = 0, lo = 0;
          if (hexval(e, hi) && p + 1 < src.size() && hexval(src[p + 1], lo)) {
            out.push_back(static_cast<char>(hi * 16 + lo));
            advance();
            advance();
          } else {
            d->fail_at(line, col, std::format("bad escape \\{}", e));
            return out;
          }
        }
      }
    }
    if (p >= src.size()) {
      d->fail_at(line, col, "unterminated string");
      return out;
    }
    advance();  // the closing quote
    return out;
  }

  Token next() {
    skip();
    Token t;
    t.line = line;
    t.col = col;
    if (p >= src.size()) {
      t.kind = Tok::Eof;
      return t;
    }
    const char c = src[p];
    if (c == '(') { t.kind = Tok::LPar; advance(); return t; }
    if (c == ')') { t.kind = Tok::RPar; advance(); return t; }
    if (c == '"') { t.kind = Tok::String; t.str = string_literal(); return t; }
    const std::size_t start = p;
    while (p < src.size() && is_idchar(src[p])) advance();
    if (p == start) {
      d->fail_at(line, col, std::format("stray character {:?}", c));
      t.kind = Tok::Eof;
      return t;
    }
    t.text = std::string(src.substr(start, p - start));
    t.kind = (t.text[0] == '$') ? Tok::Id : Tok::Keyword;
    return t;
  }
};

// ---------------------------------------------------------------------------
// numbers

std::string strip_underscores(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (char c : s)
    if (c != '_') out.push_back(c);
  return out;
}

bool parse_uint(std::string_view text, u64 max, u64& out) {
  const std::string s = strip_underscores(text);
  std::string_view v{s};
  int base = 10;
  if (v.starts_with("0x") || v.starts_with("0X")) {
    base = 16;
    v.remove_prefix(2);
  }
  if (v.empty()) return false;
  u64 acc = 0;
  for (char c : v) {
    unsigned digit;
    if (c >= '0' && c <= '9') digit = static_cast<unsigned>(c - '0');
    else if (base == 16 && c >= 'a' && c <= 'f') digit = static_cast<unsigned>(c - 'a' + 10);
    else if (base == 16 && c >= 'A' && c <= 'F') digit = static_cast<unsigned>(c - 'A' + 10);
    else return false;
    if (digit >= static_cast<unsigned>(base)) return false;
    if (acc > (max - digit) / static_cast<u64>(base)) return false;
    acc = acc * static_cast<u64>(base) + digit;
  }
  out = acc;
  return true;
}

// One routine for `i32.const` and `i64.const`. The text format lets an integer
// constant be written as either a signed or an unsigned number of the right
// width, so `i32.const 0xffffffff` and `i32.const -1` are the same instruction.
bool parse_int(std::string_view text, unsigned bits, u64& out) {
  bool neg = false;
  if (text.starts_with('+')) text.remove_prefix(1);
  else if (text.starts_with('-')) { neg = true; text.remove_prefix(1); }
  const u64 limit = (bits == 64) ? ~u64{0} : ((u64{1} << bits) - 1);
  const u64 neg_limit = (bits == 64) ? (u64{1} << 63) : (u64{1} << (bits - 1));
  u64 v = 0;
  if (!parse_uint(text, neg ? neg_limit : limit, v)) return false;
  out = neg ? (~v + 1) : v;
  if (bits < 64) out &= limit;
  return true;
}

template <typename F>
bool parse_float(std::string_view text, F& out) {
  bool neg = false;
  std::string_view t = text;
  if (t.starts_with('+')) t.remove_prefix(1);
  else if (t.starts_with('-')) { neg = true; t.remove_prefix(1); }

  const auto sign = [&](F v) { return neg ? -v : v; };

  if (t == "inf") {
    out = sign(std::numeric_limits<F>::infinity());
    return true;
  }
  if (t == "nan") {
    out = sign(std::numeric_limits<F>::quiet_NaN());
    return true;
  }
  if (t.starts_with("nan:")) {
    // `nan:0x...` names the payload, so the result is built from bits.
    u64 payload = 0;
    if (!parse_uint(t.substr(4), ~u64{0}, payload)) return false;
    if constexpr (sizeof(F) == 4) {
      u32 bits = 0x7f800000u | (static_cast<u32>(payload) & 0x7fffffu);
      if (neg) bits |= 0x80000000u;
      out = std::bit_cast<F>(bits);
    } else {
      u64 bits = 0x7ff0000000000000ull | (payload & 0xfffffffffffffull);
      if (neg) bits |= 0x8000000000000000ull;
      out = std::bit_cast<F>(bits);
    }
    return true;
  }

  const std::string s = strip_underscores(t);
  std::string_view v{s};
  auto fmt = std::chars_format::general;
  if (v.starts_with("0x") || v.starts_with("0X")) {
    v.remove_prefix(2);
    fmt = std::chars_format::hex;
  }
  F value{};
  auto res = std::from_chars(v.data(), v.data() + v.size(), value, fmt);
  if (res.ec != std::errc{} || res.ptr != v.data() + v.size()) return false;
  out = sign(value);
  return true;
}

// ---------------------------------------------------------------------------
// the parser

struct Space {
  std::map<std::string, u32> by_name;
  u32 count = 0;

  u32 add(const std::string& id) {
    const u32 idx = count++;
    if (!id.empty()) by_name[id] = idx;
    return idx;
  }
};

struct Parser {
  std::vector<Token> toks;
  std::size_t p = 0;
  Diag* d = nullptr;
  Module* m = nullptr;

  Space types, funcs, tables, mems, globals, elems, datas;
  // Inside a function: the names of parameters and locals, and the stack of
  // block labels. Both are positional, so a name is found by scanning.
  std::vector<std::string> local_names;
  std::vector<std::string> labels;
  bool seen_definition[4] = {false, false, false, false};

  const Token& cur() const { return toks[p]; }
  bool ok() const { return !d->failed; }
  void fail(std::string msg) { d->fail_at(cur().line, cur().col, std::move(msg)); }

  bool is_lpar() const { return cur().kind == Tok::LPar; }
  bool is_rpar() const { return cur().kind == Tok::RPar; }
  bool is_kw(std::string_view k) const {
    return cur().kind == Tok::Keyword && cur().text == k;
  }
  // `(kw` — the opening of a folded field with a known head.
  bool is_field(std::string_view k) const {
    return cur().kind == Tok::LPar && toks[p + 1].kind == Tok::Keyword &&
           toks[p + 1].text == k;
  }

  void bump() { if (cur().kind != Tok::Eof) ++p; }

  bool eat_kw(std::string_view k) {
    if (!is_kw(k)) return false;
    bump();
    return true;
  }
  void expect_lpar() {
    if (!is_lpar()) { fail("expected `(`"); return; }
    bump();
  }
  void expect_rpar() {
    if (!is_rpar()) { fail(std::format("expected `)`, found `{}`", describe())); return; }
    bump();
  }
  std::string describe() const {
    switch (cur().kind) {
      case Tok::LPar: return "(";
      case Tok::RPar: return ")";
      case Tok::Eof: return "end of file";
      case Tok::String: return "a string";
      default: return cur().text;
    }
  }
  std::string opt_id() {
    if (cur().kind != Tok::Id) return {};
    std::string s = cur().text;
    bump();
    return s;
  }
  std::string expect_name() {
    if (cur().kind != Tok::String) { fail("expected a name string"); return {}; }
    std::string s = cur().str;
    bump();
    return s;
  }

  void skip_field() {  // at `(`, skip through the matching `)`
    int depth = 0;
    do {
      if (cur().kind == Tok::LPar) ++depth;
      else if (cur().kind == Tok::RPar) --depth;
      else if (cur().kind == Tok::Eof) { fail("unbalanced parentheses"); return; }
      bump();
    } while (depth > 0);
  }

  // An index immediate is either `$name` or a number, and both are optional in
  // several instructions. Asking first — rather than trying and failing — is
  // what keeps `table.get` followed by `i32.add` from reading the next
  // instruction as a table index.
  bool at_index() const {
    if (cur().kind == Tok::Id) return true;
    if (cur().kind != Tok::Keyword) return false;
    u64 v = 0;
    return parse_uint(cur().text, 0xffffffffu, v);
  }

  u32 index(Space& s, std::string_view what) {
    if (cur().kind == Tok::Id) {
      auto it = s.by_name.find(cur().text);
      if (it == s.by_name.end()) {
        fail(std::format("undefined {} {}", what, cur().text));
        bump();
        return 0;
      }
      bump();
      return it->second;
    }
    if (cur().kind == Tok::Keyword) {
      u64 v = 0;
      if (parse_uint(cur().text, 0xffffffffu, v)) {
        bump();
        return static_cast<u32>(v);
      }
    }
    fail(std::format("expected a {} index", what));
    return 0;
  }

  ValType valtype() {
    ValType t;
    if (cur().kind != Tok::Keyword || !valtype_by_name(cur().text, t)) {
      fail("expected a value type");
      return ValType::I32;
    }
    bump();
    return t;
  }

  Limits limits(u32 hard_max) {
    Limits l;
    u64 v = 0;
    if (cur().kind != Tok::Keyword || !parse_uint(cur().text, hard_max, v)) {
      fail("expected a limit");
      return l;
    }
    bump();
    l.min = static_cast<u32>(v);
    if (cur().kind == Tok::Keyword && parse_uint(cur().text, hard_max, v)) {
      bump();
      l.has_max = true;
      l.max = static_cast<u32>(v);
    }
    return l;
  }

  // ---- pass one: names -----------------------------------------------------
  //
  // Walks the top-level fields without looking inside them, so that a body
  // parsed in pass two can name anything the module defines, in any order. The
  // one thing it must also decide is whether a `func`/`table`/`memory`/`global`
  // field is an import, because imports come first in their index space and a
  // definition before an import would silently shift every index.

  void register_names() {
    const std::size_t save = p;
    while (is_lpar()) {
      const std::size_t field = p;
      bump();
      if (cur().kind != Tok::Keyword) { fail("expected a module field"); return; }
      const std::string head = cur().text;
      bump();
      if (head == "import") {
        // (import "m" "n" (kind $id ...))
        if (cur().kind == Tok::String) bump();
        if (cur().kind == Tok::String) bump();
        if (is_lpar()) {
          bump();
          const std::string kind = (cur().kind == Tok::Keyword) ? cur().text : "";
          bump();
          register_one(kind, opt_id(), true);
        }
      } else {
        const std::string id = opt_id();
        const bool imported = is_field("import") ||
                              (is_field("export") && lookahead_import());
        register_one(head, id, imported);
      }
      p = field;
      skip_field();
      if (!ok()) return;
    }
    p = save;
  }

  // `(func (export "a") (import "m" "n") ...)` is legal, so an inline import may
  // hide behind any number of inline exports.
  bool lookahead_import() {
    std::size_t q = p;
    int depth = 0;
    while (toks[q].kind != Tok::Eof) {
      if (toks[q].kind == Tok::LPar) {
        if (depth == 0 && toks[q + 1].kind == Tok::Keyword) {
          if (toks[q + 1].text == "import") return true;
          if (toks[q + 1].text != "export") return false;
        }
        ++depth;
      } else if (toks[q].kind == Tok::RPar) {
        if (depth == 0) return false;
        --depth;
      } else if (depth == 0) {
        return false;
      }
      ++q;
    }
    return false;
  }

  void register_one(const std::string& kind, const std::string& id, bool imported) {
    int slot = -1;
    Space* s = nullptr;
    if (kind == "func") { slot = 0; s = &funcs; }
    else if (kind == "table") { slot = 1; s = &tables; }
    else if (kind == "memory") { slot = 2; s = &mems; }
    else if (kind == "global") { slot = 3; s = &globals; }
    else if (kind == "type") { types.add(id); return; }
    else if (kind == "elem") { elems.add(id); return; }
    else if (kind == "data") { datas.add(id); return; }
    else return;

    if (imported && seen_definition[slot]) {
      fail(std::format("an imported {} may not follow a defined one", kind));
      return;
    }
    if (!imported) seen_definition[slot] = true;
    s->add(id);
  }

  // ---- types ---------------------------------------------------------------

  void type_field() {
    bump();          // `type`
    opt_id();        // already registered
    expect_lpar();
    if (!eat_kw("func")) { fail("expected `func` in a type definition"); return; }
    FuncType ft;
    read_params_results(ft, nullptr);
    expect_rpar();
    expect_rpar();
    m->types.push_back(std::move(ft));
  }

  void read_params_results(FuncType& ft, std::vector<std::string>* names) {
    while (is_field("param")) {
      bump();
      bump();
      if (cur().kind == Tok::Id) {
        // `(param $x i32)` names exactly one parameter.
        const std::string id = opt_id();
        ft.params.push_back(valtype());
        if (names) names->push_back(id);
      } else {
        while (!is_rpar() && ok()) {
          ft.params.push_back(valtype());
          if (names) names->push_back({});
        }
      }
      expect_rpar();
    }
    while (is_field("result")) {
      bump();
      bump();
      while (!is_rpar() && ok()) ft.results.push_back(valtype());
      expect_rpar();
    }
  }

  // A typeuse either names a type or spells one out. When it spells one out, the
  // type has to exist in the type section, so an equal one is looked for and a
  // new one appended if there is none. That append is why the type section of a
  // module built from text can be longer than the `(type ...)` fields suggest.
  u32 typeuse(std::vector<std::string>* names) {
    bool named = false;
    u32 idx = 0;
    if (is_field("type")) {
      bump();
      bump();
      idx = index(types, "type");
      expect_rpar();
      named = true;
    }
    FuncType inline_ft;
    const bool has_inline = is_field("param") || is_field("result");
    if (has_inline) read_params_results(inline_ft, names);

    if (named) {
      if (has_inline && idx < m->types.size() && m->types[idx] != inline_ft)
        fail("the inline signature disagrees with the named type");
      if (!has_inline && names && idx < m->types.size())
        names->assign(m->types[idx].params.size(), std::string{});
      return idx;
    }
    for (u32 i = 0; i < m->types.size(); ++i)
      if (m->types[i] == inline_ft) return i;
    m->types.push_back(inline_ft);
    types.count = static_cast<u32>(m->types.size());
    return static_cast<u32>(m->types.size() - 1);
  }

  // ---- inline export / import ---------------------------------------------

  // Returns true if the field turned out to be an import.
  bool inline_extras(ExternKind kind, u32 index_in_space, Import& im, bool& is_import) {
    is_import = false;
    for (;;) {
      if (is_field("export")) {
        bump();
        bump();
        Export ex;
        ex.name = expect_name();
        ex.kind = kind;
        ex.index = index_in_space;
        m->exports.push_back(std::move(ex));
        expect_rpar();
      } else if (is_field("import")) {
        bump();
        bump();
        im.module = expect_name();
        im.name = expect_name();
        im.kind = kind;
        expect_rpar();
        is_import = true;
        return true;
      } else {
        return false;
      }
      if (!ok()) return false;
    }
  }

  // ---- fields --------------------------------------------------------------

  void import_field() {
    bump();  // `import`
    Import im;
    im.module = expect_name();
    im.name = expect_name();
    expect_lpar();
    if (eat_kw("func")) {
      im.kind = ExternKind::Func;
      opt_id();
      im.type_index = typeuse(nullptr);
      ++m->imported_funcs;
    } else if (eat_kw("table")) {
      im.kind = ExternKind::Table;
      opt_id();
      im.table.limits = limits(0xffffffffu);
      im.table.elem = valtype();
      ++m->imported_tables;
    } else if (eat_kw("memory")) {
      im.kind = ExternKind::Memory;
      opt_id();
      im.mem.limits = limits(kMaxPages);
      ++m->imported_mems;
    } else if (eat_kw("global")) {
      im.kind = ExternKind::Global;
      opt_id();
      im.global = globaltype();
      ++m->imported_globals;
    } else {
      fail("expected func, table, memory or global in an import");
      return;
    }
    expect_rpar();
    expect_rpar();
    m->imports.push_back(std::move(im));
  }

  GlobalType globaltype() {
    GlobalType gt;
    if (is_field("mut")) {
      bump();
      bump();
      gt.is_mutable = true;
      gt.type = valtype();
      expect_rpar();
    } else {
      gt.type = valtype();
    }
    return gt;
  }

  void func_field() {
    bump();  // `func`
    opt_id();
    // Imports are required to come before definitions of the same kind, so at
    // the moment an inline import is parsed there are no definitions yet and
    // this index is both the import's and the definition's. That is why the
    // inline exports above can be emitted before it is known which this is.
    const u32 idx = m->imported_funcs + static_cast<u32>(m->funcs.size());
    Import im;
    bool is_import = false;
    inline_extras(ExternKind::Func, idx, im, is_import);
    if (is_import) {
      im.type_index = typeuse(nullptr);
      ++m->imported_funcs;
      m->imports.push_back(std::move(im));
      expect_rpar();
      return;
    }

    Func f;
    local_names.clear();
    f.type = typeuse(&local_names);
    while (is_field("local")) {
      bump();
      bump();
      if (cur().kind == Tok::Id) {
        const std::string id = opt_id();
        f.locals.push_back(valtype());
        local_names.push_back(id);
      } else {
        while (!is_rpar() && ok()) {
          f.locals.push_back(valtype());
          local_names.push_back({});
        }
      }
      expect_rpar();
    }
    labels.clear();
    f.body = instructions();
    f.body.push_back(Inst{Op::End, 0, 0, 0, {}});
    expect_rpar();
    m->funcs.push_back(std::move(f));
  }

  void table_field() {
    bump();
    opt_id();
    const u32 idx = m->imported_tables + static_cast<u32>(m->tables.size());
    Import im;
    bool is_import = false;
    inline_extras(ExternKind::Table, idx, im, is_import);
    if (is_import) {
      im.table.limits = limits(0xffffffffu);
      im.table.elem = valtype();
      ++m->imported_tables;
      m->imports.push_back(std::move(im));
      expect_rpar();
      return;
    }
    TableType tt;
    if (cur().kind == Tok::Keyword && !valtype_by_name(cur().text, tt.elem)) {
      tt.limits = limits(0xffffffffu);
      tt.elem = valtype();
      m->tables.push_back(tt);
      expect_rpar();
      return;
    }
    // `(table funcref (elem $f ...))` — the size comes from the element list.
    tt.elem = valtype();
    m->tables.push_back(tt);
    if (is_field("elem")) {
      bump();
      bump();
      ElemSeg seg;
      seg.mode = SegMode::Active;
      seg.table = idx;
      seg.offset = Expr{Inst{Op::I32Const, 0, 0, 0, {}}, Inst{Op::End, 0, 0, 0, {}}};
      seg.type = tt.elem;
      elem_items(seg, /*allow_bare_funcidx=*/true);
      m->tables.back().limits.min = static_cast<u32>(seg.init.size());
      m->tables.back().limits.max = static_cast<u32>(seg.init.size());
      m->tables.back().limits.has_max = true;
      m->elems.push_back(std::move(seg));
      elems.add({});
      expect_rpar();
    }
    expect_rpar();
  }

  void memory_field() {
    bump();
    opt_id();
    const u32 idx = m->imported_mems + static_cast<u32>(m->mems.size());
    Import im;
    bool is_import = false;
    inline_extras(ExternKind::Memory, idx, im, is_import);
    if (is_import) {
      im.mem.limits = limits(kMaxPages);
      ++m->imported_mems;
      m->imports.push_back(std::move(im));
      expect_rpar();
      return;
    }
    if (is_field("data")) {
      // `(memory (data "..."))` — the size is the data rounded up to pages.
      bump();
      bump();
      DataSeg seg;
      seg.mode = SegMode::Active;
      seg.mem = idx;
      seg.offset = Expr{Inst{Op::I32Const, 0, 0, 0, {}}, Inst{Op::End, 0, 0, 0, {}}};
      while (cur().kind == Tok::String) {
        seg.bytes.insert(seg.bytes.end(), cur().str.begin(), cur().str.end());
        bump();
      }
      expect_rpar();
      const u32 pages = static_cast<u32>((seg.bytes.size() + kPageSize - 1) / kPageSize);
      m->mems.push_back(MemType{Limits{pages, pages, true}});
      m->datas.push_back(std::move(seg));
      datas.add({});
      expect_rpar();
      return;
    }
    m->mems.push_back(MemType{limits(kMaxPages)});
    expect_rpar();
  }

  void global_field() {
    bump();
    opt_id();
    const u32 idx = m->imported_globals + static_cast<u32>(m->globals.size());
    Import im;
    bool is_import = false;
    inline_extras(ExternKind::Global, idx, im, is_import);
    if (is_import) {
      im.global = globaltype();
      ++m->imported_globals;
      m->imports.push_back(std::move(im));
      expect_rpar();
      return;
    }
    Global g;
    g.type = globaltype();
    labels.clear();
    local_names.clear();
    g.init = instructions();
    g.init.push_back(Inst{Op::End, 0, 0, 0, {}});
    expect_rpar();
    m->globals.push_back(std::move(g));
  }

  void export_field() {
    bump();
    Export ex;
    ex.name = expect_name();
    expect_lpar();
    if (eat_kw("func")) { ex.kind = ExternKind::Func; ex.index = index(funcs, "function"); }
    else if (eat_kw("table")) { ex.kind = ExternKind::Table; ex.index = index(tables, "table"); }
    else if (eat_kw("memory")) { ex.kind = ExternKind::Memory; ex.index = index(mems, "memory"); }
    else if (eat_kw("global")) { ex.kind = ExternKind::Global; ex.index = index(globals, "global"); }
    else { fail("expected func, table, memory or global in an export"); return; }
    expect_rpar();
    expect_rpar();
    m->exports.push_back(std::move(ex));
  }

  Expr const_expr() {
    labels.clear();
    local_names.clear();
    Expr e = instructions();
    e.push_back(Inst{Op::End, 0, 0, 0, {}});
    return e;
  }

  // Exactly one folded instruction, which is what an offset or an element item
  // is when it is not wrapped in `(offset ...)` or `(item ...)`. Reading a whole
  // instruction sequence here would swallow the elements that follow it.
  Expr folded_expr() {
    labels.clear();
    local_names.clear();
    Expr e;
    folded(e);
    e.push_back(Inst{Op::End, 0, 0, 0, {}});
    return e;
  }

  Expr offset_expr() {
    if (is_field("offset")) {
      bump();
      bump();
      Expr e = const_expr();
      expect_rpar();
      return e;
    }
    return folded_expr();
  }

  void elem_items(ElemSeg& seg, bool allow_bare_funcidx) {
    for (;;) {
      if (is_field("item")) {
        bump();
        bump();
        seg.init.push_back(const_expr());
        expect_rpar();
      } else if (is_lpar()) {
        seg.init.push_back(folded_expr());
      } else if (allow_bare_funcidx && at_index() && ok()) {
        Inst rf{Op::RefFunc, index(funcs, "function"), 0, 0, {}};
        seg.init.push_back(Expr{std::move(rf), Inst{Op::End, 0, 0, 0, {}}});
      } else {
        return;
      }
      if (!ok()) return;
    }
  }

  void elem_field() {
    bump();
    opt_id();
    ElemSeg seg;
    bool declared_type = false;
    if (eat_kw("declare")) {
      seg.mode = SegMode::Declarative;
    } else if (is_field("table")) {
      bump();
      bump();
      seg.mode = SegMode::Active;
      seg.table = index(tables, "table");
      expect_rpar();
      seg.offset = offset_expr();
    } else if (is_lpar() && !is_field("item") && !is_field("ref.func") &&
               !is_field("ref.null")) {
      seg.mode = SegMode::Active;
      seg.table = 0;
      seg.offset = offset_expr();
    } else {
      seg.mode = SegMode::Passive;
    }
    bool bare = false;
    if (eat_kw("func")) {
      seg.type = ValType::FuncRef;
      bare = true;
      declared_type = true;
    } else if (cur().kind == Tok::Keyword && valtype_by_name(cur().text, seg.type)) {
      bump();
      declared_type = true;
    } else {
      seg.type = ValType::FuncRef;
      bare = true;
    }
    (void)declared_type;
    elem_items(seg, bare);
    expect_rpar();
    m->elems.push_back(std::move(seg));
  }

  void data_field() {
    bump();
    opt_id();
    DataSeg seg;
    if (is_field("memory")) {
      bump();
      bump();
      seg.mode = SegMode::Active;
      seg.mem = index(mems, "memory");
      expect_rpar();
      seg.offset = offset_expr();
    } else if (is_lpar()) {
      seg.mode = SegMode::Active;
      seg.mem = 0;
      seg.offset = offset_expr();
    } else {
      seg.mode = SegMode::Passive;
    }
    while (cur().kind == Tok::String) {
      seg.bytes.insert(seg.bytes.end(), cur().str.begin(), cur().str.end());
      bump();
    }
    expect_rpar();
    m->datas.push_back(std::move(seg));
  }

  // ---- instructions --------------------------------------------------------

  u32 local_index() {
    if (cur().kind == Tok::Id) {
      for (u32 i = 0; i < local_names.size(); ++i)
        if (local_names[i] == cur().text) { bump(); return i; }
      fail(std::format("undefined local {}", cur().text));
      bump();
      return 0;
    }
    u64 v = 0;
    if (cur().kind == Tok::Keyword && parse_uint(cur().text, 0xffffffffu, v)) {
      bump();
      return static_cast<u32>(v);
    }
    fail("expected a local index");
    return 0;
  }

  u32 label_index() {
    if (cur().kind == Tok::Id) {
      for (std::size_t i = labels.size(); i-- > 0;)
        if (labels[i] == cur().text) {
          bump();
          return static_cast<u32>(labels.size() - 1 - i);
        }
      fail(std::format("undefined label {}", cur().text));
      bump();
      return 0;
    }
    u64 v = 0;
    if (cur().kind == Tok::Keyword && parse_uint(cur().text, 0xffffffffu, v)) {
      bump();
      return static_cast<u32>(v);
    }
    fail("expected a label");
    return 0;
  }

  void blocktype(Inst& in) {
    FuncType ft;
    bool named = false;
    u32 named_idx = 0;
    if (is_field("type")) {
      bump();
      bump();
      named_idx = index(types, "type");
      expect_rpar();
      named = true;
    }
    read_params_results(ft, nullptr);
    if (named) {
      in.a = 2;
      in.b = named_idx;
      return;
    }
    if (ft.params.empty() && ft.results.empty()) { in.a = 0; in.b = 0; return; }
    if (ft.params.empty() && ft.results.size() == 1) {
      in.a = 1;
      in.b = static_cast<u8>(ft.results[0]);
      return;
    }
    // A block that takes parameters or returns several values needs a real type
    // index, which is the same find-or-append the typeuse does.
    for (u32 i = 0; i < m->types.size(); ++i)
      if (m->types[i] == ft) { in.a = 2; in.b = i; return; }
    m->types.push_back(ft);
    types.count = static_cast<u32>(m->types.size());
    in.a = 2;
    in.b = static_cast<u32>(m->types.size() - 1);
  }

  void memarg(Inst& in, u8 natural) {
    in.b = 0;
    in.a = natural;
    if (cur().kind == Tok::Keyword && cur().text.starts_with("offset=")) {
      u64 v = 0;
      if (!parse_uint(cur().text.substr(7), 0xffffffffu, v)) fail("bad offset=");
      in.b = static_cast<u32>(v);
      bump();
    }
    if (cur().kind == Tok::Keyword && cur().text.starts_with("align=")) {
      u64 v = 0;
      if (!parse_uint(cur().text.substr(6), 0xffffffffu, v) || v == 0 || (v & (v - 1)))
        fail("alignment must be a power of two");
      in.a = static_cast<u32>(std::countr_zero(v));
      bump();
    }
  }

  // The immediates of one instruction, given its opcode. The text format and the
  // binary format differ only in how these are spelled, so this switch is the
  // mirror of the one in :binary.
  void immediates(Inst& in) {
    switch (op_info(in.op).imm) {
      case Imm::None: break;
      case Imm::BlockType: blocktype(in); break;
      case Imm::Label: in.a = label_index(); break;
      case Imm::LabelTable: {
        std::vector<u32> all;
        while ((cur().kind == Tok::Id || cur().kind == Tok::Keyword) && ok()) {
          if (cur().kind == Tok::Keyword) {
            Op probe;
            if (op_by_name(cur().text, probe)) break;
            u64 v = 0;
            if (!parse_uint(cur().text, 0xffffffffu, v)) break;
          }
          all.push_back(label_index());
        }
        if (all.empty()) { fail("br_table needs at least a default label"); break; }
        in.a = all.back();
        all.pop_back();
        in.labels = std::move(all);
        break;
      }
      case Imm::Func: in.a = index(funcs, "function"); break;
      case Imm::CallIndirect:
        in.b = at_index() ? index(tables, "table") : 0;
        in.a = typeuse(nullptr);
        break;
      case Imm::Local: in.a = local_index(); break;
      case Imm::Global: in.a = index(globals, "global"); break;
      case Imm::Table:
        in.a = at_index() ? index(tables, "table") : 0;
        break;
      case Imm::TableTable:
        in.a = 0;
        in.b = 0;
        if (at_index()) {
          in.a = index(tables, "table");
          in.b = at_index() ? index(tables, "table") : 0;
        }
        break;
      case Imm::ElemTable: {
        // `table.init x y` names the table then the segment; `table.init y`
        // leaves the table implicit. The instruction stores them the other way
        // round, because that is the order the binary format writes them. Which
        // form this is can only be told by counting first — looking the first
        // name up in the wrong index space would report an error for a program
        // that is fine.
        const std::size_t mark = p;
        int n = 0;
        while (at_index()) { bump(); ++n; }
        p = mark;
        in.b = (n >= 2) ? index(tables, "table") : 0;
        in.a = index(elems, "elem segment");
        break;
      }
      case Imm::Elem: in.a = index(elems, "elem segment"); break;
      case Imm::MemArg: memarg(in, op_info(in.op).natural_align); break;
      case Imm::MemIdx: in.a = 0; break;
      case Imm::MemMem: in.a = 0; in.b = 0; break;
      case Imm::DataMem:
        in.a = index(datas, "data segment");
        in.b = 0;
        break;
      case Imm::Data: in.a = index(datas, "data segment"); break;
      case Imm::I32: case Imm::I64: {
        const unsigned bits = (op_info(in.op).imm == Imm::I32) ? 32 : 64;
        if (cur().kind != Tok::Keyword || !parse_int(cur().text, bits, in.imm))
          fail("expected an integer constant");
        else
          bump();
        break;
      }
      case Imm::F32: {
        f32 v = 0;
        if (cur().kind != Tok::Keyword || !parse_float(cur().text, v))
          fail("expected a float constant");
        else
          bump();
        in.imm = std::bit_cast<u32>(v);
        break;
      }
      case Imm::F64: {
        f64 v = 0;
        if (cur().kind != Tok::Keyword || !parse_float(cur().text, v))
          fail("expected a float constant");
        else
          bump();
        in.imm = std::bit_cast<u64>(v);
        break;
      }
      case Imm::RefType:
        // `ref.null` names a *heap* type, so it is written `func` and `extern`
        // rather than `funcref` and `externref`.
        if (eat_kw("func")) in.a = static_cast<u8>(ValType::FuncRef);
        else if (eat_kw("extern")) in.a = static_cast<u8>(ValType::ExternRef);
        else in.a = static_cast<u8>(valtype());
        break;
      case Imm::SelectT:
        while (is_field("result")) {
          bump();
          bump();
          while (!is_rpar() && ok()) in.labels.push_back(static_cast<u8>(valtype()));
          expect_rpar();
        }
        break;
    }
  }

  // `select` is written the same way with and without a type annotation, so the
  // opcode depends on what follows the keyword.
  Op resolve_select(Op op) {
    if (op != Op::Select && op != Op::SelectT) return op;
    return is_field("result") ? Op::SelectT : Op::Select;
  }

  // The flat form: instructions in a row, `end` closing what `block` opened.
  Expr instructions() {
    Expr out;
    for (;;) {
      if (!ok()) return out;
      if (is_rpar() || cur().kind == Tok::Eof) return out;
      if (is_lpar()) {
        folded(out);
        continue;
      }
      if (cur().kind != Tok::Keyword) { fail("expected an instruction"); return out; }
      const std::string name = cur().text;
      if (name == "end" || name == "else") {
        // Handled by whoever opened the block; seeing one here ends this run.
        return out;
      }
      Op op;
      if (!op_by_name(name, op)) { fail(std::format("unknown instruction `{}`", name)); return out; }
      bump();
      op = resolve_select(op);
      Inst in;
      in.op = op;
      if (op == Op::Block || op == Op::Loop || op == Op::If) {
        const std::string label = opt_id();
        immediates(in);
        out.push_back(std::move(in));
        labels.push_back(label);
        Expr body = instructions();
        out.insert(out.end(), std::make_move_iterator(body.begin()),
                   std::make_move_iterator(body.end()));
        if (is_kw("else")) {
          bump();
          opt_id();
          out.push_back(Inst{Op::Else, 0, 0, 0, {}});
          Expr alt = instructions();
          out.insert(out.end(), std::make_move_iterator(alt.begin()),
                     std::make_move_iterator(alt.end()));
        }
        if (!is_kw("end")) { fail("expected `end`"); return out; }
        bump();
        opt_id();
        labels.pop_back();
        out.push_back(Inst{Op::End, 0, 0, 0, {}});
        continue;
      }
      immediates(in);
      out.push_back(std::move(in));
    }
  }

  // The folded form: `(op operand ...)` puts the operator where a reader wants
  // it and the operands inside. Unfolding is one rule — emit the operands, then
  // the operator — with `if` the only special case, because its condition is an
  // operand but its arms are not.
  void folded(Expr& out) {
    expect_lpar();
    if (cur().kind != Tok::Keyword) { fail("expected an instruction"); return; }
    const std::string name = cur().text;
    Op op;
    if (!op_by_name(name, op)) { fail(std::format("unknown instruction `{}`", name)); return; }
    bump();
    op = resolve_select(op);

    if (op == Op::Block || op == Op::Loop) {
      Inst in;
      in.op = op;
      const std::string label = opt_id();
      immediates(in);
      out.push_back(std::move(in));
      labels.push_back(label);
      Expr body = instructions();
      out.insert(out.end(), std::make_move_iterator(body.begin()),
                 std::make_move_iterator(body.end()));
      labels.pop_back();
      out.push_back(Inst{Op::End, 0, 0, 0, {}});
      expect_rpar();
      return;
    }
    if (op == Op::If) {
      Inst in;
      in.op = op;
      const std::string label = opt_id();
      immediates(in);
      // Whatever comes before `(then ...)` computes the condition.
      while (is_lpar() && !is_field("then") && !is_field("else") && ok()) folded(out);
      out.push_back(std::move(in));
      labels.push_back(label);
      if (!is_field("then")) { fail("expected `(then ...)`"); return; }
      bump();
      bump();
      Expr body = instructions();
      out.insert(out.end(), std::make_move_iterator(body.begin()),
                 std::make_move_iterator(body.end()));
      expect_rpar();
      if (is_field("else")) {
        bump();
        bump();
        out.push_back(Inst{Op::Else, 0, 0, 0, {}});
        Expr alt = instructions();
        out.insert(out.end(), std::make_move_iterator(alt.begin()),
                   std::make_move_iterator(alt.end()));
        expect_rpar();
      }
      labels.pop_back();
      out.push_back(Inst{Op::End, 0, 0, 0, {}});
      expect_rpar();
      return;
    }

    Inst in;
    in.op = op;
    immediates(in);
    while (is_lpar() && ok()) folded(out);
    out.push_back(std::move(in));
    expect_rpar();
  }

  // ---- the module ----------------------------------------------------------

  // The `(type ...)` fields are read before anything else, because a typeuse
  // that spells its signature out appends to the type section, and the spec puts
  // those appended types after every written one. Reading types in field order
  // would interleave them and shift every explicit type index.
  void type_pass() {
    const std::size_t save = p;
    while (is_lpar() && ok()) {
      if (toks[p + 1].kind == Tok::Keyword && toks[p + 1].text == "type") {
        bump();
        type_field();
      } else {
        skip_field();
      }
    }
    p = save;
  }

  void fields() {
    while (is_lpar() && ok()) {
      if (toks[p + 1].kind != Tok::Keyword) { fail("expected a module field"); return; }
      const std::string head = toks[p + 1].text;
      bump();  // `(`
      if (head == "type") { --p; skip_field(); }
      else if (head == "import") import_field();
      else if (head == "func") func_field();
      else if (head == "table") table_field();
      else if (head == "memory") memory_field();
      else if (head == "global") global_field();
      else if (head == "export") export_field();
      else if (head == "start") { bump(); m->start = index(funcs, "function"); expect_rpar(); }
      else if (head == "elem") elem_field();
      else if (head == "data") data_field();
      else { fail(std::format("unknown module field `{}`", head)); return; }
    }
    if (ok() && !is_rpar() && cur().kind != Tok::Eof) fail("expected a module field");
  }

  void module() {
    bool wrapped = false;
    if (is_field("module")) {
      bump();
      bump();
      opt_id();
      wrapped = true;
    }
    register_names();
    if (!ok()) return;
    type_pass();
    if (!ok()) return;
    fields();
    if (!ok()) return;
    // The data count is a fact about the binary format — it lets a decoder know
    // how many segments there are before it reads the code that names them. The
    // text format has no such problem, so it is filled in here rather than
    // written.
    if (!m->datas.empty()) m->data_count = static_cast<u32>(m->datas.size());
    if (wrapped) expect_rpar();
    if (cur().kind != Tok::Eof) fail("trailing text after the module");
  }
};

export bool parse_text(std::string_view src, Module& out, Diag& d) {
  Lexer lex{src, 0, 1, 1, &d};
  std::vector<Token> toks;
  for (;;) {
    Token t = lex.next();
    const bool done = (t.kind == Tok::Eof);
    toks.push_back(std::move(t));
    if (done || d.failed) break;
  }
  if (d.failed) return false;
  // Two Eof tokens, so that a one-token lookahead never runs off the end.
  toks.push_back(Token{Tok::Eof, {}, {}, lex.line, lex.col});

  Parser ps;
  ps.toks = std::move(toks);
  ps.d = &d;
  ps.m = &out;
  ps.module();
  return !d.failed;
}

}  // namespace weasel
