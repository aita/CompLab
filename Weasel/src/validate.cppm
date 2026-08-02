// Validate partition — the type checker, and the plan it leaves behind.
//
// This is the claim the whole runtime is arranged around: **validation is not a
// safety pass bolted on before execution; validation is the compiler.** Walking
// a function to check its types requires knowing, at every instruction, how deep
// the operand stack is and what each label expects. Those are exactly the two
// numbers a branch needs at run time, and the position a branch jumps to falls
// out of the same walk. So the checker writes them down as it goes, and what it
// hands back is not a verdict but a program:
//
//   * `Code::instrs` — a flat array. `block`, `loop`, `else` and `end` are gone;
//     structured control flow does not exist at run time, only positions.
//   * `Code::brs` — one entry per branch *target*, holding where to jump, how
//     many values to carry across, and what the stack height there is. `br`,
//     `br_if` and every arm of `br_table` are an index into this.
//
// The polymorphic-stack rule for unreachable code is the one part of the
// algorithm that is not obvious, and it is in `pop_opd` below.
export module weasel:validate;

import std;
import :common;
import :opcode;
import :types;

export namespace weasel {

// A branch target, as the checker found it. `keep` values are carried from the
// top of the stack down to `height`, and then control moves to `pc`.
struct BrTarget {
  u32 pc = 0;
  u32 keep = 0;
  u32 height = 0;
  bool operator==(const BrTarget&) const = default;
};

// A planned instruction. The fields mean what they meant in `Inst`, except for
// the control instructions, which now hold positions:
//
//   Br / BrIf     a = index into `brs`
//   BrTable       a = the first of b+1 entries in `brs`; the last is the default
//   IfFalse       a = where to go when the condition is zero
//   Jump          a = where to go
struct Instr {
  Op op = Op::Nop;
  u32 a = 0;
  u32 b = 0;
  u64 imm = 0;
  bool operator==(const Instr&) const = default;
};

struct Code {
  std::vector<Instr> instrs;
  std::vector<BrTarget> brs;
  std::vector<ValType> locals;  // parameters first, then declared locals
  u32 n_params = 0;
  u32 n_results = 0;
  u32 max_stack = 0;  // an upper bound on the operand stack this function uses
};

}  // namespace weasel

namespace weasel {

// The sentinel the spec calls `Unknown`: the type of a value that is on the
// stack only because the code is unreachable, and so may be read as anything.
// 0x00 is not a value type byte, so it cannot collide with a real one.
constexpr ValType kUnknown = static_cast<ValType>(0x00);

struct Ctrl {
  Op op = Op::Block;                 // Block, Loop, If, Else, or Func for the outermost
  std::vector<ValType> in;           // what the label's block type takes
  std::vector<ValType> out;          // what it gives
  u32 height = 0;                    // operand stack height where the label was pushed
  bool unreachable = false;
  u32 loop_pc = 0;                   // where a `loop` label branches back to
  std::vector<u32> br_patches;       // brs entries waiting for this label's end
  std::vector<u32> pc_patches;       // instrs whose `a` is this label's end
  u32 if_false = 0xffffffff;         // the IfFalse instruction, until `else` or `end`

