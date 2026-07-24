// VM partition — the register dispatch loop, a port of minpython/vm.py.
//
// One run_frame call executes one function activation; a CALL recurses into
// another run_frame, so the host C++ stack is the call stack. The back-edge of
// every `while` is an unconditional JUMP to a lower pc -- the only place a loop
// re-enters -- so that is where the profiler counts and where on_backedge lets
// the JIT take over. The base VM only counts; it never changes behaviour.
//
// Runtime errors are latched into `diag` (this project has no exceptions); the
// dispatch loop bails the moment a latch is set, unwinding every active frame.
export module minpython:vm;

import std;

import :value;
import :bytecode;

export namespace minpython {

// -- runtime arithmetic on tagged values ------------------------------------
// Callers guard the zero-divisor / negative-exponent cases; these are pure.

inline std::int64_t py_floordiv(std::int64_t a, std::int64_t b) {
  std::int64_t q = a / b;
  if ((a % b != 0) && ((a < 0) != (b < 0))) q--;
  return q;
}
inline std::int64_t py_mod(std::int64_t a, std::int64_t b) {
  std::int64_t r = a % b;
  if (r != 0 && ((r < 0) != (b < 0))) r += b;
  return r;
}
inline std::int64_t py_pow(std::int64_t a, std::int64_t e) {
  std::int64_t r = 1;
  while (e) {
    if (e & 1) r *= a;
    a *= a;
    e >>= 1;
  }
  return r;
}

// repr() -- how a value looks inside a container (str quoted).
inline std::string to_repr(const Value& v);
// str() -- how print() renders a value (str raw).
inline std::string to_display(const Value& v) {
  switch (v.tag) {
    case Tag::None: return "None";
    case Tag::Bool: return v.i ? "True" : "False";
    case Tag::Int: return std::format("{}", v.i);
    case Tag::Str: return v.obj->str;
    case Tag::List: {
      std::string s = "[";
      for (std::size_t i = 0; i < v.obj->list.size(); ++i)
        s += (i ? ", " : "") + to_repr(v.obj->list[i]);
      return s + "]";
    }
    case Tag::Func: return std::format("<function {}>", v.obj->code->name);
  }
  return "?";
}
inline std::string to_repr(const Value& v) {
  if (v.tag == Tag::Str) return "'" + v.obj->str + "'";
  return to_display(v);
}

inline bool value_equal(const Value& a, const Value& b) {
  if (a.is_int_like() && b.is_int_like()) return a.i == b.i;
  if (a.tag != b.tag) return false;
  switch (a.tag) {
    case Tag::None: return true;
    case Tag::Str: return a.obj->str == b.obj->str;
    case Tag::List: {
      if (a.obj->list.size() != b.obj->list.size()) return false;
      for (std::size_t i = 0; i < a.obj->list.size(); ++i)
        if (!value_equal(a.obj->list[i], b.obj->list[i])) return false;
      return true;
    }
    default: return a.obj == b.obj;
  }
}

// Interpreter dispatch technique, selectable at compile time:
//   0 switch          -- portable; the compiler already builds a jump table
//   1 token threading -- computed goto through a 66-entry static optable[op]
//   2 direct threading-- each pc pre-decoded to its handler address in htab[pc]
// Measured on an interpreter-bound loop (// and % keep it off the JIT): token
// threading runs ~6-9% faster than the switch, from replicating the indirect
// branch per handler so the predictor gets per-opcode history. Direct threading
// measured ~6% *slower* than the switch here -- its per-function htab is larger
// and colder than the tiny static optable, and the register VM's fat 16-byte
// instructions mean pc walks are not dense enough to pay that back. So token
// threading is the default; the others stay for re-measurement on other CPUs.
// 1 and 2 need GCC/Clang labels-as-values and fall back to the switch elsewhere.
#ifndef MP_DISPATCH
#  define MP_DISPATCH 1
#endif
#if MP_DISPATCH != 0 && !defined(__GNUC__) && !defined(__clang__)
#  undef MP_DISPATCH
#  define MP_DISPATCH 1
#endif

#if MP_DISPATCH == 0            // switch: `break` falls through to the shared pc++
#  define VM_CASE(x) case Op::x
#  define VM_NEXT()  break
#  define VM_JUMP()  continue
#elif MP_DISPATCH == 1          // token threading: dispatch through optable[op]
#  define VM_CASE(x) L_##x
#  define VM_GO()                                             \
     do {                                                     \
       if (diag.failed) return Value::none();                 \
       xp = &ins[pc]; a = xp->a; b = xp->b; c = xp->c;        \
       goto *optable[(std::size_t)xp->op];                    \
     } while (0)
#  define VM_NEXT()  do { ++pc; VM_GO(); } while (0)
#  define VM_JUMP()  VM_GO()
#elif MP_DISPATCH == 2          // direct threading: dispatch through htab[pc]
#  define VM_CASE(x) L_##x
#  define VM_GO()                                             \
     do {                                                     \
       if (diag.failed) return Value::none();                 \
       xp = &ins[pc]; a = xp->a; b = xp->b; c = xp->c;        \
       goto *htab[pc];                                        \
     } while (0)
#  define VM_NEXT()  do { ++pc; VM_GO(); } while (0)
#  define VM_JUMP()  VM_GO()
#endif

class VM {
 public:
  // Native code recurses on the machine stack, where nothing bounds it and
  // running off the end is a segfault rather than an error. Record roughly
  // where the stack was when the VM was built; compiled entry points refuse to
  // start once rsp has fallen this far below it, and hand the call back to the
  // interpreter, whose own depth limit turns it into a clean error.
  static constexpr std::uintptr_t kNativeStackBudget = 4u << 20;
  std::uintptr_t stack_limit = 0;
  VM() {
    char probe = 0;
    auto here = (std::uintptr_t)&probe;
    stack_limit = here > kNativeStackBudget ? here - kNativeStackBudget : 0;
    (void)probe;
  }

