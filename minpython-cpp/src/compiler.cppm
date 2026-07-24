// Compiler partition — AST -> register bytecode, a port of minpython/compile.py.
//
// A function's named locals (params + every assigned name, minus `global`s) get
// stable low registers 0..n_locals-1; everything above is a temporary stack that
// expressions push onto and operators pop. No liveness -- correctness first; the
// trace JIT is where cleverness pays off.
//
// A Program owns the module CodeObject plus every nested function CodeObject and
// every string-constant Object, so raw pointers in const pools stay valid for
// the life of the run.
export module minpython:compiler;

import std;

import :value;
import :bytecode;
import :ast;
import :lexer;
import :parser;

export namespace minpython {

struct Program {
  std::vector<std::unique_ptr<CodeObject>> units;
  std::vector<std::unique_ptr<Object>> objects;  // string constants
  CodeObject* module = nullptr;
};

namespace detail {

// Names a function binds -> its locals. Walks the body but not nested function
// bodies. Order is first-appearance so register numbers are stable.
inline void collect_assigned(const std::vector<StmtPtr>& body,
                             std::vector<std::string>& found,
                             std::unordered_set<std::string>& seen);

inline void collect_from_stmt(const Stmt* s, std::vector<std::string>& found,
                              std::unordered_set<std::string>& seen) {
  auto add = [&](const std::string& n) {
    if (seen.insert(n).second) found.push_back(n);
  };
  switch (s->kind) {
    case StmtKind::FunctionDef:
      add(s->name);  // binds its own name; do not recurse into the body
      return;
    case StmtKind::Assign:
      for (auto& t : s->targets) add(t);
      break;
    case StmtKind::AugAssign:
      for (auto& t : s->targets) add(t);
      break;
    case StmtKind::If:
    case StmtKind::While:
      collect_assigned(s->body, found, seen);
      collect_assigned(s->orelse, found, seen);
      break;
    default:
      break;
  }
}

inline void collect_assigned(const std::vector<StmtPtr>& body,
                             std::vector<std::string>& found,
                             std::unordered_set<std::string>& seen) {
  for (auto& s : body) collect_from_stmt(s.get(), found, seen);
}

}  // namespace detail

class Compiler {
 public:
  Compiler(std::string name, std::vector<std::string> params,
           const std::vector<StmtPtr>& body, bool is_module, Program& prog,
           Diag& diag)
      : name_(std::move(name)),
        params_(std::move(params)),
        body_(body),
        is_module_(is_module),
        prog_(prog),
        diag_(diag) {
    for (auto& s : body_)
      if (s->kind == StmtKind::Global)
        for (auto& n : s->params) declared_global_.insert(n);

    if (!is_module_) {
      locals_ = params_;
      std::vector<std::string> assigned;
      std::unordered_set<std::string> seen;
      detail::collect_assigned(body_, assigned, seen);
      for (auto& n : assigned)
        if (std::find(locals_.begin(), locals_.end(), n) == locals_.end() &&
            !declared_global_.count(n))
          locals_.push_back(n);
    }
    for (std::size_t i = 0; i < locals_.size(); ++i) local_index_[locals_[i]] = (int)i;
    n_locals_ = (int)locals_.size();
    top_ = n_locals_;
    n_regs_ = n_locals_;
  }

  CodeObject* compile() {
    for (auto& s : body_) {
      stmt(s.get());
      if (diag_.failed) break;
    }
    int r = push();
    emit(Op::LoadConst, r, const_scalar(Value::none()));
    emit(Op::Return, r);
    resolve();
    auto co = std::make_unique<CodeObject>();
    co->name = name_;
    co->params = params_;
    co->n_locals = n_locals_;
    co->n_regs = n_regs_;
    co->consts = std::move(consts_);
    co->const_codes = std::move(const_codes_);
    co->names = std::move(names_);
    co->code = std::move(code_);
    co->local_names = locals_;
    co->feedback.resize(co->code.size());
    co->param_tags.resize(co->params.size());
    CodeObject* ptr = co.get();
    prog_.units.push_back(std::move(co));
    return ptr;
  }

