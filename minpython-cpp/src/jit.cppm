// JIT partition — a tracing JIT for hot `while` loops, emitting x86-64 via xbyak.
//
// Shape (LuaJIT-ish, simplified): the back-edge hook profiles each loop; once
// hot, record() single-steps one iteration -- resolving branches from the live
// register values -- into a straight-line list of ALU steps and control guards,
// aborting on anything the integer core can't handle (calls, object ops, //, %,
// **, non-int constants). compile_trace() then lowers that to machine code.
//
// Unlike the Python JIT this one keeps values in the register array in memory and
// operates on them there, which buys a property the Python version can't have: an
// honest NATIVE type guard. Each value is a 16-byte tagged slot, so the entry
// guard is real machine code -- `cmp byte [regs + slot*16], Int` -- and a live-in
// that is no longer an int makes the trace return -1 and deopt to the interpreter.
// (No side traces / LICM yet; a guard that leaves the recorded path just resumes
// the interpreter at the exit pc.)
module;
#define XBYAK_NO_EXCEPTION  // this project builds with -fno-exceptions
#include "xbyak/xbyak.h"

export module minpython:jit;

import std;
import :value;
import :bytecode;
import :vm;

export namespace minpython {

// One recorded step: either an ALU op (reuses the bytecode Instr fields) or a
// control-flow guard fixed to the direction the recorded run took.
struct TraceStep {
  bool is_guard = false;
  Op op{};
  int a = 0, b = 0, c = 0;
  std::int64_t imm = 0;  // LoadConst immediate (already resolved to an int)
  // guard:
  int cond_reg = 0;
  bool expect_truthy = false;
  int exit_pc = 0;
};

struct RecordedTrace {
  int entry_pc = 0;
  std::vector<int> liveins;       // slots read before written -> entry type guard
  std::vector<TraceStep> steps;
};

inline constexpr int kMaxSteps = 8000;

// Traceable binary ops: the ones that map to a single x86 integer instruction.
// //, %, ** are excluded on purpose and abort the trace.
inline bool traceable_binop(Op op) {
  switch (op) {
    case Op::Add: case Op::Sub: case Op::Mul: case Op::BitAnd:
    case Op::BitOr: case Op::BitXor: case Op::LShift: case Op::RShift:
      return true;
    default:
      return false;
  }
}

// -- recorder ---------------------------------------------------------------

class Recorder {
 public:
  Recorder(const CodeObject* code, int entry_pc, const std::vector<Value>& regs)
      : code_(code), shadow_(regs) {
    trace_.entry_pc = entry_pc;
  }