  Globals globals;
  Diag diag;
  bool profile = true;
  bool collect_feedback = false;  // record per-site types for the optimizing JIT

  // Back-edge hook: (code, target pc, regs, globals) -> resume pc, or <0 to keep
  // interpreting from the target. The seam on-stack replacement hooks into.
  // Returning kBackedgeDone means the hook ran the rest of the function in
  // native code and `out` holds its return value.
  static constexpr long kBackedgeDone = -2;
  std::function<long(CodeObject*, int, Value*, Globals&, Value&)> on_backedge;

  // Call hook: (callee, regs, arg_base, argc, out) -> handled. If it returns
  // true it ran native code for the whole call and `out` is the result; else the
  // VM interprets normally. The seam a method JIT overrides.
  std::function<bool(const Value&, Value*, int, int, Value&)> on_call;

  std::unordered_map<std::int64_t, long> loop_counts;  // keyed by code_ptr ^ target

  int n_gc = 0;
  std::size_t gc_threshold = 1 << 16;  // collect after this many allocations
  std::size_t live_objects() const { return arena_.size(); }

  Object* new_object() {
    // Collect before allocating, at a safe point: every live object is reachable
    // from a root (globals or an interpreter frame), and the new object does not
    // exist yet, so nothing live is missed.
    if (++alloc_since_gc_ >= gc_threshold) {
      gc();
      alloc_since_gc_ = 0;
    }
    arena_.push_back(std::make_unique<Object>());
    return arena_.back().get();
  }

  // A contiguous frame stack for JIT-compiled activations. Bumping `vtop` is a
  // frame allocation, so a call costs no heap traffic, and the whole live region
  // [0, vtop) is one GC root -- no per-frame registration.
  std::vector<Value> vstack = std::vector<Value>(1 << 18);
  std::size_t vtop = 0;

  // Reserve `n` slots; returns the base index, or npos when the stack is full.
  std::size_t frame_alloc(int n) {
    if (vtop + (std::size_t)n > vstack.size()) return (std::size_t)-1;
    std::size_t base = vtop;
    vtop += n;
    // Fresh frames read as None, and clearing also stops the collector from
    // following a stale pointer left by an earlier, already-freed frame.
    for (int k = 0; k < n; ++k) vstack[base + k] = Value::none();
    return base;
  }
  void frame_free(std::size_t base) { vtop = base; }

