// Binary partition — `\0asm` bytes into a Module.
//
// The whole format is one idea repeated: a vector is a LEB128 count followed by
// that many items, and a section is an id, a LEB128 byte length, and a vector.
// The byte length means a decoder can skip a section it does not understand;
// this one uses it instead as a bound, decoding each section from a sub-reader
// so a section that lies about its length is caught at its own edge rather than
// halfway through the next one.
//
// Nothing here checks types. A module can decode cleanly and still be rejected
// by :validate — the two are separate on purpose, and the error messages say
// which of the two refused.
export module weasel:binary;

import std;
import :common;
import :opcode;
import :types;

namespace weasel {

// The section ids, in the order the format requires them to appear.
enum class SectionId : u8 {
  Custom = 0, Type, Import, Function, Table, Memory, Global,
  Export, Start, Element, Code, Data, DataCount,
};

// Sections must appear in a fixed order, but that order is not the order of the
// ids: the data count section was added later and given id 12, while its place
// is before the code section, because a decoder has to know how many data
// segments exist before it meets a `memory.init` that names one.
int section_rank(u8 id) {
  if (id == static_cast<u8>(SectionId::DataCount)) return 10;
  if (id == static_cast<u8>(SectionId::Code)) return 11;
  if (id == static_cast<u8>(SectionId::Data)) return 12;
  return id;
}

std::string_view section_name(u8 id) {
  switch (static_cast<SectionId>(id)) {
    case SectionId::Custom: return "custom";
    case SectionId::Type: return "type";
    case SectionId::Import: return "import";
    case SectionId::Function: return "function";
    case SectionId::Table: return "table";
    case SectionId::Memory: return "memory";
    case SectionId::Global: return "global";
    case SectionId::Export: return "export";
    case SectionId::Start: return "start";
    case SectionId::Element: return "element";
    case SectionId::Code: return "code";
    case SectionId::Data: return "data";
    case SectionId::DataCount: return "data count";
  }
  return "unknown";
}

struct Decoder {
  Reader r;
  Module* m = nullptr;
  std::vector<u32> code_types;  // the function section: one typeidx per defined function

  ValType valtype() {
    const u8 b = r.byte();
    if (!valtype_exists(b)) {
      r.fail(std::format("not a value type: {:#04x}", b));
      return ValType::I32;
    }
    return static_cast<ValType>(b);
  }

  ValType reftype() {
    const ValType t = valtype();
    if (r.ok() && !is_ref(t)) r.fail("expected a reference type");
    return t;
  }

  Limits limits() {
    Limits l;
    const u8 flag = r.byte();
    if (flag != 0 && flag != 1) {
      r.fail(std::format("bad limits flag {:#04x}", flag));
      return l;
    }
    l.min = r.u32leb();
    if (flag == 1) {
      l.has_max = true;
      l.max = r.u32leb();
    }
    return l;
  }

  // The block type is an s33: negative values are the six value types and the
  // empty type, non-negative values index the type section. Reading it as a
  // signed 33-bit integer is the whole trick — it lets one field hold either.
  void blocktype(Inst& in) {
    const i64 v = r.sleb(33);
    if (!r.ok()) return;
    if (v >= 0) {
      in.a = 2;
      in.b = static_cast<u32>(v);
      return;
    }
    const u8 b = static_cast<u8>(v & 0x7f);
    if (b == 0x40) {
      in.a = 0;
      in.b = 0;
      return;
    }
    if (!valtype_exists(b)) {
      r.fail(std::format("not a block type: {:#04x}", b));
      return;
    }
    in.a = 1;
    in.b = b;
  }