  bool record(RecordedTrace& out) {
    const auto& ins = code_->code;
    int n_locals = code_->n_locals;
    int pc = trace_.entry_pc;
    for (int step = 0; step < kMaxSteps; ++step) {
      const Instr& x = ins[pc];
      int a = x.a, b = x.b, c = x.c;
      switch (x.op) {
        case Op::Jump:
          if (a == trace_.entry_pc) {  // loop closed
            for (int s : trace_.liveins)
              if (s >= n_locals) return false;  // marshalling model needs locals
            out = std::move(trace_);
            return true;
          }
          if (a <= pc) return false;  // nested backward edge
          pc = a;
          continue;
        case Op::JumpIfFalse: {
          read(a);  // cond reg is a
          bool t = truthy(shadow_[a]);
          if (t) { guard(a, true, /*exit*/ x.b); pc += 1; }
          else { guard(a, false, /*exit*/ pc + 1); pc = x.b; }
          continue;
        }
        case Op::JumpIfTrue: {
          read(a);
          bool t = truthy(shadow_[a]);
          if (t) { guard(a, true, /*exit*/ pc + 1); pc = x.b; }
          else { guard(a, false, /*exit*/ x.b); pc += 1; }
          continue;
        }
        case Op::LoadConst: {
          const Value& v = code_->consts[b];
          if (!v.is_int_like()) return false;  // None / str -> not traceable
          emit_alu(Op::LoadConst, a, 0, 0, v.i);
          write(a);
          shadow_[a] = v;
          break;
        }
        case Op::Move:
          read(b);
          emit_alu(Op::Move, a, b, 0);
          shadow_[a] = shadow_[b];
          write(a);
          break;
        default:
          if (traceable_binop(x.op)) {
            if (!shadow_[b].is_int_like() || !shadow_[c].is_int_like())
              return false;
            read(b); read(c);
            emit_alu(x.op, a, b, c);
            shadow_[a] = eval_binop(x.op, shadow_[b].i, shadow_[c].i);
            write(a);
          } else if (is_cmpop(x.op)) {
            if (!shadow_[b].is_int_like() || !shadow_[c].is_int_like())
              return false;
            read(b); read(c);
            emit_alu(x.op, a, b, c);
            shadow_[a] = Value::boolean(eval_cmp(x.op, shadow_[b].i, shadow_[c].i));
            write(a);
          } else if (is_unaryop(x.op)) {
            if (!shadow_[b].is_int_like()) return false;
            read(b);
            emit_alu(x.op, a, b, 0);
            shadow_[a] = eval_unary(x.op, shadow_[b].i);
            write(a);
          } else {
            return false;  // Call/Return/Print/globals/object ops: not traceable
          }
      }
      pc += 1;
    }
    return false;  // ran past kMaxSteps
  }

 private:
  void read(int slot) {
    if (written_.count(slot) || livein_set_.count(slot)) return;
    trace_.liveins.push_back(slot);
    livein_set_.insert(slot);
  }
  void write(int slot) { written_.insert(slot); }

  void emit_alu(Op op, int a, int b, int c, std::int64_t imm = 0) {
    TraceStep s;
    s.op = op;
    s.a = a; s.b = b; s.c = c;
    s.imm = imm;
    trace_.steps.push_back(s);
  }
  void guard(int cond_reg, bool expect_truthy, int exit_pc) {
    read(cond_reg);
    TraceStep s;
    s.is_guard = true;
    s.cond_reg = cond_reg;
    s.expect_truthy = expect_truthy;
    s.exit_pc = exit_pc;
    trace_.steps.push_back(s);
  }

  static Value eval_binop(Op op, std::int64_t x, std::int64_t y) {
    std::int64_t z = 0;
    switch (op) {
      case Op::Add: z = x + y; break;
      case Op::Sub: z = x - y; break;
      case Op::Mul: z = x * y; break;
      case Op::BitAnd: z = x & y; break;
      case Op::BitOr: z = x | y; break;
      case Op::BitXor: z = x ^ y; break;
      case Op::LShift: z = x << y; break;
      case Op::RShift: z = x >> y; break;
      default: break;
    }
    return Value::integer(z);
  }
  static bool eval_cmp(Op op, std::int64_t x, std::int64_t y) {
    switch (op) {
      case Op::Eq: return x == y;
      case Op::Ne: return x != y;
      case Op::Lt: return x < y;
      case Op::Le: return x <= y;
      case Op::Gt: return x > y;
      case Op::Ge: return x >= y;
      default: return false;
    }
  }
  static Value eval_unary(Op op, std::int64_t x) {
    switch (op) {
      case Op::Neg: return Value::integer(-x);
      case Op::Pos: return Value::integer(x);
      case Op::Invert: return Value::integer(~x);
      case Op::Not: return Value::boolean(x == 0);
      default: return Value::integer(x);
    }
  }

  const CodeObject* code_;
  std::vector<Value> shadow_;
  RecordedTrace trace_;
  std::unordered_set<int> written_;
  std::unordered_set<int> livein_set_;
};

// -- codegen ----------------------------------------------------------------

using TraceFn = long (*)(void*);

class TraceCode : public Xbyak::CodeGenerator {
 public:
  explicit TraceCode(const RecordedTrace& t) { emit(t); }

