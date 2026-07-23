// Method JIT partition — a port of minpython/jit/method.py.
//
// The tracing JIT only fires on hot `while` back-edges, so a loop-free function
// -- most importantly a recursive one like fib_rec -- never gets native code.
// This compiler fills that gap: when a function is *called* often enough it
// compiles the whole body, both arms of every branch, to machine code, with
// direct self-recursion becoming a native `call`.
//
// int-specialised like the traces: the interpreter->native boundary (on_call)
// guards that the arguments are ints before entering; inside, everything is int.
// Values live in callee-saved registers (so they survive the recursive call)
// assigned by the shared linear-scan allocator, spilling to the stack frame.
module;
#define XBYAK_NO_EXCEPTION
#include "xbyak/xbyak.h"

export module minpython:method;

import std;
import :value;
import :bytecode;
import :regalloc;
import :vm;

export namespace minpython {

namespace mdetail {

// Reachable bytecode offsets from entry, following both branch arms, stopping at
// RETURN. Only these are compiled; the trailing implicit `return None` stays
// unreachable, so its non-int None is never a problem.
inline std::unordered_set<int> reachable(const CodeObject& code) {
  std::unordered_set<int> seen;
  std::vector<int> stack{0};
  while (!stack.empty()) {
    int pc = stack.back();
    stack.pop_back();
    if (!seen.insert(pc).second) continue;
    const Instr& ins = code.code[pc];
    if (ins.op == Op::Return) continue;
    if (ins.op == Op::Jump) {
      stack.push_back(ins.a);
    } else if (ins.op == Op::JumpIfFalse || ins.op == Op::JumpIfTrue) {
      stack.push_back(ins.b);
      stack.push_back(pc + 1);
    } else {
      stack.push_back(pc + 1);
    }
  }
  return seen;
}

inline std::vector<int> successors(const CodeObject& code, int pc) {
  const Instr& ins = code.code[pc];
  switch (ins.op) {
    case Op::Return: return {};
    case Op::Jump: return {ins.a};
    case Op::JumpIfFalse:
    case Op::JumpIfTrue: return {pc + 1, ins.b};
    default: return {pc + 1};
  }
}

inline bool is_method_bin(Op op) {
  return op == Op::Add || op == Op::Sub || op == Op::BitAnd ||
         op == Op::BitOr || op == Op::BitXor;
}

// def / use: the VM registers an instruction writes and reads. The elided
// self-call callee load is a no-op, and CALL does not read its callee slot.
inline void def_use(const Instr& ins, std::vector<int>& defs,
                    std::vector<int>& uses) {
  defs.clear();
  uses.clear();
  Op op = ins.op;
  if (op == Op::LoadConst) { defs = {ins.a}; }
  else if (op == Op::Move) { defs = {ins.a}; uses = {ins.b}; }
  else if (op == Op::LoadGlobal) { /* nothing */ }
  else if (is_method_bin(op) || op == Op::Mul || op == Op::LShift ||
           op == Op::RShift || is_cmpop(op)) {
    defs = {ins.a};
    uses = {ins.b, ins.c};
  } else if (op == Op::Neg || op == Op::Invert || op == Op::Not) {
    defs = {ins.a};
    uses = {ins.b};
  } else if (op == Op::JumpIfFalse || op == Op::JumpIfTrue) {
    uses = {ins.a};
  } else if (op == Op::Call) {
    defs = {ins.a};
    for (int i = 0; i < ins.c; ++i) uses.push_back(ins.b + 1 + i);
  } else if (op == Op::Return) {
    uses = {ins.a};
  }
}

// Validate that every reachable CALL is a direct self-recursive call; return the
// callee registers (empty allowed). Returns false if any call isn't resolvable.
inline bool self_call_regs(const CodeObject& code,
                           const std::unordered_set<int>& reach,
                           std::unordered_set<int>& callee_regs, int n_arg_regs) {
  for (int pc : reach) {
    const Instr& ins = code.code[pc];
    if (ins.op != Op::Call) continue;
    int func_reg = ins.b;
    const Instr* src = nullptr;
    for (int j = pc - 1; j >= 0; --j) {
      const Instr& prev = code.code[j];
      if (prev.op == Op::LoadGlobal && prev.a == func_reg) { src = &prev; break; }
      if (prev.a == func_reg && prev.op != Op::LoadGlobal) break;
    }
    if (!src || code.names[src->b] != code.name) return false;
    if (ins.c > n_arg_regs) return false;
    callee_regs.insert(func_reg);
  }
  return true;
}

// The v1 gate. Returns the reachable set if `code` is in the subset, else empty
// optional: int arithmetic, if, return, direct self-recursion, no loops /
// globals / print / // / % / **, <= n_arg_regs params.
inline std::optional<std::unordered_set<int>> feasible(const CodeObject& code,
                                                       int n_arg_regs) {
  if ((int)code.params.size() > n_arg_regs) return std::nullopt;
  std::unordered_set<int> reach = reachable(code);
  std::unordered_set<int> callee_regs;
  if (!self_call_regs(code, reach, callee_regs, n_arg_regs)) return std::nullopt;

  auto supported = [](Op op) {
    return is_method_bin(op) || is_cmpop(op) || op == Op::LoadConst ||
           op == Op::Move || op == Op::Mul || op == Op::LShift ||
           op == Op::RShift || op == Op::Neg || op == Op::Invert ||
           op == Op::Not || op == Op::Jump || op == Op::JumpIfFalse ||
           op == Op::JumpIfTrue || op == Op::Call || op == Op::Return ||
           op == Op::LoadGlobal;
  };
  for (int pc : reach) {
    const Instr& ins = code.code[pc];
    if (!supported(ins.op)) return std::nullopt;
    if (ins.op == Op::LoadConst && !code.consts[ins.b].is_int_like())
      return std::nullopt;
    if (ins.op == Op::Jump && ins.a <= pc) return std::nullopt;  // loop
    if (ins.op == Op::LoadGlobal && !callee_regs.count(ins.a))
      return std::nullopt;  // a real global, not a self-call
  }
  return reach;
}

// Backward-dataflow liveness -> a [start, end] interval per VM register.
inline std::unordered_map<int, std::pair<int, int>> live_ranges(
    const CodeObject& code, const std::unordered_set<int>& reach) {
  std::vector<int> order(reach.begin(), reach.end());
  std::sort(order.rbegin(), order.rend());  // descending

  std::unordered_map<int, std::unordered_set<int>> live_in;
  std::unordered_map<int, std::pair<std::vector<int>, std::vector<int>>> du;
  for (int pc : reach) {
    live_in[pc] = {};
    std::vector<int> d, u;
    def_use(code.code[pc], d, u);
    du[pc] = {d, u};
  }
  bool changed = true;
  while (changed) {
    changed = false;
    for (int pc : order) {
      std::unordered_set<int> lo;
      for (int s : successors(code, pc))
        if (live_in.count(s))
          for (int v : live_in[s]) lo.insert(v);
      auto& [d, u] = du[pc];
      std::unordered_set<int> li = lo;
      for (int v : d) li.erase(v);
      for (int v : u) li.insert(v);
      if (li != live_in[pc]) { live_in[pc] = std::move(li); changed = true; }
    }
  }

  std::unordered_map<int, std::pair<int, int>> ranges;
  std::vector<int> asc(reach.begin(), reach.end());
  std::sort(asc.begin(), asc.end());
  for (int pc : asc) {
    auto& [d, u] = du[pc];
    std::unordered_set<int> regs = live_in[pc];
    for (int v : d) regs.insert(v);
    for (int v : u) regs.insert(v);
    for (int r : regs) {
      auto it = ranges.find(r);
      if (it == ranges.end()) ranges[r] = {pc, pc};
      else it->second.second = pc;
    }
  }
  return ranges;
}

// Gate for the *object-capable* compiler: like `feasible`, but values may be any
// type, calls may be to anything (they go through the VM), and constants may be
// str/None. Loops still go to the tracing JIT.
inline std::optional<std::unordered_set<int>> mixed_feasible(
    const CodeObject& code) {
  std::unordered_set<int> reach = reachable(code);
  auto supported = [](Op op) {
    // //, %, ** need division sequences the inline path doesn't emit.
    bool bin = op == Op::Add || op == Op::Sub || op == Op::Mul ||
               op == Op::BitAnd || op == Op::BitOr || op == Op::BitXor ||
               op == Op::LShift || op == Op::RShift;
    return bin || is_cmpop(op) || is_unaryop(op) || op == Op::LoadConst ||
           op == Op::Move || op == Op::LoadGlobal || op == Op::Len ||
           op == Op::Subscr || op == Op::Jump || op == Op::JumpIfFalse ||
           op == Op::JumpIfTrue || op == Op::Call || op == Op::Return;
  };
  bool has_object_work = false;
  for (int pc : reach) {
    const Instr& ins = code.code[pc];
    if (!supported(ins.op)) return std::nullopt;
    if (ins.op == Op::Jump && ins.a <= pc) return std::nullopt;  // loop
    if (ins.op == Op::Len || ins.op == Op::Subscr) has_object_work = true;
    if (ins.op == Op::LoadConst && !code.consts[ins.b].is_int_like())
      has_object_work = true;
  }
  if (!has_object_work) return std::nullopt;  // the int compiler handles it
  return reach;
}

inline bool mixed_inline_bin(Op op) {
  return op == Op::Add || op == Op::Sub || op == Op::Mul || op == Op::BitAnd ||
         op == Op::BitOr || op == Op::BitXor || op == Op::LShift ||
         op == Op::RShift;
}

// Which slots are *provably* int-like on entry to each pc -- a forward "must"
// analysis (intersection at merges). The object-capable compiler uses it to drop
// redundant type guards: once a value has been guarded (or produced by an int
// op), later uses need no guard at all. This is the cheap stand-in for the type
// feedback a production JIT would collect from inline caches.
inline std::unordered_map<int, std::unordered_set<int>> known_int_slots(
    const CodeObject& code, const std::unordered_set<int>& reach) {
  std::unordered_set<int> universe;
  for (int r = 0; r < code.n_regs; ++r) universe.insert(r);
  std::unordered_map<int, std::unordered_set<int>> in;
  for (int pc : reach) in[pc] = universe;
  in[0].clear();  // parameters can be any type

  auto transfer = [&](const std::unordered_set<int>& s, const Instr& ins) {
    std::unordered_set<int> o = s;
    Op op = ins.op;
    if (op == Op::LoadConst) {
      if (code.consts[ins.b].is_int_like()) o.insert(ins.a);
      else o.erase(ins.a);
    } else if (op == Op::Move) {
      if (s.count(ins.b)) o.insert(ins.a); else o.erase(ins.a);
    } else if (op == Op::LoadGlobal || op == Op::Call || op == Op::Subscr) {
      o.erase(ins.a);            // result type unknown
    } else if (op == Op::Len) {
      o.insert(ins.a);           // always an int
    } else if (mixed_inline_bin(op) || is_cmpop(op)) {
      o.insert(ins.b); o.insert(ins.c);  // guarded here, so known after
      o.insert(ins.a);
    } else if (is_unaryop(op)) {
      o.insert(ins.b);
      o.insert(ins.a);
    } else if (op == Op::JumpIfFalse || op == Op::JumpIfTrue) {
      o.insert(ins.a);
    }
    return o;
  };

  std::vector<int> asc(reach.begin(), reach.end());
  std::sort(asc.begin(), asc.end());
  bool changed = true;
  while (changed) {
    changed = false;
    for (int pc : asc) {
      auto out = transfer(in[pc], code.code[pc]);
      for (int s : successors(code, pc)) {
        auto it = in.find(s);
        if (it == in.end()) continue;
        std::unordered_set<int> merged;
        for (int v : it->second)
          if (out.count(v)) merged.insert(v);
        if (merged != it->second) { it->second = std::move(merged); changed = true; }
      }
    }
  }
  return in;
}

}  // namespace mdetail

// -- runtime helpers for the object-capable compiler -------------------------
// They work on the frame array (a GC root), so allocation inside them is safe.
// Returning 0 means the VM latched an error and the native code must bail.

inline int jit_m_subscr(VM* vm, Value* regs, int a, int b, int c) {
  regs[a] = vm->op_subscr(regs[b], regs[c]);
  return vm->diag.failed ? 0 : 1;
}
inline int jit_m_len(VM* vm, Value* regs, int a, int b) {
  regs[a] = vm->op_length(regs[b]);
  return vm->diag.failed ? 0 : 1;
}
// A full VM call. Recursion lands back in on_call, so a recursive callee gets
// native code too -- and each level's own entry point absorbs its own deopt.
inline int jit_m_call(VM* vm, Value* regs, int a, int b, int c) {
  return vm->op_call(regs, a, b, c) ? 1 : 0;
}
inline int jit_m_loadglobal(VM* vm, Globals* glb, Value* regs,
                            const CodeObject* code, int a, int b) {
  return vm->op_loadglobal(glb, regs, code, a, b) ? 1 : 0;
}

// -- codegen ----------------------------------------------------------------

class MethodCode : public Xbyak::CodeGenerator {
 public:
  MethodCode(const CodeObject& code, const std::unordered_set<int>& reach,
             int argc) {
    using namespace Xbyak::util;
    pool_ = {rbx, r12, r13, r14, r15};
    arg_regs_ = {rdi, rsi, rdx, rcx, r8, r9};

    // Live-range linear scan over the function's VM registers. Parameters are
    // live from entry, so their intervals start at 0.
    auto ranges = mdetail::live_ranges(code, reach);
    for (int p = 0; p < argc; ++p)
      if (ranges.count(p)) ranges[p].first = 0;
    std::vector<Interval> intervals;
    for (auto& [r, se] : ranges) intervals.push_back({se.first, se.second, r});
    alloc_ = linear_scan(intervals, (int)pool_.size());
    save_n_ = (int)alloc_.used.size();
    int framesize = (((save_n_ + alloc_.n_spill) * 8 + 15) / 16) * 16;

    emit(code, reach, argc, framesize);
    ready();
  }