 private:
  // -- register / pool helpers --------------------------------------------
  int push() {
    int r = top_++;
    if (top_ > n_regs_) n_regs_ = top_;
    return r;
  }

  int const_scalar(const Value& v) {
    for (std::size_t i = 0; i < consts_.size(); ++i) {
      if (const_codes_[i]) continue;
      const Value& e = consts_[i];
      if (e.tag != v.tag) continue;
      bool eq = (v.tag == Tag::None) ||
                ((v.tag == Tag::Int || v.tag == Tag::Bool) && e.i == v.i) ||
                (v.tag == Tag::Str && e.obj->str == v.obj->str);
      if (eq) return (int)i;
    }
    consts_.push_back(v);
    const_codes_.push_back(nullptr);
    return (int)consts_.size() - 1;
  }

  int const_code(const CodeObject* child) {
    consts_.push_back(Value::none());
    const_codes_.push_back(child);
    return (int)consts_.size() - 1;
  }

  Value make_str_const(const std::string& s) {
    auto o = std::make_unique<Object>();
    o->kind = Object::Kind::Str;
    o->str = s;
    Value v = Value::object(Tag::Str, o.get());
    prog_.objects.push_back(std::move(o));
    return v;
  }

  int name_index(const std::string& n) {
    for (std::size_t i = 0; i < names_.size(); ++i)
      if (names_[i] == n) return (int)i;
    names_.push_back(n);
    return (int)names_.size() - 1;
  }

  // -- emission / labels --------------------------------------------------
  int emit(Op op, int a = 0, int b = 0, int c = 0) {
    code_.push_back({op, a, b, c});
    return (int)code_.size() - 1;
  }

  int new_label() { label_pos_.push_back(-1); return (int)label_pos_.size() - 1; }
  void bind(int label) { label_pos_[label] = (int)code_.size(); }
  void resolve() {
    for (auto& [pc, is_a, label] : fixups_) {
      if (label_pos_[label] < 0) {
        diag_.fail("internal: unbound jump label");
        return;
      }
      if (is_a) code_[pc].a = label_pos_[label];
      else code_[pc].b = label_pos_[label];
    }
  }
  void emit_jump(Op op, int label, int cond = 0) {
    int pc = (op == Op::Jump) ? emit(op, 0) : emit(op, cond, 0);
    fixups_.push_back({pc, op == Op::Jump, label});
  }

  // -- name access --------------------------------------------------------
  bool is_local(const std::string& n) const {
    return local_index_.count(n) && !declared_global_.count(n);
  }

  int load_name(const std::string& n, int into = -1) {
    if (is_local(n)) {
      int reg = local_index_.at(n);
      if (into != -1 && into != reg) { emit(Op::Move, into, reg); return into; }
      return reg;
    }
    int dst = (into != -1) ? into : push();
    emit(Op::LoadGlobal, dst, name_index(n));
    return dst;
  }

  void store_name(const std::string& n, int src) {
    if (is_local(n)) {
      int dst = local_index_.at(n);
      if (dst != src) emit(Op::Move, dst, src);
    } else {
      emit(Op::StoreGlobal, name_index(n), src);
    }
  }