  // Objects a JIT has baked an address into. Compiled code guards a call site
  // by comparing the callee's address against the one it compiled for, so that
  // address must never be handed to a different object: keeping it alive is
  // what makes the comparison mean what it says.
  std::vector<Value> pinned;
  void pin(const Value& v) {
    for (const Value& p : pinned)
      if (p.obj == v.obj) return;
    pinned.push_back(v);
  }

  // The GC roots, in one place. Anything reachable from one of these survives a
  // collection; everything else in the arena is freed. The four sources:
  //   - module globals
  //   - every live interpreter frame (run_frame registers each via frames_)
  //   - the JIT frame stack's live region [0, vtop)
  //   - whatever a JIT has pinned (baked-in callee addresses)
  // A precise, non-moving collector only reads the roots, so `f` takes them by
  // const ref; a moving one would take Value& and rewrite in place.
  template <class F>
  void for_each_root(F&& f) {
    for (auto& [name, v] : globals) f(v);
    for (auto* fr : frames_)
      for (const Value& v : *fr) f(v);
    for (std::size_t k = 0; k < vtop; ++k) f(vstack[k]);
    for (const Value& v : pinned) f(v);
  }

  // Mark-sweep GC. Only arena objects are swept; compile-time string constants
  // live in the Program and are never freed.
  void gc() {
    for_each_root([](const Value& v) { v.gc_mark(); });
    sweep();
    n_gc++;
  }

  // Object ops the JIT calls back into for str/list work (it can't inline heap
  // allocation or std::string/vector). Public so a JIT helper can reach them.
  Value op_subscr(const Value& obj, const Value& idx) { return subscr(obj, idx); }
  Value op_length(const Value& v) { return length(v); }
  // Generic slow paths, so JIT code can handle a non-int operand by calling out
  // and carrying on instead of abandoning the whole function to the interpreter.
  Value op_binop(Op op, const Value& l, const Value& r) { return binop(op, l, r); }
  Value op_compare(Op op, const Value& l, const Value& r) {
    return compare(op, l, r);
  }
  Value op_unary(Op op, const Value& v) { return unaryop(op, v); }
  // Full VM call (may re-enter native code through on_call) on a raw frame.
  bool op_call(Value* regs, int dst, int func_reg, int argc) {
    regs[dst] = do_call(regs[func_reg], regs, func_reg + 1, argc);
    return !diag.failed;
  }
  bool op_loadglobal(Globals* glb, Value* regs, const CodeObject* code, int a,
                     int b) {
    auto it = glb->find(code->names[b]);
    if (it == glb->end()) {
      diag.fail(std::format("name '{}' is not defined", code->names[b]));
      return false;
    }
    regs[a] = it->second;
    return true;
  }

  Value run_code(CodeObject* code, std::vector<Value> args = {}) {
    std::vector<Value> regs(code->n_regs);
    for (std::size_t i = 0; i < args.size(); ++i) regs[i] = args[i];
    return run_frame(code, regs, globals);
  }

  // Register/unregister a frame as a GC root. The JIT entry helper uses these
  // around native execution, which owns its frame but is not `run_frame`.
  void gc_push_frame(std::vector<Value>* f) { frames_.push_back(f); }
  void gc_pop_frame() { frames_.pop_back(); }

  // `start_pc` lets a JIT bail out mid-function: the frame array already holds
  // the state, so the interpreter just picks up where the native code stopped.
  Value run_frame(CodeObject* code, std::vector<Value>& regs, Globals& glb,
                  int start_pc = 0) {
    frames_.push_back(&regs);  // this frame's registers are GC roots
    struct FrameGuard {
      std::vector<std::vector<Value>*>& f;
      ~FrameGuard() { f.pop_back(); }
    } frame_guard{frames_};
    return run_frame_raw(code, regs.data(), glb, start_pc);
  }