  void* entry_addr() { return (void*)getCode(); }

 private:
  bool rloc(int r, Xbyak::Reg64& out) {
    auto it = alloc_.loc.find(r);
    if (it == alloc_.loc.end() || !it->second.in_reg()) return false;
    out = pool_[it->second.reg];
    return true;
  }
  static bool same(const Xbyak::Reg64& a, const Xbyak::Reg64& b) {
    return a.getIdx() == b.getIdx();
  }
  Xbyak::Address save_mem(int i) {
    return Xbyak::util::qword[Xbyak::util::rbp - (i + 1) * 8];
  }
  Xbyak::Address mem(int r) {
    int idx = alloc_.loc[r].spill;
    return Xbyak::util::qword[Xbyak::util::rbp - (save_n_ + idx + 1) * 8];
  }
  // dst <- VM register r (from its reg or spill slot)
  void load(const Xbyak::Reg64& dst, int r) {
    Xbyak::Reg64 s;
    if (rloc(r, s)) { if (!same(s, dst)) mov(dst, s); }
    else mov(dst, mem(r));
  }
  // VM register r <- rax
  void store(int r) {
    using namespace Xbyak::util;
    Xbyak::Reg64 d;
    if (rloc(r, d)) { if (!same(d, rax)) mov(d, rax); }
    else mov(mem(r), rax);
  }

