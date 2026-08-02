// Dump partition — printing a module, and printing the plan.
//
// Two printers, for two different jobs.
//
// `dump_module` prints what a front end produced, and prints nothing that a
// front end could disagree about — no names, no source positions, constants as
// bit patterns. That is what makes it a test: the same `.wat` read by :text and
// the same `.wat` run through `wat2wasm` and read by :binary must print the same
// characters, or one of the two front ends is wrong.
//
// `dump_plan` prints what :validate produced, and is the only way to see that
// `block` and `end` are really gone.
export module weasel:dump;

import std;
import :common;
import :opcode;
import :types;
import :validate;
import :store;

namespace weasel {

std::string quote(std::string_view s) {
  std::string out = "\"";
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') {
      out.push_back('\\');
      out.push_back(static_cast<char>(c));
    } else if (c >= 0x20 && c < 0x7f) {
      out.push_back(static_cast<char>(c));
    } else {
      out += std::format("\\{:02x}", c);
    }
  }
  out.push_back('"');
  return out;
}

std::string types_of(std::span<const ValType> ts) {
  std::string out;
  for (ValType t : ts) {
    if (!out.empty()) out.push_back(' ');
    out += valtype_name(t);
  }
  return out;
}

std::string limits_of(const Limits& l) {
  return l.has_max ? std::format("{} {}", l.min, l.max) : std::format("{}", l.min);
}

// The immediates of one instruction, in the same order the format writes them.
// Constants are printed as bit patterns, because that is the only spelling that
// two front ends are guaranteed to agree on.
std::string immediates_of(const Inst& in) {
  switch (op_info(in.op).imm) {
    case Imm::None: return {};
    case Imm::BlockType:
      if (in.a == 0) return {};
      if (in.a == 1) return std::format(" (result {})", valtype_name(static_cast<ValType>(in.b)));
      return std::format(" (type {})", in.b);
    case Imm::Label: case Imm::Func: case Imm::Local: case Imm::Global:
    case Imm::Table: case Imm::Elem: case Imm::Data: case Imm::MemIdx:
      return std::format(" {}", in.a);
    case Imm::LabelTable: {
      std::string out;
      for (u32 l : in.labels) out += std::format(" {}", l);
      out += std::format(" default={}", in.a);
      return out;
    }
    case Imm::CallIndirect: return std::format(" (type {}) table={}", in.a, in.b);
    case Imm::TableTable: case Imm::MemMem: return std::format(" {} {}", in.a, in.b);
    case Imm::ElemTable: case Imm::DataMem: return std::format(" {} {}", in.a, in.b);
    case Imm::MemArg: return std::format(" align=2^{} offset={}", in.a, in.b);
    case Imm::I32: return std::format(" {:#010x}", static_cast<u32>(in.imm));
    case Imm::I64: return std::format(" {:#018x}", in.imm);
    case Imm::F32: return std::format(" {:#010x}", static_cast<u32>(in.imm));
    case Imm::F64: return std::format(" {:#018x}", in.imm);
    case Imm::RefType: return std::format(" {}", valtype_name(static_cast<ValType>(in.a)));
    case Imm::SelectT: {
      std::string out;
      for (u32 t : in.labels) out += std::format(" {}", valtype_name(static_cast<ValType>(t)));
      return out;
    }
  }
  return {};
}

void print_expr(std::string& out, const Expr& e, int indent) {
  int depth = indent;
  for (const Inst& in : e) {
    if (in.op == Op::End || in.op == Op::Else) --depth;
    out += std::string(static_cast<std::size_t>(depth) * 2, ' ');
    out += op_name(in.op);
    out += immediates_of(in);
    out.push_back('\n');
    switch (in.op) {
      case Op::Block: case Op::Loop: case Op::If: case Op::Else: ++depth; break;
      default: break;
    }
  }
}

std::string mode_of(SegMode m) {
  switch (m) {
    case SegMode::Active: return "active";
    case SegMode::Passive: return "passive";
    case SegMode::Declarative: return "declarative";
  }
  return "?";
}

}  // namespace weasel