  // The dispatch loop on a raw frame. The caller must have the frame rooted
  // (either via run_frame's guard or by living in the value stack).
  //
  // The handler bodies below are written once and dispatched three ways,
  // selected at compile time by MP_DISPATCH (see the macros above the class):
  //   0 = switch          (the compiler already builds a jump table)
  //   1 = token threading (computed goto through an opcode->handler table)
  //   2 = direct threading(each pc pre-decoded to its handler's address)
  // VM_NEXT advances to the next instruction; VM_JUMP re-dispatches at an
  // already-set pc; VM_CASE(x) is `case Op::x:` or the label `L_x:`.
  Value run_frame_raw(CodeObject* code, Value* regs, Globals& glb,
                      int start_pc = 0) {
    const std::vector<Instr>& ins = code->code;
    int pc = start_pc;
    const Instr* xp = nullptr;
    int a = 0, b = 0, c = 0;
    (void)xp; (void)a; (void)b; (void)c;

#if MP_DISPATCH != 0
    // Handler addresses, filled once. Label addresses are process-stable, so a
    // single static table serves every call (the interpreter is single-threaded;
    // the tiered worker only compiles).
    static void* optable[kOpTableSize];
    static bool tbl_init = false;
    if (!tbl_init) {
      for (auto& e : optable) e = &&L_bad;
      optable[(std::size_t)Op::LoadConst] = &&L_LoadConst;
      optable[(std::size_t)Op::Move] = &&L_Move;
      optable[(std::size_t)Op::LoadGlobal] = &&L_LoadGlobal;
      optable[(std::size_t)Op::StoreGlobal] = &&L_StoreGlobal;
      optable[(std::size_t)Op::Add] = optable[(std::size_t)Op::Sub] =
        optable[(std::size_t)Op::Mul] = optable[(std::size_t)Op::FloorDiv] =
        optable[(std::size_t)Op::Mod] = optable[(std::size_t)Op::Pow] =
        optable[(std::size_t)Op::BitAnd] = optable[(std::size_t)Op::BitOr] =
        optable[(std::size_t)Op::BitXor] = optable[(std::size_t)Op::LShift] =
        optable[(std::size_t)Op::RShift] = &&L_Add;
      optable[(std::size_t)Op::Eq] = optable[(std::size_t)Op::Ne] =
        optable[(std::size_t)Op::Lt] = optable[(std::size_t)Op::Le] =
        optable[(std::size_t)Op::Gt] = optable[(std::size_t)Op::Ge] = &&L_Eq;
      optable[(std::size_t)Op::Neg] = optable[(std::size_t)Op::Pos] =
        optable[(std::size_t)Op::Invert] = optable[(std::size_t)Op::Not] =
        &&L_Neg;
      optable[(std::size_t)Op::Jump] = &&L_Jump;
      optable[(std::size_t)Op::JumpIfFalse] = &&L_JumpIfFalse;
      optable[(std::size_t)Op::JumpIfTrue] = &&L_JumpIfTrue;
      optable[(std::size_t)Op::Call] = &&L_Call;
      optable[(std::size_t)Op::Return] = &&L_Return;
      optable[(std::size_t)Op::Print] = &&L_Print;
      optable[(std::size_t)Op::MakeFunction] = &&L_MakeFunction;
      optable[(std::size_t)Op::MakeList] = &&L_MakeList;
      optable[(std::size_t)Op::Subscr] = &&L_Subscr;
      optable[(std::size_t)Op::Len] = &&L_Len;
      tbl_init = true;
    }
#endif
#if MP_DISPATCH == 2
    if (code->htab.empty() && !ins.empty()) {   // pre-decode once per function
      code->htab.resize(ins.size());
      for (std::size_t i = 0; i < ins.size(); ++i)
        code->htab[i] = optable[(std::size_t)ins[i].op];
    }
    void** const htab = code->htab.data();
#endif

#if MP_DISPATCH == 0
    while (true) {
      if (diag.failed) return Value::none();
      xp = &ins[pc]; a = xp->a; b = xp->b; c = xp->c;
      switch (xp->op) {
#else
    VM_GO();   // enter the first handler
#endif

        VM_CASE(LoadConst): regs[a] = code->consts[b]; VM_NEXT();
        VM_CASE(Move): regs[a] = regs[b]; VM_NEXT();
        VM_CASE(LoadGlobal): {
          auto it = glb.find(code->names[b]);
          if (it == glb.end()) {
            diag.fail(std::format("name '{}' is not defined", code->names[b]));
            return Value::none();
          }
          regs[a] = it->second;
          VM_NEXT();
        }
        VM_CASE(StoreGlobal): glb[code->names[a]] = regs[b]; VM_NEXT();

        VM_CASE(Add): VM_CASE(Sub): VM_CASE(Mul): VM_CASE(FloorDiv):
        VM_CASE(Mod): VM_CASE(Pow): VM_CASE(BitAnd): VM_CASE(BitOr):
        VM_CASE(BitXor): VM_CASE(LShift): VM_CASE(RShift):
          if (collect_feedback) note2(code, pc, regs[b], regs[c]);
          regs[a] = binop(xp->op, regs[b], regs[c]);
          VM_NEXT();
        VM_CASE(Eq): VM_CASE(Ne): VM_CASE(Lt): VM_CASE(Le):
        VM_CASE(Gt): VM_CASE(Ge):
          if (collect_feedback) note2(code, pc, regs[b], regs[c]);
          regs[a] = compare(xp->op, regs[b], regs[c]);
          VM_NEXT();
        VM_CASE(Neg): VM_CASE(Pos): VM_CASE(Invert): VM_CASE(Not):
          if (collect_feedback) note1(code, pc, regs[b]);
          regs[a] = unaryop(xp->op, regs[b]);
          VM_NEXT();

        VM_CASE(Jump):
          if (a <= pc) {
            if (profile) {
              std::int64_t key = ((std::int64_t)(std::intptr_t)code) ^ ((std::int64_t)a << 1);
              loop_counts[key]++;
            }
            if (on_backedge) {
              Value done;
              long resume = on_backedge(code, a, regs, glb, done);
              if (resume == kBackedgeDone) return done;   // finished natively
              if (resume >= 0) { pc = (int)resume; VM_JUMP(); }
            }
          }
          pc = a;
          VM_JUMP();
        VM_CASE(JumpIfFalse):
          if (collect_feedback) note1(code, pc, regs[a]);
          if (!truthy(regs[a])) { pc = b; VM_JUMP(); }
          VM_NEXT();
        VM_CASE(JumpIfTrue):
          if (collect_feedback) note1(code, pc, regs[a]);
          if (truthy(regs[a])) { pc = b; VM_JUMP(); }
          VM_NEXT();

        VM_CASE(Call):
          if (collect_feedback) note_callee(code, pc, regs[b]);
          regs[a] = do_call(regs[b], regs, b + 1, c);
          VM_NEXT();
        VM_CASE(Return): return regs[a];
        VM_CASE(Print): do_print(regs, a, b); VM_NEXT();
        VM_CASE(MakeFunction): {
          Object* o = new_object();
          o->kind = Object::Kind::Func;
          o->code = code->const_codes[b];
          o->globals = &glb;
          regs[a] = Value::object(Tag::Func, o);
          VM_NEXT();
        }
        VM_CASE(MakeList): {
          Object* o = new_object();
          o->kind = Object::Kind::List;
          o->list.assign(regs + b, regs + b + c);
          regs[a] = Value::object(Tag::List, o);
          VM_NEXT();
        }
        VM_CASE(Subscr):
          if (collect_feedback) note2(code, pc, regs[b], regs[c]);
          regs[a] = subscr(regs[b], regs[c]);
          VM_NEXT();
        VM_CASE(Len):
          if (collect_feedback) note1(code, pc, regs[b]);
          regs[a] = length(regs[b]);
          VM_NEXT();

#if MP_DISPATCH == 0
      }
      pc++;
    }
#else
    L_bad: return Value::none();   // opcode with no handler: unreachable
#endif
  }