  // -- expressions --------------------------------------------------------
  int expr(const Expr* node) {
    if (diag_.failed) return 0;
    switch (node->kind) {
      case ExprKind::ConstInt: {
        int dst = push();
        emit(Op::LoadConst, dst, const_scalar(Value::integer(node->int_val)));
        return dst;
      }
      case ExprKind::ConstBool: {
        int dst = push();
        emit(Op::LoadConst, dst, const_scalar(Value::boolean(node->bool_val)));
        return dst;
      }
      case ExprKind::ConstNone: {
        int dst = push();
        emit(Op::LoadConst, dst, const_scalar(Value::none()));
        return dst;
      }
      case ExprKind::ConstStr: {
        int dst = push();
        emit(Op::LoadConst, dst, const_scalar(make_str_const(node->str_val)));
        return dst;
      }
      case ExprKind::Name:
        return load_name(node->str_val);
      case ExprKind::List: {
        int base = top_;
        for (auto& elt : node->elts) into(elt.get(), push());
        top_ = base;
        int dst = push();
        emit(Op::MakeList, dst, base, (int)node->elts.size());
        return dst;
      }
      case ExprKind::Subscript: {
        int mark = top_;
        int obj = expr(node->obj.get());
        int idx = expr(node->index.get());
        top_ = mark;
        int dst = push();
        emit(Op::Subscr, dst, obj, idx);
        return dst;
      }
      case ExprKind::BinOp: {
        int mark = top_;
        int lhs = expr(node->lhs.get());
        int rhs = expr(node->rhs.get());
        top_ = mark;
        int dst = push();
        emit(node->op, dst, lhs, rhs);
        return dst;
      }
      case ExprKind::UnaryOp: {
        int mark = top_;
        int src = expr(node->operand.get());
        top_ = mark;
        int dst = push();
        emit(node->op, dst, src);
        return dst;
      }
      case ExprKind::BoolOp:
        return boolop(node);
      case ExprKind::Compare:
        return compare(node);
      case ExprKind::IfExp: {
        int dst = push();
        into_cond(node->body.get(), dst, node->test.get(), node->orelse.get());
        return dst;
      }
      case ExprKind::Call:
        return call(node);
    }
    diag_.fail("internal: unhandled expr kind");
    return 0;
  }

  void into(const Expr* node, int dst) {
    int mark = top_;
    int r = expr(node);
    top_ = mark;
    if (r != dst) emit(Op::Move, dst, r);
  }

  void into_cond(const Expr* node, int dst, const Expr* guard,
                 const Expr* orelse) {
    int end = new_label(), other = new_label();
    branch_if_false(guard, other);
    into(node, dst);
    emit_jump(Op::Jump, end);
    bind(other);
    into(orelse, dst);
    bind(end);
  }

  int boolop(const Expr* node) {
    Op shortc = node->is_and ? Op::JumpIfFalse : Op::JumpIfTrue;
    int dst = push();
    int end = new_label();
    for (std::size_t i = 0; i < node->elts.size(); ++i) {
      into(node->elts[i].get(), dst);
      if (i != node->elts.size() - 1) emit_jump(shortc, end, dst);
    }
    bind(end);
    return dst;
  }

  int compare(const Expr* node) {
    int dst = push();
    int mark = top_;
    int end = new_label();
    int cur = expr(node->lhs.get());
    for (std::size_t i = 0; i < node->ops.size(); ++i) {
      int nxt = expr(node->elts[i].get());
      emit(node->ops[i], dst, cur, nxt);
      if (i != node->ops.size() - 1) emit_jump(Op::JumpIfFalse, end, dst);
      cur = nxt;
    }
    top_ = mark;
    bind(end);
    return dst;
  }

  void branch_if_false(const Expr* test, int target) {
    int mark = top_;
    int cond = expr(test);
    top_ = mark;
    emit_jump(Op::JumpIfFalse, target, cond);
  }

  int call(const Expr* node) {
    const std::string& name = node->str_val;
    if (name == "print") {
      int base = top_;
      for (auto& arg : node->elts) into(arg.get(), push());
      top_ = base;
      emit(Op::Print, base, (int)node->elts.size());
      int dst = push();
      emit(Op::LoadConst, dst, const_scalar(Value::none()));
      return dst;
    }
    if (name == "len") {
      if (node->elts.size() != 1) {
        diag_.fail("len() takes exactly one argument");
        return push();
      }
      int mark = top_;
      int src = expr(node->elts[0].get());
      top_ = mark;
      int dst = push();
      emit(Op::Len, dst, src);
      return dst;
    }
    int base = top_;
    int freg = push();
    load_name(name, freg);
    for (auto& arg : node->elts) into(arg.get(), push());
    top_ = base;
    int dst = push();
    emit(Op::Call, dst, freg, (int)node->elts.size());
    return dst;
  }