  Inst instruction() {
    Inst in;
    u16 code = r.byte();
    if (!r.ok()) return in;
    if (code == 0xfc) {
      const u32 sub = r.u32leb();
      if (!r.ok()) return in;
      if (sub > 0x11) {
        r.fail(std::format("unknown 0xfc instruction {}", sub));
        return in;
      }
      code = static_cast<u16>(0x100 + sub);
    } else if (code == 0xfd || code == 0xfe) {
      r.fail(std::format("{} instructions are not supported",
                         code == 0xfd ? "SIMD" : "atomic"));
      return in;
    }
    if (!op_exists(code)) {
      r.fail(std::format("unknown opcode {:#04x}", code));
      return in;
    }
    in.op = static_cast<Op>(code);

    switch (op_info(in.op).imm) {
      case Imm::None:
        break;
      case Imm::BlockType:
        blocktype(in);
        break;
      case Imm::Label:
      case Imm::Func:
      case Imm::Local:
      case Imm::Global:
      case Imm::Table:
      case Imm::Elem:
      case Imm::Data:
        in.a = r.u32leb();
        break;
      case Imm::LabelTable: {
        const u32 n = r.u32leb();
        if (!r.ok()) break;
        if (n > (1u << 20)) {  // a table this size means a corrupt length
          r.fail("br_table is implausibly large");
          break;
        }
        in.labels.reserve(n);
        for (u32 i = 0; i < n && r.ok(); ++i) in.labels.push_back(r.u32leb());
        in.a = r.u32leb();
        break;
      }
      case Imm::CallIndirect:
        in.a = r.u32leb();
        in.b = r.u32leb();
        break;
      case Imm::TableTable:
      case Imm::MemMem:
        in.a = r.u32leb();
        in.b = r.u32leb();
        break;
      case Imm::ElemTable:
      case Imm::DataMem:
        in.a = r.u32leb();
        in.b = r.u32leb();
        break;
      case Imm::MemArg: {
        const u32 align = r.u32leb();
        if (align & 0x40) {
          r.fail("multi-memory memarg is not supported");
          break;
        }
        in.a = align;
        in.b = r.u32leb();
        break;
      }
      case Imm::MemIdx:
        in.a = r.u32leb();
        break;
      case Imm::I32:
        in.imm = static_cast<u32>(r.i32leb());
        break;
      case Imm::I64:
        in.imm = static_cast<u64>(r.i64leb());
        break;
      case Imm::F32:
        in.imm = r.f32bits();
        break;
      case Imm::F64:
        in.imm = r.f64bits();
        break;
      case Imm::RefType:
        in.a = static_cast<u8>(reftype());
        break;
      case Imm::SelectT: {
        const u32 n = r.u32leb();
        for (u32 i = 0; i < n && r.ok(); ++i)
          in.labels.push_back(static_cast<u8>(valtype()));
        break;
      }
    }
    return in;
  }

  // An expression runs to its matching `end`, which is kept: a function body
  // ending in `end` is the same shape as a block ending in `end`, and the
  // validator gets one rule instead of two.
  Expr expr() {
    Expr e;
    int depth = 0;
    for (;;) {
      if (!r.ok()) return e;
      if (r.eof()) {
        r.fail("expression ran off the end without `end`");
        return e;
      }
      Inst in = instruction();
      if (!r.ok()) return e;
      switch (in.op) {
        case Op::Block: case Op::Loop: case Op::If: ++depth; break;
        case Op::End:
          if (depth == 0) {
            e.push_back(std::move(in));
            return e;
          }
          --depth;
          break;
        default: break;
      }
      e.push_back(std::move(in));
    }
  }

  void type_section() {
    const u32 n = r.u32leb();
    for (u32 i = 0; i < n && r.ok(); ++i) {
      const u8 form = r.byte();
      if (form != 0x60) {
        r.fail(std::format("type {} is not a function type ({:#04x})", i, form));
        return;
      }
      FuncType ft;
      const u32 np = r.u32leb();
      for (u32 j = 0; j < np && r.ok(); ++j) ft.params.push_back(valtype());
      const u32 nq = r.u32leb();
      for (u32 j = 0; j < nq && r.ok(); ++j) ft.results.push_back(valtype());
      m->types.push_back(std::move(ft));
    }
  }

  void import_section() {
    const u32 n = r.u32leb();
    for (u32 i = 0; i < n && r.ok(); ++i) {
      Import im;
      im.module = r.name();
      im.name = r.name();
      const u8 k = r.byte();
      if (k > 3) {
        r.fail(std::format("bad import kind {:#04x}", k));
        return;
      }
      im.kind = static_cast<ExternKind>(k);
      switch (im.kind) {
        case ExternKind::Func:
          im.type_index = r.u32leb();
          ++m->imported_funcs;
          break;
        case ExternKind::Table:
          im.table.elem = reftype();
          im.table.limits = limits();
          ++m->imported_tables;
          break;
        case ExternKind::Memory:
          im.mem.limits = limits();
          ++m->imported_mems;
          break;
        case ExternKind::Global:
          im.global.type = valtype();
          im.global.is_mutable = r.byte() != 0;
          ++m->imported_globals;
          break;
      }
      m->imports.push_back(std::move(im));
    }
  }

  void function_section() {
    const u32 n = r.u32leb();
    for (u32 i = 0; i < n && r.ok(); ++i) code_types.push_back(r.u32leb());
  }

  void table_section() {
    const u32 n = r.u32leb();
    for (u32 i = 0; i < n && r.ok(); ++i) {
      TableType t;
      t.elem = reftype();
      t.limits = limits();
      m->tables.push_back(t);
    }
  }