 private:
  // Memory operands into the register array (base pointer = arg0 = rdi).
  Xbyak::Address tag(int slot) {
    return Xbyak::util::byte[Xbyak::util::rdi + slot * kValueSize + kTagOffset];
  }
  Xbyak::Address val(int slot) {
    return Xbyak::util::qword[Xbyak::util::rdi + slot * kValueSize +
                              kPayloadOffset];
  }

  void emit(const RecordedTrace& t) {
    using namespace Xbyak::util;
    Xbyak::Label deopt;

    // Entry type guard: every live-in must still be an int (Int or Bool). This
    // is the native type guard -- if it fails the trace bails to the interpreter.
    for (int s : t.liveins) {
      Xbyak::Label ok;
      mov(al, tag(s));
      cmp(al, (int)Tag::Int);
      je(ok, T_NEAR);
      cmp(al, (int)Tag::Bool);
      jne(deopt, T_NEAR);
      L(ok);
    }

    std::vector<Xbyak::Label> exits(t.steps.size());

    Xbyak::Label top;
    L(top);
    for (std::size_t i = 0; i < t.steps.size(); ++i) {
      const TraceStep& s = t.steps[i];
      if (s.is_guard) {
        mov(rax, val(s.cond_reg));
        test(rax, rax);
        if (s.expect_truthy) jz(exits[i], T_NEAR);   // stay while nonzero
        else jnz(exits[i], T_NEAR);                   // stay while zero
        continue;
      }
      emit_alu(s);
    }
    jmp(top, T_NEAR);

    // Guard exit stubs: state is already live in the register array, so just
    // hand the interpreter the resume pc.
    for (std::size_t i = 0; i < t.steps.size(); ++i) {
      if (!t.steps[i].is_guard) continue;
      L(exits[i]);
      mov(rax, t.steps[i].exit_pc);
      ret();
    }
    // Entry type-guard failure: -1 tells the driver to deopt.
    L(deopt);
    mov(rax, -1);
    ret();

    ready();
  }

  void emit_alu(const TraceStep& s) {
    using namespace Xbyak::util;
    switch (s.op) {
      case Op::LoadConst:
        mov(rax, s.imm);
        mov(val(s.a), rax);
        mov(tag(s.a), (int)Tag::Int);
        return;
      case Op::Move:
        mov(rax, qword[rdi + s.b * kValueSize + kTagOffset]);
        mov(qword[rdi + s.a * kValueSize + kTagOffset], rax);
        mov(rax, val(s.b));
        mov(val(s.a), rax);
        return;
      case Op::Add: mov(rax, val(s.b)); add(rax, val(s.c)); store_int(s.a); return;
      case Op::Sub: mov(rax, val(s.b)); sub(rax, val(s.c)); store_int(s.a); return;
      case Op::Mul: mov(rax, val(s.b)); imul(rax, val(s.c)); store_int(s.a); return;
      case Op::BitAnd: mov(rax, val(s.b)); and_(rax, val(s.c)); store_int(s.a); return;
      case Op::BitOr: mov(rax, val(s.b)); or_(rax, val(s.c)); store_int(s.a); return;
      case Op::BitXor: mov(rax, val(s.b)); xor_(rax, val(s.c)); store_int(s.a); return;
      case Op::LShift:
        mov(rax, val(s.b)); mov(rcx, val(s.c)); shl(rax, cl); store_int(s.a); return;
      case Op::RShift:
        mov(rax, val(s.b)); mov(rcx, val(s.c)); sar(rax, cl); store_int(s.a); return;
      case Op::Neg: mov(rax, val(s.b)); neg(rax); store_int(s.a); return;
      case Op::Pos: mov(rax, val(s.b)); store_int(s.a); return;
      case Op::Invert: mov(rax, val(s.b)); not_(rax); store_int(s.a); return;
      case Op::Not:
        mov(rax, val(s.b)); test(rax, rax); sete(al); movzx(eax, al);
        store_bool(s.a); return;
      case Op::Eq: cmp_set(s, &TraceCode::sete_); return;
      case Op::Ne: cmp_set(s, &TraceCode::setne_); return;
      case Op::Lt: cmp_set(s, &TraceCode::setl_); return;
      case Op::Le: cmp_set(s, &TraceCode::setle_); return;
      case Op::Gt: cmp_set(s, &TraceCode::setg_); return;
      case Op::Ge: cmp_set(s, &TraceCode::setge_); return;
      default: return;
    }
  }

