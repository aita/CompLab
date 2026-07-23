// Parser partition — a recursive-descent parser producing the fat-node AST.
//
// Grammar is the MinPython subset: def / if-elif-else / while / return / assign /
// augassign / expression statements, and a full expression precedence ladder
// (ternary, or, and, not, comparison chains, bit ops, shifts, +-, */ //%, unary,
// **, calls, subscripts, atoms). Unsupported operators (`/`) fail here with the
// same message the Python compiler gives.
//
// No exceptions: a failure latches `diag_` and returns a dummy node; loops and
// recursion check the latch and unwind. The caller discards the tree on failure.
export module minpython:parser;

import std;

import :value;
import :lexer;
import :ast;
import :bytecode;

export namespace minpython {

class Parser {
 public:
  explicit Parser(std::vector<Token> toks) : toks_(std::move(toks)) {}

  bool failed() const { return diag_.failed; }
  const std::string& error() const { return diag_.message; }

  std::vector<StmtPtr> parse_module() {
    std::vector<StmtPtr> body;
    while (!at(Tok::Eof) && !diag_.failed) {
      if (at(Tok::Newline)) { advance(); continue; }
      body.push_back(statement());
    }
    return body;
  }

 private:
  // -- token cursor -------------------------------------------------------
  const Token& peek(int k = 0) const { return toks_[pos_ + k]; }
  bool at(Tok k) const { return peek().kind == k; }
  const Token& advance() { return toks_[pos_++]; }
  bool accept(Tok k) {
    if (at(k)) { pos_++; return true; }
    return false;
  }
  const Token& expect(Tok k, const char* what) {
    if (!at(k)) {
      diag_.fail(std::format("expected {} at line {}", what, peek().lineno));
      return peek();  // no advance; the latch stops parsing
    }
    return advance();
  }

  ExprPtr none_expr() {
    auto e = std::make_unique<Expr>();
    e->kind = ExprKind::ConstNone;
    return e;
  }
  ExprPtr fail_expr(std::string m) {
    diag_.fail(std::move(m));
    return none_expr();
  }
  StmtPtr pass_stmt() {
    auto s = std::make_unique<Stmt>();
    s->kind = StmtKind::Pass;
    return s;
  }
  StmtPtr fail_stmt(std::string m) {
    diag_.fail(std::move(m));
    return pass_stmt();
  }

  // -- statements ---------------------------------------------------------
  StmtPtr statement() {
    switch (peek().kind) {
      case Tok::Def: return function_def();
      case Tok::If: return if_stmt();
      case Tok::While: return while_stmt();
      default: return simple_statement();
    }
  }

  StmtPtr function_def() {
    int ln = peek().lineno;
    advance();  // def
    std::string name = expect(Tok::Name, "function name").text;
    expect(Tok::LParen, "'('");
    std::vector<std::string> params;
    if (!at(Tok::RParen)) {
      do {
        params.push_back(expect(Tok::Name, "parameter name").text);
      } while (!diag_.failed && accept(Tok::Comma));
    }
    expect(Tok::RParen, "')'");
    expect(Tok::Colon, "':'");
    auto s = std::make_unique<Stmt>();
    s->kind = StmtKind::FunctionDef;
    s->lineno = ln;
    s->name = name;
    s->params = std::move(params);
    s->body = block();
    return s;
  }

  StmtPtr if_stmt() {
    int ln = peek().lineno;
    advance();  // if / elif
    auto s = std::make_unique<Stmt>();
    s->kind = StmtKind::If;
    s->lineno = ln;
    s->value = expression();
    expect(Tok::Colon, "':'");
    s->body = block();
    if (at(Tok::Elif)) {
      s->orelse.push_back(if_stmt());  // elif chains as a nested If
    } else if (accept(Tok::Else)) {
      expect(Tok::Colon, "':'");
      s->orelse = block();
    }
    return s;
  }

  StmtPtr while_stmt() {
    int ln = peek().lineno;
    advance();  // while
    auto s = std::make_unique<Stmt>();
    s->kind = StmtKind::While;
    s->lineno = ln;
    s->value = expression();
    expect(Tok::Colon, "':'");
    s->body = block();
    if (at(Tok::Else)) return fail_stmt("while/else is not supported");
    return s;
  }

