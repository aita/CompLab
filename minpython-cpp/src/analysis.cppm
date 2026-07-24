// Analysis partition — the CodeObject analyses the method JIT compiles from.
//
// Split out of :method because it is pure: dataflow over bytecode, no xbyak and
// no code generation. Reachability, def/use, live ranges, the feasibility gates,
// and the must-analyses (which slots are provably int, what tag the frame holds)
// all live here. This is the layer an SSA/LICM optimiser would extend.
module;

export module minpython:analysis;

import std;
import :value;
import :bytecode;

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
// Which slots definitely hold an Int rather than a Bool. The integer compiler
// keeps values as raw int64 with no tag at all, so its result is handed back as
// an Int -- which is wrong for `return a < b`, where the interpreter says True.
// Parameters count as Int because the entry guard insists on it.
inline bool int_result_only(const CodeObject& code,
                            const std::unordered_set<int>& reach, int argc) {
  std::unordered_set<int> universe;               // optimistic: shrink to fit
  for (int r = 0; r < code.n_regs; ++r) universe.insert(r);
  std::unordered_map<int, std::unordered_set<int>> in;
  for (int pc : reach) in[pc] = universe;
  std::unordered_set<int> entry;
  for (int p = 0; p < argc; ++p) entry.insert(p);
  in[0] = entry;

  auto transfer = [&](const std::unordered_set<int>& s, const Instr& ins) {
    std::unordered_set<int> o = s;
    Op op = ins.op;
    if (op == Op::LoadConst) {
      if (code.consts[ins.b].tag == Tag::Int) o.insert(ins.a);
      else o.erase(ins.a);
    } else if (op == Op::Move) {
      if (s.count(ins.b)) o.insert(ins.a); else o.erase(ins.a);
    } else if (is_cmpop(op) || op == Op::Not) {
      o.erase(ins.a);                 // a bool, by definition
    } else if (bool_closed(op)) {
      if (s.count(ins.b) && s.count(ins.c)) o.insert(ins.a);
      else o.erase(ins.a);            // bool & bool is a bool
    } else if (is_binop(op) || op == Op::Neg || op == Op::Invert ||
               op == Op::Call) {
      o.insert(ins.a);                // +, -, *, shifts and our own result
    }
    return o;
  };

  bool changed = true;
  std::vector<int> asc(reach.begin(), reach.end());
  std::sort(asc.begin(), asc.end());
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
  for (int pc : reach)
    if (code.code[pc].op == Op::Return && !in[pc].count(code.code[pc].a))
      return false;
  return true;
}

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
  if (!int_result_only(code, reach, (int)code.params.size()))
    return std::nullopt;    // could return a bool, which this tier cannot say
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
      if (!sure) {
        s.erase(ins.a);
      } else if (is_cmpop(op)) {
        set(Tag::Bool);
      } else if (!bool_closed(op)) {
        set(Tag::Int);
      } else {
        // bool & bool is a bool, so only knowing both operand tags settles it.
        auto b = s.find(ins.b), c = s.find(ins.c);
        if (b == s.end() || c == s.end()) s.erase(ins.a);
        else set(b->second == (int)Tag::Bool && c->second == (int)Tag::Bool
                     ? Tag::Bool : Tag::Int);
      }
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
}  // namespace minpython