  enum class Bin { Add, Sub, And, Or, Xor, Mul };
  static Bin bin_of(Op op) {
    switch (op) {
      case Op::Add: return Bin::Add;
      case Op::Sub: return Bin::Sub;
      case Op::BitAnd: return Bin::And;
      case Op::BitOr: return Bin::Or;
      case Op::BitXor: return Bin::Xor;
      default: return Bin::Mul;
    }
  }
  template <class O>
  void bin_op(Bin k, const Xbyak::Reg64& d, const O& o) {
    switch (k) {
      case Bin::Add: add(d, o); break;
      case Bin::Sub: sub(d, o); break;
      case Bin::And: and_(d, o); break;
      case Bin::Or: or_(d, o); break;
      case Bin::Xor: xor_(d, o); break;
      case Bin::Mul: imul(d, o); break;
    }
  }
  void apply_bin(Bin k, const Xbyak::Reg64& d, int src) {
    Xbyak::Reg64 r;
    if (rloc(src, r)) bin_op(k, d, r);
    else bin_op(k, d, mem(src));
  }
  static bool commutative(Bin k) {
    return k == Bin::Add || k == Bin::And || k == Bin::Or || k == Bin::Xor ||
           k == Bin::Mul;
  }

  void emit_bin(int x, int y, int z, Bin k) {
    using namespace Xbyak::util;
    Xbyak::Reg64 d, yr, zr;
    if (rloc(x, d)) {
      bool yreg = rloc(y, yr), zreg = rloc(z, zr);
      if (yreg && same(yr, d)) apply_bin(k, d, z);
      else if (commutative(k) && zreg && same(zr, d)) apply_bin(k, d, y);
      else if (zreg && same(zr, d)) {  // non-commutative, z sits in dst
        load(rax, y);
        bin_op(k, rax, d);
        mov(d, rax);
      } else {
        load(d, y);
        apply_bin(k, d, z);
      }
    } else {
      load(rax, y);
      apply_bin(k, rax, z);
      store(x);
    }
  }

