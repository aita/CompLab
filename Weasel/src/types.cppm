// Module partition — what a module is, after reading and before running.
//
// This is the shape both front ends produce: the binary decoder and the text
// parser fill in exactly this and nothing else. Control flow is still
// structured here — `block`, `loop`, `if`, `end` are instructions, and a branch
// names a label by how many blocks to leave, not a position to jump to.
// Turning that into positions is validation's job, in :validate.
//
// So the invariant this partition exists to state is: **a Module is what the
// two front ends must agree on.** `weasel dump` prints it, and the tests demand
// the print be identical whichever front end produced it.
export module weasel:types;

import std;
import :common;
import :opcode;

export namespace weasel {

// The value types, spelled with the byte the binary format gives them. They are
// the negative sleb encodings read as a byte: i32 is -0x01, i.e. 0x7f.
enum class ValType : u8 {
  I32 = 0x7f,
  I64 = 0x7e,
  F32 = 0x7d,
  F64 = 0x7c,
  FuncRef = 0x70,
  ExternRef = 0x6f,
};

inline bool valtype_exists(u8 b) {
  switch (b) {
    case 0x7f: case 0x7e: case 0x7d: case 0x7c: case 0x70: case 0x6f: return true;
    default: return false;
  }
}
inline bool is_ref(ValType t) { return t == ValType::FuncRef || t == ValType::ExternRef; }
inline bool is_num(ValType t) { return !is_ref(t); }

inline std::string_view valtype_name(ValType t) {
  switch (t) {
    case ValType::I32: return "i32";
    case ValType::I64: return "i64";
    case ValType::F32: return "f32";
    case ValType::F64: return "f64";
    case ValType::FuncRef: return "funcref";
    case ValType::ExternRef: return "externref";
  }
  return "?";
}

inline bool valtype_by_name(std::string_view s, ValType& out) {
  if (s == "i32") { out = ValType::I32; return true; }
  if (s == "i64") { out = ValType::I64; return true; }
  if (s == "f32") { out = ValType::F32; return true; }
  if (s == "f64") { out = ValType::F64; return true; }
  if (s == "funcref") { out = ValType::FuncRef; return true; }
  if (s == "externref") { out = ValType::ExternRef; return true; }
  return false;
}

struct FuncType {
  std::vector<ValType> params;
  std::vector<ValType> results;
  bool operator==(const FuncType&) const = default;
};

struct Limits {
  u32 min = 0;
  u32 max = 0;
  bool has_max = false;
  bool operator==(const Limits&) const = default;
};

struct TableType {
  ValType elem = ValType::FuncRef;
  Limits limits;
  bool operator==(const TableType&) const = default;
};

struct MemType {
  Limits limits;
  bool operator==(const MemType&) const = default;
};

struct GlobalType {
  ValType type = ValType::I32;
  bool is_mutable = false;
  bool operator==(const GlobalType&) const = default;
};

// One structured instruction. `a` and `b` hold the small immediates, `imm` holds
// a 32- or 64-bit constant's bit pattern, and `labels` holds the only two
// variable-length immediates in the language: `br_table`'s targets and
// `select`'s explicit type.
//
// What `a` and `b` mean is decided by `op_info(op).imm`:
//
//   BlockType     a = 0 empty / 1 valtype / 2 typeidx, b = the valtype or index
//   Label         a = label depth
//   LabelTable    labels = the targets, a = the default
//   Func          a = funcidx
//   CallIndirect  a = typeidx, b = tableidx
//   Local/Global/Table/Elem/Data  a = index
//   TableTable    a = dst, b = src
//   ElemTable     a = elemidx, b = tableidx
//   DataMem       a = dataidx, b = memidx
//   MemArg        a = alignment (log2), b = offset
//   MemIdx        a = memidx        MemMem  a = dst, b = src
//   I32/I64/F32/F64  imm = the bit pattern
//   RefType       a = the valtype byte
//   SelectT       labels = the valtype bytes
struct Inst {
  Op op = Op::Nop;
  u32 a = 0;
  u32 b = 0;
  u64 imm = 0;
  std::vector<u32> labels;
  bool operator==(const Inst&) const = default;
};

using Expr = std::vector<Inst>;

struct Func {
  u32 type = 0;
  std::vector<ValType> locals;  // flattened: the binary's run-lengths are expanded
  Expr body;
};

enum class ExternKind : u8 { Func = 0, Table = 1, Memory = 2, Global = 3 };

inline std::string_view kind_name(ExternKind k) {
  switch (k) {
    case ExternKind::Func: return "func";
    case ExternKind::Table: return "table";
    case ExternKind::Memory: return "memory";
    case ExternKind::Global: return "global";
  }
  return "?";
}

struct Import {
  std::string module;
  std::string name;
  ExternKind kind = ExternKind::Func;
  u32 type_index = 0;  // Func: typeidx
  TableType table;
  MemType mem;
  GlobalType global;
};

struct Export {
  std::string name;
  ExternKind kind = ExternKind::Func;
  u32 index = 0;
};

struct Global {
  GlobalType type;
  Expr init;
};

enum class SegMode : u8 { Active, Passive, Declarative };

struct ElemSeg {
  SegMode mode = SegMode::Active;
  ValType type = ValType::FuncRef;
  u32 table = 0;
  Expr offset;
  std::vector<Expr> init;  // one expression per element
};

struct DataSeg {
  SegMode mode = SegMode::Active;
  u32 mem = 0;
  Expr offset;
  std::vector<u8> bytes;
};

// The custom `name` section, if there is one. It changes nothing about
// execution; it is here because a trace with `$fib` in it is worth reading and a
// trace with `func[7]` in it is not.
struct NameSection {
  std::string module;
  std::map<u32, std::string> funcs;
  std::map<u32, std::map<u32, std::string>> locals;
};

struct Module {
  std::vector<FuncType> types;
  std::vector<Import> imports;
  std::vector<Func> funcs;      // defined only; imported functions come first in the index space
  std::vector<TableType> tables;
  std::vector<MemType> mems;
  std::vector<Global> globals;
  std::vector<Export> exports;
  std::optional<u32> start;
  std::vector<ElemSeg> elems;
  std::vector<DataSeg> datas;
  std::optional<u32> data_count;
  NameSection names;