  // A branch to this label carries the loop's parameters or the block's results.
  const std::vector<ValType>& label_types() const { return op == Op::Loop ? in : out; }
};

// The signature of every instruction whose types do not depend on the module.
// `i I f F` are i32, i64, f32, f64; what is before the colon is popped, right to
// left, and what is after it is pushed.
std::string_view simple_sig(Op op) {
  switch (op) {
    case Op::I32Eqz: return "i:i";
    case Op::I32Eq: case Op::I32Ne: case Op::I32LtS: case Op::I32LtU:
    case Op::I32GtS: case Op::I32GtU: case Op::I32LeS: case Op::I32LeU:
    case Op::I32GeS: case Op::I32GeU: return "ii:i";
    case Op::I64Eqz: return "I:i";
    case Op::I64Eq: case Op::I64Ne: case Op::I64LtS: case Op::I64LtU:
    case Op::I64GtS: case Op::I64GtU: case Op::I64LeS: case Op::I64LeU:
    case Op::I64GeS: case Op::I64GeU: return "II:i";
    case Op::F32Eq: case Op::F32Ne: case Op::F32Lt: case Op::F32Gt:
    case Op::F32Le: case Op::F32Ge: return "ff:i";
    case Op::F64Eq: case Op::F64Ne: case Op::F64Lt: case Op::F64Gt:
    case Op::F64Le: case Op::F64Ge: return "FF:i";
    case Op::I32Clz: case Op::I32Ctz: case Op::I32Popcnt:
    case Op::I32Extend8S: case Op::I32Extend16S: return "i:i";
    case Op::I32Add: case Op::I32Sub: case Op::I32Mul: case Op::I32DivS:
    case Op::I32DivU: case Op::I32RemS: case Op::I32RemU: case Op::I32And:
    case Op::I32Or: case Op::I32Xor: case Op::I32Shl: case Op::I32ShrS:
    case Op::I32ShrU: case Op::I32Rotl: case Op::I32Rotr: return "ii:i";
    case Op::I64Clz: case Op::I64Ctz: case Op::I64Popcnt:
    case Op::I64Extend8S: case Op::I64Extend16S: case Op::I64Extend32S: return "I:I";
    case Op::I64Add: case Op::I64Sub: case Op::I64Mul: case Op::I64DivS:
    case Op::I64DivU: case Op::I64RemS: case Op::I64RemU: case Op::I64And:
    case Op::I64Or: case Op::I64Xor: case Op::I64Shl: case Op::I64ShrS:
    case Op::I64ShrU: case Op::I64Rotl: case Op::I64Rotr: return "II:I";
    case Op::F32Abs: case Op::F32Neg: case Op::F32Ceil: case Op::F32Floor:
    case Op::F32Trunc: case Op::F32Nearest: case Op::F32Sqrt: return "f:f";
    case Op::F32Add: case Op::F32Sub: case Op::F32Mul: case Op::F32Div:
    case Op::F32Min: case Op::F32Max: case Op::F32Copysign: return "ff:f";
    case Op::F64Abs: case Op::F64Neg: case Op::F64Ceil: case Op::F64Floor:
    case Op::F64Trunc: case Op::F64Nearest: case Op::F64Sqrt: return "F:F";
    case Op::F64Add: case Op::F64Sub: case Op::F64Mul: case Op::F64Div:
    case Op::F64Min: case Op::F64Max: case Op::F64Copysign: return "FF:F";
    case Op::I32WrapI64: return "I:i";
    case Op::I32TruncF32S: case Op::I32TruncF32U:
    case Op::I32TruncSatF32S: case Op::I32TruncSatF32U: return "f:i";
    case Op::I32TruncF64S: case Op::I32TruncF64U:
    case Op::I32TruncSatF64S: case Op::I32TruncSatF64U: return "F:i";
    case Op::I64ExtendI32S: case Op::I64ExtendI32U: return "i:I";
    case Op::I64TruncF32S: case Op::I64TruncF32U:
    case Op::I64TruncSatF32S: case Op::I64TruncSatF32U: return "f:I";
    case Op::I64TruncF64S: case Op::I64TruncF64U:
    case Op::I64TruncSatF64S: case Op::I64TruncSatF64U: return "F:I";
    case Op::F32ConvertI32S: case Op::F32ConvertI32U: return "i:f";
    case Op::F32ConvertI64S: case Op::F32ConvertI64U: return "I:f";
    case Op::F32DemoteF64: return "F:f";
    case Op::F64ConvertI32S: case Op::F64ConvertI32U: return "i:F";
    case Op::F64ConvertI64S: case Op::F64ConvertI64U: return "I:F";
    case Op::F64PromoteF32: return "f:F";
    case Op::I32ReinterpretF32: return "f:i";
    case Op::I64ReinterpretF64: return "F:I";
    case Op::F32ReinterpretI32: return "i:f";
    case Op::F64ReinterpretI64: return "I:F";
    case Op::I32Const: return ":i";
    case Op::I64Const: return ":I";
    case Op::F32Const: return ":f";
    case Op::F64Const: return ":F";
    case Op::I32Load: return "i:i";
    case Op::I64Load: return "i:I";
    case Op::F32Load: return "i:f";
    case Op::F64Load: return "i:F";
    case Op::I32Load8S: case Op::I32Load8U: case Op::I32Load16S:
    case Op::I32Load16U: return "i:i";
    case Op::I64Load8S: case Op::I64Load8U: case Op::I64Load16S:
    case Op::I64Load16U: case Op::I64Load32S: case Op::I64Load32U: return "i:I";
    case Op::I32Store: return "ii:";
    case Op::I64Store: return "iI:";
    case Op::F32Store: return "if:";
    case Op::F64Store: return "iF:";
    case Op::I32Store8: case Op::I32Store16: return "ii:";
    case Op::I64Store8: case Op::I64Store16: case Op::I64Store32: return "iI:";
    case Op::MemorySize: return ":i";
    case Op::MemoryGrow: return "i:i";
    case Op::MemoryFill: case Op::MemoryCopy: case Op::MemoryInit: return "iii:";
    case Op::DataDrop: case Op::ElemDrop: return ":";
    case Op::TableInit: case Op::TableCopy: return "iii:";
    case Op::TableSize: return ":i";
    default: return {};
  }
}

ValType type_of(char c) {
  switch (c) {
    case 'i': return ValType::I32;
    case 'I': return ValType::I64;
    case 'f': return ValType::F32;
    default: return ValType::F64;
  }
}

// Which functions a body is allowed to take a reference to. The rule is not
// about safety — any index in range would be safe — it is about letting an
// engine know, before it compiles a single body, which functions can escape into
// a table. Everything named *outside* the function bodies counts: exports,
// element segments, global initialisers, the start function. A function that is
// referenced only from inside a body has to be announced, and the announcement
// is a declarative element segment, which is why that otherwise pointless kind
// of segment exists.
std::set<u32> declared_funcs(const Module& m) {
  std::set<u32> refs;
  const auto scan = [&](const Expr& e) {
    for (const Inst& in : e)
      if (in.op == Op::RefFunc) refs.insert(in.a);
  };
  for (const Export& ex : m.exports)
    if (ex.kind == ExternKind::Func) refs.insert(ex.index);
  for (const Global& g : m.globals) scan(g.init);
  for (const ElemSeg& seg : m.elems)
    for (const Expr& e : seg.init) scan(e);
  if (m.start) refs.insert(*m.start);
  return refs;
}

struct Validator {
  const Module& m;
  Diag& d;
  const std::set<u32>* refs = nullptr;
  Code* code = nullptr;
  std::vector<ValType> opds;
  std::vector<Ctrl> ctrls;
  u32 func_index = 0;
  std::size_t inst_index = 0;