  void emit(const CodeObject& code, const std::unordered_set<int>& reach,
            int argc, int framesize) {
    using namespace Xbyak::util;
    std::vector<Xbyak::Reg64> used_callee;
    for (int idx : alloc_.used) used_callee.push_back(pool_[idx]);

    std::unordered_map<int, Xbyak::Label> labels;
    for (int pc : reach) labels[pc];  // default-construct one Label per pc

    L(entry_);
    push(rbp);
    mov(rbp, rsp);
    if (framesize) sub(rsp, framesize);
    for (int i = 0; i < (int)used_callee.size(); ++i)
      mov(save_mem(i), used_callee[i]);
    for (int i = 0; i < argc; ++i) {
      if (!alloc_.loc.count(i)) continue;
      Xbyak::Reg64 d;
      if (rloc(i, d)) mov(d, arg_regs_[i]);
      else mov(mem(i), arg_regs_[i]);
    }

    auto epilogue = [&] {
      for (int i = 0; i < (int)used_callee.size(); ++i)
        mov(used_callee[i], save_mem(i));
      mov(rsp, rbp);
      pop(rbp);
      ret();
    };

    for (int pc = 0; pc < (int)code.code.size(); ++pc) {
      if (!reach.count(pc)) continue;
      L(labels[pc]);
      const Instr& ins = code.code[pc];
      int x = ins.a, y = ins.b, z = ins.c;
      switch (ins.op) {
        case Op::LoadConst: {
          std::int64_t v = code.consts[y].i;
          Xbyak::Reg64 d;
          if (rloc(x, d)) mov(d, v);
          else { mov(rax, v); store(x); }
          break;
        }
        case Op::Move: {
          Xbyak::Reg64 d;
          if (rloc(x, d)) load(d, y);
          else { load(rax, y); store(x); }
          break;
        }
        case Op::LoadGlobal: break;  // self-call callee: resolved at CALL

        case Op::Add: case Op::Sub: case Op::BitAnd: case Op::BitOr:
        case Op::BitXor: case Op::Mul:
          emit_bin(x, y, z, bin_of(ins.op));
          break;

        case Op::LShift: case Op::RShift: {
          Xbyak::Reg64 tgt, yr;
          bool xreg = rloc(x, tgt);
          if (!xreg) tgt = rax;
          if (!(rloc(y, yr) && same(yr, tgt))) load(tgt, y);
          Xbyak::Reg64 zr;
          if (rloc(z, zr)) mov(rcx, zr); else mov(rcx, mem(z));
          if (ins.op == Op::LShift) shl(tgt, cl); else sar(tgt, cl);
          if (!xreg) store(x);
          break;
        }

        case Op::Neg: case Op::Invert: {
          Xbyak::Reg64 d, yr;
          if (rloc(x, d)) {
            if (!(rloc(y, yr) && same(yr, d))) load(d, y);
            if (ins.op == Op::Neg) neg(d); else not_(d);
          } else {
            load(rax, y);
            if (ins.op == Op::Neg) neg(rax); else not_(rax);
            store(x);
          }
          break;
        }
        case Op::Not:
          load(rax, y);
          test(rax, rax);
          sete(al);
          movzx(eax, al);
          store(x);
          break;

        case Op::Eq: case Op::Ne: case Op::Lt: case Op::Le:
        case Op::Gt: case Op::Ge: {
          Xbyak::Reg64 lhs;
          if (!rloc(y, lhs)) { mov(rax, mem(y)); lhs = rax; }
          Xbyak::Reg64 zr;
          if (rloc(z, zr)) cmp(lhs, zr); else cmp(lhs, mem(z));
          switch (ins.op) {
            case Op::Eq: sete(al); break;
            case Op::Ne: setne(al); break;
            case Op::Lt: setl(al); break;
            case Op::Le: setle(al); break;
            case Op::Gt: setg(al); break;
            default: setge(al); break;
          }
          movzx(eax, al);
          store(x);
          break;
        }

        case Op::Jump: jmp(labels[x], T_NEAR); break;
        case Op::JumpIfFalse: {
          Xbyak::Reg64 cond;
          if (!rloc(x, cond)) { mov(rax, mem(x)); cond = rax; }
          test(cond, cond);
          jz(labels[y], T_NEAR);
          break;
        }
        case Op::JumpIfTrue: {
          Xbyak::Reg64 cond;
          if (!rloc(x, cond)) { mov(rax, mem(x)); cond = rax; }
          test(cond, cond);
          jnz(labels[y], T_NEAR);
          break;
        }

        case Op::Call: {
          int arg_base = y + 1;
          for (int i = 0; i < z; ++i) load(arg_regs_[i], arg_base + i);
          call(entry_);  // direct self-recursion
          store(x);
          break;
        }
        case Op::Return:
          load(rax, x);
          epilogue();
          break;
        default: break;
      }
    }
  }