  // A suite: either an inline simple statement, or an indented block.
  std::vector<StmtPtr> block() {
    std::vector<StmtPtr> body;
    if (accept(Tok::Newline)) {
      expect(Tok::Indent, "an indented block");
      while (!at(Tok::Dedent) && !at(Tok::Eof) && !diag_.failed) {
        if (at(Tok::Newline)) { advance(); continue; }
        body.push_back(statement());
      }
      expect(Tok::Dedent, "a dedent");
    } else {
      body.push_back(simple_statement());
    }
    return body;
  }

  StmtPtr simple_statement() {
    StmtPtr s = small_statement();
    if (!at(Tok::Eof)) expect(Tok::Newline, "a newline");
    return s;
  }

  StmtPtr small_statement() {
    int ln = peek().lineno;
    switch (peek().kind) {
      case Tok::Return: {
        advance();
        auto s = std::make_unique<Stmt>();
        s->kind = StmtKind::Return;
        s->lineno = ln;
        if (!at(Tok::Newline) && !at(Tok::Eof)) s->value = expression();
        return s;
      }
      case Tok::Break: {
        advance();
        auto s = std::make_unique<Stmt>();
        s->kind = StmtKind::Break;
        s->lineno = ln;
        return s;
      }
      case Tok::Continue: {
        advance();
        auto s = std::make_unique<Stmt>();
        s->kind = StmtKind::Continue;
        s->lineno = ln;
        return s;
      }
      case Tok::Pass: {
        advance();
        auto s = std::make_unique<Stmt>();
        s->kind = StmtKind::Pass;
        s->lineno = ln;
        return s;
      }
      case Tok::Global: {
        advance();
        auto s = std::make_unique<Stmt>();
        s->kind = StmtKind::Global;
        s->lineno = ln;
        do {
          s->params.push_back(expect(Tok::Name, "a name").text);
        } while (!diag_.failed && accept(Tok::Comma));
        return s;
      }
      default:
        return expr_or_assign(ln);
    }
  }

  StmtPtr expr_or_assign(int ln) {
    ExprPtr first = expression();
    // augmented assignment?
    if (Op aug; aug_op(peek().kind, aug)) {
      advance();
      auto s = std::make_unique<Stmt>();
      s->kind = StmtKind::AugAssign;
      s->lineno = ln;
      s->op = aug;
      s->targets.push_back(target_name(first, "augmented assignment target"));
      s->value = expression();
      return s;
    }
    // plain assignment (possibly chained a = b = value)
    if (at(Tok::Assign)) {
      std::vector<std::string> targets;
      targets.push_back(target_name(first, "assignment target"));
      ExprPtr rhs;
      while (accept(Tok::Assign)) {
        ExprPtr e = expression();
        if (at(Tok::Assign))
          targets.push_back(target_name(e, "assignment target"));
        else
          rhs = std::move(e);
      }
      auto s = std::make_unique<Stmt>();
      s->kind = StmtKind::Assign;
      s->lineno = ln;
      s->targets = std::move(targets);
      s->value = std::move(rhs);
      return s;
    }
    auto s = std::make_unique<Stmt>();
    s->kind = StmtKind::ExprStmt;
    s->lineno = ln;
    s->value = std::move(first);
    return s;
  }

  std::string target_name(const ExprPtr& e, const char* what) {
    if (e->kind != ExprKind::Name) {
      diag_.fail(std::format("only simple name {}s are supported", what));
      return "";
    }
    return e->str_val;
  }

  bool aug_op(Tok t, Op& out) {
    switch (t) {
      case Tok::PlusEq: out = Op::Add; return true;
      case Tok::MinusEq: out = Op::Sub; return true;
      case Tok::StarEq: out = Op::Mul; return true;
      case Tok::DSlashEq: out = Op::FloorDiv; return true;
      case Tok::PercentEq: out = Op::Mod; return true;
      case Tok::DStarEq: out = Op::Pow; return true;
      case Tok::AmpEq: out = Op::BitAnd; return true;
      case Tok::PipeEq: out = Op::BitOr; return true;
      case Tok::CaretEq: out = Op::BitXor; return true;
      case Tok::ShlEq: out = Op::LShift; return true;
      case Tok::ShrEq: out = Op::RShift; return true;
      case Tok::SlashEq:
        diag_.fail("'/' is not supported (it yields a float); use '//'");
        return false;
      default: return false;
    }
  }