  bool ok() const { return !d.failed; }
  void fail(std::string msg) {
    d.fail(std::format("{}: instruction {}: {}", m.func_label(func_index), inst_index,
                       std::move(msg)));
  }

  // ---- the operand stack ---------------------------------------------------

  void push(ValType t) {
    opds.push_back(t);
    if (opds.size() > code->max_stack) code->max_stack = static_cast<u32>(opds.size());
  }

  // The one rule worth staring at. Inside unreachable code the stack has been
  // cut back to the enclosing label's height, and every further pop hands out
  // `Unknown` instead of failing. That is what makes
  //
  //     unreachable
  //     i32.add
  //
  // legal: `i32.add` wants two i32s and gets two Unknowns, which agree with
  // anything. Without the rule, every dead branch would have to be written so as
  // to leave the stack plausible, which no compiler back end wants to do.
  ValType pop_opd() {
    const Ctrl& c = ctrls.back();
    if (opds.size() == c.height) {
      if (c.unreachable) return kUnknown;
      fail("operand stack underflow");
      return kUnknown;
    }
    const ValType t = opds.back();
    opds.pop_back();
    return t;
  }

  ValType pop_expect(ValType expect) {
    const ValType actual = pop_opd();
    if (!ok()) return expect;
    if (actual == kUnknown) return expect;
    if (expect == kUnknown) return actual;
    if (actual != expect) {
      fail(std::format("expected {} on the stack, found {}", valtype_name(expect),
                       valtype_name(actual)));
      return expect;
    }
    return actual;
  }

  void pop_all(std::span<const ValType> ts) {
    for (std::size_t i = ts.size(); i-- > 0;) pop_expect(ts[i]);
  }
  void push_all(std::span<const ValType> ts) {
    for (ValType t : ts) push(t);
  }

  void mark_unreachable() {
    Ctrl& c = ctrls.back();
    opds.resize(c.height);
    c.unreachable = true;
  }