  void store_int(int slot) {
    using namespace Xbyak::util;
    mov(val(slot), rax);
    mov(tag(slot), (int)Tag::Int);
  }
  void store_bool(int slot) {
    using namespace Xbyak::util;
    mov(val(slot), rax);
    mov(tag(slot), (int)Tag::Bool);
  }
  // setcc helpers (member pointers let cmp_set share the shape)
  void sete_() { sete(Xbyak::util::al); }
  void setne_() { setne(Xbyak::util::al); }
  void setl_() { setl(Xbyak::util::al); }
  void setle_() { setle(Xbyak::util::al); }
  void setg_() { setg(Xbyak::util::al); }
  void setge_() { setge(Xbyak::util::al); }
  void cmp_set(const TraceStep& s, void (TraceCode::*set)()) {
    using namespace Xbyak::util;
    mov(rax, val(s.b));
    cmp(rax, val(s.c));
    (this->*set)();
    movzx(eax, al);
    store_bool(s.a);
  }
};

struct CompiledTrace {
  std::unique_ptr<TraceCode> code;
  TraceFn fn;
};

// -- driver -----------------------------------------------------------------

class TracingJIT {
 public:
  explicit TracingJIT(VM& vm, int threshold = 50)
      : vm_(vm), threshold_(threshold) {
    vm_.on_backedge = [this](CodeObject* code, int target,
                             std::vector<Value>& regs, Globals&) -> long {
      return on_backedge(code, target, regs);
    };
  }

  int n_compiled = 0;
  int n_aborted = 0;
  int n_trace_runs = 0;
  int n_type_deopt = 0;

 private:
  long on_backedge(CodeObject* code, int target, std::vector<Value>& regs) {
    std::int64_t key = mix(code, target);

    auto it = traces_.find(key);
    if (it != traces_.end()) return run(it->second, regs);

    if (blacklist_.count(key)) return -1;

    if (++hot_[key] < threshold_) return -1;

    RecordedTrace tr;
    Recorder rec(code, target, regs);
    if (!rec.record(tr)) {
      blacklist_.insert(key);
      n_aborted++;
      return -1;
    }

    Xbyak::ClearError();
    CompiledTrace ct;
    ct.code = std::make_unique<TraceCode>(tr);
    if (Xbyak::GetError()) {  // codegen ran out of space / bad encoding
      Xbyak::ClearError();
      blacklist_.insert(key);
      n_aborted++;
      return -1;
    }
    ct.fn = ct.code->getCode<TraceFn>();
    CompiledTrace& stored = (traces_[key] = std::move(ct));
    n_compiled++;
    return run(stored, regs);
  }

  long run(CompiledTrace& ct, std::vector<Value>& regs) {
    long r = ct.fn(regs.data());
    if (r < 0) {  // entry type guard failed
      n_type_deopt++;
      return -1;
    }
    n_trace_runs++;
    return r;
  }

  static std::int64_t mix(const CodeObject* code, int target) {
    return ((std::int64_t)(std::intptr_t)code) ^ ((std::int64_t)target << 1);
  }

  VM& vm_;
  int threshold_;
  std::unordered_map<std::int64_t, int> hot_;
  std::unordered_map<std::int64_t, CompiledTrace> traces_;
  std::unordered_set<std::int64_t> blacklist_;
};

}  // namespace minpython