  std::vector<Xbyak::Reg64> pool_;
  std::vector<Xbyak::Reg64> arg_regs_;
  Alloc alloc_;
  int save_n_ = 0;
  Xbyak::Label entry_;
};

// The object-capable method compiler.
//
// Signature: `long f(Value* regs, VM* vm, Globals* glb)`. The frame array has
// n_regs + 1 slots; slot n_regs is where the result is left. It returns -1 when
// the function ran to completion, or a bytecode pc when a type guard failed --
// the caller then finishes the frame in the interpreter from that pc, which
// works because the frame array *is* the state (nothing is hoisted).
//
// Calls (including recursion) go through a helper that performs a full VM call,
// so a recursive callee gets native code of its own via on_call, and each level
// absorbs its own deopt. That costs a C++ call per call, but it means no
// deoptimisation machinery and no second GC root mechanism.
class MixedMethodCode : public Xbyak::CodeGenerator {
 public:
  MixedMethodCode(const CodeObject& code, const std::unordered_set<int>& reach) {
    n_regs_ = code.n_regs;
    known_ = mdetail::known_int_slots(code, reach);
    emit(code, reach);
    ready();
  }
  void* entry_addr() { return (void*)getCode(); }

 private:
  Xbyak::Address tg(int slot) {
    return Xbyak::util::byte[Xbyak::util::r12 + slot * kValueSize + kTagOffset];
  }
  Xbyak::Address val(int slot) {
    return Xbyak::util::qword[Xbyak::util::r12 + slot * kValueSize +
                              kPayloadOffset];
  }
  Xbyak::Address hi(int slot) {  // the tag word (tag + padding)
    return Xbyak::util::qword[Xbyak::util::r12 + slot * kValueSize + kTagOffset];
  }

