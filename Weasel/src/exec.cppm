// Exec partition — the loop.
//
// One `std::vector<Value>` is the whole of the machine's data. A call does not
// allocate: the arguments are already on the stack, so the callee's frame simply
// declares that they are now its locals, pushes zeros for the locals it declared
// itself, and starts its operands above them.
//
//     ... caller's operands | arg0 arg1 | local2 local3 | callee's operands ...
//                           ^locals_base                ^stack_base
//
// A branch is three numbers copied out of the plan :validate left: move `keep`
// values down to `stack_base + height`, then set the program counter. It never
// looks for a label, because there are no labels here — `block`, `loop` and
// `end` produced no instruction at all.
export module weasel:exec;

import std;
import :common;
import :opcode;
import :types;
import :validate;
import :store;
import :dump;

export namespace weasel {

struct Frame {
  const Code* code = nullptr;
  Instance* inst = nullptr;
  MemInst* mem = nullptr;  // memory 0, resolved once per call
  u32 locals_base = 0;
  u32 stack_base = 0;
  u32 pc = 0;
  u32 func_addr = 0;
};

struct Machine {
  Store& store;
  std::vector<Value> stack;
  std::vector<Frame> frames;

  Trap trap = Trap::None;
  std::string trap_message;
  i32 exit_code = 0;

  u32 max_frames = 1024;
  u64 fuel = 0;      // 0 means no limit
  u64 steps = 0;
  bool trace = false;

  explicit Machine(Store& s) : store(s) { stack.reserve(1u << 16); }

  bool failed() const { return trap != Trap::None; }
  void fail(Trap t, std::string msg = {}) {
    if (trap == Trap::None) {
      trap = t;
      trap_message = std::move(msg);
    }
  }
  std::string trap_text() const {
    if (trap == Trap::None) return {};
    if (trap_message.empty()) return std::string(trap_name(trap));
    return std::format("{}: {}", trap_name(trap), trap_message);
  }

  // ---- the stack -----------------------------------------------------------

  void push(Value v) { stack.push_back(v); }
  Value pop() {
    Value v = stack.back();
    stack.pop_back();
    return v;
  }
  u32 pop_u32() { return pop().i32(); }
  u64 pop_u64() { return pop().i64(); }
  f32 pop_f32() { return pop().f32v(); }
  f64 pop_f64() { return pop().f64v(); }

  // ---- memory --------------------------------------------------------------

  bool bounds(const MemInst& mem, u64 addr, u64 size) {
    if (addr + size > mem.bytes.size()) {
      fail(Trap::OutOfBoundsMemory,
           std::format("{} bytes at {:#x}, memory is {} bytes", size, addr,
                       mem.bytes.size()));
      return false;
    }
    return true;
  }

  // Loads and stores are always little-endian, whatever the host is, and always
  // unaligned-tolerant: the alignment immediate is a hint the validator bounds
  // and the machine ignores.
  template <typename T>
  bool load_raw(const MemInst& mem, u64 addr, T& out) {
    if (!bounds(mem, addr, sizeof(T))) return false;
    T v{};
    std::memcpy(&v, mem.bytes.data() + addr, sizeof(T));
    if constexpr (std::endian::native == std::endian::big) v = std::byteswap(v);
    out = v;
    return true;
  }
  template <typename T>
  bool store_raw(MemInst& mem, u64 addr, T v) {
    if (!bounds(mem, addr, sizeof(T))) return false;
    if constexpr (std::endian::native == std::endian::big) v = std::byteswap(v);
    std::memcpy(mem.bytes.data() + addr, &v, sizeof(T));
    return true;
  }

  // ---- the numeric corners -------------------------------------------------

  // `min` and `max` are not the host's. The host returns the non-NaN operand
  // when one is NaN, and cannot tell -0 from +0; wasm demands the opposite of
  // both.
  template <typename F>
  static F wasm_min(F a, F b) {
    if (std::isnan(a) || std::isnan(b)) return std::numeric_limits<F>::quiet_NaN();
    if (a == b) return std::signbit(a) ? a : b;  // -0 is less than +0
    return a < b ? a : b;
  }
  template <typename F>
  static F wasm_max(F a, F b) {
    if (std::isnan(a) || std::isnan(b)) return std::numeric_limits<F>::quiet_NaN();
    if (a == b) return std::signbit(a) ? b : a;
    return a > b ? a : b;
  }

  // Truncation is checked in double, where every bound below is exact: a f32
  // widens to double without loss, so one set of comparisons covers both source
  // types. `2147483647.0` is representable; `2^63 - 1` is not, which is why the
  // 64-bit bounds are strict inequalities against the power of two.
  template <typename Int>
  bool trunc_checked(f64 x, Int& out) {
    if (std::isnan(x)) {
      fail(Trap::InvalidConversion);
      return false;
    }
    const f64 t = std::trunc(x);
    bool ok;
    if constexpr (std::is_same_v<Int, i32>) ok = t >= -2147483648.0 && t <= 2147483647.0;
    else if constexpr (std::is_same_v<Int, u32>) ok = t >= 0.0 && t <= 4294967295.0;
    else if constexpr (std::is_same_v<Int, i64>) ok = t >= -9223372036854775808.0 && t < 9223372036854775808.0;
    else ok = t >= 0.0 && t < 18446744073709551616.0;
    if (!ok) {
      fail(Trap::IntegerOverflow);
      return false;
    }
    out = static_cast<Int>(t);
    return true;
  }