  // ---- labels --------------------------------------------------------------

  void push_ctrl(Op op, std::vector<ValType> in, std::vector<ValType> out) {
    pop_all(in);
    Ctrl c;
    c.op = op;
    c.in = std::move(in);
    c.out = std::move(out);
    c.height = static_cast<u32>(opds.size());
    c.loop_pc = static_cast<u32>(code->instrs.size());
    ctrls.push_back(std::move(c));
    push_all(ctrls.back().in);
  }

  // Closing a label is where the plan gets written: every branch that named this
  // label now learns where it lands.
  Ctrl pop_ctrl() {
    if (ctrls.empty()) {
      fail("unbalanced `end`");
      return {};
    }
    Ctrl c = ctrls.back();
    pop_all(c.out);
    if (opds.size() != c.height && ok())
      fail(std::format(
          "the block's type accounts for {} result value(s), and {} more are left over",
          c.out.size(), opds.size() - c.height));
    ctrls.pop_back();
    return c;
  }

  void resolve(const Ctrl& c) {
    const u32 here = static_cast<u32>(code->instrs.size());
    for (u32 i : c.br_patches) code->brs[i].pc = here;
    for (u32 i : c.pc_patches) code->instrs[i].a = here;
  }

  // ---- immediates ----------------------------------------------------------

  bool block_type(const Inst& in, std::vector<ValType>& params,
                  std::vector<ValType>& results) {
    switch (in.a) {
      case 0:
        return true;
      case 1:
        if (!valtype_exists(static_cast<u8>(in.b))) { fail("bad block type"); return false; }
        results.push_back(static_cast<ValType>(in.b));
        return true;
      default:
        if (in.b >= m.types.size()) { fail("block type index out of range"); return false; }
        params = m.types[in.b].params;
        results = m.types[in.b].results;
        return true;
    }
  }

  // A branch names a label by how many to leave. Turning that into an entry in
  // `brs` is the only place the runtime's view of control flow is created.
  u32 branch(u32 depth) {
    if (depth >= ctrls.size()) {
      fail(std::format("branch to label {}, and only {} label(s) are in scope", depth,
                       ctrls.size()));
      return 0;
    }
    Ctrl& target = ctrls[ctrls.size() - 1 - depth];
    const auto& types = target.label_types();
    // The values the branch carries have to be on the stack, and stay there:
    // the branch may be conditional.
    for (std::size_t i = types.size(); i-- > 0;) {
      const ValType t = pop_expect(types[i]);
      (void)t;
    }
    push_all(types);

    const u32 slot = static_cast<u32>(code->brs.size());
    code->brs.push_back(BrTarget{0, static_cast<u32>(types.size()), target.height});
    if (target.op == Op::Loop)
      code->brs[slot].pc = target.loop_pc;
    else
      target.br_patches.push_back(slot);
    return slot;
  }

  void emit(Op op, u32 a = 0, u32 b = 0, u64 imm = 0) {
    code->instrs.push_back(Instr{op, a, b, imm});
  }

  void check_memory() {
    if (m.total_mems() == 0) fail("this instruction needs a memory, and there is none");
  }
  void check_align(const Inst& in) {
    if (in.a > op_info(in.op).natural_align)
      fail(std::format("alignment 2^{} is larger than the {} byte access", in.a,
                       1u << op_info(in.op).natural_align));
  }

  // ---- one function --------------------------------------------------------

  void function(const Func& f, u32 index) {
    func_index = index;
    if (f.type >= m.types.size()) {
      d.fail(std::format("function {} has type index {}, out of range", index, f.type));
      return;
    }
    const FuncType& ft = m.types[f.type];
    code->locals = ft.params;
    code->locals.insert(code->locals.end(), f.locals.begin(), f.locals.end());
    code->n_params = static_cast<u32>(ft.params.size());
    code->n_results = static_cast<u32>(ft.results.size());

    opds.clear();
    ctrls.clear();
    // The outermost label is the function itself, so `return` is `br` to it and
    // needs no rule of its own.
    Ctrl top;
    top.op = Op::Block;
    top.out = ft.results;
    top.height = 0;
    ctrls.push_back(std::move(top));

    for (inst_index = 0; inst_index < f.body.size() && ok(); ++inst_index)
      instruction(f.body[inst_index]);
    if (!ok()) return;
    if (!ctrls.empty()) {
      d.fail(std::format("{}: the body ends inside a block", m.func_label(index)));
      return;
    }
    emit(Op::Return);
  }