  // The value must be int-like for the inline integer path; otherwise bail to
  // the interpreter, which knows what `+` on two strings means.
  void guard_int(int pc, int slot, Xbyak::Label& bail) {
    using namespace Xbyak::util;
    auto it = known_.find(pc);
    if (it != known_.end() && it->second.count(slot)) {
      n_guards_elided_++;
      return;  // provably int-like here: no guard needed
    }
    n_guards_++;
    Xbyak::Label ok;
    mov(al, tg(slot));
    cmp(al, (int)Tag::Int);
    je(ok, T_NEAR);
    cmp(al, (int)Tag::Bool);
    jne(bail, T_NEAR);
    L(ok);
  }
  void copy_value(int dst, int src) {
    using namespace Xbyak::util;
    mov(rax, hi(src));
    mov(hi(dst), rax);
    mov(rax, val(src));
    mov(val(dst), rax);
  }

  void emit(const CodeObject& code, const std::unordered_set<int>& reach) {
    using namespace Xbyak::util;
    std::unordered_map<int, Xbyak::Label> labels, bail;
    for (int pc : reach) { labels[pc]; bail[pc]; }

    // 3 pushes = 24 bytes, leaving rsp 16-aligned for the helper calls.
    push(rbx); push(r12); push(r13);
    mov(r12, rdi);  // frame array
    mov(rbx, rsi);  // VM*
    mov(r13, rdx);  // Globals*

    auto pops = [&] { pop(r13); pop(r12); pop(rbx); };

    for (int pc = 0; pc < (int)code.code.size(); ++pc) {
      if (!reach.count(pc)) continue;
      L(labels[pc]);
      const Instr& ins = code.code[pc];
      int x = ins.a, y = ins.b, z = ins.c;
      switch (ins.op) {
        case Op::LoadConst:  // any type: copy the 16-byte Value from the pool
          mov(rcx, (std::uint64_t)(std::uintptr_t)&code.consts[y]);
          mov(rax, qword[rcx]);
          mov(hi(x), rax);
          mov(rax, qword[rcx + 8]);
          mov(val(x), rax);
          break;
        case Op::Move: copy_value(x, y); break;

        case Op::LoadGlobal:
          mov(rdi, rbx); mov(rsi, r13); mov(rdx, r12);
          mov(rcx, (std::uint64_t)(std::uintptr_t)&code);
          mov(r8d, x); mov(r9d, y);
          mov(rax, (std::uint64_t)(std::uintptr_t)&jit_m_loadglobal);
          call(rax);
          test(eax, eax);
          jz(bail[pc], T_NEAR);
          break;

        case Op::Add: case Op::Sub: case Op::Mul: case Op::BitAnd:
        case Op::BitOr: case Op::BitXor: case Op::LShift: case Op::RShift:
          guard_int(pc, y, bail[pc]);
          guard_int(pc, z, bail[pc]);
          mov(rax, val(y));
          switch (ins.op) {
            case Op::Add: add(rax, val(z)); break;
            case Op::Sub: sub(rax, val(z)); break;
            case Op::Mul: imul(rax, val(z)); break;
            case Op::BitAnd: and_(rax, val(z)); break;
            case Op::BitOr: or_(rax, val(z)); break;
            case Op::BitXor: xor_(rax, val(z)); break;
            case Op::LShift: mov(rcx, val(z)); shl(rax, cl); break;
            default: mov(rcx, val(z)); sar(rax, cl); break;
          }
          mov(val(x), rax);
          mov(tg(x), (int)Tag::Int);
          break;

        case Op::Eq: case Op::Ne: case Op::Lt: case Op::Le:
        case Op::Gt: case Op::Ge:
          guard_int(pc, y, bail[pc]);
          guard_int(pc, z, bail[pc]);
          mov(rax, val(y));
          cmp(rax, val(z));
          switch (ins.op) {
            case Op::Eq: sete(al); break;
            case Op::Ne: setne(al); break;
            case Op::Lt: setl(al); break;
            case Op::Le: setle(al); break;
            case Op::Gt: setg(al); break;
            default: setge(al); break;
          }
          movzx(eax, al);
          mov(val(x), rax);
          mov(tg(x), (int)Tag::Bool);
          break;

        case Op::Neg: case Op::Pos: case Op::Invert: case Op::Not:
          guard_int(pc, y, bail[pc]);
          mov(rax, val(y));
          if (ins.op == Op::Neg) neg(rax);
          else if (ins.op == Op::Invert) not_(rax);
          else if (ins.op == Op::Not) { test(rax, rax); sete(al); movzx(eax, al); }
          mov(val(x), rax);
          mov(tg(x), ins.op == Op::Not ? (int)Tag::Bool : (int)Tag::Int);
          break;

        case Op::Len:
          mov(rdi, rbx); mov(rsi, r12); mov(edx, x); mov(ecx, y);
          mov(rax, (std::uint64_t)(std::uintptr_t)&jit_m_len);
          call(rax);
          test(eax, eax);
          jz(bail[pc], T_NEAR);
          break;
        case Op::Subscr:
          mov(rdi, rbx); mov(rsi, r12); mov(edx, x); mov(ecx, y); mov(r8d, z);
          mov(rax, (std::uint64_t)(std::uintptr_t)&jit_m_subscr);
          call(rax);
          test(eax, eax);
          jz(bail[pc], T_NEAR);
          break;
        case Op::Call:
          mov(rdi, rbx); mov(rsi, r12); mov(edx, x); mov(ecx, y); mov(r8d, z);
          mov(rax, (std::uint64_t)(std::uintptr_t)&jit_m_call);
          call(rax);
          test(eax, eax);
          jz(bail[pc], T_NEAR);
          break;

        case Op::Jump: jmp(labels[x], T_NEAR); break;
        case Op::JumpIfFalse:
          guard_int(pc, x, bail[pc]);
          mov(rax, val(x)); test(rax, rax); jz(labels[y], T_NEAR);
          break;
        case Op::JumpIfTrue:
          guard_int(pc, x, bail[pc]);
          mov(rax, val(x)); test(rax, rax); jnz(labels[y], T_NEAR);
          break;

        case Op::Return:
          copy_value(n_regs_, x);  // the result slot
          pops();
          mov(rax, -1);
          ret();
          break;
        default: break;
      }
    }

    // Bail stubs: the frame array is already authoritative, so the interpreter
    // just resumes at this pc.
    for (int pc : reach) {
      L(bail[pc]);
      pops();
      mov(rax, pc);
      ret();
    }
  }