  std::string output() const {
    std::string s;
    for (std::size_t i = 0; i < out_.size(); ++i) s += (i ? "\n" : "") + out_[i];
    return s;
  }

 private:
  Value binop(Op op, const Value& l, const Value& r) {
    if (op == Op::Add) {
      if (l.tag == Tag::Str && r.tag == Tag::Str) {
        Object* o = new_object();
        o->kind = Object::Kind::Str;
        o->str = l.obj->str + r.obj->str;
        return Value::object(Tag::Str, o);
      }
      if (l.tag == Tag::List && r.tag == Tag::List) {
        Object* o = new_object();
        o->kind = Object::Kind::List;
        o->list = l.obj->list;
        o->list.insert(o->list.end(), r.obj->list.begin(), r.obj->list.end());
        return Value::object(Tag::List, o);
      }
    }
    if (!l.is_int_like() || !r.is_int_like()) {
      diag.fail(std::format("unsupported operand types for {}", op_name(op)));
      return Value::none();
    }
    std::int64_t x = l.i, y = r.i, z = 0;
    switch (op) {
      case Op::Add: z = x + y; break;
      case Op::Sub: z = x - y; break;
      case Op::Mul: z = x * y; break;
      case Op::FloorDiv:
      case Op::Mod:
        if (y == 0) {
          diag.fail("integer division or modulo by zero");
          return Value::none();
        }
        z = (op == Op::FloorDiv) ? py_floordiv(x, y) : py_mod(x, y);
        break;
      case Op::Pow:
        if (y < 0) {
          diag.fail("negative exponent is not supported");
          return Value::none();
        }
        z = py_pow(x, y);
        break;
      case Op::BitAnd: z = x & y; break;
      case Op::BitOr: z = x | y; break;
      case Op::BitXor: z = x ^ y; break;
      case Op::LShift: z = x << y; break;
      case Op::RShift: z = x >> y; break;
      default: break;
    }
    // `&`, `|` and `^` are the one place bool is closed under the operator:
    // True & True is True, but True + True is 2 and True << 1 is 2. Python's
    // bool.__and__ does this, so the reference implementation gets it for free
    // from operator.and_; here it has to be spelled out.
    if (bool_closed(op) && l.tag == Tag::Bool && r.tag == Tag::Bool)
      return Value::boolean(z != 0);
    return Value::integer(z);
  }