  // -- expressions (precedence climbing) ----------------------------------
  ExprPtr expression() { return ternary(); }

  ExprPtr ternary() {
    ExprPtr body = or_test();
    if (accept(Tok::If)) {
      auto e = std::make_unique<Expr>();
      e->kind = ExprKind::IfExp;
      e->body = std::move(body);
      e->test = or_test();
      expect(Tok::Else, "'else' in conditional expression");
      e->orelse = ternary();
      return e;
    }
    return body;
  }

  ExprPtr or_test() { return bool_chain(Tok::Or, false); }
  ExprPtr and_test_entry() { return bool_chain(Tok::And, true); }

  ExprPtr bool_chain(Tok kw, bool is_and) {
    ExprPtr left = is_and ? not_test() : and_test_entry();
    if (!at(kw)) return left;
    auto e = std::make_unique<Expr>();
    e->kind = ExprKind::BoolOp;
    e->is_and = is_and;
    e->elts.push_back(std::move(left));
    while (!diag_.failed && accept(kw))
      e->elts.push_back(is_and ? not_test() : and_test_entry());
    return e;
  }

  ExprPtr not_test() {
    if (accept(Tok::Not)) {
      auto e = std::make_unique<Expr>();
      e->kind = ExprKind::UnaryOp;
      e->op = Op::Not;
      e->operand = not_test();
      return e;
    }
    return comparison();
  }

  ExprPtr comparison() {
    ExprPtr left = bit_or();
    if (!is_cmp(peek().kind)) return left;
    auto e = std::make_unique<Expr>();
    e->kind = ExprKind::Compare;
    e->lhs = std::move(left);
    while (is_cmp(peek().kind) && !diag_.failed) {
      e->ops.push_back(cmp_op(advance().kind));
      e->elts.push_back(bit_or());
    }
    return e;
  }

  ExprPtr bit_or() { return left_binop(&Parser::bit_xor, {{Tok::Pipe, Op::BitOr}}); }
  ExprPtr bit_xor() { return left_binop(&Parser::bit_and, {{Tok::Caret, Op::BitXor}}); }
  ExprPtr bit_and() { return left_binop(&Parser::shift, {{Tok::Amp, Op::BitAnd}}); }
  ExprPtr shift() {
    return left_binop(&Parser::arith, {{Tok::Shl, Op::LShift}, {Tok::Shr, Op::RShift}});
  }
  ExprPtr arith() {
    return left_binop(&Parser::term, {{Tok::Plus, Op::Add}, {Tok::Minus, Op::Sub}});
  }
  ExprPtr term() {
    ExprPtr e = left_binop(&Parser::factor,
                           {{Tok::Star, Op::Mul}, {Tok::DoubleSlash, Op::FloorDiv},
                            {Tok::Percent, Op::Mod}});
    if (at(Tok::Slash))
      return fail_expr("'/' is not supported (it yields a float); use '//'");
    return e;
  }

  ExprPtr factor() {
    Tok t = peek().kind;
    if (t == Tok::Minus || t == Tok::Plus || t == Tok::Tilde) {
      advance();
      auto e = std::make_unique<Expr>();
      e->kind = ExprKind::UnaryOp;
      e->op = (t == Tok::Minus) ? Op::Neg : (t == Tok::Plus) ? Op::Pos : Op::Invert;
      e->operand = factor();
      return e;
    }
    if (at(Tok::Slash))
      return fail_expr("'/' is not supported (it yields a float); use '//'");
    return power();
  }

  ExprPtr power() {
    ExprPtr base = atom_expr();
    if (accept(Tok::DoubleStar)) {
      auto e = std::make_unique<Expr>();
      e->kind = ExprKind::BinOp;
      e->op = Op::Pow;
      e->lhs = std::move(base);
      e->rhs = factor();  // right-associative
      return e;
    }
    return base;
  }