  // The saturating form of the same thing, which is the whole of the
  // non-trapping conversions proposal: NaN becomes zero, everything out of range
  // becomes the nearest end.
  template <typename Int>
  static Int trunc_sat(f64 x) {
    if (std::isnan(x)) return 0;
    const f64 t = std::trunc(x);
    if constexpr (std::is_same_v<Int, i32>) {
      if (t <= -2147483648.0) return std::numeric_limits<i32>::min();
      if (t >= 2147483647.0) return std::numeric_limits<i32>::max();
    } else if constexpr (std::is_same_v<Int, u32>) {
      if (t <= 0.0) return 0;
      if (t >= 4294967295.0) return std::numeric_limits<u32>::max();
    } else if constexpr (std::is_same_v<Int, i64>) {
      if (t <= -9223372036854775808.0) return std::numeric_limits<i64>::min();
      if (t >= 9223372036854775808.0) return std::numeric_limits<i64>::max();
    } else {
      if (t <= 0.0) return 0;
      if (t >= 18446744073709551616.0) return std::numeric_limits<u64>::max();
    }
    return static_cast<Int>(t);
  }

  // ---- calls ---------------------------------------------------------------

  bool push_frame(u32 addr) {
    FuncInst& fi = store.funcs[addr];
    if (frames.size() >= max_frames) {
      fail(Trap::StackExhausted);
      return false;
    }
    const u32 nparams = static_cast<u32>(fi.type.params.size());
    Frame f;
    f.code = fi.code;
    f.inst = fi.instance;
    f.func_addr = addr;
    f.locals_base = static_cast<u32>(stack.size()) - nparams;
    for (std::size_t i = nparams; i < fi.code->locals.size(); ++i) push(Value{0});
    f.stack_base = static_cast<u32>(stack.size());
    f.pc = 0;
    f.mem = (fi.instance && !fi.instance->mems.empty())
                ? &store.mems[fi.instance->mems[0]]
                : nullptr;
    frames.push_back(f);
    return true;
  }

  void call_host(u32 addr) {
    FuncInst& fi = store.funcs[addr];
    const u32 nparams = static_cast<u32>(fi.type.params.size());
    const u32 nresults = static_cast<u32>(fi.type.results.size());
    std::vector<Value> args(stack.end() - nparams, stack.end());
    stack.resize(stack.size() - nparams);
    std::vector<Value> results(nresults);
    Caller caller;
    caller.store = &store;
    caller.instance = frames.empty() ? nullptr : frames.back().inst;
    fi.host(caller, args, results);
    if (caller.trap != Trap::None) {
      fail(caller.trap, caller.message);
      exit_code = caller.exit_code;
      return;
    }
    for (Value v : results) push(v);
  }

  // ---- the loop ------------------------------------------------------------

  void run();

  // Call a function by store address. The arguments must already match its
  // type; nothing here checks them, because everything that reaches this point
  // has been through :validate or is the embedder's own doing.
  bool invoke(u32 addr, std::span<const Value> args, std::vector<Value>& results) {
    trap = Trap::None;
    trap_message.clear();
    stack.clear();
    frames.clear();
    for (Value v : args) push(v);
    FuncInst& fi = store.funcs[addr];
    if (fi.is_host()) {
      call_host(addr);
    } else {
      if (!push_frame(addr)) return false;
      run();
    }
    if (failed()) return false;
    const u32 n = static_cast<u32>(fi.type.results.size());
    results.assign(stack.end() - n, stack.end());
    return true;
  }
};

}  // namespace weasel