  int n_regs_ = 0;
  std::unordered_map<int, std::unordered_set<int>> known_;

 public:
  int n_guards_ = 0, n_guards_elided_ = 0;
};

struct CompiledMethod {
  std::unique_ptr<MethodCode> code;
  void* fn;
  int argc;
};

inline std::int64_t call_native(void* fn, int argc, const std::int64_t* a) {
  switch (argc) {
    case 0: return ((std::int64_t (*)())fn)();
    case 1: return ((std::int64_t (*)(std::int64_t))fn)(a[0]);
    case 2: return ((std::int64_t (*)(std::int64_t, std::int64_t))fn)(a[0], a[1]);
    case 3: return ((std::int64_t (*)(std::int64_t, std::int64_t,
                                      std::int64_t))fn)(a[0], a[1], a[2]);
    case 4: return ((std::int64_t (*)(std::int64_t, std::int64_t, std::int64_t,
                                      std::int64_t))fn)(a[0], a[1], a[2], a[3]);
    case 5: return ((std::int64_t (*)(std::int64_t, std::int64_t, std::int64_t,
                                      std::int64_t, std::int64_t))fn)(
        a[0], a[1], a[2], a[3], a[4]);
    default: return ((std::int64_t (*)(std::int64_t, std::int64_t, std::int64_t,
                                       std::int64_t, std::int64_t,
                                       std::int64_t))fn)(a[0], a[1], a[2], a[3],
                                                         a[4], a[5]);
  }
}

// -- driver -----------------------------------------------------------------

class MethodJIT {
 public:
  explicit MethodJIT(VM& vm, int threshold = 10)
      : vm_(vm), threshold_(threshold) {
    vm_.on_call = [this](const Value& callee, Value* regs,
                         int arg_base, int argc, Value& out) -> bool {
      return on_call(callee, regs, arg_base, argc, out);
    };
  }

