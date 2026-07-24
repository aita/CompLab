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
import :disasm;
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

// def / use for the *object-capable* compiler. It differs from the int one:
// LOAD_GLOBAL really defines its slot (nothing is elided), CALL reads the callee
// slot for its identity guard, and LEN / SUBSCR exist at all. Getting this wrong
// silently corrupts register allocation, so it is spelled out separately.
inline void def_use_obj(const Instr& ins, std::vector<int>& defs,
                        std::vector<int>& uses) {
  defs.clear();
  uses.clear();
  Op op = ins.op;
  if (op == Op::LoadConst || op == Op::LoadGlobal) {
    defs = {ins.a};
  } else if (op == Op::Move) {
    defs = {ins.a}; uses = {ins.b};
  } else if (is_binop(op) || is_cmpop(op) || op == Op::Subscr) {
    defs = {ins.a}; uses = {ins.b, ins.c};
  } else if (is_unaryop(op) || op == Op::Len) {
    defs = {ins.a}; uses = {ins.b};
  } else if (op == Op::JumpIfFalse || op == Op::JumpIfTrue) {
    uses = {ins.a};
  } else if (op == Op::Call) {
    defs = {ins.a};
    uses.push_back(ins.b);                       // the callee itself
    for (int i = 0; i < ins.c; ++i) uses.push_back(ins.b + 1 + i);
  } else if (op == Op::Return) {
    uses = {ins.a};
  }
}