  void memory_section() {
    const u32 n = r.u32leb();
    for (u32 i = 0; i < n && r.ok(); ++i) m->mems.push_back(MemType{limits()});
  }

  void global_section() {
    const u32 n = r.u32leb();
    for (u32 i = 0; i < n && r.ok(); ++i) {
      Global g;
      g.type.type = valtype();
      g.type.is_mutable = r.byte() != 0;
      g.init = expr();
      m->globals.push_back(std::move(g));
    }
  }

  void export_section() {
    const u32 n = r.u32leb();
    for (u32 i = 0; i < n && r.ok(); ++i) {
      Export ex;
      ex.name = r.name();
      const u8 k = r.byte();
      if (k > 3) {
        r.fail(std::format("bad export kind {:#04x}", k));
        return;
      }
      ex.kind = static_cast<ExternKind>(k);
      ex.index = r.u32leb();
      m->exports.push_back(std::move(ex));
    }
  }

  // Eight forms, distinguished by a three-bit flag: bit 0 says "not active at
  // table 0", bit 1 says "declarative or explicit table", bit 2 says "the
  // elements are expressions rather than function indices".
  void element_section() {
    const u32 n = r.u32leb();
    for (u32 i = 0; i < n && r.ok(); ++i) {
      const u32 flags = r.u32leb();
      if (flags > 7) {
        r.fail(std::format("bad element segment flags {}", flags));
        return;
      }
      ElemSeg seg;
      const bool exprs = (flags & 4) != 0;
      switch (flags & 3) {
        case 0:
          seg.mode = SegMode::Active;
          seg.table = 0;
          seg.offset = expr();
          break;
        case 1:
          seg.mode = SegMode::Passive;
          break;
        case 2:
          seg.mode = SegMode::Active;
          seg.table = r.u32leb();
          seg.offset = expr();
          break;
        case 3:
          seg.mode = SegMode::Declarative;
          break;
      }
      // Forms 0 and 4 have no type field at all; the rest carry one, spelled as
      // an "element kind" byte (always 0x00, meaning funcref) for index lists
      // and as a full reference type for expression lists.
      if ((flags & 3) != 0) {
        if (exprs) {
          seg.type = reftype();
        } else {
          const u8 kind = r.byte();
          if (kind != 0) {
            r.fail(std::format("bad element kind {:#04x}", kind));
            return;
          }
          seg.type = ValType::FuncRef;
        }
      } else {
        seg.type = ValType::FuncRef;
      }
      const u32 count = r.u32leb();
      for (u32 j = 0; j < count && r.ok(); ++j) {
        if (exprs) {
          seg.init.push_back(expr());
        } else {
          Inst rf;
          rf.op = Op::RefFunc;
          rf.a = r.u32leb();
          Inst end;
          end.op = Op::End;
          seg.init.push_back(Expr{std::move(rf), std::move(end)});
        }
      }
      m->elems.push_back(std::move(seg));
    }
  }

  void code_section() {
    const u32 n = r.u32leb();
    if (r.ok() && n != code_types.size()) {
      r.fail(std::format("code section has {} bodies but the function section named {}",
                         n, code_types.size()));
      return;
    }
    for (u32 i = 0; i < n && r.ok(); ++i) {
      const u32 size = r.u32leb();
      auto body = r.take(size);
      if (!r.ok()) return;
      Decoder sub{Reader{body, 0, r.d}, m, {}};
      Func f;
      f.type = code_types[i];
      const u32 groups = sub.r.u32leb();
      u64 total = 0;
      for (u32 g = 0; g < groups && sub.r.ok(); ++g) {
        const u32 count = sub.r.u32leb();
        const ValType t = sub.valtype();
        total += count;
        if (total > 100000) {
          sub.r.fail("too many locals");
          return;
        }
        f.locals.insert(f.locals.end(), count, t);
      }
      f.body = sub.expr();
      if (sub.r.ok() && !sub.r.eof())
        sub.r.fail("bytes left over after the function body");
      m->funcs.push_back(std::move(f));
    }
  }

  void data_section() {
    const u32 n = r.u32leb();
    for (u32 i = 0; i < n && r.ok(); ++i) {
      const u32 flags = r.u32leb();
      DataSeg seg;
      switch (flags) {
        case 0:
          seg.mode = SegMode::Active;
          seg.mem = 0;
          seg.offset = expr();
          break;
        case 1:
          seg.mode = SegMode::Passive;
          break;
        case 2:
          seg.mode = SegMode::Active;
          seg.mem = r.u32leb();
          seg.offset = expr();
          break;
        default:
          r.fail(std::format("bad data segment flags {}", flags));
          return;
      }
      const u32 len = r.u32leb();
      auto s = r.take(len);
      if (!r.ok()) return;
      seg.bytes.assign(s.begin(), s.end());
      m->datas.push_back(std::move(seg));
    }
  }