  void instruction(const Inst& in) {
    switch (in.op) {
      case Op::Unreachable:
        emit(Op::Unreachable);
        mark_unreachable();
        return;
      case Op::Nop:
        return;  // a nop is nothing at run time, so nothing is planned

      case Op::Block: case Op::Loop: {
        std::vector<ValType> params, results;
        if (!block_type(in, params, results)) return;
        push_ctrl(in.op, std::move(params), std::move(results));
        return;  // block and loop plan no instruction at all
      }
      case Op::If: {
        std::vector<ValType> params, results;
        if (!block_type(in, params, results)) return;
        pop_expect(ValType::I32);
        const u32 slot = static_cast<u32>(code->instrs.size());
        emit(Op::IfFalse);
        push_ctrl(Op::If, std::move(params), std::move(results));
        ctrls.back().if_false = slot;
        return;
      }
      case Op::Else: {
        Ctrl c = pop_ctrl();
        if (!ok()) return;
        if (c.op != Op::If) { fail("`else` without `if`"); return; }
        // Falling out of the then-arm jumps past the else-arm.
        c.pc_patches.push_back(static_cast<u32>(code->instrs.size()));
        emit(Op::Jump);
        // A false condition lands here, at the start of the else-arm.
        code->instrs[c.if_false].a = static_cast<u32>(code->instrs.size());
        Ctrl next;
        next.op = Op::Else;
        next.in = c.in;
        next.out = c.out;
        next.height = c.height;
        next.loop_pc = static_cast<u32>(code->instrs.size());
        next.br_patches = std::move(c.br_patches);
        next.pc_patches = std::move(c.pc_patches);
        ctrls.push_back(std::move(next));
        push_all(ctrls.back().in);
        return;
      }
      case Op::End: {
        Ctrl c = pop_ctrl();
        if (!ok()) return;
        if (c.op == Op::If) {
          // An `if` with no `else` falls straight through when false, so its
          // block type has to leave the stack the same either way.
          if (c.in != c.out) {
            fail("an `if` without an `else` must return what it takes");
            return;
          }
          code->instrs[c.if_false].a = static_cast<u32>(code->instrs.size());
        }
        resolve(c);
        push_all(c.out);
        if (ctrls.empty()) {
          // The function's own `end`: what is on the stack is the result.
          return;
        }
        return;
      }

      case Op::Br: {
        const u32 slot = branch(in.a);
        emit(Op::Br, slot);
        mark_unreachable();
        return;
      }
      case Op::BrIf: {
        pop_expect(ValType::I32);
        const u32 slot = branch(in.a);
        emit(Op::BrIf, slot);
        return;
      }
      case Op::BrTable: {
        pop_expect(ValType::I32);
        if (in.a >= ctrls.size()) { fail("br_table default is out of range"); return; }
        // Every arm must carry the same values, so the default's arity fixes the
        // arity of the whole table.
        const std::size_t arity =
            ctrls[ctrls.size() - 1 - in.a].label_types().size();
        const u32 first = static_cast<u32>(code->brs.size());
        for (u32 depth : in.labels) {
          if (depth >= ctrls.size()) { fail("br_table target is out of range"); return; }
          if (ctrls[ctrls.size() - 1 - depth].label_types().size() != arity) {
            fail("br_table arms disagree about how many values they carry");
            return;
          }
          branch(depth);
          if (!ok()) return;
        }
        branch(in.a);
        if (!ok()) return;
        emit(Op::BrTable, first, static_cast<u32>(in.labels.size()));
        mark_unreachable();
        return;
      }
      case Op::Return: {
        const u32 slot = branch(static_cast<u32>(ctrls.size() - 1));
        emit(Op::Br, slot);
        mark_unreachable();
        return;
      }

      case Op::Call: {
        if (in.a >= m.total_funcs()) { fail("call of an undefined function"); return; }
        const FuncType& ft = m.types[m.func_type_index(in.a)];
        pop_all(ft.params);
        push_all(ft.results);
        emit(Op::Call, in.a);
        return;
      }
      case Op::CallIndirect: {
        if (in.b >= m.total_tables()) { fail("call_indirect names no table"); return; }
        if (m.table_type(in.b).elem != ValType::FuncRef) {
          fail("call_indirect needs a funcref table");
          return;
        }
        if (in.a >= m.types.size()) { fail("call_indirect type is out of range"); return; }
        pop_expect(ValType::I32);
        const FuncType& ft = m.types[in.a];
        pop_all(ft.params);
        push_all(ft.results);
        emit(Op::CallIndirect, in.a, in.b);
        return;
      }

      case Op::Drop:
        pop_opd();
        emit(Op::Drop);
        return;
      case Op::Select: {
        pop_expect(ValType::I32);
        const ValType b = pop_opd();
        const ValType a = pop_expect(b);
        if (a != kUnknown && !is_num(a)) {
          fail("plain `select` works on numbers only; annotate it for references");
          return;
        }
        push(a == kUnknown ? b : a);
        emit(Op::Select);
        return;
      }
      case Op::SelectT: {
        if (in.labels.size() != 1) { fail("`select` takes exactly one result type"); return; }
        const ValType t = static_cast<ValType>(static_cast<u8>(in.labels[0]));
        pop_expect(ValType::I32);
        pop_expect(t);
        pop_expect(t);
        push(t);
        emit(Op::Select);
        return;
      }

      case Op::LocalGet: case Op::LocalSet: case Op::LocalTee: {
        if (in.a >= code->locals.size()) { fail("local index out of range"); return; }
        const ValType t = code->locals[in.a];
        if (in.op == Op::LocalGet) push(t);
        else if (in.op == Op::LocalSet) pop_expect(t);
        else { pop_expect(t); push(t); }
        emit(in.op, in.a);
        return;
      }
      case Op::GlobalGet: case Op::GlobalSet: {
        if (in.a >= m.total_globals()) { fail("global index out of range"); return; }
        const GlobalType gt = m.global_type(in.a);
        if (in.op == Op::GlobalGet) {
          push(gt.type);
        } else {
          if (!gt.is_mutable) { fail("global.set on an immutable global"); return; }
          pop_expect(gt.type);
        }
        emit(in.op, in.a);
        return;
      }

      case Op::TableGet: case Op::TableSet: {
        if (in.a >= m.total_tables()) { fail("table index out of range"); return; }
        const ValType t = m.table_type(in.a).elem;
        if (in.op == Op::TableGet) {
          pop_expect(ValType::I32);
          push(t);
        } else {
          pop_expect(t);  // the value is on top, the index below it
          pop_expect(ValType::I32);
        }
        emit(in.op, in.a);
        return;
      }
      case Op::TableGrow: {
        if (in.a >= m.total_tables()) { fail("table index out of range"); return; }
        pop_expect(ValType::I32);
        pop_expect(m.table_type(in.a).elem);
        push(ValType::I32);
        emit(in.op, in.a);
        return;
      }
      case Op::TableFill: {
        if (in.a >= m.total_tables()) { fail("table index out of range"); return; }
        pop_expect(ValType::I32);
        pop_expect(m.table_type(in.a).elem);
        pop_expect(ValType::I32);
        emit(in.op, in.a);
        return;
      }
      case Op::RefNull: {
        if (!valtype_exists(static_cast<u8>(in.a)) ||
            !is_ref(static_cast<ValType>(in.a))) {
          fail("ref.null needs a reference type");
          return;
        }
        push(static_cast<ValType>(in.a));
        emit(in.op, in.a);
        return;
      }
      case Op::RefIsNull: {
        const ValType t = pop_opd();
        if (t != kUnknown && !is_ref(t)) { fail("ref.is_null needs a reference"); return; }
        push(ValType::I32);
        emit(in.op);
        return;
      }
      case Op::RefFunc: {
        if (in.a >= m.total_funcs()) { fail("ref.func names no function"); return; }
        if (!refs->contains(in.a)) {
          fail(std::format(
              "function {} is not declared; export it or add `(elem declare func ...)`",
              in.a));
          return;
        }
        push(ValType::FuncRef);
        emit(in.op, in.a);
        return;
      }

      default:
        break;
    }

    // Everything left has a fixed signature, plus at most a bound to check.
    const std::string_view sig = simple_sig(in.op);
    if (sig.empty()) {
      fail(std::format("no typing rule for `{}`", op_name(in.op)));
      return;
    }
    switch (op_info(in.op).imm) {
      case Imm::MemArg:
        check_memory();
        check_align(in);
        break;
      case Imm::MemIdx: case Imm::MemMem:
        check_memory();
        break;
      case Imm::DataMem:
        check_memory();
        [[fallthrough]];
      case Imm::Data:
        if (in.a >= m.datas.size()) { fail("data segment index out of range"); return; }
        if (!m.data_count) { fail("this module needs a data count section"); return; }
        break;
      case Imm::Elem:
        if (in.a >= m.elems.size()) { fail("elem segment index out of range"); return; }
        break;
      case Imm::ElemTable:
        if (in.a >= m.elems.size()) { fail("elem segment index out of range"); return; }
        if (in.b >= m.total_tables()) { fail("table index out of range"); return; }
        if (m.elems[in.a].type != m.table_type(in.b).elem) {
          fail("table.init between different reference types");
          return;
        }
        break;
      case Imm::TableTable:
        if (in.a >= m.total_tables() || in.b >= m.total_tables()) {
          fail("table index out of range");
          return;
        }
        if (m.table_type(in.a).elem != m.table_type(in.b).elem) {
          fail("table.copy between different reference types");
          return;
        }
        break;
      case Imm::Table:
        if (in.a >= m.total_tables()) { fail("table index out of range"); return; }
        break;
      default:
        break;
    }
    if (!ok()) return;

    const std::size_t colon = sig.find(':');
    for (std::size_t i = colon; i-- > 0;) pop_expect(type_of(sig[i]));
    for (std::size_t i = colon + 1; i < sig.size(); ++i) push(type_of(sig[i]));
    if (!ok()) return;
    emit(in.op, in.a, in.b, in.imm);
  }
};

// A constant expression is a tiny language of its own: the four constants, a
// null or a function reference, and a read of an already-initialised import.
// Nothing else, because these run before the module exists.
bool check_const_expr(const Module& m, const Expr& e, ValType want, Diag& d,
                      std::string_view where) {
  std::vector<ValType> stack;
  for (const Inst& in : e) {
    switch (in.op) {
      case Op::I32Const: stack.push_back(ValType::I32); break;
      case Op::I64Const: stack.push_back(ValType::I64); break;
      case Op::F32Const: stack.push_back(ValType::F32); break;
      case Op::F64Const: stack.push_back(ValType::F64); break;
      case Op::RefNull:
        if (!valtype_exists(static_cast<u8>(in.a)) || !is_ref(static_cast<ValType>(in.a))) {
          d.fail(std::format("{}: ref.null needs a reference type", where));
          return false;
        }
        stack.push_back(static_cast<ValType>(in.a));
        break;
      case Op::RefFunc:
        if (in.a >= m.total_funcs()) {
          d.fail(std::format("{}: ref.func names no function", where));
          return false;
        }
        stack.push_back(ValType::FuncRef);
        break;
      case Op::GlobalGet:
        if (in.a >= m.imported_globals) {
          d.fail(std::format(
              "{}: a constant expression may only read an imported global", where));
          return false;
        }
        if (m.global_type(in.a).is_mutable) {
          d.fail(std::format("{}: a constant expression may not read a mutable global",
                             where));
          return false;
        }
        stack.push_back(m.global_type(in.a).type);
        break;
      case Op::End:
        break;
      default:
        d.fail(std::format("{}: `{}` is not allowed in a constant expression", where,
                           op_name(in.op)));
        return false;
    }
  }
  if (stack.size() != 1) {
    d.fail(std::format("{}: a constant expression must leave exactly one value", where));
    return false;
  }
  if (stack[0] != want) {
    d.fail(std::format("{}: expected {}, found {}", where, valtype_name(want),
                       valtype_name(stack[0])));
    return false;
  }
  return true;
}

bool check_limits(const Limits& l, u32 bound, Diag& d, std::string_view what) {
  if (l.min > bound) {
    d.fail(std::format("{}: minimum {} is above the limit {}", what, l.min, bound));
    return false;
  }
  if (l.has_max) {
    if (l.max > bound) {
      d.fail(std::format("{}: maximum {} is above the limit {}", what, l.max, bound));
      return false;
    }
    if (l.max < l.min) {
      d.fail(std::format("{}: maximum {} is below minimum {}", what, l.max, l.min));
      return false;
    }
  }
  return true;
}

}  // namespace weasel