  // -- statements ---------------------------------------------------------
  void stmt(const Stmt* node) {
    if (diag_.failed) return;
    int mark = top_;
    switch (node->kind) {
      case StmtKind::FunctionDef:
        function_def(node);
        break;
      case StmtKind::Return: {
        int r;
        if (!node->value) {
          r = push();
          emit(Op::LoadConst, r, const_scalar(Value::none()));
        } else {
          r = expr(node->value.get());
        }
        emit(Op::Return, r);
        break;
      }
      case StmtKind::Assign: {
        int src = expr(node->value.get());
        for (auto& t : node->targets) store_name(t, src);
        break;
      }
      case StmtKind::AugAssign: {
        int cur = load_name(node->targets[0]);
        int delta = expr(node->value.get());
        int dst = push();
        emit(node->op, dst, cur, delta);
        store_name(node->targets[0], dst);
        break;
      }
      case StmtKind::ExprStmt:
        expr(node->value.get());
        break;
      case StmtKind::If:
        if_stmt(node);
        break;
      case StmtKind::While:
        while_stmt(node);
        break;
      case StmtKind::Break:
        if (loops_.empty()) { diag_.fail("'break' outside loop"); break; }
        emit_jump(Op::Jump, loops_.back().second);
        break;
      case StmtKind::Continue:
        if (loops_.empty()) { diag_.fail("'continue' outside loop"); break; }
        emit_jump(Op::Jump, loops_.back().first);
        break;
      case StmtKind::Pass:
      case StmtKind::Global:
        break;
    }
    top_ = mark;
  }

  void if_stmt(const Stmt* node) {
    int else_label = new_label();
    branch_if_false(node->value.get(), else_label);
    for (auto& s : node->body) stmt(s.get());
    if (!node->orelse.empty()) {
      int end = new_label();
      emit_jump(Op::Jump, end);
      bind(else_label);
      for (auto& s : node->orelse) stmt(s.get());
      bind(end);
    } else {
      bind(else_label);
    }
  }

  void while_stmt(const Stmt* node) {
    int top = new_label(), end = new_label();
    bind(top);
    branch_if_false(node->value.get(), end);
    loops_.push_back({top, end});
    for (auto& s : node->body) stmt(s.get());
    loops_.pop_back();
    emit_jump(Op::Jump, top);  // the back-edge: hot-loop anchor
    bind(end);
  }

  void function_def(const Stmt* node) {
    Compiler child(node->name, node->params, node->body, false, prog_, diag_);
    CodeObject* co = child.compile();
    int dst = push();
    emit(Op::MakeFunction, dst, const_code(co));
    store_name(node->name, dst);
  }

  std::string name_;
  std::vector<std::string> params_;
  const std::vector<StmtPtr>& body_;
  bool is_module_;
  Program& prog_;
  Diag& diag_;

  std::unordered_set<std::string> declared_global_;
  std::vector<std::string> locals_;
  std::unordered_map<std::string, int> local_index_;

  std::vector<Value> consts_;
  std::vector<const CodeObject*> const_codes_;
  std::vector<std::string> names_;
  std::vector<Instr> code_;

  int n_locals_ = 0, top_ = 0, n_regs_ = 0;
  std::vector<int> label_pos_;
  std::vector<std::tuple<int, bool, int>> fixups_;  // (pc, is_a, label)
  std::vector<std::pair<int, int>> loops_;          // (continue, break) labels
};

// Compile `source` to a Program. On failure returns nullptr and sets `err`.
inline std::unique_ptr<Program> compile_module(const std::string& source,
                                               std::string& err) {
  Lexer lexer(source);
  std::vector<Token> toks = lexer.tokenize();
  if (lexer.failed()) { err = lexer.error(); return nullptr; }

  Parser parser(std::move(toks));
  std::vector<StmtPtr> body = parser.parse_module();
  if (parser.failed()) { err = parser.error(); return nullptr; }

  auto prog = std::make_unique<Program>();
  Diag diag;
  Compiler c("<module>", {}, body, true, *prog, diag);
  prog->module = c.compile();
  if (diag.failed) { err = diag.message; return nullptr; }
  return prog;
}

}  // namespace minpython