  // The counts of imported entities, which is where each index space starts
  // counting the module's own definitions.
  u32 imported_funcs = 0;
  u32 imported_tables = 0;
  u32 imported_mems = 0;
  u32 imported_globals = 0;

  u32 total_funcs() const { return imported_funcs + static_cast<u32>(funcs.size()); }
  u32 total_tables() const { return imported_tables + static_cast<u32>(tables.size()); }
  u32 total_mems() const { return imported_mems + static_cast<u32>(mems.size()); }
  u32 total_globals() const { return imported_globals + static_cast<u32>(globals.size()); }

  // The type of any function in the index space, imported or not.
  u32 func_type_index(u32 idx) const {
    if (idx < imported_funcs) {
      u32 seen = 0;
      for (const auto& im : imports) {
        if (im.kind != ExternKind::Func) continue;
        if (seen == idx) return im.type_index;
        ++seen;
      }
      return 0;
    }
    return funcs[idx - imported_funcs].type;
  }

  TableType table_type(u32 idx) const {
    if (idx < imported_tables) {
      u32 seen = 0;
      for (const auto& im : imports) {
        if (im.kind != ExternKind::Table) continue;
        if (seen == idx) return im.table;
        ++seen;
      }
      return {};
    }
    return tables[idx - imported_tables];
  }

  GlobalType global_type(u32 idx) const {
    if (idx < imported_globals) {
      u32 seen = 0;
      for (const auto& im : imports) {
        if (im.kind != ExternKind::Global) continue;
        if (seen == idx) return im.global;
        ++seen;
      }
      return {};
    }
    return globals[idx - imported_globals].type;
  }

  std::string func_label(u32 idx) const {
    if (auto it = names.funcs.find(idx); it != names.funcs.end())
      return std::format("${}", it->second);
    return std::format("func[{}]", idx);
  }
};

// A wasm page is 64 KiB, and a memory is measured in pages everywhere except
// inside a load.
inline constexpr u64 kPageSize = 65536;
inline constexpr u32 kMaxPages = 65536;

}  // namespace weasel
