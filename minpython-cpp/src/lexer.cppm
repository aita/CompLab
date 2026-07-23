// Lexer partition — an indentation-aware tokenizer for the MinPython subset.
//
// Mirrors CPython's tokenizer just enough: it tracks an indent stack and emits
// INDENT / DEDENT / NEWLINE tokens, suppresses newlines inside (), [] brackets,
// and drops `#` comments and blank lines. Numbers are integers only; strings are
// single- or double-quoted with a small escape set.
export module minpython:lexer;

import std;

import :value;

export namespace minpython {

enum class Tok {
  Newline, Indent, Dedent, Eof,
  Name, Int, Str,
  // keywords
  Def, Return, If, Elif, Else, While, Break, Continue, Pass, Global,
  And, Or, Not, KwTrue, KwFalse, KwNone,
  // operators
  Plus, Minus, Star, Slash, DoubleSlash, Percent, DoubleStar,
  Amp, Pipe, Caret, Shl, Shr, Tilde,
  Lt, Le, Gt, Ge, EqEq, NotEq,
  Assign, PlusEq, MinusEq, StarEq, SlashEq, DSlashEq, PercentEq, DStarEq,
  AmpEq, PipeEq, CaretEq, ShlEq, ShrEq,
  LParen, RParen, LBracket, RBracket, Colon, Comma,
};

struct Token {
  Tok kind;
  std::string text;      // Name / Str payload
  std::int64_t int_val = 0;   // Int
  int lineno = 0;
};

class Lexer {
 public:
  explicit Lexer(std::string src) : src_(std::move(src)) {}

  bool failed() const { return diag_.failed; }
  const std::string& error() const { return diag_.message; }

  std::vector<Token> tokenize() {
    std::vector<Token> out;
    indents_.push_back(0);
    while (pos_ < src_.size() && !diag_.failed) {
      if (bracket_depth_ == 0 && at_line_start_) {
        handle_indentation(out);
        if (pos_ >= src_.size() || diag_.failed) break;
      }
      char ch = src_[pos_];
      if (ch == '\n') {
        pos_++;
        line_++;
        if (bracket_depth_ == 0 && !at_line_start_) {
          emit(out, Tok::Newline);
          at_line_start_ = true;
        }
        continue;
      }
      if (ch == ' ' || ch == '\t' || ch == '\r') { pos_++; continue; }
      if (ch == '#') { while (pos_ < src_.size() && src_[pos_] != '\n') pos_++; continue; }
      at_line_start_ = false;
      lex_token(out);
    }
    if (!out.empty() && out.back().kind != Tok::Newline)
      emit(out, Tok::Newline);
    while (indents_.size() > 1) { indents_.pop_back(); emit(out, Tok::Dedent); }
    emit(out, Tok::Eof);
    return out;
  }

 private:
  void emit(std::vector<Token>& out, Tok k, std::string text = "",
            std::int64_t iv = 0) {
    out.push_back({k, std::move(text), iv, line_});
  }

  void handle_indentation(std::vector<Token>& out) {
    // Measure the indent of the next non-blank, non-comment line.
    while (pos_ < src_.size()) {
      std::size_t p = pos_;
      int col = 0;
      while (p < src_.size() && (src_[p] == ' ' || src_[p] == '\t')) {
        col += (src_[p] == '\t') ? 8 : 1;
        p++;
      }
      if (p >= src_.size()) { pos_ = p; return; }
      if (src_[p] == '\n') { pos_ = p + 1; line_++; continue; }  // blank line
      if (src_[p] == '#') {  // comment-only line
        while (p < src_.size() && src_[p] != '\n') p++;
        pos_ = p;
        continue;
      }
      pos_ = p;
      at_line_start_ = false;
      if (col > indents_.back()) {
        indents_.push_back(col);
        emit(out, Tok::Indent);
      } else {
        while (col < indents_.back()) {
          indents_.pop_back();
          emit(out, Tok::Dedent);
        }
        if (col != indents_.back())
          diag_.fail(
              std::format("inconsistent indentation at line {}", line_));
      }
      return;
    }
  }

  void lex_token(std::vector<Token>& out) {
    char ch = src_[pos_];
    if (std::isalpha((unsigned char)ch) || ch == '_') { lex_name(out); return; }
    if (std::isdigit((unsigned char)ch)) { lex_number(out); return; }
    if (ch == '"' || ch == '\'') { lex_string(out); return; }
    lex_operator(out);
  }

  void lex_name(std::vector<Token>& out) {
    std::size_t start = pos_;
    while (pos_ < src_.size() &&
           (std::isalnum((unsigned char)src_[pos_]) || src_[pos_] == '_'))
      pos_++;
    std::string s = src_.substr(start, pos_ - start);
    Tok kw = keyword(s);
    if (kw != Tok::Name) emit(out, kw, s);
    else emit(out, Tok::Name, s);
  }

  static Tok keyword(const std::string& s) {
    if (s == "def") return Tok::Def;
    if (s == "return") return Tok::Return;
    if (s == "if") return Tok::If;
    if (s == "elif") return Tok::Elif;
    if (s == "else") return Tok::Else;
    if (s == "while") return Tok::While;
    if (s == "break") return Tok::Break;
    if (s == "continue") return Tok::Continue;
    if (s == "pass") return Tok::Pass;
    if (s == "global") return Tok::Global;
    if (s == "and") return Tok::And;
    if (s == "or") return Tok::Or;
    if (s == "not") return Tok::Not;
    if (s == "True") return Tok::KwTrue;
    if (s == "False") return Tok::KwFalse;
    if (s == "None") return Tok::KwNone;
    return Tok::Name;
  }