  // The name section is a custom section, so it is allowed to be malformed; a
  // reader that dislikes it must ignore it rather than reject the module. Every
  // failure here is therefore swallowed, and the module keeps whatever names
  // were read before the trouble started.
  void name_section(std::span<const u8> body) {
    Diag scratch;
    Reader nr{body, 0, &scratch};
    while (!nr.eof() && !scratch.failed) {
      const u8 id = nr.byte();
      const u32 size = nr.u32leb();
      auto sub_bytes = nr.take(size);
      if (scratch.failed) return;
      Reader sub{sub_bytes, 0, &scratch};
      if (id == 0) {
        m->names.module = sub.name();
      } else if (id == 1) {
        const u32 count = sub.u32leb();
        for (u32 i = 0; i < count && !scratch.failed; ++i) {
          const u32 idx = sub.u32leb();
          m->names.funcs[idx] = sub.name();
        }
      } else if (id == 2) {
        const u32 count = sub.u32leb();
        for (u32 i = 0; i < count && !scratch.failed; ++i) {
          const u32 fn = sub.u32leb();
          const u32 inner = sub.u32leb();
          for (u32 j = 0; j < inner && !scratch.failed; ++j) {
            const u32 idx = sub.u32leb();
            m->names.locals[fn][idx] = sub.name();
          }
        }
      }
    }
  }
};

export bool decode_module(std::span<const u8> bytes, Module& out, Diag& d) {
  Reader r{bytes, 0, &d};
  auto magic = r.take(4);
  if (!r.ok()) return false;
  if (!(magic[0] == 0x00 && magic[1] == 'a' && magic[2] == 's' && magic[3] == 'm')) {
    d.fail("not a WebAssembly module (bad magic)");
    return false;
  }
  const u32 version = r.f32bits();  // four little-endian bytes, same shape as an f32
  if (version != 1) {
    d.fail(std::format("unsupported binary version {}", version));
    return false;
  }

  Decoder dec{r, &out, {}};
  // Custom sections may appear anywhere; the rest must appear at most once and
  // in id order. Tracking the last id seen is the whole check.
  int last = -1;
  while (!dec.r.eof() && !d.failed) {
    const u8 id = dec.r.byte();
    const u32 size = dec.r.u32leb();
    auto body = dec.r.take(size);
    if (d.failed) break;
    if (id > static_cast<u8>(SectionId::DataCount)) {
      d.fail(std::format("unknown section id {}", id));
      break;
    }
    if (id != 0) {
      if (section_rank(id) <= last) {
        d.fail(std::format("{} section is out of order", section_name(id)));
        break;
      }
      last = section_rank(id);
    }

    Decoder sub{Reader{body, 0, &d}, &out, {}};
    sub.code_types = dec.code_types;
    switch (static_cast<SectionId>(id)) {
      case SectionId::Custom: {
        Diag scratch;
        Reader nr{body, 0, &scratch};
        const std::string name = nr.name();
        if (!scratch.failed && name == "name")
          sub.name_section(body.subspan(nr.pos));
        continue;  // no trailing-bytes check: a custom section may hold anything
      }
      case SectionId::Type: sub.type_section(); break;
      case SectionId::Import: sub.import_section(); break;
      case SectionId::Function: sub.function_section(); break;
      case SectionId::Table: sub.table_section(); break;
      case SectionId::Memory: sub.memory_section(); break;
      case SectionId::Global: sub.global_section(); break;
      case SectionId::Export: sub.export_section(); break;
      case SectionId::Start: out.start = sub.r.u32leb(); break;
      case SectionId::Element: sub.element_section(); break;
      case SectionId::Code: sub.code_section(); break;
      case SectionId::Data: sub.data_section(); break;
      case SectionId::DataCount: out.data_count = sub.r.u32leb(); break;
    }
    if (d.failed) break;
    if (!sub.r.eof()) {
      d.fail(std::format("{} section has {} bytes left over", section_name(id),
                         sub.r.left()));
      break;
    }
    dec.code_types = sub.code_types;
  }
  if (d.failed) return false;
  if (!dec.code_types.empty() && out.funcs.size() != dec.code_types.size()) {
    d.fail("the function section has no matching code section");
    return false;
  }
  return true;
}

}  // namespace weasel