  int n_compiled = 0;
  int n_mixed = 0;  // object-capable compilations
  int n_aborted = 0;
  int n_calls_native = 0;

 private:
  struct MixedEntry {
    std::unique_ptr<MixedMethodCode> code;
    void* fn;
  };

  // Run an object-capable compilation: build a tagged frame, root it, run
  // native, and finish in the interpreter if a type guard bailed.
  bool run_mixed(MixedEntry& e, const CodeObject* code, const Value& callee,
                 Value* regs, int arg_base, int argc, Value& out) {
    // The frame comes from the VM's contiguous value stack: a call costs a
    // pointer bump instead of a heap allocation, and the live region is already
    // a GC root, so nothing has to be registered.
    std::size_t base = vm_.frame_alloc(code->n_regs + 1);
    if (base == (std::size_t)-1) return false;  // stack full -> interpret
    Value* frame = vm_.vstack.data() + base;
    for (int i = 0; i < argc; ++i) frame[i] = regs[arg_base + i];
    using Fn = long (*)(void*, void*, void*);
    long r = ((Fn)e.fn)(frame, &vm_, callee.obj->globals);
    if (r < 0) out = frame[code->n_regs];
    else
      out = vm_.run_frame_raw(const_cast<CodeObject*>(code), frame,
                              *callee.obj->globals, (int)r);
    vm_.frame_free(base);
    n_calls_native++;
    return true;
  }

  bool on_call(const Value& callee, Value* regs, int arg_base,
               int argc, Value& out) {
    const CodeObject* code = callee.obj->code;
    const void* key = code;

    auto mit = mixed_.find(key);
    if (mit != mixed_.end())
      return run_mixed(*mit->second, code, callee, regs, arg_base, argc, out);

    auto it = compiled_.find(key);
    if (it == compiled_.end()) {
      if (blacklist_.count(key)) return false;
      if (++counts_[key] < threshold_) return false;
      auto reach = mdetail::feasible(*code, /*n_arg_regs=*/6);
      if (!reach) {
        // Not int-only: try the object-capable compiler.
        auto mreach = mdetail::mixed_feasible(*code);
        if (!mreach) { blacklist_.insert(key); n_aborted++; return false; }
        auto me = std::make_unique<MixedEntry>();
        me->code = std::make_unique<MixedMethodCode>(*code, *mreach);
        if (Xbyak::GetError()) {
          Xbyak::ClearError();
          blacklist_.insert(key);
          n_aborted++;
          return false;
        }
        me->fn = me->code->entry_addr();
        auto& slot = mixed_.emplace(key, std::move(me)).first->second;
        n_mixed++;
        return run_mixed(*slot, code, callee, regs, arg_base, argc, out);
      }
      auto cm = std::make_unique<CompiledMethod>();
      cm->code = std::make_unique<MethodCode>(*code, *reach, argc);
      if (Xbyak::GetError()) {
        Xbyak::ClearError();
        blacklist_.insert(key);
        n_aborted++;
        return false;
      }
      cm->fn = cm->code->entry_addr();
      cm->argc = argc;
      it = compiled_.emplace(key, std::move(cm)).first;
      n_compiled++;
    }

    // entry type guard: every argument must be an int for the native code
    for (int i = 0; i < argc; ++i)
      if (!regs[arg_base + i].is_int_like()) return false;  // deopt
    std::int64_t a[6] = {0};
    for (int i = 0; i < argc; ++i) a[i] = regs[arg_base + i].i;
    out = Value::integer(call_native(it->second->fn, argc, a));
    n_calls_native++;
    return true;
  }

  VM& vm_;
  int threshold_;
  std::unordered_map<const void*, int> counts_;
  std::unordered_map<const void*, std::unique_ptr<CompiledMethod>> compiled_;
  std::unordered_map<const void*, std::unique_ptr<MixedEntry>> mixed_;
  std::unordered_set<const void*> blacklist_;
};

}  // namespace minpython