  Value compare(Op op, const Value& l, const Value& r) {
    if (op == Op::Eq) return Value::boolean(value_equal(l, r));
    if (op == Op::Ne) return Value::boolean(!value_equal(l, r));
    int cmp;
    if (l.is_int_like() && r.is_int_like())
      cmp = (l.i < r.i) ? -1 : (l.i > r.i) ? 1 : 0;
    else if (l.tag == Tag::Str && r.tag == Tag::Str)
      cmp = l.obj->str.compare(r.obj->str) < 0 ? -1
            : l.obj->str.compare(r.obj->str) > 0 ? 1 : 0;
    else {
      diag.fail("unsupported operand types for comparison");
      return Value::none();
    }
    switch (op) {
      case Op::Lt: return Value::boolean(cmp < 0);
      case Op::Le: return Value::boolean(cmp <= 0);
      case Op::Gt: return Value::boolean(cmp > 0);
      case Op::Ge: return Value::boolean(cmp >= 0);
      default: return Value::boolean(false);
    }
  }

  Value unaryop(Op op, const Value& v) {
    if (op == Op::Not) return Value::boolean(!truthy(v));
    if (!v.is_int_like()) {
      diag.fail("unsupported operand type for unary op");
      return Value::none();
    }
    switch (op) {
      case Op::Neg: return Value::integer(-v.i);
      case Op::Pos: return Value::integer(+v.i);
      case Op::Invert: return Value::integer(~v.i);
      default: return Value::none();
    }
  }

  Value subscr(const Value& obj, const Value& idx) {
    if (!idx.is_int_like()) {
      diag.fail("list/str indices must be integers");
      return Value::none();
    }
    std::int64_t i = idx.i;
    if (obj.tag == Tag::List) {
      auto& lst = obj.obj->list;
      if (i < 0) i += (std::int64_t)lst.size();
      if (i < 0 || i >= (std::int64_t)lst.size()) {
        diag.fail("list index out of range");
        return Value::none();
      }
      return lst[i];
    }
    if (obj.tag == Tag::Str) {
      auto& s = obj.obj->str;
      if (i < 0) i += (std::int64_t)s.size();
      if (i < 0 || i >= (std::int64_t)s.size()) {
        diag.fail("string index out of range");
        return Value::none();
      }
      Object* o = new_object();
      o->kind = Object::Kind::Str;
      o->str = std::string(1, s[i]);
      return Value::object(Tag::Str, o);
    }
    diag.fail("object is not subscriptable");
    return Value::none();
  }

