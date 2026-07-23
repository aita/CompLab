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
import :regalloc;
import :vm;

export namespace minpython {

// One recorded step: either an ALU op (reuses the bytecode Instr fields) or a
// control-flow guard fixed to the direction the recorded run took.
struct TraceStep {
  bool is_guard = false;      // control-flow guard
  bool is_typeguard = false;  // value-type guard: regs[tg_slot].tag must be tg_tag
  bool is_objop = false;      // str/list op, executed by a runtime helper
  Op op{};
  int a = 0, b = 0, c = 0;
  std::int64_t imm = 0;  // LoadConst immediate (already resolved to an int)
  // control guard:
  int cond_reg = 0;
  bool expect_truthy = false;
  int exit_pc = 0;
  // type guard:
  int tg_slot = 0;
  Tag tg_tag = Tag::Int;
  // Where the interpreter must resume when this type guard fails. The guarded
  // op has already run, and earlier ops in this iteration may have written
  // locals, so we must NOT restart at the loop header -- resume right after it.
  int tg_resume_pc = 0;
};

struct RecordedTrace {
  int entry_pc = 0;
  int n_locals = 0;               // slots < n_locals must be flushed on exit
  std::vector<int> liveins;       // slots read before written -> entry type guard
  std::vector<Tag> livein_tags;   // the tag each live-in is guarded against
  std::vector<TraceStep> steps;
  bool mixed = false;             // contains object ops -> helper-calling codegen
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
  Recorder(const CodeObject* code, int entry_pc, const Value* regs, int n)
      : code_(code), shadow_(regs, regs + n) {
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
            trace_.n_locals = n_locals;
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

        // -- object ops: executed by a runtime helper, guarded by type ------
        case Op::Len: {
          if (shadow_[b].tag != Tag::Str && shadow_[b].tag != Tag::List)
            return false;
          read(b);  // the entry guard pins it to Str / List
          emit_objop(Op::Len, a, b, 0);
          shadow_[a] = Value::integer(
              shadow_[b].tag == Tag::Str
                  ? (std::int64_t)shadow_[b].obj->str.size()
                  : (std::int64_t)shadow_[b].obj->list.size());
          write(a);
          break;
        }
        case Op::Subscr: {
          if (shadow_[b].tag != Tag::Str && shadow_[b].tag != Tag::List)
            return false;
          if (!shadow_[c].is_int_like()) return false;
          read(b);
          read(c);
          Value elem;
          if (shadow_[b].tag == Tag::List) {
            auto& lst = shadow_[b].obj->list;
            std::int64_t k = shadow_[c].i;
            if (k < 0) k += (std::int64_t)lst.size();
            if (k < 0 || k >= (std::int64_t)lst.size()) return false;
            elem = lst[k];
          } else {
            elem.tag = Tag::Str;  // a 1-char string; only its type matters here
          }
          emit_objop(Op::Subscr, a, b, c);
          // The element type is only what this run saw -- guard it, so a
          // differently-typed element deopts instead of being used blindly. The
          // subscript itself has already happened, so resume after it.
          emit_typeguard(a, elem.tag, pc + 1);
          shadow_[a] = elem;
          write(a);
          break;
        }
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
  // A slot read before it is written is a live-in; remember the type it had on
  // entry so the trace can guard it in machine code.
  void read(int slot) {
    if (written_.count(slot) || livein_set_.count(slot)) return;
    trace_.liveins.push_back(slot);
    trace_.livein_tags.push_back(shadow_[slot].tag);
    livein_set_.insert(slot);
  }
  void write(int slot) { written_.insert(slot); }

  void emit_objop(Op op, int a, int b, int c) {
    TraceStep s;
    s.is_objop = true;
    s.op = op;
    s.a = a; s.b = b; s.c = c;
    trace_.steps.push_back(s);
    trace_.mixed = true;
  }
  void emit_typeguard(int slot, Tag tag, int resume_pc) {
    TraceStep s;
    s.is_typeguard = true;
    s.tg_slot = slot;
    s.tg_tag = tag;
    s.tg_resume_pc = resume_pc;
    trace_.steps.push_back(s);
  }

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

// A compiled trace is `long trace(Value* regs, VM* vm)`. Pure-int traces ignore
// the VM pointer; mixed traces use it to call back for str/list work.
using TraceFn = long (*)(void*, void*);

// Runtime helpers the mixed codegen calls. They work straight on the register
// array (which is a GC root), so an allocation inside them is safe. Returning 0
// means the VM latched an error and the trace must bail.
inline int jit_help_subscr(VM* vm, Value* regs, int a, int b, int c) {
  regs[a] = vm->op_subscr(regs[b], regs[c]);
  return vm->diag.failed ? 0 : 1;
}
inline int jit_help_len(VM* vm, Value* regs, int a, int b) {
  regs[a] = vm->op_length(regs[b]);
  return vm->diag.failed ? 0 : 1;
}

// A slot lives either in one of these caller-saved machine registers (so no
// prologue/epilogue is needed) or, if the pool is exhausted, in the register
// array in memory. rax/rcx are scratch, rdi is the array base pointer.
//
// Register-resident slots keep only their *payload* in the register across the
// loop; the tag byte is always kept in memory (written on every op), which keeps
// bool-vs-int exact for free. Payloads are loaded from memory once at entry and
// flushed back only on a guard exit -- so a hot loop touches memory a handful of
// times instead of on every operation.
class TraceCode : public Xbyak::CodeGenerator {
 public:
  explicit TraceCode(const RecordedTrace& t) { emit(t); }

 private:
  Xbyak::Address tag(int slot) {
    return Xbyak::util::byte[Xbyak::util::rdi + slot * kValueSize + kTagOffset];
  }
  Xbyak::Address pay(int slot) {
    return Xbyak::util::qword[Xbyak::util::rdi + slot * kValueSize +
                              kPayloadOffset];
  }
  bool has_reg(int slot) const { return slot_reg_.count(slot) != 0; }
  Xbyak::Reg64 reg(int slot) const { return slot_reg_.at(slot); }

  // rax <- slot payload
  void load_rax(int slot) {
    using namespace Xbyak::util;
    if (has_reg(slot)) mov(rax, reg(slot));
    else mov(rax, pay(slot));
  }
  // rcx <- slot payload (shift count)
  void load_rcx(int slot) {
    using namespace Xbyak::util;
    if (has_reg(slot)) mov(rcx, reg(slot));
    else mov(rcx, pay(slot));
  }
  // slot payload <- rax
  void store_rax(int slot) {
    using namespace Xbyak::util;
    if (has_reg(slot)) mov(reg(slot), rax);
    else mov(pay(slot), rax);
  }
  void store(int slot, Tag t) {
    store_rax(slot);
    mov(tag(slot), (int)t);  // tag lives in memory regardless of residency
  }
  // apply `f` with the slot's payload as a reg-or-memory operand
  template <class F>
  void with(int slot, F&& f) {
    if (has_reg(slot)) f(reg(slot));
    else f(pay(slot));
  }

  // Allocate slots to registers via the SAME shared linear-scan the method JIT
  // uses. A slot's live interval is its [first, last] step -- except loop-carried
  // slots (live-ins, and written locals whose value crosses the back-edge) get
  // the whole trace [0, N-1], so they never share a register with anything and
  // stay exact across iterations. Slots that spill just stay in memory (their
  // own array slot); we only take the register assignments.
  void allocate(const RecordedTrace& t) {
    using namespace Xbyak::util;
    std::vector<Xbyak::Reg64> pool = {rdx, rsi, r8, r9, r10, r11};
    int N = (int)t.steps.size();
    std::unordered_set<int> livein(t.liveins.begin(), t.liveins.end());
    std::unordered_map<int, std::pair<int, int>> range;
    std::unordered_set<int> written;
    auto touch = [&](int slot, int i) {
      auto it = range.find(slot);
      if (it == range.end()) range[slot] = {i, i};
      else it->second.second = i;
    };
    for (int i = 0; i < N; ++i) {
      const TraceStep& s = t.steps[i];
      if (s.is_guard) { touch(s.cond_reg, i); continue; }
      touch(s.a, i);
      written.insert(s.a);
      if (s.op != Op::LoadConst) touch(s.b, i);
      if (traceable_binop(s.op) || is_cmpop(s.op)) touch(s.c, i);
    }
    std::vector<Interval> intervals;
    for (auto& [slot, fl] : range) {
      bool carried = livein.count(slot) ||
                     (slot < t.n_locals && written.count(slot));
      int lo = carried ? 0 : fl.first;
      int hi = carried ? (N ? N - 1 : 0) : fl.second;
      intervals.push_back({lo, hi, slot});
    }
    Alloc a = linear_scan(intervals, (int)pool.size());
    for (auto& [slot, loc] : a.loc)
      if (loc.in_reg()) slot_reg_.insert({slot, pool[loc.reg]});
  }

  void emit(const RecordedTrace& t) {
    using namespace Xbyak::util;
    n_locals_ = t.n_locals;
    allocate(t);
    Xbyak::Label deopt;

    // Entry type guard (native): every live-in must still be an int (Int/Bool).
    for (int s : t.liveins) {
      Xbyak::Label ok;
      mov(al, tag(s));
      cmp(al, (int)Tag::Int);
      je(ok, T_NEAR);
      cmp(al, (int)Tag::Bool);
      jne(deopt, T_NEAR);
      L(ok);
    }
    // Load register-resident live-ins from memory once (their first use is a read).
    for (int s : t.liveins)
      if (has_reg(s)) mov(reg(s), pay(s));

    std::vector<Xbyak::Label> exits(t.steps.size());
    Xbyak::Label top;
    L(top);
    for (std::size_t i = 0; i < t.steps.size(); ++i) {
      const TraceStep& s = t.steps[i];
      if (s.is_guard) {
        load_rax(s.cond_reg);
        test(rax, rax);
        if (s.expect_truthy) jz(exits[i], T_NEAR);  // stay while nonzero
        else jnz(exits[i], T_NEAR);                  // stay while zero
        continue;
      }
      emit_alu(s);
    }
    jmp(top, T_NEAR);

    // Guard exit stubs: flush register-resident locals to the array (the
    // interpreter reads them from there), then return the resume pc.
    for (std::size_t i = 0; i < t.steps.size(); ++i) {
      if (!t.steps[i].is_guard) continue;
      L(exits[i]);
      flush_locals();
      mov(rax, t.steps[i].exit_pc);
      ret();
    }
    // Entry type-guard failure: nothing ran, so no flush; -1 means deopt.
    L(deopt);
    mov(rax, -1);
    ret();

    ready();
  }

  void flush_locals() {
    for (auto& [slot, r] : slot_reg_)
      if (slot < n_locals_) mov(pay(slot), r);
  }

  void emit_alu(const TraceStep& s) {
    using namespace Xbyak::util;
    switch (s.op) {
      case Op::LoadConst:
        mov(rax, s.imm);
        store(s.a, Tag::Int);
        return;
      case Op::Move:
        mov(al, tag(s.b));       // copy the tag through memory (keeps it exact)
        mov(tag(s.a), al);
        load_rax(s.b);
        store_rax(s.a);
        return;
      case Op::Add: load_rax(s.b); with(s.c, [&](auto&& o){ add(rax, o); }); store(s.a, Tag::Int); return;
      case Op::Sub: load_rax(s.b); with(s.c, [&](auto&& o){ sub(rax, o); }); store(s.a, Tag::Int); return;
      case Op::Mul: load_rax(s.b); with(s.c, [&](auto&& o){ imul(rax, o); }); store(s.a, Tag::Int); return;
      case Op::BitAnd: load_rax(s.b); with(s.c, [&](auto&& o){ and_(rax, o); }); store(s.a, Tag::Int); return;
      case Op::BitOr: load_rax(s.b); with(s.c, [&](auto&& o){ or_(rax, o); }); store(s.a, Tag::Int); return;
      case Op::BitXor: load_rax(s.b); with(s.c, [&](auto&& o){ xor_(rax, o); }); store(s.a, Tag::Int); return;
      case Op::LShift: load_rax(s.b); load_rcx(s.c); shl(rax, cl); store(s.a, Tag::Int); return;
      case Op::RShift: load_rax(s.b); load_rcx(s.c); sar(rax, cl); store(s.a, Tag::Int); return;
      case Op::Neg: load_rax(s.b); neg(rax); store(s.a, Tag::Int); return;
      case Op::Pos: load_rax(s.b); store(s.a, Tag::Int); return;
      case Op::Invert: load_rax(s.b); not_(rax); store(s.a, Tag::Int); return;
      case Op::Not:
        load_rax(s.b); test(rax, rax); sete(al); movzx(eax, al);
        store(s.a, Tag::Bool); return;
      case Op::Eq: cmp_set(s, &TraceCode::sete_); return;
      case Op::Ne: cmp_set(s, &TraceCode::setne_); return;
      case Op::Lt: cmp_set(s, &TraceCode::setl_); return;
      case Op::Le: cmp_set(s, &TraceCode::setle_); return;
      case Op::Gt: cmp_set(s, &TraceCode::setg_); return;
      case Op::Ge: cmp_set(s, &TraceCode::setge_); return;
      default: return;
    }
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
    load_rax(s.b);
    with(s.c, [&](auto&& o){ cmp(rax, o); });
    (this->*set)();
    movzx(eax, al);
    store(s.a, Tag::Bool);
  }

  int n_locals_ = 0;
  std::unordered_map<int, Xbyak::Reg64> slot_reg_;
};

// Codegen for traces that touch str/list.
//
// Values are hoisted into *callee-saved* registers (so they survive the helper
// calls) by the same shared linear-scan the other tiers use. The GC-safety rule
// is a **safepoint protocol** rather than a stack map: a helper call is the only
// point where a collection can happen, so right before one every register-
// resident slot is written back to the register array -- which is a GC root, and
// is also what the helper reads. After the call the destination slot is reloaded.
// Because the collector is non-moving, pointers already in registers stay valid,
// so nothing else needs reloading and the GC never has to scan native frames.
class MixedTraceCode : public Xbyak::CodeGenerator {
 public:
  explicit MixedTraceCode(const RecordedTrace& t) { emit(t); }

 private:
  Xbyak::Address tg(int slot) {
    return Xbyak::util::byte[Xbyak::util::r12 + slot * kValueSize + kTagOffset];
  }
  Xbyak::Address mem(int slot) {
    return Xbyak::util::qword[Xbyak::util::r12 + slot * kValueSize +
                              kPayloadOffset];
  }
  bool has_reg(int slot) const { return slot_reg_.count(slot) != 0; }
  Xbyak::Reg64 reg(int slot) const { return slot_reg_.at(slot); }

  void load_rax(int slot) {
    using namespace Xbyak::util;
    if (has_reg(slot)) mov(rax, reg(slot));
    else mov(rax, mem(slot));
  }
  void load_rcx(int slot) {
    using namespace Xbyak::util;
    if (has_reg(slot)) mov(rcx, reg(slot));
    else mov(rcx, mem(slot));
  }
  void store_rax(int slot) {
    using namespace Xbyak::util;
    if (has_reg(slot)) mov(reg(slot), rax);
    else mov(mem(slot), rax);
  }
  template <class F>
  void with(int slot, F&& f) {
    if (has_reg(slot)) f(reg(slot));
    else f(mem(slot));
  }
  // Safepoint / exit: make the register array authoritative again.
  void flush_all() {
    for (auto& [slot, r] : slot_reg_) mov(mem(slot), r);
  }

  // Same interval rule as the other tiers: loop-carried slots are live for the
  // whole trace so they never share a register.
  void allocate(const RecordedTrace& t) {
    using namespace Xbyak::util;
    std::vector<Xbyak::Reg64> pool = {r13, r14, r15};  // callee-saved
    int N = (int)t.steps.size();
    std::unordered_set<int> livein(t.liveins.begin(), t.liveins.end());
    std::unordered_map<int, std::pair<int, int>> range;
    std::unordered_set<int> written;
    auto touch = [&](int slot, int i) {
      auto it = range.find(slot);
      if (it == range.end()) range[slot] = {i, i};
      else it->second.second = i;
    };
    for (int i = 0; i < N; ++i) {
      const TraceStep& s = t.steps[i];
      if (s.is_guard) { touch(s.cond_reg, i); continue; }
      if (s.is_typeguard) { touch(s.tg_slot, i); continue; }
      if (s.is_objop) {
        touch(s.a, i); written.insert(s.a);
        touch(s.b, i);
        if (s.op == Op::Subscr) touch(s.c, i);
        continue;
      }
      touch(s.a, i);
      written.insert(s.a);
      if (s.op != Op::LoadConst) touch(s.b, i);
      if (traceable_binop(s.op) || is_cmpop(s.op)) touch(s.c, i);
    }
    std::vector<Interval> intervals;
    for (auto& [slot, fl] : range) {
      bool carried = livein.count(slot) ||
                     (slot < t.n_locals && written.count(slot));
      intervals.push_back({carried ? 0 : fl.first,
                           carried ? (N ? N - 1 : 0) : fl.second, slot});
    }
    Alloc a = linear_scan(intervals, (int)pool.size());
    for (auto& [slot, loc] : a.loc)
      if (loc.in_reg()) slot_reg_.insert({slot, pool[loc.reg]});
  }

  void emit(const RecordedTrace& t) {
    using namespace Xbyak::util;
    allocate(t);
    Xbyak::Label deopt, err;

    // 5 pushes = 40 bytes, which leaves rsp 16-aligned for the helper calls.
    push(rbx); push(r12); push(r13); push(r14); push(r15);
    mov(r12, rdi);  // register array
    mov(rbx, rsi);  // VM

    // Entry type guards: each live-in must still have the type it was recorded
    // with (int-like for Int/Bool, exact tag for str/list).
    for (std::size_t i = 0; i < t.liveins.size(); ++i) {
      int s = t.liveins[i];
      Tag want = t.livein_tags[i];
      Xbyak::Label ok;
      mov(al, tg(s));
      if (want == Tag::Int || want == Tag::Bool) {
        cmp(al, (int)Tag::Int);
        je(ok, T_NEAR);
        cmp(al, (int)Tag::Bool);
        jne(deopt, T_NEAR);
      } else {
        cmp(al, (int)want);
        jne(deopt, T_NEAR);
      }
      L(ok);
    }
    // Hoist register-resident live-ins out of the array once.
    for (int s : t.liveins)
      if (has_reg(s)) mov(reg(s), mem(s));

    std::vector<Xbyak::Label> exits(t.steps.size());
    Xbyak::Label top;
    L(top);
    for (std::size_t i = 0; i < t.steps.size(); ++i) {
      const TraceStep& s = t.steps[i];
      if (s.is_guard) {
        load_rax(s.cond_reg);
        test(rax, rax);
        if (s.expect_truthy) jz(exits[i], T_NEAR);
        else jnz(exits[i], T_NEAR);
      } else if (s.is_typeguard) {
        mov(al, tg(s.tg_slot));
        cmp(al, (int)s.tg_tag);
        jne(exits[i], T_NEAR);
      } else if (s.is_objop) {
        emit_objop(s, err);
      } else {
        emit_alu(s);
      }
    }
    jmp(top, T_NEAR);

    auto pops = [&] {
      pop(r15); pop(r14); pop(r13); pop(r12); pop(rbx);
    };
    // Any exit that ran trace code must make the array authoritative first; the
    // entry-guard deopt must NOT (the pool registers still hold caller values).
    auto epilogue = [&] { flush_all(); pops(); };
    for (std::size_t i = 0; i < t.steps.size(); ++i) {
      const TraceStep& s = t.steps[i];
      if (s.is_guard) {
        L(exits[i]);
        epilogue();
        mov(rax, s.exit_pc);
        ret();
      } else if (s.is_typeguard) {
        // Encoded so the driver can both count it and resume at the right pc:
        // -(pc + 2), leaving -1 to mean "entry guard failed, nothing ran".
        L(exits[i]);
        epilogue();
        mov(rax, -(s.tg_resume_pc + 2));
        ret();
      }
    }
    L(err);  // helper latched a VM error: hand back to the interpreter, which
    epilogue();  // checks diag and unwinds
    mov(rax, t.entry_pc);
    ret();
    L(deopt);  // entry guard failed: nothing ran, so no flush
    pops();
    mov(rax, -1);
    ret();

    ready();
  }

  // A safepoint: flush every hoisted slot so the collector (and the helper) sees
  // the real values, call out, then reload just the slot the helper wrote.
  void emit_objop(const TraceStep& s, Xbyak::Label& err) {
    using namespace Xbyak::util;
    Xbyak::Label slow, done;
    if (inline_lists_) {
      // Fast path for Lists, inline: no call, so no flush and no safepoint.
      // Operands may be register-resident, so go through the load/store helpers
      // rather than touching the array (whose payloads can be stale here).
      mov(al, tg(s.b));
      cmp(al, (int)Tag::List);
      jne(slow, T_NEAR);
      if (s.op == Op::Len) {
        load_rcx(s.b);
        mov(rdx, qword[rcx + list_off_]);         // begin
        mov(rax, qword[rcx + list_off_ + 8]);     // end
        sub(rax, rdx);
        sar(rax, 4);
        store(s.a, Tag::Int);
        jmp(done, T_NEAR);
      } else {
        mov(al, tg(s.c));
        cmp(al, (int)Tag::Int);
        jne(slow, T_NEAR);
        load_rcx(s.b);
        mov(rdx, qword[rcx + list_off_]);         // begin
        mov(r8, qword[rcx + list_off_ + 8]);      // end
        sub(r8, rdx);
        sar(r8, 4);                               // size
        load_rax(s.c);
        cmp(rax, r8);
        jae(slow, T_NEAR);  // unsigned: catches negative and out-of-range
        shl(rax, 4);
        add(rdx, rax);
        mov(rax, qword[rdx]);                     // tag word -> memory
        mov(qword[r12 + s.a * kValueSize + kTagOffset], rax);
        mov(rax, qword[rdx + kPayloadOffset]);
        store_rax(s.a);                           // payload -> reg or memory
        jmp(done, T_NEAR);
      }
    }
    L(slow);
    flush_all();
    mov(rdi, rbx);  // VM*
    mov(rsi, r12);  // Value* regs
    mov(edx, s.a);
    mov(ecx, s.b);
    if (s.op == Op::Subscr) {
      mov(r8d, s.c);
      mov(rax, (std::uint64_t)(std::uintptr_t)&jit_help_subscr);
    } else {
      mov(rax, (std::uint64_t)(std::uintptr_t)&jit_help_len);
    }
    call(rax);
    test(eax, eax);
    jz(err, T_NEAR);
    if (has_reg(s.a)) mov(reg(s.a), mem(s.a));  // the helper wrote the array
    L(done);
  }

  void store(int slot, Tag t) {
    using namespace Xbyak::util;
    store_rax(slot);
    mov(tg(slot), (int)t);  // the tag always lives in memory
  }

  void emit_alu(const TraceStep& s) {
    using namespace Xbyak::util;
    switch (s.op) {
      case Op::LoadConst: mov(rax, s.imm); store(s.a, Tag::Int); return;
      case Op::Move:
        mov(al, tg(s.b));      // copy the tag through memory (keeps it exact)
        mov(tg(s.a), al);
        load_rax(s.b);
        store_rax(s.a);
        return;
      case Op::Add: load_rax(s.b); with(s.c, [&](auto&& o){ add(rax, o); }); store(s.a, Tag::Int); return;
      case Op::Sub: load_rax(s.b); with(s.c, [&](auto&& o){ sub(rax, o); }); store(s.a, Tag::Int); return;
      case Op::Mul: load_rax(s.b); with(s.c, [&](auto&& o){ imul(rax, o); }); store(s.a, Tag::Int); return;
      case Op::BitAnd: load_rax(s.b); with(s.c, [&](auto&& o){ and_(rax, o); }); store(s.a, Tag::Int); return;
      case Op::BitOr: load_rax(s.b); with(s.c, [&](auto&& o){ or_(rax, o); }); store(s.a, Tag::Int); return;
      case Op::BitXor: load_rax(s.b); with(s.c, [&](auto&& o){ xor_(rax, o); }); store(s.a, Tag::Int); return;
      case Op::LShift: load_rax(s.b); load_rcx(s.c); shl(rax, cl); store(s.a, Tag::Int); return;
      case Op::RShift: load_rax(s.b); load_rcx(s.c); sar(rax, cl); store(s.a, Tag::Int); return;
      case Op::Neg: load_rax(s.b); neg(rax); store(s.a, Tag::Int); return;
      case Op::Pos: load_rax(s.b); store(s.a, Tag::Int); return;
      case Op::Invert: load_rax(s.b); not_(rax); store(s.a, Tag::Int); return;
      case Op::Not:
        load_rax(s.b); test(rax, rax); sete(al); movzx(eax, al);
        store(s.a, Tag::Bool); return;
      case Op::Eq: case Op::Ne: case Op::Lt: case Op::Le:
      case Op::Gt: case Op::Ge:
        load_rax(s.b);
        with(s.c, [&](auto&& o){ cmp(rax, o); });
        switch (s.op) {
          case Op::Eq: sete(al); break;
          case Op::Ne: setne(al); break;
          case Op::Lt: setl(al); break;
          case Op::Le: setle(al); break;
          case Op::Gt: setg(al); break;
          default: setge(al); break;
        }
        movzx(eax, al);
        store(s.a, Tag::Bool);
        return;
      default: return;
    }
  }

  bool inline_lists_ = list_layout().ok;
  int list_off_ = (int)list_layout().list_off;
  std::unordered_map<int, Xbyak::Reg64> slot_reg_;
};

struct CompiledTrace {
  std::unique_ptr<Xbyak::CodeGenerator> code;
  TraceFn fn;
};

// -- driver -----------------------------------------------------------------

class TracingJIT {
 public:
  explicit TracingJIT(VM& vm, int threshold = 50)
      : vm_(vm), threshold_(threshold) {
    vm_.on_backedge = [this](CodeObject* code, int target, Value* regs,
                             Globals&) -> long {
      return on_backedge(code, target, regs);
    };
  }

  int n_compiled = 0;
  int n_mixed = 0;  // traces containing str/list ops
  int n_aborted = 0;
  int n_trace_runs = 0;
  int n_type_deopt = 0;

 private:
  long on_backedge(CodeObject* code, int target, Value* regs) {
    std::int64_t key = mix(code, target);

    auto it = traces_.find(key);
    if (it != traces_.end()) return run(it->second, regs);

    if (blacklist_.count(key)) return -1;

    if (++hot_[key] < threshold_) return -1;

    RecordedTrace tr;
    Recorder rec(code, target, regs, code->n_regs);
    if (!rec.record(tr)) {
      blacklist_.insert(key);
      n_aborted++;
      return -1;
    }

    Xbyak::ClearError();
    CompiledTrace ct;
    if (tr.mixed) ct.code = std::make_unique<MixedTraceCode>(tr);
    else ct.code = std::make_unique<TraceCode>(tr);
    if (Xbyak::GetError()) {  // codegen ran out of space / bad encoding
      Xbyak::ClearError();
      blacklist_.insert(key);
      n_aborted++;
      return -1;
    }
    if (tr.mixed) n_mixed++;
    ct.fn = (TraceFn)ct.code->getCode();
    CompiledTrace& stored = (traces_[key] = std::move(ct));
    n_compiled++;
    return run(stored, regs);
  }

  long run(CompiledTrace& ct, Value* regs) {
    long r = ct.fn(regs, &vm_);
    if (r == -1) {  // entry type guard failed: nothing ran, re-interpret
      n_type_deopt++;
      return -1;
    }
    if (r < -1) {  // a mid-trace type guard failed: resume at -(r) - 2
      n_type_deopt++;
      return -r - 2;
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