  void lex_number(std::vector<Token>& out) {
    std::size_t start = pos_;
    while (pos_ < src_.size() &&
           (std::isdigit((unsigned char)src_[pos_]) || src_[pos_] == '_'))
      pos_++;
    if (pos_ < src_.size() && (src_[pos_] == '.' || src_[pos_] == 'e' ||
                               src_[pos_] == 'E')) {
      diag_.fail("unsupported literal: floats are not supported");
      return;
    }
    std::string digits;
    for (std::size_t i = start; i < pos_; ++i)
      if (src_[i] != '_') digits += src_[i];
    std::int64_t iv = 0;
    std::from_chars(digits.data(), digits.data() + digits.size(), iv);
    emit(out, Tok::Int, "", iv);
  }

  void lex_string(std::vector<Token>& out) {
    char quote = src_[pos_++];
    std::string s;
    while (pos_ < src_.size() && src_[pos_] != quote) {
      char c = src_[pos_++];
      if (c == '\\' && pos_ < src_.size()) {
        char e = src_[pos_++];
        switch (e) {
          case 'n': s += '\n'; break;
          case 't': s += '\t'; break;
          case '\\': s += '\\'; break;
          case '\'': s += '\''; break;
          case '"': s += '"'; break;
          default: s += e; break;
        }
      } else {
        s += c;
      }
    }
    if (pos_ >= src_.size()) {
      diag_.fail("unterminated string literal");
      return;
    }
    pos_++;  // closing quote
    emit(out, Tok::Str, s);
  }

  void lex_operator(std::vector<Token>& out) {
    char c = src_[pos_];
    auto two = [&](char n) {
      return pos_ + 1 < src_.size() && src_[pos_ + 1] == n;
    };
    switch (c) {
      case '(': pos_++; bracket_depth_++; emit(out, Tok::LParen); return;
      case ')': pos_++; if (bracket_depth_) bracket_depth_--; emit(out, Tok::RParen); return;
      case '[': pos_++; bracket_depth_++; emit(out, Tok::LBracket); return;
      case ']': pos_++; if (bracket_depth_) bracket_depth_--; emit(out, Tok::RBracket); return;
      case ':': pos_++; emit(out, Tok::Colon); return;
      case ',': pos_++; emit(out, Tok::Comma); return;
      case '~': pos_++; emit(out, Tok::Tilde); return;
      case '+': pos_++; if (*at() == '=') { pos_++; emit(out, Tok::PlusEq); } else emit(out, Tok::Plus); return;
      case '-': pos_++; if (*at() == '=') { pos_++; emit(out, Tok::MinusEq); } else emit(out, Tok::Minus); return;
      case '%': pos_++; if (*at() == '=') { pos_++; emit(out, Tok::PercentEq); } else emit(out, Tok::Percent); return;
      case '&': pos_++; if (*at() == '=') { pos_++; emit(out, Tok::AmpEq); } else emit(out, Tok::Amp); return;
      case '|': pos_++; if (*at() == '=') { pos_++; emit(out, Tok::PipeEq); } else emit(out, Tok::Pipe); return;
      case '^': pos_++; if (*at() == '=') { pos_++; emit(out, Tok::CaretEq); } else emit(out, Tok::Caret); return;
      case '=': pos_++; if (*at() == '=') { pos_++; emit(out, Tok::EqEq); } else emit(out, Tok::Assign); return;
      case '!':
        if (two('=')) { pos_ += 2; emit(out, Tok::NotEq); return; }
        break;
      case '*':
        if (two('*')) { pos_ += 2; if (*at() == '=') { pos_++; emit(out, Tok::DStarEq); } else emit(out, Tok::DoubleStar); return; }
        pos_++; if (*at() == '=') { pos_++; emit(out, Tok::StarEq); } else emit(out, Tok::Star); return;
      case '/':
        if (two('/')) { pos_ += 2; if (*at() == '=') { pos_++; emit(out, Tok::DSlashEq); } else emit(out, Tok::DoubleSlash); return; }
        pos_++; if (*at() == '=') { pos_++; emit(out, Tok::SlashEq); } else emit(out, Tok::Slash); return;
      case '<':
        if (two('<')) { pos_ += 2; if (*at() == '=') { pos_++; emit(out, Tok::ShlEq); } else emit(out, Tok::Shl); return; }
        pos_++; if (*at() == '=') { pos_++; emit(out, Tok::Le); } else emit(out, Tok::Lt); return;
      case '>':
        if (two('>')) { pos_ += 2; if (*at() == '=') { pos_++; emit(out, Tok::ShrEq); } else emit(out, Tok::Shr); return; }
        pos_++; if (*at() == '=') { pos_++; emit(out, Tok::Ge); } else emit(out, Tok::Gt); return;
    }
    diag_.fail(std::format("unexpected character '{}' at line {}",
                           std::string(1, c), line_));
    pos_++;  // make progress so the tokenize loop can terminate
  }

  // Peek the current char (or '\0' at end) -- used after pos_ was advanced.
  const char* at() const {
    static const char nul = '\0';
    return pos_ < src_.size() ? &src_[pos_] : &nul;
  }

  std::string src_;
  std::size_t pos_ = 0;
  int line_ = 1;
  int bracket_depth_ = 0;
  bool at_line_start_ = true;
  std::vector<int> indents_;
  Diag diag_;
};

}  // namespace minpython