  ExprPtr atom_expr() {
    ExprPtr e = atom();
    while (!diag_.failed) {
      if (at(Tok::LParen)) {
        if (e->kind != ExprKind::Name)
          return fail_expr("only calls to named functions are supported");
        e = call(std::move(e));
      } else if (at(Tok::LBracket)) {
        e = subscript(std::move(e));
      } else {
        break;
      }
    }
    return e;
  }

  ExprPtr call(ExprPtr callee) {
    advance();  // (
    auto e = std::make_unique<Expr>();
    e->kind = ExprKind::Call;
    e->str_val = callee->str_val;
    if (!at(Tok::RParen)) {
      do {
        if (at(Tok::Name) && peek(1).kind == Tok::Assign)
          return fail_expr("keyword arguments are not supported");
        e->elts.push_back(expression());
      } while (!diag_.failed && accept(Tok::Comma));
    }
    expect(Tok::RParen, "')'");
    return e;
  }

  ExprPtr subscript(ExprPtr obj) {
    advance();  // [
    auto e = std::make_unique<Expr>();
    e->kind = ExprKind::Subscript;
    e->obj = std::move(obj);
    e->index = expression();
    if (at(Tok::Colon)) return fail_expr("slices are not supported");
    expect(Tok::RBracket, "']'");
    return e;
  }

  ExprPtr atom() {
    const Token& t = peek();
    switch (t.kind) {
      case Tok::Int: {
        advance();
        auto e = std::make_unique<Expr>();
        e->kind = ExprKind::ConstInt;
        e->int_val = t.int_val;
        return e;
      }
      case Tok::Str: {
        advance();
        auto e = std::make_unique<Expr>();
        e->kind = ExprKind::ConstStr;
        e->str_val = t.text;
        return e;
      }
      case Tok::KwTrue:
      case Tok::KwFalse: {
        advance();
        auto e = std::make_unique<Expr>();
        e->kind = ExprKind::ConstBool;
        e->bool_val = (t.kind == Tok::KwTrue);
        return e;
      }
      case Tok::KwNone: {
        advance();
        auto e = std::make_unique<Expr>();
        e->kind = ExprKind::ConstNone;
        return e;
      }
      case Tok::Name: {
        advance();
        auto e = std::make_unique<Expr>();
        e->kind = ExprKind::Name;
        e->str_val = t.text;
        return e;
      }
      case Tok::LParen: {
        advance();
        ExprPtr e = expression();
        expect(Tok::RParen, "')'");
        return e;
      }
      case Tok::LBracket: {
        advance();
        auto e = std::make_unique<Expr>();
        e->kind = ExprKind::List;
        if (!at(Tok::RBracket)) {
          do {
            if (at(Tok::RBracket)) break;  // trailing comma
            e->elts.push_back(expression());
          } while (!diag_.failed && accept(Tok::Comma));
        }
        expect(Tok::RBracket, "']'");
        return e;
      }
      default:
        return fail_expr(std::format("unexpected token at line {}", t.lineno));
    }
  }

  // -- helpers ------------------------------------------------------------
  using SubRule = ExprPtr (Parser::*)();
  ExprPtr left_binop(SubRule sub, std::vector<std::pair<Tok, Op>> ops) {
    ExprPtr left = (this->*sub)();
    while (!diag_.failed) {
      Op matched{};
      bool found = false;
      for (auto& [t, o] : ops)
        if (at(t)) { matched = o; found = true; break; }
      if (!found) return left;
      advance();
      auto e = std::make_unique<Expr>();
      e->kind = ExprKind::BinOp;
      e->op = matched;
      e->lhs = std::move(left);
      e->rhs = (this->*sub)();
      left = std::move(e);
    }
    return left;
  }

  static bool is_cmp(Tok t) {
    return t == Tok::Lt || t == Tok::Le || t == Tok::Gt || t == Tok::Ge ||
           t == Tok::EqEq || t == Tok::NotEq;
  }
  static Op cmp_op(Tok t) {
    switch (t) {
      case Tok::Lt: return Op::Lt;
      case Tok::Le: return Op::Le;
      case Tok::Gt: return Op::Gt;
      case Tok::Ge: return Op::Ge;
      case Tok::EqEq: return Op::Eq;
      default: return Op::Ne;
    }
  }

  std::vector<Token> toks_;
  std::size_t pos_ = 0;
  Diag diag_;
};

}  // namespace minpython
