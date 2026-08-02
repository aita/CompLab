// Opcode partition — one enumerator per instruction, and what follows it.
//
// The enumerator's *value is the opcode byte*. Single-byte instructions get
// their byte; the `0xFC` prefix family gets `0x100 + n`. So the binary decoder
// is a cast rather than a lookup, and the dumper can print the byte it came
// from without carrying it around.
//
// Beside the name, each entry records the shape of its immediates. That one
// table is what the binary decoder, the text parser and the dumper share: three
// passes over the same list, so a new instruction is one line here and a case in
// the interpreter, never a fourth place to forget.
export module weasel:opcode;

import std;
import :common;

export namespace weasel {

// The shape of what follows an opcode.
enum class Imm : u8 {
  None,
  BlockType,   // block / loop / if
  Label,       // br, br_if
  LabelTable,  // br_table: a vector of labels and a default
  Func,        // call, ref.func
  CallIndirect,// typeidx, tableidx
  Local,
  Global,
  Table,       // table.get/set/grow/size/fill
  TableTable,  // table.copy: dst, src
  ElemTable,   // table.init: elemidx, tableidx
  Elem,        // elem.drop
  MemArg,      // align, offset
  MemIdx,      // memory.size/grow/fill: one zero byte
  MemMem,      // memory.copy: two zero bytes
  DataMem,     // memory.init: dataidx, memidx
  Data,        // data.drop
  I32, I64, F32, F64,
  RefType,     // ref.null
  SelectT,     // select with an explicit result type vector
};

// name, opcode, immediate shape, natural alignment (log2) for memory access.
#define WEASEL_OPCODES(X)                                                      \
  X(Unreachable,      0x00, "unreachable",          None,        0)            \
  X(Nop,              0x01, "nop",                  None,        0)            \
  X(Block,            0x02, "block",                BlockType,   0)            \
  X(Loop,             0x03, "loop",                 BlockType,   0)            \
  X(If,               0x04, "if",                   BlockType,   0)            \
  X(Else,             0x05, "else",                 None,        0)            \
  X(End,              0x0b, "end",                  None,        0)            \
  X(Br,               0x0c, "br",                   Label,       0)            \
  X(BrIf,             0x0d, "br_if",                Label,       0)            \
  X(BrTable,          0x0e, "br_table",             LabelTable,  0)            \
  X(Return,           0x0f, "return",               None,        0)            \
  X(Call,             0x10, "call",                 Func,        0)            \
  X(CallIndirect,     0x11, "call_indirect",        CallIndirect,0)            \
  X(Drop,             0x1a, "drop",                 None,        0)            \
  X(Select,           0x1b, "select",               None,        0)            \
  X(SelectT,          0x1c, "select",               SelectT,     0)            \
  X(LocalGet,         0x20, "local.get",            Local,       0)            \
  X(LocalSet,         0x21, "local.set",            Local,       0)            \
  X(LocalTee,         0x22, "local.tee",            Local,       0)            \
  X(GlobalGet,        0x23, "global.get",           Global,      0)            \
  X(GlobalSet,        0x24, "global.set",           Global,      0)            \
  X(TableGet,         0x25, "table.get",            Table,       0)            \
  X(TableSet,         0x26, "table.set",            Table,       0)            \
  X(I32Load,          0x28, "i32.load",             MemArg,      2)            \
  X(I64Load,          0x29, "i64.load",             MemArg,      3)            \
  X(F32Load,          0x2a, "f32.load",             MemArg,      2)            \
  X(F64Load,          0x2b, "f64.load",             MemArg,      3)            \
  X(I32Load8S,        0x2c, "i32.load8_s",          MemArg,      0)            \
  X(I32Load8U,        0x2d, "i32.load8_u",          MemArg,      0)            \
  X(I32Load16S,       0x2e, "i32.load16_s",         MemArg,      1)            \
  X(I32Load16U,       0x2f, "i32.load16_u",         MemArg,      1)            \
  X(I64Load8S,        0x30, "i64.load8_s",          MemArg,      0)            \
  X(I64Load8U,        0x31, "i64.load8_u",          MemArg,      0)            \
  X(I64Load16S,       0x32, "i64.load16_s",         MemArg,      1)            \
  X(I64Load16U,       0x33, "i64.load16_u",         MemArg,      1)            \
  X(I64Load32S,       0x34, "i64.load32_s",         MemArg,      2)            \
  X(I64Load32U,       0x35, "i64.load32_u",         MemArg,      2)            \
  X(I32Store,         0x36, "i32.store",            MemArg,      2)            \
  X(I64Store,         0x37, "i64.store",            MemArg,      3)            \
  X(F32Store,         0x38, "f32.store",            MemArg,      2)            \
  X(F64Store,         0x39, "f64.store",            MemArg,      3)            \
  X(I32Store8,        0x3a, "i32.store8",           MemArg,      0)            \
  X(I32Store16,       0x3b, "i32.store16",          MemArg,      1)            \
  X(I64Store8,        0x3c, "i64.store8",           MemArg,      0)            \
  X(I64Store16,       0x3d, "i64.store16",          MemArg,      1)            \
  X(I64Store32,       0x3e, "i64.store32",          MemArg,      2)            \
  X(MemorySize,       0x3f, "memory.size",          MemIdx,      0)            \
  X(MemoryGrow,       0x40, "memory.grow",          MemIdx,      0)            \
  X(I32Const,         0x41, "i32.const",            I32,         0)            \
  X(I64Const,         0x42, "i64.const",            I64,         0)            \
  X(F32Const,         0x43, "f32.const",            F32,         0)            \
  X(F64Const,         0x44, "f64.const",            F64,         0)            \
  X(I32Eqz,           0x45, "i32.eqz",              None,        0)            \
  X(I32Eq,            0x46, "i32.eq",               None,        0)            \
  X(I32Ne,            0x47, "i32.ne",               None,        0)            \
  X(I32LtS,           0x48, "i32.lt_s",             None,        0)            \
  X(I32LtU,           0x49, "i32.lt_u",             None,        0)            \
  X(I32GtS,           0x4a, "i32.gt_s",             None,        0)            \
  X(I32GtU,           0x4b, "i32.gt_u",             None,        0)            \
  X(I32LeS,           0x4c, "i32.le_s",             None,        0)            \
  X(I32LeU,           0x4d, "i32.le_u",             None,        0)            \
  X(I32GeS,           0x4e, "i32.ge_s",             None,        0)            \
  X(I32GeU,           0x4f, "i32.ge_u",             None,        0)            \
  X(I64Eqz,           0x50, "i64.eqz",              None,        0)            \
  X(I64Eq,            0x51, "i64.eq",               None,        0)            \
  X(I64Ne,            0x52, "i64.ne",               None,        0)            \
  X(I64LtS,           0x53, "i64.lt_s",             None,        0)            \
  X(I64LtU,           0x54, "i64.lt_u",             None,        0)            \
  X(I64GtS,           0x55, "i64.gt_s",             None,        0)            \
  X(I64GtU,           0x56, "i64.gt_u",             None,        0)            \
  X(I64LeS,           0x57, "i64.le_s",             None,        0)            \
  X(I64LeU,           0x58, "i64.le_u",             None,        0)            \
  X(I64GeS,           0x59, "i64.ge_s",             None,        0)            \
  X(I64GeU,           0x5a, "i64.ge_u",             None,        0)            \
  X(F32Eq,            0x5b, "f32.eq",               None,        0)            \
  X(F32Ne,            0x5c, "f32.ne",               None,        0)            \
  X(F32Lt,            0x5d, "f32.lt",               None,        0)            \
  X(F32Gt,            0x5e, "f32.gt",               None,        0)            \
  X(F32Le,            0x5f, "f32.le",               None,        0)            \
  X(F32Ge,            0x60, "f32.ge",               None,        0)            \
  X(F64Eq,            0x61, "f64.eq",               None,        0)            \
  X(F64Ne,            0x62, "f64.ne",               None,        0)            \
  X(F64Lt,            0x63, "f64.lt",               None,        0)            \
  X(F64Gt,            0x64, "f64.gt",               None,        0)            \
  X(F64Le,            0x65, "f64.le",               None,        0)            \
  X(F64Ge,            0x66, "f64.ge",               None,        0)            \
  X(I32Clz,           0x67, "i32.clz",              None,        0)            \
  X(I32Ctz,           0x68, "i32.ctz",              None,        0)            \
  X(I32Popcnt,        0x69, "i32.popcnt",           None,        0)            \
  X(I32Add,           0x6a, "i32.add",              None,        0)            \
  X(I32Sub,           0x6b, "i32.sub",              None,        0)            \
  X(I32Mul,           0x6c, "i32.mul",              None,        0)            \
  X(I32DivS,          0x6d, "i32.div_s",            None,        0)            \
  X(I32DivU,          0x6e, "i32.div_u",            None,        0)            \
  X(I32RemS,          0x6f, "i32.rem_s",            None,        0)            \
  X(I32RemU,          0x70, "i32.rem_u",            None,        0)            \
  X(I32And,           0x71, "i32.and",              None,        0)            \
  X(I32Or,            0x72, "i32.or",               None,        0)            \
  X(I32Xor,           0x73, "i32.xor",              None,        0)            \
  X(I32Shl,           0x74, "i32.shl",              None,        0)            \
  X(I32ShrS,          0x75, "i32.shr_s",            None,        0)            \
  X(I32ShrU,          0x76, "i32.shr_u",            None,        0)            \
  X(I32Rotl,          0x77, "i32.rotl",             None,        0)            \
  X(I32Rotr,          0x78, "i32.rotr",             None,        0)            \
  X(I64Clz,           0x79, "i64.clz",              None,        0)            \
  X(I64Ctz,           0x7a, "i64.ctz",              None,        0)            \
  X(I64Popcnt,        0x7b, "i64.popcnt",           None,        0)            \
  X(I64Add,           0x7c, "i64.add",              None,        0)            \
  X(I64Sub,           0x7d, "i64.sub",              None,        0)            \
  X(I64Mul,           0x7e, "i64.mul",              None,        0)            \
  X(I64DivS,          0x7f, "i64.div_s",            None,        0)            \
  X(I64DivU,          0x80, "i64.div_u",            None,        0)            \
  X(I64RemS,          0x81, "i64.rem_s",            None,        0)            \
  X(I64RemU,          0x82, "i64.rem_u",            None,        0)            \
  X(I64And,           0x83, "i64.and",              None,        0)            \
  X(I64Or,            0x84, "i64.or",               None,        0)            \
  X(I64Xor,           0x85, "i64.xor",              None,        0)            \
  X(I64Shl,           0x86, "i64.shl",              None,        0)            \
  X(I64ShrS,          0x87, "i64.shr_s",            None,        0)            \
  X(I64ShrU,          0x88, "i64.shr_u",            None,        0)            \
  X(I64Rotl,          0x89, "i64.rotl",             None,        0)            \
  X(I64Rotr,          0x8a, "i64.rotr",             None,        0)            \
  X(F32Abs,           0x8b, "f32.abs",              None,        0)            \
  X(F32Neg,           0x8c, "f32.neg",              None,        0)            \
  X(F32Ceil,          0x8d, "f32.ceil",             None,        0)            \
  X(F32Floor,         0x8e, "f32.floor",            None,        0)            \
  X(F32Trunc,         0x8f, "f32.trunc",            None,        0)            \
  X(F32Nearest,       0x90, "f32.nearest",          None,        0)            \
  X(F32Sqrt,          0x91, "f32.sqrt",             None,        0)            \
  X(F32Add,           0x92, "f32.add",              None,        0)            \
  X(F32Sub,           0x93, "f32.sub",              None,        0)            \
  X(F32Mul,           0x94, "f32.mul",              None,        0)            \
  X(F32Div,           0x95, "f32.div",              None,        0)            \
  X(F32Min,           0x96, "f32.min",              None,        0)            \
  X(F32Max,           0x97, "f32.max",              None,        0)            \
  X(F32Copysign,      0x98, "f32.copysign",         None,        0)            \
  X(F64Abs,           0x99, "f64.abs",              None,        0)            \
  X(F64Neg,           0x9a, "f64.neg",              None,        0)            \
  X(F64Ceil,          0x9b, "f64.ceil",             None,        0)            \
  X(F64Floor,         0x9c, "f64.floor",            None,        0)            \
  X(F64Trunc,         0x9d, "f64.trunc",            None,        0)            \
  X(F64Nearest,       0x9e, "f64.nearest",          None,        0)            \
  X(F64Sqrt,          0x9f, "f64.sqrt",             None,        0)            \
  X(F64Add,           0xa0, "f64.add",              None,        0)            \
  X(F64Sub,           0xa1, "f64.sub",              None,        0)            \
  X(F64Mul,           0xa2, "f64.mul",              None,        0)            \
  X(F64Div,           0xa3, "f64.div",              None,        0)            \
  X(F64Min,           0xa4, "f64.min",              None,        0)            \
  X(F64Max,           0xa5, "f64.max",              None,        0)            \
  X(F64Copysign,      0xa6, "f64.copysign",         None,        0)            \
  X(I32WrapI64,       0xa7, "i32.wrap_i64",         None,        0)            \
  X(I32TruncF32S,     0xa8, "i32.trunc_f32_s",      None,        0)            \
  X(I32TruncF32U,     0xa9, "i32.trunc_f32_u",      None,        0)            \
  X(I32TruncF64S,     0xaa, "i32.trunc_f64_s",      None,        0)            \
  X(I32TruncF64U,     0xab, "i32.trunc_f64_u",      None,        0)            \
  X(I64ExtendI32S,    0xac, "i64.extend_i32_s",     None,        0)            \
  X(I64ExtendI32U,    0xad, "i64.extend_i32_u",     None,        0)            \
  X(I64TruncF32S,     0xae, "i64.trunc_f32_s",      None,        0)            \
  X(I64TruncF32U,     0xaf, "i64.trunc_f32_u",      None,        0)            \
  X(I64TruncF64S,     0xb0, "i64.trunc_f64_s",      None,        0)            \
  X(I64TruncF64U,     0xb1, "i64.trunc_f64_u",      None,        0)            \
  X(F32ConvertI32S,   0xb2, "f32.convert_i32_s",    None,        0)            \
  X(F32ConvertI32U,   0xb3, "f32.convert_i32_u",    None,        0)            \
  X(F32ConvertI64S,   0xb4, "f32.convert_i64_s",    None,        0)            \
  X(F32ConvertI64U,   0xb5, "f32.convert_i64_u",    None,        0)            \
  X(F32DemoteF64,     0xb6, "f32.demote_f64",       None,        0)            \
  X(F64ConvertI32S,   0xb7, "f64.convert_i32_s",    None,        0)            \
  X(F64ConvertI32U,   0xb8, "f64.convert_i32_u",    None,        0)            \
  X(F64ConvertI64S,   0xb9, "f64.convert_i64_s",    None,        0)            \
  X(F64ConvertI64U,   0xba, "f64.convert_i64_u",    None,        0)            \
  X(F64PromoteF32,    0xbb, "f64.promote_f32",      None,        0)            \
  X(I32ReinterpretF32,0xbc, "i32.reinterpret_f32",  None,        0)            \
  X(I64ReinterpretF64,0xbd, "i64.reinterpret_f64",  None,        0)            \
  X(F32ReinterpretI32,0xbe, "f32.reinterpret_i32",  None,        0)            \
  X(F64ReinterpretI64,0xbf, "f64.reinterpret_i64",  None,        0)            \
  X(I32Extend8S,      0xc0, "i32.extend8_s",        None,        0)            \
  X(I32Extend16S,     0xc1, "i32.extend16_s",       None,        0)            \
  X(I64Extend8S,      0xc2, "i64.extend8_s",        None,        0)            \
  X(I64Extend16S,     0xc3, "i64.extend16_s",       None,        0)            \
  X(I64Extend32S,     0xc4, "i64.extend32_s",       None,        0)            \
  X(RefNull,          0xd0, "ref.null",             RefType,     0)            \
  X(RefIsNull,        0xd1, "ref.is_null",          None,        0)            \
  X(RefFunc,          0xd2, "ref.func",             Func,        0)            \
  X(I32TruncSatF32S,  0x100,"i32.trunc_sat_f32_s",  None,        0)            \
  X(I32TruncSatF32U,  0x101,"i32.trunc_sat_f32_u",  None,        0)            \
  X(I32TruncSatF64S,  0x102,"i32.trunc_sat_f64_s",  None,        0)            \
  X(I32TruncSatF64U,  0x103,"i32.trunc_sat_f64_u",  None,        0)            \
  X(I64TruncSatF32S,  0x104,"i64.trunc_sat_f32_s",  None,        0)            \
  X(I64TruncSatF32U,  0x105,"i64.trunc_sat_f32_u",  None,        0)            \
  X(I64TruncSatF64S,  0x106,"i64.trunc_sat_f64_s",  None,        0)            \
  X(I64TruncSatF64U,  0x107,"i64.trunc_sat_f64_u",  None,        0)            \
  X(MemoryInit,       0x108,"memory.init",          DataMem,     0)            \
  X(DataDrop,         0x109,"data.drop",            Data,        0)            \
  X(MemoryCopy,       0x10a,"memory.copy",          MemMem,      0)            \
  X(MemoryFill,       0x10b,"memory.fill",          MemIdx,      0)            \
  X(TableInit,        0x10c,"table.init",           ElemTable,   0)            \
  X(ElemDrop,         0x10d,"elem.drop",            Elem,        0)            \
  X(TableCopy,        0x10e,"table.copy",           TableTable,  0)            \
  X(TableGrow,        0x10f,"table.grow",           Table,       0)            \
  X(TableSize,        0x110,"table.size",           Table,       0)            \
  X(TableFill,        0x111,"table.fill",           Table,       0)                \
  /* Not in the language. Validation plans structured control flow away and     \
     leaves these two behind in its place; see :validate. They have no encoding \
     and no spelling in the text format, which is what `kFirstInternal` below   \
     protects. */                                                               \
  X(IfFalse,          0x180,"if.false",             None,        0)             \
  X(Jump,             0x181,"jump",                 None,        0)

enum class Op : u16 {
#define WEASEL_X(id, code, name, imm, al) id = code,
  WEASEL_OPCODES(WEASEL_X)
#undef WEASEL_X
};

struct OpInfo {
  Op op;
  std::string_view name;
  Imm imm;
  u8 natural_align;  // log2 of the access width, for memory instructions
};

inline constexpr OpInfo kOpTable[] = {
#define WEASEL_X(id, code, name, imm, al) OpInfo{Op::id, name, Imm::imm, al},
    WEASEL_OPCODES(WEASEL_X)
#undef WEASEL_X
};

inline constexpr std::size_t kOpCount = std::size(kOpTable);
inline constexpr u16 kOpSpace = 0x200;

// code -> index into kOpTable, or 0xffff. Dense, so decoding is one load.
inline constexpr auto kOpIndex = [] {
  std::array<u16, kOpSpace> t{};
  for (auto& e : t) e = 0xffff;
  for (u16 i = 0; i < kOpCount; ++i) t[static_cast<u16>(kOpTable[i].op)] = i;
  return t;
}();

inline bool op_exists(u16 code) {
  return code < kOpSpace && kOpIndex[code] != 0xffff;
}

inline const OpInfo& op_info(Op op) {
  return kOpTable[kOpIndex[static_cast<u16>(op)]];
}

inline std::string_view op_name(Op op) {
  const u16 c = static_cast<u16>(op);
  if (!op_exists(c)) return "?";
  return kOpTable[kOpIndex[c]].name;
}

// Instructions at or above this code are the planner's own and cannot be
// written, encoded or decoded.
inline constexpr u16 kFirstInternal = 0x180;
inline bool is_internal(Op op) { return static_cast<u16>(op) >= kFirstInternal; }

// The text format spells `select` two ways and they share a name; every other
// name is unique, so a linear scan that takes the first match is enough. The
// parser calls this once per token, and modules are small.
inline bool op_by_name(std::string_view name, Op& out) {
  for (const auto& e : kOpTable) {
    if (is_internal(e.op)) continue;
    if (e.name == name) {
      out = e.op;
      return true;
    }
  }
  return false;
}

}  // namespace weasel