namespace weasel {

void Machine::run() {
  Frame* f = &frames.back();
  const Code* code = f->code;
  MemInst* mem = f->mem;
  u32 pc = f->pc;

  const auto enter = [&](u32 addr) -> bool {
    f->pc = pc;
    if (!push_frame(addr)) return false;
    f = &frames.back();
    code = f->code;
    mem = f->mem;
    pc = 0;
    return true;
  };

  // Copy the values a branch carries down to where the target expects them.
  const auto take_branch = [&](const BrTarget& t) {
    const std::size_t dest = f->stack_base + t.height;
    const std::size_t top = stack.size();
    for (u32 i = 0; i < t.keep; ++i) stack[dest + i] = stack[top - t.keep + i];
    stack.resize(dest + t.keep);
    pc = t.pc;
  };

  for (;;) {
    if (fuel && ++steps > fuel) {
      fail(Trap::HostError, "out of fuel");
      return;
    }
    const Instr& in = code->instrs[pc];
    // The stack printed is the state *before* the instruction runs.
    if (trace) [[unlikely]] {
      std::print(std::cerr, "{:>4} {:<24} |", pc,
                 std::format("{}{}", op_name(in.op), planned_immediates(*code, in)));
      for (std::size_t i = f->stack_base; i < stack.size(); ++i)
        std::print(std::cerr, " {:#x}", stack[i].bits);
      std::println(std::cerr, "");
    }
    ++pc;

    switch (in.op) {
      // ---- control ---------------------------------------------------------
      case Op::Unreachable:
        fail(Trap::Unreachable);
        return;
      case Op::Nop:
        break;
      case Op::Jump:
        pc = in.a;
        break;
      case Op::IfFalse:
        if (pop_u32() == 0) pc = in.a;
        break;
      case Op::Br:
        take_branch(code->brs[in.a]);
        break;
      case Op::BrIf:
        if (pop_u32() != 0) take_branch(code->brs[in.a]);
        break;
      case Op::BrTable: {
        const u32 i = pop_u32();
        const u32 which = (i < in.b) ? i : in.b;  // past the end is the default
        take_branch(code->brs[in.a + which]);
        break;
      }
      case Op::Return: {
        const u32 n = code->n_results;
        const std::size_t base = f->locals_base;
        const std::size_t top = stack.size();
        for (u32 i = 0; i < n; ++i) stack[base + i] = stack[top - n + i];
        stack.resize(base + n);
        frames.pop_back();
        if (frames.empty()) return;
        f = &frames.back();
        code = f->code;
        mem = f->mem;
        pc = f->pc;
        break;
      }
      case Op::Call: {
        const u32 addr = f->inst->funcs[in.a];
        if (store.funcs[addr].is_host()) {
          call_host(addr);
          if (failed()) return;
        } else if (!enter(addr)) {
          return;
        }
        break;
      }
      case Op::CallIndirect: {
        const u32 i = pop_u32();
        TableInst& tab = store.tables[f->inst->tables[in.b]];
        if (i >= tab.elems.size()) {
          fail(Trap::OutOfBoundsTable, std::format("index {} in a table of {}", i,
                                                   tab.elems.size()));
          return;
        }
        const Value r = tab.elems[i];
        if (r.is_null()) {
          fail(Trap::UninitializedElement, std::format("table index {}", i));
          return;
        }
        const u32 addr = r.ref_addr();
        if (store.funcs[addr].type != f->inst->module->types[in.a]) {
          fail(Trap::IndirectCallTypeMismatch, std::format("table index {}", i));
          return;
        }
        if (store.funcs[addr].is_host()) {
          call_host(addr);
          if (failed()) return;
        } else if (!enter(addr)) {
          return;
        }
        break;
      }

      // ---- parametric and variable ----------------------------------------
      case Op::Drop:
        stack.pop_back();
        break;
      case Op::Select: {
        const u32 c = pop_u32();
        const Value b = pop();
        const Value a = pop();
        push(c ? a : b);
        break;
      }
      case Op::LocalGet:
        push(stack[f->locals_base + in.a]);
        break;
      case Op::LocalSet:
        stack[f->locals_base + in.a] = pop();
        break;
      case Op::LocalTee:
        stack[f->locals_base + in.a] = stack.back();
        break;
      case Op::GlobalGet:
        push(store.globals[f->inst->globals[in.a]].value);
        break;
      case Op::GlobalSet:
        store.globals[f->inst->globals[in.a]].value = pop();
        break;

      // ---- references ------------------------------------------------------
      case Op::RefNull:
        push(Value::null_ref());
        break;
      case Op::RefIsNull:
        push(Value::of_i32(pop().is_null() ? 1 : 0));
        break;
      case Op::RefFunc:
        push(Value::of_ref(f->inst->funcs[in.a]));
        break;

      // ---- tables ----------------------------------------------------------
      case Op::TableGet: {
        TableInst& tab = store.tables[f->inst->tables[in.a]];
        const u32 i = pop_u32();
        if (i >= tab.elems.size()) { fail(Trap::OutOfBoundsTable); return; }
        push(tab.elems[i]);
        break;
      }
      case Op::TableSet: {
        TableInst& tab = store.tables[f->inst->tables[in.a]];
        const Value v = pop();
        const u32 i = pop_u32();
        if (i >= tab.elems.size()) { fail(Trap::OutOfBoundsTable); return; }
        tab.elems[i] = v;
        break;
      }
      case Op::TableSize:
        push(Value::of_i32(
            static_cast<u32>(store.tables[f->inst->tables[in.a]].elems.size())));
        break;
      case Op::TableGrow: {
        TableInst& tab = store.tables[f->inst->tables[in.a]];
        const u32 delta = pop_u32();
        const Value fill = pop();
        push(Value::of_i32(static_cast<u32>(tab.grow(delta, fill))));
        break;
      }
      case Op::TableFill: {
        TableInst& tab = store.tables[f->inst->tables[in.a]];
        const u32 n = pop_u32();
        const Value v = pop();
        const u32 d = pop_u32();
        if (u64{d} + n > tab.elems.size()) { fail(Trap::OutOfBoundsTable); return; }
        for (u32 i = 0; i < n; ++i) tab.elems[d + i] = v;
        break;
      }
      case Op::TableCopy: {
        TableInst& dst = store.tables[f->inst->tables[in.a]];
        TableInst& src = store.tables[f->inst->tables[in.b]];
        const u32 n = pop_u32();
        const u32 s = pop_u32();
        const u32 d = pop_u32();
        if (u64{s} + n > src.elems.size() || u64{d} + n > dst.elems.size()) {
          fail(Trap::OutOfBoundsTable);
          return;
        }
        if (d <= s)
          for (u32 i = 0; i < n; ++i) dst.elems[d + i] = src.elems[s + i];
        else
          for (u32 i = n; i-- > 0;) dst.elems[d + i] = src.elems[s + i];
        break;
      }
      case Op::TableInit: {
        TableInst& dst = store.tables[f->inst->tables[in.b]];
        const auto& seg = f->inst->elems[in.a];
        const u32 n = pop_u32();
        const u32 s = pop_u32();
        const u32 d = pop_u32();
        if (u64{s} + n > seg.size() || u64{d} + n > dst.elems.size()) {
          fail(Trap::OutOfBoundsTable);
          return;
        }
        for (u32 i = 0; i < n; ++i) dst.elems[d + i] = seg[s + i];
        break;
      }
      case Op::ElemDrop:
        f->inst->elems[in.a].clear();
        f->inst->elem_dropped[in.a] = true;
        break;

      // ---- memory ----------------------------------------------------------
      case Op::MemorySize:
        push(Value::of_i32(mem->pages()));
        break;
      case Op::MemoryGrow: {
        const u32 delta = pop_u32();
        push(Value::of_i32(static_cast<u32>(mem->grow(delta))));
        break;
      }
      case Op::MemoryFill: {
        const u32 n = pop_u32();
        const u8 v = static_cast<u8>(pop_u32());
        const u32 d = pop_u32();
        if (!bounds(*mem, d, n)) return;
        std::memset(mem->bytes.data() + d, v, n);
        break;
      }
      case Op::MemoryCopy: {
        const u32 n = pop_u32();
        const u32 s = pop_u32();
        const u32 d = pop_u32();
        if (!bounds(*mem, s, n) || !bounds(*mem, d, n)) return;
        std::memmove(mem->bytes.data() + d, mem->bytes.data() + s, n);
        break;
      }
      case Op::MemoryInit: {
        const auto& seg = f->inst->datas[in.a];
        const u32 n = pop_u32();
        const u32 s = pop_u32();
        const u32 d = pop_u32();
        if (u64{s} + n > seg.size()) {
          fail(Trap::OutOfBoundsData, std::format("{} bytes at {} of a {} byte segment",
                                                  n, s, seg.size()));
          return;
        }
        if (!bounds(*mem, d, n)) return;
        if (n) std::memcpy(mem->bytes.data() + d, seg.data() + s, n);
        break;
      }
      case Op::DataDrop:
        f->inst->datas[in.a].clear();
        f->inst->data_dropped[in.a] = true;
        break;

#define WEASEL_LOAD(OP, CTYPE, PUSH)                             \
  case Op::OP: {                                                 \
    const u64 addr = u64{pop_u32()} + in.b;                      \
    CTYPE v{};                                                   \
    if (!load_raw(*mem, addr, v)) return;                        \
    push(PUSH);                                                  \
    break;                                                       \
  }
      WEASEL_LOAD(I32Load, u32, Value::of_i32(v))
      WEASEL_LOAD(I64Load, u64, Value::of_i64(v))
      WEASEL_LOAD(F32Load, u32, Value::of_i32(v))
      WEASEL_LOAD(F64Load, u64, Value::of_i64(v))
      WEASEL_LOAD(I32Load8S, u8, Value::of_i32(static_cast<u32>(sext(v, 8))))
      WEASEL_LOAD(I32Load8U, u8, Value::of_i32(v))
      WEASEL_LOAD(I32Load16S, u16, Value::of_i32(static_cast<u32>(sext(v, 16))))
      WEASEL_LOAD(I32Load16U, u16, Value::of_i32(v))
      WEASEL_LOAD(I64Load8S, u8, Value::of_i64(static_cast<u64>(sext(v, 8))))
      WEASEL_LOAD(I64Load8U, u8, Value::of_i64(v))
      WEASEL_LOAD(I64Load16S, u16, Value::of_i64(static_cast<u64>(sext(v, 16))))
      WEASEL_LOAD(I64Load16U, u16, Value::of_i64(v))
      WEASEL_LOAD(I64Load32S, u32, Value::of_i64(static_cast<u64>(sext(v, 32))))
      WEASEL_LOAD(I64Load32U, u32, Value::of_i64(v))
#undef WEASEL_LOAD

#define WEASEL_STORE(OP, CTYPE, GET)                             \
  case Op::OP: {                                                 \
    const CTYPE v = static_cast<CTYPE>(GET);                     \
    const u64 addr = u64{pop_u32()} + in.b;                      \
    if (!store_raw(*mem, addr, v)) return;                       \
    break;                                                       \
  }
      WEASEL_STORE(I32Store, u32, pop_u32())
      WEASEL_STORE(I64Store, u64, pop_u64())
      WEASEL_STORE(F32Store, u32, pop_u32())
      WEASEL_STORE(F64Store, u64, pop_u64())
      WEASEL_STORE(I32Store8, u8, pop_u32())
      WEASEL_STORE(I32Store16, u16, pop_u32())
      WEASEL_STORE(I64Store8, u8, pop_u64())
      WEASEL_STORE(I64Store16, u16, pop_u64())
      WEASEL_STORE(I64Store32, u32, pop_u64())
#undef WEASEL_STORE

      // ---- constants -------------------------------------------------------
      case Op::I32Const: case Op::I64Const: case Op::F32Const: case Op::F64Const:
        push(Value{in.imm});
        break;

      // ---- i32 -------------------------------------------------------------
      case Op::I32Eqz: push(Value::of_i32(pop_u32() == 0)); break;
#define WEASEL_I32CMP(OP, EXPR)                                  \
  case Op::OP: {                                                 \
    const u32 b = pop_u32();                                     \
    const u32 a = pop_u32();                                     \
    (void)a; (void)b;                                            \
    push(Value::of_i32((EXPR) ? 1 : 0));                         \
    break;                                                       \
  }
      WEASEL_I32CMP(I32Eq, a == b)
      WEASEL_I32CMP(I32Ne, a != b)
      WEASEL_I32CMP(I32LtS, static_cast<i32>(a) < static_cast<i32>(b))
      WEASEL_I32CMP(I32LtU, a < b)
      WEASEL_I32CMP(I32GtS, static_cast<i32>(a) > static_cast<i32>(b))
      WEASEL_I32CMP(I32GtU, a > b)
      WEASEL_I32CMP(I32LeS, static_cast<i32>(a) <= static_cast<i32>(b))
      WEASEL_I32CMP(I32LeU, a <= b)
      WEASEL_I32CMP(I32GeS, static_cast<i32>(a) >= static_cast<i32>(b))
      WEASEL_I32CMP(I32GeU, a >= b)
#undef WEASEL_I32CMP

      case Op::I32Clz: push(Value::of_i32(static_cast<u32>(std::countl_zero(pop_u32())))); break;
      case Op::I32Ctz: push(Value::of_i32(static_cast<u32>(std::countr_zero(pop_u32())))); break;
      case Op::I32Popcnt: push(Value::of_i32(static_cast<u32>(std::popcount(pop_u32())))); break;

#define WEASEL_I32BIN(OP, EXPR)                                  \
  case Op::OP: {                                                 \
    const u32 b = pop_u32();                                     \
    const u32 a = pop_u32();                                     \
    (void)a; (void)b;                                            \
    push(Value::of_i32(EXPR));                                   \
    break;                                                       \
  }
      WEASEL_I32BIN(I32Add, a + b)
      WEASEL_I32BIN(I32Sub, a - b)
      WEASEL_I32BIN(I32Mul, a * b)
      WEASEL_I32BIN(I32And, a & b)
      WEASEL_I32BIN(I32Or, a | b)
      WEASEL_I32BIN(I32Xor, a ^ b)
      WEASEL_I32BIN(I32Shl, a << (b & 31))
      WEASEL_I32BIN(I32ShrU, a >> (b & 31))
      WEASEL_I32BIN(I32ShrS, static_cast<u32>(static_cast<i32>(a) >> (b & 31)))
      WEASEL_I32BIN(I32Rotl, std::rotl(a, static_cast<int>(b & 31)))
      WEASEL_I32BIN(I32Rotr, std::rotr(a, static_cast<int>(b & 31)))
#undef WEASEL_I32BIN

      case Op::I32DivS: {
        const i32 b = static_cast<i32>(pop_u32());
        const i32 a = static_cast<i32>(pop_u32());
        if (b == 0) { fail(Trap::DivideByZero); return; }
        if (a == std::numeric_limits<i32>::min() && b == -1) {
          fail(Trap::IntegerOverflow);
          return;
        }
        push(Value::of_i32(static_cast<u32>(a / b)));
        break;
      }
      case Op::I32DivU: {
        const u32 b = pop_u32();
        const u32 a = pop_u32();
        if (b == 0) { fail(Trap::DivideByZero); return; }
        push(Value::of_i32(a / b));
        break;
      }
      case Op::I32RemS: {
        const i32 b = static_cast<i32>(pop_u32());
        const i32 a = static_cast<i32>(pop_u32());
        if (b == 0) { fail(Trap::DivideByZero); return; }
        // The one case C++ leaves undefined and wasm defines: the remainder is
        // zero, even though the quotient would overflow.
        if (b == -1) { push(Value::of_i32(0)); break; }
        push(Value::of_i32(static_cast<u32>(a % b)));
        break;
      }
      case Op::I32RemU: {
        const u32 b = pop_u32();
        const u32 a = pop_u32();
        if (b == 0) { fail(Trap::DivideByZero); return; }
        push(Value::of_i32(a % b));
        break;
      }

      // ---- i64 -------------------------------------------------------------
      case Op::I64Eqz: push(Value::of_i32(pop_u64() == 0)); break;
#define WEASEL_I64CMP(OP, EXPR)                                  \
  case Op::OP: {                                                 \
    const u64 b = pop_u64();                                     \
    const u64 a = pop_u64();                                     \
    (void)a; (void)b;                                            \
    push(Value::of_i32((EXPR) ? 1 : 0));                         \
    break;                                                       \
  }
      WEASEL_I64CMP(I64Eq, a == b)
      WEASEL_I64CMP(I64Ne, a != b)
      WEASEL_I64CMP(I64LtS, static_cast<i64>(a) < static_cast<i64>(b))
      WEASEL_I64CMP(I64LtU, a < b)
      WEASEL_I64CMP(I64GtS, static_cast<i64>(a) > static_cast<i64>(b))
      WEASEL_I64CMP(I64GtU, a > b)
      WEASEL_I64CMP(I64LeS, static_cast<i64>(a) <= static_cast<i64>(b))
      WEASEL_I64CMP(I64LeU, a <= b)
      WEASEL_I64CMP(I64GeS, static_cast<i64>(a) >= static_cast<i64>(b))
      WEASEL_I64CMP(I64GeU, a >= b)
#undef WEASEL_I64CMP

      case Op::I64Clz: push(Value::of_i64(static_cast<u64>(std::countl_zero(pop_u64())))); break;
      case Op::I64Ctz: push(Value::of_i64(static_cast<u64>(std::countr_zero(pop_u64())))); break;
      case Op::I64Popcnt: push(Value::of_i64(static_cast<u64>(std::popcount(pop_u64())))); break;

#define WEASEL_I64BIN(OP, EXPR)                                  \
  case Op::OP: {                                                 \
    const u64 b = pop_u64();                                     \
    const u64 a = pop_u64();                                     \
    (void)a; (void)b;                                            \
    push(Value::of_i64(EXPR));                                   \
    break;                                                       \
  }
      WEASEL_I64BIN(I64Add, a + b)
      WEASEL_I64BIN(I64Sub, a - b)
      WEASEL_I64BIN(I64Mul, a * b)
      WEASEL_I64BIN(I64And, a & b)
      WEASEL_I64BIN(I64Or, a | b)
      WEASEL_I64BIN(I64Xor, a ^ b)
      WEASEL_I64BIN(I64Shl, a << (b & 63))
      WEASEL_I64BIN(I64ShrU, a >> (b & 63))
      WEASEL_I64BIN(I64ShrS, static_cast<u64>(static_cast<i64>(a) >> (b & 63)))
      WEASEL_I64BIN(I64Rotl, std::rotl(a, static_cast<int>(b & 63)))
      WEASEL_I64BIN(I64Rotr, std::rotr(a, static_cast<int>(b & 63)))
#undef WEASEL_I64BIN

      case Op::I64DivS: {
        const i64 b = static_cast<i64>(pop_u64());
        const i64 a = static_cast<i64>(pop_u64());
        if (b == 0) { fail(Trap::DivideByZero); return; }
        if (a == std::numeric_limits<i64>::min() && b == -1) {
          fail(Trap::IntegerOverflow);
          return;
        }
        push(Value::of_i64(static_cast<u64>(a / b)));
        break;
      }
      case Op::I64DivU: {
        const u64 b = pop_u64();
        const u64 a = pop_u64();
        if (b == 0) { fail(Trap::DivideByZero); return; }
        push(Value::of_i64(a / b));
        break;
      }
      case Op::I64RemS: {
        const i64 b = static_cast<i64>(pop_u64());
        const i64 a = static_cast<i64>(pop_u64());
        if (b == 0) { fail(Trap::DivideByZero); return; }
        if (b == -1) { push(Value::of_i64(0)); break; }
        push(Value::of_i64(static_cast<u64>(a % b)));
        break;
      }
      case Op::I64RemU: {
        const u64 b = pop_u64();
        const u64 a = pop_u64();
        if (b == 0) { fail(Trap::DivideByZero); return; }
        push(Value::of_i64(a % b));
        break;
      }

      // ---- floats ----------------------------------------------------------
#define WEASEL_FCMP(OP, TY, POP, EXPR)                           \
  case Op::OP: {                                                 \
    const TY b = POP();                                          \
    const TY a = POP();                                          \
    (void)a; (void)b;                                            \
    push(Value::of_i32((EXPR) ? 1 : 0));                         \
    break;                                                       \
  }
      WEASEL_FCMP(F32Eq, f32, pop_f32, a == b)
      WEASEL_FCMP(F32Ne, f32, pop_f32, a != b)
      WEASEL_FCMP(F32Lt, f32, pop_f32, a < b)
      WEASEL_FCMP(F32Gt, f32, pop_f32, a > b)
      WEASEL_FCMP(F32Le, f32, pop_f32, a <= b)
      WEASEL_FCMP(F32Ge, f32, pop_f32, a >= b)
      WEASEL_FCMP(F64Eq, f64, pop_f64, a == b)
      WEASEL_FCMP(F64Ne, f64, pop_f64, a != b)
      WEASEL_FCMP(F64Lt, f64, pop_f64, a < b)
      WEASEL_FCMP(F64Gt, f64, pop_f64, a > b)
      WEASEL_FCMP(F64Le, f64, pop_f64, a <= b)
      WEASEL_FCMP(F64Ge, f64, pop_f64, a >= b)
#undef WEASEL_FCMP

#define WEASEL_FUN(OP, TY, POP, MAKE, EXPR)                      \
  case Op::OP: {                                                 \
    const TY a = POP();                                          \
    (void)a;                                                     \
    push(MAKE(EXPR));                                            \
    break;                                                       \
  }
      // abs, neg and copysign are bit operations, not arithmetic: they must not
      // quieten a signalling NaN or lose a payload, so they are written on bits.
      case Op::F32Abs: push(Value::of_i32(pop_u32() & 0x7fffffffu)); break;
      case Op::F32Neg: push(Value::of_i32(pop_u32() ^ 0x80000000u)); break;
      case Op::F64Abs: push(Value::of_i64(pop_u64() & 0x7fffffffffffffffull)); break;
      case Op::F64Neg: push(Value::of_i64(pop_u64() ^ 0x8000000000000000ull)); break;
      WEASEL_FUN(F32Ceil, f32, pop_f32, Value::of_f32, std::ceil(a))
      WEASEL_FUN(F32Floor, f32, pop_f32, Value::of_f32, std::floor(a))
      WEASEL_FUN(F32Trunc, f32, pop_f32, Value::of_f32, std::trunc(a))
      WEASEL_FUN(F32Nearest, f32, pop_f32, Value::of_f32, std::nearbyint(a))
      WEASEL_FUN(F32Sqrt, f32, pop_f32, Value::of_f32, std::sqrt(a))
      WEASEL_FUN(F64Ceil, f64, pop_f64, Value::of_f64, std::ceil(a))
      WEASEL_FUN(F64Floor, f64, pop_f64, Value::of_f64, std::floor(a))
      WEASEL_FUN(F64Trunc, f64, pop_f64, Value::of_f64, std::trunc(a))
      WEASEL_FUN(F64Nearest, f64, pop_f64, Value::of_f64, std::nearbyint(a))
      WEASEL_FUN(F64Sqrt, f64, pop_f64, Value::of_f64, std::sqrt(a))
#undef WEASEL_FUN

#define WEASEL_FBIN(OP, TY, POP, MAKE, EXPR)                     \
  case Op::OP: {                                                 \
    const TY b = POP();                                          \
    const TY a = POP();                                          \
    (void)a; (void)b;                                            \
    push(MAKE(EXPR));                                            \
    break;                                                       \
  }
      WEASEL_FBIN(F32Add, f32, pop_f32, Value::of_f32, a + b)
      WEASEL_FBIN(F32Sub, f32, pop_f32, Value::of_f32, a - b)
      WEASEL_FBIN(F32Mul, f32, pop_f32, Value::of_f32, a * b)
      WEASEL_FBIN(F32Div, f32, pop_f32, Value::of_f32, a / b)
      WEASEL_FBIN(F32Min, f32, pop_f32, Value::of_f32, wasm_min(a, b))
      WEASEL_FBIN(F32Max, f32, pop_f32, Value::of_f32, wasm_max(a, b))
      WEASEL_FBIN(F32Copysign, f32, pop_f32, Value::of_f32, std::copysign(a, b))
      WEASEL_FBIN(F64Add, f64, pop_f64, Value::of_f64, a + b)
      WEASEL_FBIN(F64Sub, f64, pop_f64, Value::of_f64, a - b)
      WEASEL_FBIN(F64Mul, f64, pop_f64, Value::of_f64, a * b)
      WEASEL_FBIN(F64Div, f64, pop_f64, Value::of_f64, a / b)
      WEASEL_FBIN(F64Min, f64, pop_f64, Value::of_f64, wasm_min(a, b))
      WEASEL_FBIN(F64Max, f64, pop_f64, Value::of_f64, wasm_max(a, b))
      WEASEL_FBIN(F64Copysign, f64, pop_f64, Value::of_f64, std::copysign(a, b))
#undef WEASEL_FBIN

      // ---- conversions -----------------------------------------------------
      case Op::I32WrapI64: push(Value::of_i32(static_cast<u32>(pop_u64()))); break;
      case Op::I64ExtendI32S:
        push(Value::of_i64(static_cast<u64>(static_cast<i64>(static_cast<i32>(pop_u32())))));
        break;
      case Op::I64ExtendI32U: push(Value::of_i64(pop_u32())); break;
      case Op::I32Extend8S: push(Value::of_i32(static_cast<u32>(sext(pop_u32(), 8)))); break;
      case Op::I32Extend16S: push(Value::of_i32(static_cast<u32>(sext(pop_u32(), 16)))); break;
      case Op::I64Extend8S: push(Value::of_i64(static_cast<u64>(sext(pop_u64(), 8)))); break;
      case Op::I64Extend16S: push(Value::of_i64(static_cast<u64>(sext(pop_u64(), 16)))); break;
      case Op::I64Extend32S: push(Value::of_i64(static_cast<u64>(sext(pop_u64(), 32)))); break;

#define WEASEL_TRUNC(OP, SRC, POP, INT, MAKE)                    \
  case Op::OP: {                                                 \
    const SRC a = POP();                                         \
    INT out{};                                                   \
    if (!trunc_checked<INT>(static_cast<f64>(a), out)) return;    \
    push(MAKE(static_cast<std::make_unsigned_t<INT>>(out)));      \
    break;                                                       \
  }
      WEASEL_TRUNC(I32TruncF32S, f32, pop_f32, i32, Value::of_i32)
      WEASEL_TRUNC(I32TruncF32U, f32, pop_f32, u32, Value::of_i32)
      WEASEL_TRUNC(I32TruncF64S, f64, pop_f64, i32, Value::of_i32)
      WEASEL_TRUNC(I32TruncF64U, f64, pop_f64, u32, Value::of_i32)
      WEASEL_TRUNC(I64TruncF32S, f32, pop_f32, i64, Value::of_i64)
      WEASEL_TRUNC(I64TruncF32U, f32, pop_f32, u64, Value::of_i64)
      WEASEL_TRUNC(I64TruncF64S, f64, pop_f64, i64, Value::of_i64)
      WEASEL_TRUNC(I64TruncF64U, f64, pop_f64, u64, Value::of_i64)
#undef WEASEL_TRUNC

#define WEASEL_TRUNCSAT(OP, SRC, POP, INT, MAKE)                 \
  case Op::OP:                                                   \
    push(MAKE(static_cast<std::make_unsigned_t<INT>>(            \
        trunc_sat<INT>(static_cast<f64>(POP())))));              \
    break;
      WEASEL_TRUNCSAT(I32TruncSatF32S, f32, pop_f32, i32, Value::of_i32)
      WEASEL_TRUNCSAT(I32TruncSatF32U, f32, pop_f32, u32, Value::of_i32)
      WEASEL_TRUNCSAT(I32TruncSatF64S, f64, pop_f64, i32, Value::of_i32)
      WEASEL_TRUNCSAT(I32TruncSatF64U, f64, pop_f64, u32, Value::of_i32)
      WEASEL_TRUNCSAT(I64TruncSatF32S, f32, pop_f32, i64, Value::of_i64)
      WEASEL_TRUNCSAT(I64TruncSatF32U, f32, pop_f32, u64, Value::of_i64)
      WEASEL_TRUNCSAT(I64TruncSatF64S, f64, pop_f64, i64, Value::of_i64)
      WEASEL_TRUNCSAT(I64TruncSatF64U, f64, pop_f64, u64, Value::of_i64)
#undef WEASEL_TRUNCSAT

      case Op::F32ConvertI32S: push(Value::of_f32(static_cast<f32>(static_cast<i32>(pop_u32())))); break;
      case Op::F32ConvertI32U: push(Value::of_f32(static_cast<f32>(pop_u32()))); break;
      case Op::F32ConvertI64S: push(Value::of_f32(static_cast<f32>(static_cast<i64>(pop_u64())))); break;
      case Op::F32ConvertI64U: push(Value::of_f32(static_cast<f32>(pop_u64()))); break;
      case Op::F64ConvertI32S: push(Value::of_f64(static_cast<f64>(static_cast<i32>(pop_u32())))); break;
      case Op::F64ConvertI32U: push(Value::of_f64(static_cast<f64>(pop_u32()))); break;
      case Op::F64ConvertI64S: push(Value::of_f64(static_cast<f64>(static_cast<i64>(pop_u64())))); break;
      case Op::F64ConvertI64U: push(Value::of_f64(static_cast<f64>(pop_u64()))); break;
      case Op::F32DemoteF64: push(Value::of_f32(static_cast<f32>(pop_f64()))); break;
      case Op::F64PromoteF32: push(Value::of_f64(static_cast<f64>(pop_f32()))); break;

      // Reinterpretation is the identity here, because a Value is bits already.
      // The instruction exists in the language, and nowhere in the machine.
      case Op::I32ReinterpretF32: case Op::I64ReinterpretF64:
      case Op::F32ReinterpretI32: case Op::F64ReinterpretI64:
        break;

      default:
        fail(Trap::HostError, std::format("no rule for `{}`", op_name(in.op)));
        return;
    }
    if (failed()) return;
  }
}

}  // namespace weasel