  Value length(const Value& v) {
    if (v.tag == Tag::Str) return Value::integer((std::int64_t)v.obj->str.size());
    if (v.tag == Tag::List) return Value::integer((std::int64_t)v.obj->list.size());
    diag.fail("object has no len()");
    return Value::none();
  }

  Value do_call(const Value& callee, Value* regs, int arg_base, int argc) {
    if (callee.tag != Tag::Func) {
      diag.fail("object is not callable");
      return Value::none();
    }
    const CodeObject* code = callee.obj->code;
    if (argc != (int)code->params.size()) {
      diag.fail(std::format("{}() takes {} argument(s) but {} given", code->name,
                            code->params.size(), argc));
      return Value::none();
    }
    if (collect_feedback) {
      auto* co = const_cast<CodeObject*>(code);
      for (int i = 0; i < argc && i < (int)co->param_tags.size(); ++i)
        co->param_tags[i] |= tag_bit(regs[arg_base + i]);
    }
    // A nested call is a nested C++ call, so runaway recursion would take the
    // machine stack down with it. Bound it by the same budget the compiled
    // entry points use, and report it rather than crashing. Native frames are
    // much smaller than interpreter ones, so a compiled tier gets further into
    // a deep recursion before it trips -- the budget is the honest resource,
    // not a portable depth count.
    char probe = 0;
    if ((std::uintptr_t)&probe < stack_limit) {
      diag.fail(std::format("maximum recursion depth exceeded calling {}()",
                            code->name));
      return Value::none();
    }
    if (on_call) {
      Value out;
      if (on_call(callee, regs, arg_base, argc, out)) return out;
    }
    std::vector<Value> frame(code->n_regs);
    for (int i = 0; i < argc; ++i) frame[i] = regs[arg_base + i];
    return run_frame(const_cast<CodeObject*>(code), frame, *callee.obj->globals);
  }

  void do_print(Value* regs, int base, int argc) {
    std::string line;
    for (int i = 0; i < argc; ++i)
      line += (i ? " " : "") + to_display(regs[base + i]);
    out_.push_back(line);
    std::println("{}", line);
  }

  static void note1(CodeObject* code, int pc, const Value& b) {
    if (pc < (int)code->feedback.size()) code->feedback[pc].tags_b |= tag_bit(b);
  }
  static void note2(CodeObject* code, int pc, const Value& b, const Value& c) {
    if (pc >= (int)code->feedback.size()) return;
    SiteFeedback& f = code->feedback[pc];
    f.tags_b |= tag_bit(b);
    f.tags_c |= tag_bit(c);
  }
  static void note_callee(CodeObject* code, int pc, const Value& fn) {
    if (pc >= (int)code->feedback.size()) return;
    SiteFeedback& f = code->feedback[pc];
    const void* o = fn.tag == Tag::Func ? (const void*)fn.obj : nullptr;
    if (!f.callee) f.callee = o;
    else if (f.callee != o) f.polymorphic = true;
  }

  // Sweep phase: keep the objects the mark reached, freeing the rest, and clear
  // the survivors' bits for the next cycle.
  void sweep() {
    std::vector<std::unique_ptr<Object>> keep;
    keep.reserve(arena_.size());
    for (auto& o : arena_) {
      if (o->marked) {
        o->marked = false;
        keep.push_back(std::move(o));
      }
    }
    arena_ = std::move(keep);
  }

  std::vector<std::unique_ptr<Object>> arena_;
  std::vector<std::vector<Value>*> frames_;  // live interpreter frames (GC roots)
  std::size_t alloc_since_gc_ = 0;
  std::vector<std::string> out_;
};

}  // namespace minpython

#undef VM_CASE
#undef VM_NEXT
#undef VM_JUMP
#ifdef VM_GO
#  undef VM_GO
#endif