// Backward-dataflow liveness -> a [start, end] interval per VM register.
inline std::unordered_map<int, std::pair<int, int>> live_ranges(
    const CodeObject& code, const std::unordered_set<int>& reach,
    bool object_mode = false) {
  std::vector<int> order(reach.begin(), reach.end());
  std::sort(order.rbegin(), order.rend());  // descending

  std::unordered_map<int, std::unordered_set<int>> live_in;
  std::unordered_map<int, std::pair<std::vector<int>, std::vector<int>>> du;
  for (int pc : reach) {
    live_in[pc] = {};
    std::vector<int> d, u;
    if (object_mode) def_use_obj(code.code[pc], d, u);
    else def_use(code.code[pc], d, u);
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
// type, calls may be to anything (they go through the VM), constants may be
// str/None, and loops are allowed -- the codegen binds a label per reachable pc,
// so a back-edge is just another jump, and the must-analysis is a fixpoint that
// already converges over cycles.
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
  for (int pc : reach)
    if (!supported(code.code[pc].op)) return std::nullopt;
  return reach;
}

// Parameters the interpreter has only ever seen as ints. Guarding these once on
// entry is what lets the must-analysis survive a loop header: without a seed the
// intersection with the function entry is empty, so every loop body re-guards
// everything, every iteration.
inline std::unordered_set<int> int_params(const CodeObject& code) {
  std::unordered_set<int> out;
  for (std::size_t p = 0; p < code.param_tags.size(); ++p)
    if (only_int_like(code.param_tags[p])) out.insert((int)p);
  return out;
}

inline bool mixed_inline_bin(Op op) {
  return op == Op::Add || op == Op::Sub || op == Op::Mul || op == Op::BitAnd ||
         op == Op::BitOr || op == Op::BitXor || op == Op::LShift ||
         op == Op::RShift;
}

// Does the recorded feedback say this site is worth an inline integer path?
// No feedback at all (never executed, or collection off) -> speculate int.
inline bool int_site(const CodeObject& code, int pc, bool two) {
  if (pc >= (int)code.feedback.size()) return true;
  const SiteFeedback& f = code.feedback[pc];
  if (f.tags_b == 0 && f.tags_c == 0) return true;
  if (!only_int_like(f.tags_b)) return false;
  return !two || f.tags_c == 0 || only_int_like(f.tags_c);
}

// Which slots are *provably* int-like on entry to each pc -- a forward "must"
// analysis (intersection at merges). The object-capable compiler uses it to drop
// redundant type guards: once a value has been guarded (or produced by an int
// op), later uses need no guard at all. This is the cheap stand-in for the type
// feedback a production JIT would collect from inline caches.
inline std::unordered_map<int, std::unordered_set<int>> known_int_slots(
    const CodeObject& code, const std::unordered_set<int>& reach,
    const std::unordered_set<int>& seed = {}) {
  std::unordered_set<int> universe;
  for (int r = 0; r < code.n_regs; ++r) universe.insert(r);
  std::unordered_map<int, std::unordered_set<int>> in;
  for (int pc : reach) in[pc] = universe;
  in[0] = seed;  // parameters the entry guard has already pinned down

  // A guard that fails does not end the compiled region: it jumps to an
  // out-of-line slow path that calls the interpreter's helper and then rejoins.
  // So "we guarded it here" says nothing about the merge point *after* the
  // instruction -- only about the fast path, which the slow path merges into.
  // An inline result is therefore known only when the slow path is provably
  // unreachable, i.e. when every operand was already known.
  auto transfer = [&](const std::unordered_set<int>& s, int pc) {
    const Instr& ins = code.code[pc];
    std::unordered_set<int> o = s;
    Op op = ins.op;
    if (op == Op::LoadConst) {
      if (code.consts[ins.b].is_int_like()) o.insert(ins.a);
      else o.erase(ins.a);
    } else if (op == Op::Move) {
      if (s.count(ins.b)) o.insert(ins.a); else o.erase(ins.a);
    } else if (op == Op::Len) {
      o.insert(ins.a);           // always an int
    } else if (mixed_inline_bin(op) || is_cmpop(op)) {
      if (int_site(code, pc, true) && s.count(ins.b) && s.count(ins.c))
        o.insert(ins.a);
      else
        o.erase(ins.a);
    } else if (is_unaryop(op)) {
      if (s.count(ins.b)) o.insert(ins.a); else o.erase(ins.a);
    } else if (op == Op::JumpIfFalse || op == Op::JumpIfTrue ||
               op == Op::StoreGlobal || op == Op::Jump || op == Op::Return ||
               op == Op::Print) {
      // no destination register
    } else {
      o.erase(ins.a);            // Call / Subscr / MakeList / ... : unknown
    }
    return o;
  };

  std::vector<int> asc(reach.begin(), reach.end());
  std::sort(asc.begin(), asc.end());
  bool changed = true;
  while (changed) {
    changed = false;
    for (int pc : asc) {
      auto out = transfer(in[pc], pc);
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

// Which *exact* tag the frame array is known to already hold for each slot, on
// entry to each pc. Absent slot = unknown. A forward must-analysis again, but
// over exact tags rather than the int-like/not question above.
//
// This exists to kill redundant tag stores. Frames are tagged, so a naive
// compiler writes a tag byte after every single result -- and in a tight
// integer loop that is most of the memory traffic, even though the byte being
// written is nearly always the byte that is already there. Skipping a store
// whose value the array already holds leaves memory bit-for-bit identical, so
// nothing else -- GC, bail-out, flush -- needs to know this pass ran.
using TagMap = std::unordered_map<int, int>;

inline std::unordered_map<int, TagMap> mem_tags(
    const CodeObject& code, const std::unordered_set<int>& reach,
    const std::unordered_map<int, std::unordered_set<int>>& known) {
  auto is_known = [&](int pc, int slot) {
    auto it = known.find(pc);
    return it != known.end() && it->second.count(slot) > 0;
  };

  auto transfer = [&](TagMap s, int pc) {
    const Instr& ins = code.code[pc];
    Op op = ins.op;
    auto set = [&](Tag t) { s[ins.a] = (int)t; };
    // Same slow-path-rejoin caveat as known_int_slots: an inline result has a
    // statically known tag only when the slow path cannot be reached.
    bool sure = int_site(code, pc, true) && is_known(pc, ins.b) &&
                (is_cmpop(op) || mixed_inline_bin(op) ? is_known(pc, ins.c)
                                                      : true);
    if (op == Op::LoadConst) {
      set(code.consts[ins.b].tag);
    } else if (op == Op::Move) {
      auto it = s.find(ins.b);
      if (it != s.end()) s[ins.a] = it->second; else s.erase(ins.a);
    } else if (op == Op::Len) {
      set(Tag::Int);             // both the inline path and the helper agree
    } else if (mixed_inline_bin(op) || is_cmpop(op)) {
      if (sure) set(is_cmpop(op) ? Tag::Bool : Tag::Int); else s.erase(ins.a);
    } else if (is_unaryop(op)) {
      if (sure) set(op == Op::Not ? Tag::Bool : Tag::Int); else s.erase(ins.a);
    } else if (op == Op::JumpIfFalse || op == Op::JumpIfTrue ||
               op == Op::StoreGlobal || op == Op::Jump || op == Op::Return ||
               op == Op::Print) {
      // no destination register
    } else {
      s.erase(ins.a);
    }
    return s;
  };

  // Optimistic init: unvisited blocks are top, and top meets to the other side.
  std::unordered_map<int, TagMap> in;
  std::unordered_set<int> seen{0};
  in[0] = {};   // entry: parameters carry whatever the caller passed

  std::vector<int> asc(reach.begin(), reach.end());
  std::sort(asc.begin(), asc.end());
  bool changed = true;
  while (changed) {
    changed = false;
    for (int pc : asc) {
      if (!seen.count(pc)) continue;
      TagMap out = transfer(in[pc], pc);
      for (int s : successors(code, pc)) {
        if (!reach.count(s)) continue;
        if (!seen.count(s)) {
          seen.insert(s);
          in[s] = out;
          changed = true;
          continue;
        }
        TagMap& cur = in[s];
        TagMap merged;
        for (auto& [slot, t] : cur) {
          auto it = out.find(slot);
          if (it != out.end() && it->second == t) merged.emplace(slot, t);
        }
        if (merged != cur) { cur = std::move(merged); changed = true; }
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
// Generic slow paths. When an inline integer path's type check fails, native
// code calls one of these and keeps going -- the function is never abandoned to
// the interpreter just because a value was a str or a list.
inline int jit_m_binop(VM* vm, Value* regs, int op, int a, int b, int c) {
  regs[a] = vm->op_binop((Op)op, regs[b], regs[c]);
  return vm->diag.failed ? 0 : 1;
}
inline int jit_m_cmp(VM* vm, Value* regs, int op, int a, int b, int c) {
  regs[a] = vm->op_compare((Op)op, regs[b], regs[c]);
  return vm->diag.failed ? 0 : 1;
}
inline int jit_m_unary(VM* vm, Value* regs, int op, int a, int b) {
  regs[a] = vm->op_unary((Op)op, regs[b]);
  return vm->diag.failed ? 0 : 1;
}
inline int jit_m_truthy(Value* regs, int slot) {
  return truthy(regs[slot]) ? 1 : 0;
}

// A natively-called frame bailed on a type guard: finish it in the interpreter
// and hand the result back, so the native caller can carry on. The 16-byte
// Value comes back in rax:rdx per the SysV ABI.
inline Value jit_m_finish(VM* vm, Value* frame, const CodeObject* code,
                          Globals* glb, int pc) {
  return vm->run_frame_raw(const_cast<CodeObject*>(code), frame, *glb, pc);
}

// Is the CALL at `pc` a direct call to `code` itself? (the preceding
// LOAD_GLOBAL that defines its callee register names this function)
inline bool is_self_call(const CodeObject& code, int pc) {
  const Instr& ins = code.code[pc];
  if (ins.op != Op::Call) return false;
  for (int j = pc - 1; j >= 0; --j) {
    const Instr& prev = code.code[j];
    if (prev.op == Op::LoadGlobal && prev.a == ins.b)
      return code.names[prev.b] == code.name;
    if (prev.a == ins.b) return false;  // written by something else
  }
  return false;
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
  // `self_obj` is the Function object this code was compiled for; a direct
  // self-call is guarded against it and then made as a real native call.
  MixedMethodCode(const CodeObject& code, const std::unordered_set<int>& reach,
                  VM* vm, const Object* self_obj)
      : vm_(vm), self_obj_(self_obj) {
    n_regs_ = code.n_regs;
    int_params_ = mdetail::int_params(code);
    known_ = mdetail::known_int_slots(code, reach, int_params_);
    mem_ = mdetail::mem_tags(code, reach, known_);
    allocate(code, reach);
    emit(code, reach);
    ready();
  }
  void* entry_addr() { return (void*)getCode(); }
  // Entry for on-stack replacement: same ABI plus a start pc in the 4th
  // argument. Null when the function has no loop to re-enter.
  void* osr_addr() {
    return osr_targets_.empty() ? nullptr : (void*)(getCode() + osr_off_);
  }
  bool has_osr() const { return !osr_targets_.empty(); }
  // Which VM slots ended up in which machine register -- the thing you need to
  // read the disassembly.
  std::string reg_map() const {
    std::vector<std::pair<int, int>> v;
    for (auto& [slot, r] : slot_reg_) v.push_back({slot, r.getIdx()});
    std::sort(v.begin(), v.end());
    std::string s = "regs:";
    for (auto& [slot, idx] : v) s += std::format(" r{}=>x{}", slot, idx);
    if (v.empty()) s += " (none hoisted)";
    if (!osr_targets_.empty()) s += std::format("  osr_off={}", osr_off_);
    return s;
  }
  int frame_size() const { return n_regs_ + 1; }

 private:
  // Slot addressing goes through `off_`, which is 0 for the function's own body
  // and the base of a region when an inlined callee's body is being emitted.
  Xbyak::Address tg(int slot) {
    return Xbyak::util::byte[Xbyak::util::r12 +
                             (slot + off_) * kValueSize + kTagOffset];
  }
  // Hoisting. Payloads of hot slots live in callee-saved registers; the tag
  // always stays in memory, so bool-vs-int stays exact for free. Any path that
  // calls out (a safepoint, and the only place a GC can run) flushes first, so
  // the collector and the helper both see the real values.
  bool has_reg(int s) const { return off_ == 0 && slot_reg_.count(s) != 0; }
  Xbyak::Reg64 reg(int s) const { return slot_reg_.at(s); }
  void ld(const Xbyak::Reg64& dst, int slot) {
    if (has_reg(slot)) { if (reg(slot).getIdx() != dst.getIdx()) mov(dst, reg(slot)); }
    else mov(dst, val(slot));
  }
  void st(int slot) {  // payload <- rax
    using namespace Xbyak::util;
    if (has_reg(slot)) mov(reg(slot), rax);
    else mov(val(slot), rax);
  }
  template <class F>
  void with(int slot, F&& f) {
    if (has_reg(slot)) f(reg(slot));
    else f(val(slot));
  }
  void flush_all() {
    for (auto& [slot, r] : slot_reg_) mov(val(slot), r);
  }
  void reload(int slot) {
    if (has_reg(slot)) mov(reg(slot), val(slot));
  }
  void load_all() {
    for (auto& [slot, r] : slot_reg_) mov(r, val(slot));
  }

  void allocate(const CodeObject& code, const std::unordered_set<int>& reach) {
    using namespace Xbyak::util;
    std::vector<Xbyak::Reg64> pool = {r13, r14, r15, rbp};  // callee-saved
    // Deliberately not linear-scan: that shares one register between slots whose
    // live ranges are disjoint, which is right for a compiler that tracks where
    // each value lives at each point. This one loads its registers once on entry
    // and flushes them at every exit, so a shared register means one slot
    // silently clobbering another -- which is exactly what went wrong. Give the
    // hottest slots whole-function ownership instead.
    std::unordered_map<int, int> refs;
    std::vector<int> defs, uses;
    for (int pc : reach) {
      mdetail::def_use_obj(code.code[pc], defs, uses);
      for (int r : defs) refs[r]++;
      for (int r : uses) refs[r]++;
    }
    std::vector<std::pair<int, int>> ranked;
    for (auto& [slot, n] : refs)
      if (slot < code.n_regs) ranked.push_back({slot, n});
    std::sort(ranked.begin(), ranked.end(), [](auto& x, auto& y) {
      return x.second != y.second ? x.second > y.second : x.first < y.first;
    });
    for (std::size_t k = 0; k < ranked.size() && k < pool.size(); ++k)
      slot_reg_.insert({ranked[k].first, pool[k]});
  }
  Xbyak::Address val(int slot) {
    return Xbyak::util::qword[Xbyak::util::r12 +
                              (slot + off_) * kValueSize + kPayloadOffset];
  }
  Xbyak::Address hi(int slot) {  // the tag word (tag + padding)
    return Xbyak::util::qword[Xbyak::util::r12 +
                              (slot + off_) * kValueSize + kTagOffset];
  }

  // The value must be int-like for the inline integer path; otherwise bail to
  // the interpreter, which knows what `+` on two strings means.
  // Does this site still need a runtime type check, or has the analysis already
  // pinned the slot down?
  // What the frame array is already known to hold for `slot` on entry to `pc`.
  // Only valid for the function's own body: an inlined region's pcs are the
  // callee's, so the analysis does not apply (off_ != 0).
  std::optional<Tag> mem_tag(int pc, int slot) const {
    if (off_ != 0) return std::nullopt;
    auto it = mem_.find(pc);
    if (it == mem_.end()) return std::nullopt;
    auto s = it->second.find(slot);
    if (s == it->second.end()) return std::nullopt;
    return (Tag)s->second;
  }
  // Write a slot's tag -- unless the array demonstrably holds that byte already,
  // which in a tight loop is nearly always. Eliding leaves memory unchanged, so
  // no other part of the runtime can tell the difference.
  void set_tag(int pc, int slot, Tag t) {
    if (mem_tag(pc, slot) == t) { n_tags_elided_++; return; }
    n_tags_++;
    mov(tg(slot), (int)t);
  }

  bool needs_guard(int pc, int slot) const {
    auto it = known_.find(pc);
    return !(it != known_.end() && it->second.count(slot));
  }

  void guard_int(int pc, int slot, Xbyak::Label& target) {
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
    jne(target, T_NEAR);
    L(ok);
  }
  // Does the recorded feedback say this site is worth an inline integer path?
  // No feedback at all (never executed, or collection off) -> speculate int.
  static bool int_site(const CodeObject& code, int pc, bool two) {
    return mdetail::int_site(code, pc, two);
  }
  // Has this site ever seen a List? If not, the inline list path is dead weight.
  static bool list_site(const CodeObject& code, int pc) {
    if (pc >= (int)code.feedback.size()) return true;
    const SiteFeedback& f = code.feedback[pc];
    if (f.tags_b == 0) return true;
    return (f.tags_b & (1u << (int)Tag::List)) != 0;
  }

  // vm, regs, op, a, b, c -> rdi, rsi, edx, ecx, r8d, r9d
  void emit_slow3(int (*fn)(VM*, Value*, int, int, int, int), int op, int a,
                  int b, int c, Xbyak::Label& bail) {
    using namespace Xbyak::util;
    flush_all();   // safepoint: the helper reads the array, and may collect
    mov(rdi, rbx); mov(rsi, r12); mov(edx, op);
    mov(ecx, a); mov(r8d, b); mov(r9d, c);
    mov(rax, (std::uint64_t)(std::uintptr_t)fn);
    call(rax);
    test(eax, eax);
    jz(bail, T_NEAR);
    reload(a);
  }

  // Move between VM slots, honouring hoisting: the tag travels through memory
  // (it always lives there), the payload through the register file.
  void move_value(int pc, int dst, int src) {
    using namespace Xbyak::util;
    if (auto t = mem_tag(pc, src)) {
      set_tag(pc, dst, *t);      // constant: no round trip through memory
    } else {
      mov(al, tg(src));
      mov(tg(dst), al);
    }
    if (has_reg(dst) && has_reg(src)) {          // straight register copy
      if (reg(dst).getIdx() != reg(src).getIdx()) mov(reg(dst), reg(src));
    } else {
      ld(rax, src);
      st(dst);
    }
  }

  // Slow paths are emitted after the body instead of inline, so the hot path is
  // contiguous and does not even need a jump over them.
  Xbyak::Label& late_label() {
    late_labels_.emplace_back();
    return late_labels_.back();
  }
  void defer(std::function<void()> f) { late_.push_back(std::move(f)); }
  void flush_late() {
    for (auto& f : late_) f();
    late_.clear();
  }

  static std::vector<int> sorted(const std::unordered_set<int>& s) {
    std::vector<int> v(s.begin(), s.end());
    std::sort(v.begin(), v.end());
    return v;
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

    // 6 pushes + a 24-byte scratch area leaves rsp 16-aligned for our calls.
    // r13/r14/r15/rbp are freed for value hoisting, so the Globals pointer and
    // the self-call temporaries live in the scratch area instead.
    L(entry_);
    push(rbx); push(r12); push(r13); push(r14); push(r15); push(rbp);
    sub(rsp, 24);
    mov(r12, rdi);  // frame array
    mov(rbx, rsi);  // VM*
    mov(qword[rsp + 0], rdx);  // Globals*
    // Pin the int parameters once. Everything downstream is allowed to assume
    // it, which is what keeps the loop bodies guard-free.
    for (int p : sorted(int_params_)) {
      Xbyak::Label ok;
      mov(al, tg(p));
      cmp(al, (int)Tag::Int);
      je(ok, T_NEAR);
      cmp(al, (int)Tag::Bool);
      jne(entry_bail_, T_NEAR);
      L(ok);
    }
    load_all();

    auto pops = [&] {
      add(rsp, 24);
      pop(rbp); pop(r15); pop(r14); pop(r13); pop(r12); pop(rbx);
    };

    for (int pc = 0; pc < (int)code.code.size(); ++pc) {
      if (!reach.count(pc)) continue;
      L(labels[pc]);
      const Instr& ins = code.code[pc];
      int x = ins.a, y = ins.b, z = ins.c;
      switch (ins.op) {
        case Op::LoadConst: {
          const Value& k = code.consts[y];
          if (k.is_int_like()) {          // the common case: just an immediate
            if (has_reg(x)) mov(reg(x), k.i);   // straight into its register
            else { mov(rax, k.i); mov(val(x), rax); }
            set_tag(pc, x, k.tag);
          } else {                        // str / None: copy the whole Value
            mov(rcx, (std::uint64_t)(std::uintptr_t)&code.consts[y]);
            mov(rax, qword[rcx]);
            mov(hi(x), rax);
            mov(rax, qword[rcx + 8]);
            st(x);
          }
          break;
        }
        case Op::Move: move_value(pc, x, y); break;

        case Op::LoadGlobal:
          flush_all();
          mov(rdi, rbx); mov(rsi, qword[rsp + 0]); mov(rdx, r12);
          mov(rcx, (std::uint64_t)(std::uintptr_t)&code);
          mov(r8d, x); mov(r9d, y);
          mov(rax, (std::uint64_t)(std::uintptr_t)&jit_m_loadglobal);
          call(rax);
          test(eax, eax);
          jz(bail[pc], T_NEAR);
          reload(x);
          break;

        case Op::Add: case Op::Sub: case Op::Mul: case Op::BitAnd:
        case Op::BitOr: case Op::BitXor: case Op::LShift: case Op::RShift: {
          if (!int_site(code, pc, true)) {   // never an int here: slow path only
            emit_slow3(&jit_m_binop, (int)ins.op, x, y, z, bail[pc]);
            break;
          }
          Xbyak::Label& slow = late_label();
          Xbyak::Label& done = late_label();
          guard_int(pc, y, slow);
          guard_int(pc, z, slow);
          // Two-address form: when the destination has a register of its own and
          // is not also the right operand, accumulate straight into it.
          Xbyak::Reg64 acc = rax;
          if (has_reg(x) && x != z) {
            acc = reg(x);
            if (!(has_reg(y) && reg(y).getIdx() == acc.getIdx())) ld(acc, y);
          } else {
            ld(rax, y);
          }
          switch (ins.op) {
            case Op::Add: with(z, [&](auto&& o){ add(acc, o); }); break;
            case Op::Sub: with(z, [&](auto&& o){ sub(acc, o); }); break;
            case Op::Mul: with(z, [&](auto&& o){ imul(acc, o); }); break;
            case Op::BitAnd: with(z, [&](auto&& o){ and_(acc, o); }); break;
            case Op::BitOr: with(z, [&](auto&& o){ or_(acc, o); }); break;
            case Op::BitXor: with(z, [&](auto&& o){ xor_(acc, o); }); break;
            case Op::LShift: ld(rcx, z); shl(acc, cl); break;
            default: ld(rcx, z); sar(acc, cl); break;
          }
          if (acc.getIdx() == rax.getIdx()) st(x);
          set_tag(pc, x, Tag::Int);
          L(done);
          {
            Op o = ins.op;
            Xbyak::Label& b = bail[pc];
            defer([this, o, x, y, z, &slow, &done, &b] {
              L(slow);
              emit_slow3(&jit_m_binop, (int)o, x, y, z, b);
              jmp(done, T_NEAR);
            });
          }
          break;
        }

        case Op::Eq: case Op::Ne: case Op::Lt: case Op::Le:
        case Op::Gt: case Op::Ge: {
          if (!int_site(code, pc, true)) {
            emit_slow3(&jit_m_cmp, (int)ins.op, x, y, z, bail[pc]);
            break;
          }
          Xbyak::Label& slow = late_label();
          Xbyak::Label& done = late_label();
          guard_int(pc, y, slow);
          guard_int(pc, z, slow);
          if (has_reg(y)) with(z, [&](auto&& o){ cmp(reg(y), o); });
          else { ld(rax, y); with(z, [&](auto&& o){ cmp(rax, o); }); }
          switch (ins.op) {
            case Op::Eq: sete(al); break;
            case Op::Ne: setne(al); break;
            case Op::Lt: setl(al); break;
            case Op::Le: setle(al); break;
            case Op::Gt: setg(al); break;
            default: setge(al); break;
          }
          movzx(eax, al);
          st(x);
          set_tag(pc, x, Tag::Bool);
          L(done);
          {
            Op o = ins.op;
            Xbyak::Label& b = bail[pc];
            defer([this, o, x, y, z, &slow, &done, &b] {
              L(slow);
              emit_slow3(&jit_m_cmp, (int)o, x, y, z, b);
              jmp(done, T_NEAR);
            });
          }
          break;
        }

        case Op::Neg: case Op::Pos: case Op::Invert: case Op::Not: {
          Xbyak::Label slow, done;
          guard_int(pc, y, slow);
          ld(rax, y);
          if (ins.op == Op::Neg) neg(rax);
          else if (ins.op == Op::Invert) not_(rax);
          else if (ins.op == Op::Not) { test(rax, rax); sete(al); movzx(eax, al); }
          st(x);
          set_tag(pc, x, ins.op == Op::Not ? Tag::Bool : Tag::Int);
          jmp(done, T_NEAR);
          L(slow);
          flush_all();
          mov(rdi, rbx); mov(rsi, r12); mov(edx, (int)ins.op);
          mov(ecx, x); mov(r8d, y);
          mov(rax, (std::uint64_t)(std::uintptr_t)&jit_m_unary);
          call(rax);
          test(eax, eax);
          jz(bail[pc], T_NEAR);
          reload(x);
          L(done);
          break;
        }

        case Op::Len: {
          Xbyak::Label slow, done;
          if (inline_lists_ && list_site(code, pc)) {  // inline List size
            mov(al, tg(y));
            cmp(al, (int)Tag::List);
            jne(slow, T_NEAR);
            ld(rcx, y);
            mov(rdx, qword[rcx + list_off_]);
            mov(rax, qword[rcx + list_off_ + 8]);
            sub(rax, rdx);
            sar(rax, 4);
            st(x);
            set_tag(pc, x, Tag::Int);
            jmp(done, T_NEAR);
          }
          L(slow);
          flush_all();
          mov(rdi, rbx); mov(rsi, r12); mov(edx, x); mov(ecx, y);
          mov(rax, (std::uint64_t)(std::uintptr_t)&jit_m_len);
          call(rax);
          test(eax, eax);
          jz(bail[pc], T_NEAR);
          reload(x);
          L(done);
          break;
        }
        case Op::Subscr: {
          Xbyak::Label slow, done;
          if (inline_lists_ && list_site(code, pc)) {  // inline List[int]
            mov(al, tg(y));
            cmp(al, (int)Tag::List);
            jne(slow, T_NEAR);
            mov(al, tg(z));
            cmp(al, (int)Tag::Int);
            jne(slow, T_NEAR);
            ld(rcx, y);
            mov(rdx, qword[rcx + list_off_]);        // begin
            mov(r8, qword[rcx + list_off_ + 8]);     // end
            sub(r8, rdx);
            sar(r8, 4);                              // size
            ld(rax, z);
            cmp(rax, r8);
            jae(slow, T_NEAR);   // unsigned: catches negative and out-of-range
            shl(rax, 4);
            add(rdx, rax);
            mov(rax, qword[rdx]);
            mov(hi(x), rax);
            mov(rax, qword[rdx + kPayloadOffset]);
            st(x);
            jmp(done, T_NEAR);
          }
          L(slow);
          flush_all();
          mov(rdi, rbx); mov(rsi, r12); mov(edx, x); mov(ecx, y); mov(r8d, z);
          mov(rax, (std::uint64_t)(std::uintptr_t)&jit_m_subscr);
          call(rax);
          test(eax, eax);
          jz(bail[pc], T_NEAR);
          reload(x);
          L(done);
          break;
        }
        case Op::Call:
          if (self_obj_ && is_self_call(code, pc)) {
            emit_native_self_call(code, x, y, z, bail[pc]);
          } else {
            flush_all();
            mov(rdi, rbx); mov(rsi, r12); mov(edx, x); mov(ecx, y); mov(r8d, z);
            mov(rax, (std::uint64_t)(std::uintptr_t)&jit_m_call);
            call(rax);
            test(eax, eax);
            jz(bail[pc], T_NEAR);
            reload(x);
          }
          break;

        case Op::Jump: jmp(labels[x], T_NEAR); break;
        case Op::JumpIfFalse: case Op::JumpIfTrue: {
          Xbyak::Label& have = late_label();
          if (needs_guard(pc, x)) {
            Xbyak::Label& slow = late_label();
            guard_int(pc, x, slow);
            defer([this, x, &slow, &have] {
              L(slow);            // any other type: ask the runtime
              flush_all();
              mov(rdi, r12); mov(esi, x);
              mov(rax, (std::uint64_t)(std::uintptr_t)&jit_m_truthy);
              call(rax);
              movzx(eax, al);  // returns int; clear the upper half before test
              jmp(have, T_NEAR);
            });
          }
          ld(rax, x);             // int-like: truthiness is payload != 0
          L(have);
          test(rax, rax);
          if (ins.op == Op::JumpIfFalse) jz(labels[y], T_NEAR);
          else jnz(labels[y], T_NEAR);
          break;
        }

        case Op::Return:
          flush_all();             // make the array authoritative first
          copy_value(n_regs_, x);  // ... then take the result out of it
          pops();
          mov(rax, -1);
          ret();
          break;
        default: break;
      }
    }

    flush_late();  // the out-of-line slow paths, after the hot body

    // Bail stubs: the frame array is already authoritative, so the interpreter
    // just resumes at this pc.
    for (int pc : reach) {
      L(bail[pc]);
      flush_all();
      pops();
      mov(rax, pc);
      ret();
    }

    L(entry_bail_);  // a parameter was not the type we compiled for: nothing has
    pops();          // run yet, so the interpreter just takes the whole call
    mov(rax, 0);
    ret();

    // On-stack replacement entry. `long f(Value*, VM*, Globals*, long pc)`:
    // set up exactly like the normal entry, then jump to the requested loop
    // header. Only back-edge targets are reachable this way.
    for (int pc : reach) {
      const Instr& ins = code.code[pc];
      if (ins.op == Op::Jump && ins.a <= pc) osr_targets_.insert(ins.a);
    }
    if (!osr_targets_.empty()) {
      osr_off_ = (int)getSize();
      push(rbx); push(r12); push(r13); push(r14); push(r15); push(rbp);
      sub(rsp, 24);
      mov(r12, rdi);
      mov(rbx, rsi);
      mov(qword[rsp + 0], rdx);
      std::vector<int> targets(osr_targets_.begin(), osr_targets_.end());
      std::sort(targets.begin(), targets.end());
      for (int t : targets) {
        Xbyak::Label next;
        cmp(ecx, t);
        jne(next, T_NEAR);
        // OSR is a third edge into this header, and neither analysis modelled
        // it -- so verify here what they were allowed to assume, or hand the
        // loop back to the interpreter. Paid once per OSR entry.
        std::unordered_set<int> exact;
        auto mt = mem_.find(t);
        if (mt != mem_.end()) {
          std::vector<std::pair<int, int>> v(mt->second.begin(),
                                             mt->second.end());
          std::sort(v.begin(), v.end());
          for (auto& [sl, tag] : v) {
            exact.insert(sl);
            cmp(tg(sl), tag);
            jne(osr_bail_, T_NEAR);
          }
        }
        auto it = known_.find(t);
        if (it != known_.end())
          for (int sl : sorted(it->second)) {
            if (exact.count(sl)) continue;   // pinned exactly just above
            Xbyak::Label ok;
            mov(al, tg(sl));
            cmp(al, (int)Tag::Int);
            je(ok, T_NEAR);
            cmp(al, (int)Tag::Bool);
            jne(osr_bail_, T_NEAR);
            L(ok);
          }
        load_all();
        jmp(labels[t], T_NEAR);
        L(next);
      }
      jmp(labels[0], T_NEAR);  // unknown pc: start from the top

      L(osr_bail_);            // nothing ran: resume interpreting at that pc
      mov(rax, rcx);
      add(rsp, 40);
      pop(rbp); pop(r15); pop(r14); pop(r13); pop(r12); pop(rbx);
      ret();
    }
  }

  // A direct self-recursive call made natively: guard that the callee is still
  // this same function, take a frame off the VM value stack (a pointer bump),
  // copy the arguments and `call` our own entry -- skipping the whole
  // helper -> op_call -> do_call -> on_call -> driver dispatch chain.
  void emit_native_self_call(const CodeObject& code, int dst, int fr, int argc,
                             Xbyak::Label& bail) {
    using namespace Xbyak::util;
    int fsize = n_regs_ + 1;
    flush_all();  // the callee copies its arguments out of our frame array

    mov(al, tg(fr));                       // callee identity guard
    cmp(al, (int)Tag::Func);
    jne(bail, T_NEAR);
    mov(rax, val(fr));
    mov(rcx, (std::uint64_t)(std::uintptr_t)self_obj_);
    cmp(rax, rcx);
    jne(bail, T_NEAR);

    mov(rcx, (std::uint64_t)(std::uintptr_t)&vm_->vtop);
    mov(rax, qword[rcx]);
    mov(qword[rsp + 8], rax);              // saved vtop, restored after
    mov(rdx, rax);
    add(rdx, fsize);
    mov(r8, (std::uint64_t)vm_->vstack.size());
    cmp(rdx, r8);
    ja(bail, T_NEAR);                      // frame stack full -> interpret
    mov(qword[rcx], rdx);

    mov(r8, (std::uint64_t)(std::uintptr_t)vm_->vstack.data());
    shl(rax, 4);
    add(r8, rax);                          // r8 = callee frame
    mov(qword[rsp + 16], r8);

    for (int k = 0; k < fsize; ++k)        // a fresh frame reads as None
      mov(byte[r8 + k * kValueSize], (int)Tag::None);
    for (int i = 0; i < argc; ++i) {
      mov(rax, qword[r12 + (fr + 1 + i) * kValueSize]);
      mov(qword[r8 + i * kValueSize], rax);
      mov(rax, val(fr + 1 + i));
      mov(qword[r8 + i * kValueSize + kPayloadOffset], rax);
    }

    mov(rdi, r8);
    mov(rsi, rbx);
    mov(rdx, qword[rsp + 0]);
    call(entry_);

    Xbyak::Label done, finish;
    mov(r8, qword[rsp + 16]);              // the call clobbered r8
    cmp(rax, 0);
    jge(finish, T_NEAR);
    mov(rcx, qword[r8 + n_regs_ * kValueSize]);      // completed: take result
    mov(hi(dst), rcx);
    mov(rax, qword[r8 + n_regs_ * kValueSize + kPayloadOffset]);
    st(dst);
    jmp(done, T_NEAR);

    L(finish);   // the callee bailed: finish that frame in the interpreter
    mov(rdi, rbx);
    mov(rsi, r8);
    mov(rdx, (std::uint64_t)(std::uintptr_t)&code);
    mov(rcx, qword[rsp + 0]);
    mov(r8d, eax);
    mov(rax, (std::uint64_t)(std::uintptr_t)&jit_m_finish);
    call(rax);
    mov(hi(dst), rax);
    mov(rax, rdx);
    st(dst);

    L(done);
    mov(rcx, (std::uint64_t)(std::uintptr_t)&vm_->vtop);
    mov(rax, qword[rsp + 8]);
    mov(qword[rcx], rax);                  // release the frame
    mov(rax, (std::uint64_t)(std::uintptr_t)&vm_->diag.failed);
    mov(al, byte[rax]);
    test(al, al);
    jnz(bail, T_NEAR);                     // a latched error unwinds
  }

  bool inline_lists_ = list_layout().ok;
  int list_off_ = (int)list_layout().list_off;
  std::unordered_map<int, Xbyak::Reg64> slot_reg_;
  std::deque<Xbyak::Label> late_labels_;
  std::vector<std::function<void()>> late_;
  std::unordered_set<int> int_params_;
  Xbyak::Label entry_bail_, osr_bail_;
  int off_ = 0;
  int n_regs_ = 0;
  int osr_off_ = 0;
  std::unordered_set<int> osr_targets_;
  Xbyak::Label entry_;
  VM* vm_ = nullptr;
  const Object* self_obj_ = nullptr;
  std::unordered_map<int, std::unordered_set<int>> known_;
  std::unordered_map<int, mdetail::TagMap> mem_;
  int n_tags_ = 0, n_tags_elided_ = 0;

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
    vm_.collect_feedback = true;
    // Take the back-edge hook too, unless a tracing JIT already owns it: a hot
    // loop in a function that is only *called* once never reaches the call
    // threshold, so the only way in is on-stack replacement.
    if (!vm_.on_backedge)
      vm_.on_backedge = [this](CodeObject* code, int target, Value* regs,
                               Globals& glb, Value& out) -> long {
        return on_backedge(code, target, regs, glb, out);
      };
    vm_.on_call = [this](const Value& callee, Value* regs,
                         int arg_base, int argc, Value& out) -> bool {
      return on_call(callee, regs, arg_base, argc, out);
    };
  }

  int n_compiled = 0;
  int n_mixed = 0;  // object-capable compilations
  int n_aborted = 0;
  int n_calls_native = 0;
  int n_osr = 0;

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

  // On-stack replacement: a loop got hot inside a frame the interpreter owns.
  // Copy that frame into a value-stack frame of the compiled function's size,
  // enter native code at the loop header, and either return the function's
  // value or copy the frame back and hand the interpreter a resume pc.
  long on_backedge(CodeObject* code, int target, Value* regs, Globals& glb,
                   Value& out) {
    const void* key = code;
    auto it = mixed_.find(key);
    if (it == mixed_.end()) {
      if (blacklist_.count(key) || osr_tried_.count(key)) return -1;
      if (++osr_counts_[key] < osr_threshold_) return -1;
      osr_tried_.insert(key);
      auto reach = mdetail::mixed_feasible(*code);
      if (!reach) { blacklist_.insert(key); n_aborted++; return -1; }
      auto me = std::make_unique<MixedEntry>();
      me->code = std::make_unique<MixedMethodCode>(*code, *reach, &vm_, nullptr);
      if (Xbyak::GetError()) {
        Xbyak::ClearError();
        blacklist_.insert(key);
        n_aborted++;
        return -1;
      }
      me->fn = me->code->entry_addr();
      jit_dump(std::format("method(obj,osr) {}", code->name), me->fn,
               me->code->getSize(), me->code->reg_map());
      it = mixed_.emplace(key, std::move(me)).first;
      n_mixed++;
    }
    MixedMethodCode* mc = it->second->code.get();
    void* osr = mc->osr_addr();
    if (!osr) return -1;  // no loop to re-enter

    int fsize = mc->frame_size();
    std::size_t base = vm_.frame_alloc(fsize);
    if (base == (std::size_t)-1) return -1;
    Value* frame = vm_.vstack.data() + base;
    for (int k = 0; k < code->n_regs; ++k) frame[k] = regs[k];

    using Fn = long (*)(void*, void*, void*, long);
    long r = ((Fn)osr)(frame, &vm_, &glb, target);
    n_osr++;
    if (r < 0) {                       // ran the function to completion
      out = frame[code->n_regs];
      vm_.frame_free(base);
      return VM::kBackedgeDone;
    }
    for (int k = 0; k < code->n_regs; ++k) regs[k] = frame[k];  // bailed
    vm_.frame_free(base);
    return r;
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
        me->code = std::make_unique<MixedMethodCode>(*code, *mreach, &vm_,
                                                     callee.obj);
        if (Xbyak::GetError()) {
          Xbyak::ClearError();
          blacklist_.insert(key);
          n_aborted++;
          return false;
        }
        me->fn = me->code->entry_addr();
        jit_dump(std::format("method(obj) {}", code->name), me->fn,
                 me->code->getSize(), me->code->reg_map());
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
      jit_dump(std::format("method(int) {}", code->name), cm->fn,
               cm->code->getSize());
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
  std::unordered_map<const void*, int> osr_counts_;
  std::unordered_set<const void*> osr_tried_;
  int osr_threshold_ = 200;
};

}  // namespace minpython