export namespace weasel {

// Validate a whole module and hand back one plan per defined function.
bool validate(const Module& m, std::vector<Code>& out, Diag& d) {
  for (const Import& im : m.imports) {
    if (im.kind == ExternKind::Func && im.type_index >= m.types.size()) {
      d.fail(std::format("import {}.{} has a type index out of range", im.module, im.name));
      return false;
    }
    if (im.kind == ExternKind::Table && !check_limits(im.table.limits, 0xffffffffu, d, "imported table"))
      return false;
    if (im.kind == ExternKind::Memory && !check_limits(im.mem.limits, kMaxPages, d, "imported memory"))
      return false;
  }
  for (const TableType& t : m.tables)
    if (!check_limits(t.limits, 0xffffffffu, d, "table")) return false;
  for (const MemType& t : m.mems)
    if (!check_limits(t.limits, kMaxPages, d, "memory")) return false;
  if (m.total_mems() > 1) {
    d.fail("more than one memory is not supported");
    return false;
  }

  for (u32 i = 0; i < m.globals.size(); ++i)
    if (!check_const_expr(m, m.globals[i].init, m.globals[i].type.type, d,
                          std::format("global {}", m.imported_globals + i)))
      return false;

  std::set<std::string> export_names;
  for (const Export& ex : m.exports) {
    if (!export_names.insert(ex.name).second) {
      d.fail(std::format("duplicate export name `{}`", ex.name));
      return false;
    }
    const u32 bound = (ex.kind == ExternKind::Func)     ? m.total_funcs()
                      : (ex.kind == ExternKind::Table)  ? m.total_tables()
                      : (ex.kind == ExternKind::Memory) ? m.total_mems()
                                                        : m.total_globals();
    if (ex.index >= bound) {
      d.fail(std::format("export `{}` names {} {}, which does not exist", ex.name,
                         kind_name(ex.kind), ex.index));
      return false;
    }
  }

  if (m.start) {
    if (*m.start >= m.total_funcs()) {
      d.fail("the start function does not exist");
      return false;
    }
    const FuncType& ft = m.types[m.func_type_index(*m.start)];
    if (!ft.params.empty() || !ft.results.empty()) {
      d.fail("the start function must take and return nothing");
      return false;
    }
  }

  for (u32 i = 0; i < m.elems.size(); ++i) {
    const ElemSeg& seg = m.elems[i];
    if (!is_ref(seg.type)) {
      d.fail(std::format("elem segment {} has a non-reference type", i));
      return false;
    }
    for (const Expr& e : seg.init)
      if (!check_const_expr(m, e, seg.type, d, std::format("elem segment {}", i)))
        return false;
    if (seg.mode == SegMode::Active) {
      if (seg.table >= m.total_tables()) {
        d.fail(std::format("elem segment {} names table {}, which does not exist", i,
                           seg.table));
        return false;
      }
      if (m.table_type(seg.table).elem != seg.type) {
        d.fail(std::format("elem segment {} does not match its table's type", i));
        return false;
      }
      if (!check_const_expr(m, seg.offset, ValType::I32, d,
                            std::format("elem segment {} offset", i)))
        return false;
    }
  }
  for (u32 i = 0; i < m.datas.size(); ++i) {
    const DataSeg& seg = m.datas[i];
    if (seg.mode != SegMode::Active) continue;
    if (seg.mem >= m.total_mems()) {
      d.fail(std::format("data segment {} names memory {}, which does not exist", i,
                         seg.mem));
      return false;
    }
    if (!check_const_expr(m, seg.offset, ValType::I32, d,
                          std::format("data segment {} offset", i)))
      return false;
  }
  if (m.data_count && *m.data_count != m.datas.size()) {
    d.fail("the data count section disagrees with the data section");
    return false;
  }

  const std::set<u32> refs = declared_funcs(m);
  out.clear();
  out.resize(m.funcs.size());
  for (u32 i = 0; i < m.funcs.size(); ++i) {
    Validator v{m, d};
    v.refs = &refs;
    v.code = &out[i];
    v.function(m.funcs[i], m.imported_funcs + i);
    if (d.failed) return false;
  }
  return true;
}

}  // namespace weasel