export namespace weasel {

std::string dump_module(const Module& m) {
  std::string out = "(module\n";
  for (u32 i = 0; i < m.types.size(); ++i) {
    out += std::format("  (type {} (func", i);
    if (!m.types[i].params.empty())
      out += std::format(" (param {})", types_of(m.types[i].params));
    if (!m.types[i].results.empty())
      out += std::format(" (result {})", types_of(m.types[i].results));
    out += "))\n";
  }
  u32 nf = 0, nt = 0, nm = 0, ng = 0;
  for (const Import& im : m.imports) {
    out += std::format("  (import {} {} ", quote(im.module), quote(im.name));
    switch (im.kind) {
      case ExternKind::Func:
        out += std::format("(func {} (type {})))\n", nf++, im.type_index);
        break;
      case ExternKind::Table:
        out += std::format("(table {} {} {}))\n", nt++, limits_of(im.table.limits),
                           valtype_name(im.table.elem));
        break;
      case ExternKind::Memory:
        out += std::format("(memory {} {}))\n", nm++, limits_of(im.mem.limits));
        break;
      case ExternKind::Global:
        out += std::format("(global {} {}{}))\n", ng++,
                           im.global.is_mutable ? "mut " : "", valtype_name(im.global.type));
        break;
    }
  }
  for (u32 i = 0; i < m.tables.size(); ++i)
    out += std::format("  (table {} {} {})\n", m.imported_tables + i,
                       limits_of(m.tables[i].limits), valtype_name(m.tables[i].elem));
  for (u32 i = 0; i < m.mems.size(); ++i)
    out += std::format("  (memory {} {})\n", m.imported_mems + i,
                       limits_of(m.mems[i].limits));
  for (u32 i = 0; i < m.globals.size(); ++i) {
    out += std::format("  (global {} {}{}\n", m.imported_globals + i,
                       m.globals[i].type.is_mutable ? "mut " : "",
                       valtype_name(m.globals[i].type.type));
    print_expr(out, m.globals[i].init, 2);
    out += "  )\n";
  }
  for (const Export& ex : m.exports)
    out += std::format("  (export {} ({} {}))\n", quote(ex.name), kind_name(ex.kind),
                       ex.index);
  if (m.start) out += std::format("  (start {})\n", *m.start);
  for (u32 i = 0; i < m.elems.size(); ++i) {
    const ElemSeg& seg = m.elems[i];
    out += std::format("  (elem {} {} {}", i, mode_of(seg.mode), valtype_name(seg.type));
    if (seg.mode == SegMode::Active) out += std::format(" table={}", seg.table);
    out += std::format(" count={}\n", seg.init.size());
    if (seg.mode == SegMode::Active) {
      out += "    offset\n";
      print_expr(out, seg.offset, 3);
    }
    for (const Expr& e : seg.init) {
      out += "    item\n";
      print_expr(out, e, 3);
    }
    out += "  )\n";
  }
  for (u32 i = 0; i < m.datas.size(); ++i) {
    const DataSeg& seg = m.datas[i];
    out += std::format("  (data {} {}", i, mode_of(seg.mode));
    if (seg.mode == SegMode::Active) out += std::format(" mem={}", seg.mem);
    out += std::format(" bytes={}\n", seg.bytes.size());
    if (seg.mode == SegMode::Active) {
      out += "    offset\n";
      print_expr(out, seg.offset, 3);
    }
    out += "    ";
    for (u8 b : seg.bytes) out += std::format("{:02x}", b);
    out.push_back('\n');
    out += "  )\n";
  }
  for (u32 i = 0; i < m.funcs.size(); ++i) {
    out += std::format("  (func {} (type {})", m.imported_funcs + i, m.funcs[i].type);
    if (!m.funcs[i].locals.empty())
      out += std::format(" (local {})", types_of(m.funcs[i].locals));
    out.push_back('\n');
    print_expr(out, m.funcs[i].body, 2);
    out += "  )\n";
  }
  out += ")\n";
  return out;
}

// The immediates of a *planned* instruction. Control flow reads differently here
// than in the module: what was a label depth is now a position.
std::string planned_immediates(const Code& c, const Instr& in) {
  switch (in.op) {
    case Op::Br: case Op::BrIf: {
      const BrTarget& t = c.brs[in.a];
      return std::format(" -> {} keep={} height={}", t.pc, t.keep, t.height);
    }
    case Op::BrTable: {
      std::string out;
      for (u32 i = 0; i <= in.b; ++i) {
        const BrTarget& t = c.brs[in.a + i];
        out += std::format(" {}{}", (i == in.b) ? "default=" : "", t.pc);
      }
      const BrTarget& t = c.brs[in.a];
      out += std::format(" keep={} height={}", t.keep, t.height);
      return out;
    }
    case Op::IfFalse: case Op::Jump:
      return std::format(" -> {}", in.a);
    // A constant reads better here than in the module dump: this listing is for
    // a person, and nothing is being compared against another front end.
    case Op::I32Const: return std::format(" {}", static_cast<i32>(in.imm));
    case Op::I64Const: return std::format(" {}", static_cast<i64>(in.imm));
    case Op::F32Const: return std::format(" {}", std::bit_cast<f32>(static_cast<u32>(in.imm)));
    case Op::F64Const: return std::format(" {}", std::bit_cast<f64>(in.imm));
    default: {
      Inst as_inst;
      as_inst.op = in.op;
      as_inst.a = in.a;
      as_inst.b = in.b;
      as_inst.imm = in.imm;
      return immediates_of(as_inst);
    }
  }
}

std::string dump_code(const Module& m, const Code& c, u32 func_index) {
  std::string out = std::format(
      "{} : ({}) -> ({})\n", m.func_label(func_index),
      types_of(std::span<const ValType>(c.locals).first(c.n_params)),
      types_of(m.types[m.func_type_index(func_index)].results));
  if (c.locals.size() > c.n_params)
    out += std::format("  locals {}\n",
                       types_of(std::span<const ValType>(c.locals).subspan(c.n_params)));
  out += std::format("  max operand stack {}\n", c.max_stack);
  for (u32 pc = 0; pc < c.instrs.size(); ++pc)
    out += std::format("  {:>4}  {}{}\n", pc, op_name(c.instrs[pc].op),
                       planned_immediates(c, c.instrs[pc]));
  return out;
}

std::string dump_plan(const Module& m, const std::vector<Code>& codes) {
  std::string out;
  for (u32 i = 0; i < codes.size(); ++i) {
    out += dump_code(m, codes[i], m.imported_funcs + i);
    out.push_back('\n');
  }
  return out;
}

// How a result is printed on the way out of the runtime. Floats show the value
// and the bits, because for a float those are two different facts.
std::string format_value(ValType t, Value v) {
  switch (t) {
    case ValType::I32: return std::format("{}", static_cast<i32>(v.i32()));
    case ValType::I64: return std::format("{}", static_cast<i64>(v.i64()));
    case ValType::F32: return std::format("{} ({:#010x})", v.f32v(), static_cast<u32>(v.bits));
    case ValType::F64: return std::format("{} ({:#018x})", v.f64v(), v.bits);
    case ValType::FuncRef:
      return v.is_null() ? "null" : std::format("func {}", v.ref_addr());
    case ValType::ExternRef:
      return v.is_null() ? "null" : std::format("extern {}", v.ref_addr());
  }
  return "?";
}

}  // namespace weasel
