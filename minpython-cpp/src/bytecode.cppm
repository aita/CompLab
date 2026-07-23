// Bytecode partition — a C++ port of minpython/bytecode.py.
//
// A register machine (Lua-style): every instruction names the registers it reads
// and writes, so `x = a + b` is one `ADD dst, a, b`. Each function compiles to a
// CodeObject: a flat register file (locals low, temporaries above), a constant
// pool, a global-name pool, and the instruction array. Instructions are 4-tuples
// (op, a, b, c) with unused operands left 0.
export module minpython:bytecode;

import std;

import :value;

export namespace minpython {

enum class Op : std::uint8_t {
  // value movement: dst <- ...
  LoadConst = 1,     // a=dst, b=const-pool index
  LoadGlobal = 2,    // a=dst, b=name-pool index
  StoreGlobal = 3,   // a=name-pool index, b=src
  Move = 4,          // a=dst, b=src
  MakeFunction = 5,  // a=dst, b=const index holding the child CodeObject

  // binary arithmetic: dst <- b <op> c
  Add = 10,
  Sub = 11,
  Mul = 12,
  FloorDiv = 13,
  Mod = 14,
  Pow = 15,
  BitAnd = 16,
  BitOr = 17,
  BitXor = 18,
  LShift = 19,
  RShift = 20,

  // unary: dst <- <op> b
  Neg = 30,
  Pos = 31,
  Invert = 32,
  Not = 33,

  // comparison: dst <- (b <cmp> c) -> bool
  Eq = 40,
  Ne = 41,
  Lt = 42,
  Le = 43,
  Gt = 44,
  Ge = 45,

  // control flow
  Jump = 50,         // a=target pc
  JumpIfFalse = 51,  // a=cond reg, b=target pc
  JumpIfTrue = 52,   // a=cond reg, b=target pc

  // calls / builtins
  Call = 60,    // a=dst, b=func reg, c=argc (args in func+1 .. func+argc)
  Return = 61,  // a=src
  Print = 62,   // a=arg base, b=argc

  // object types (str / list) -- always interpreted, never JIT-compiled
  MakeList = 63,  // a=dst, b=base, c=count (regs[a] = regs[b .. b+count])
  Subscr = 64,    // a=dst, b=obj, c=idx    (regs[a] = regs[b][regs[c]])
  Len = 65,       // a=dst, b=src           (regs[a] = len(regs[b]))
};

struct Instr {
  Op op;
  int a = 0;
  int b = 0;
  int c = 0;
};

// What the interpreter has actually seen at one bytecode site. The optimizing
// compiler reads this instead of guessing: a site that only ever saw ints gets
// the inline integer path, one that never did skips it, and a call site with a
// single callee can be made a direct native call.
struct SiteFeedback {
  std::uint8_t tags_b = 0;   // bitmask over Tag, for operand b (or a, for jumps)
  std::uint8_t tags_c = 0;   // ... for operand c
  const void* callee = nullptr;  // CALL: the one callee seen, if monomorphic
  bool polymorphic = false;      // CALL: more than one callee seen
};

inline std::uint8_t tag_bit(Value v) { return (std::uint8_t)(1u << (int)v.tag); }
inline bool only_int_like(std::uint8_t seen) {
  constexpr std::uint8_t kIntLike =
      (1u << (int)Tag::Int) | (1u << (int)Tag::Bool);
  return seen != 0 && (seen & ~kIntLike) == 0;
}

struct CodeObject {
  std::string name;
  std::vector<std::string> params;
  int n_locals = 0;
  int n_regs = 0;
  std::vector<Value> consts;
  std::vector<const CodeObject*> const_codes;  // by const index; null if scalar
  std::vector<std::string> names;              // global-name pool
  std::vector<Instr> code;
  std::vector<std::string> local_names;
  std::vector<SiteFeedback> feedback;  // one per instruction; filled by the VM
};

inline bool is_binop(Op op) { return op >= Op::Add && op <= Op::RShift; }
inline bool is_unaryop(Op op) { return op >= Op::Neg && op <= Op::Not; }
inline bool is_cmpop(Op op) { return op >= Op::Eq && op <= Op::Ge; }

inline const char* op_name(Op op) {
  switch (op) {
    case Op::LoadConst: return "LOAD_CONST";
    case Op::LoadGlobal: return "LOAD_GLOBAL";
    case Op::StoreGlobal: return "STORE_GLOBAL";
    case Op::Move: return "MOVE";
    case Op::MakeFunction: return "MAKE_FUNCTION";
    case Op::Add: return "ADD";
    case Op::Sub: return "SUB";
    case Op::Mul: return "MUL";
    case Op::FloorDiv: return "FLOORDIV";
    case Op::Mod: return "MOD";
    case Op::Pow: return "POW";
    case Op::BitAnd: return "BIT_AND";
    case Op::BitOr: return "BIT_OR";
    case Op::BitXor: return "BIT_XOR";
    case Op::LShift: return "LSHIFT";
    case Op::RShift: return "RSHIFT";
    case Op::Neg: return "NEG";
    case Op::Pos: return "POS";
    case Op::Invert: return "INVERT";
    case Op::Not: return "NOT";
    case Op::Eq: return "EQ";
    case Op::Ne: return "NE";
    case Op::Lt: return "LT";
    case Op::Le: return "LE";
    case Op::Gt: return "GT";
    case Op::Ge: return "GE";
    case Op::Jump: return "JUMP";
    case Op::JumpIfFalse: return "JUMP_IF_FALSE";
    case Op::JumpIfTrue: return "JUMP_IF_TRUE";
    case Op::Call: return "CALL";
    case Op::Return: return "RETURN";
    case Op::Print: return "PRINT";
    case Op::MakeList: return "MAKE_LIST";
    case Op::Subscr: return "SUBSCR";
    case Op::Len: return "LEN";
  }
  return "?";
}

inline std::string disassemble(const CodeObject& code, bool recurse = true) {
  std::string out =
      std::format("{}({})  [{} locals, {} regs]\n", code.name,
                  [&] {
                    std::string s;
                    for (std::size_t i = 0; i < code.params.size(); ++i)
                      s += (i ? ", " : "") + code.params[i];
                    return s;
                  }(),
                  code.n_locals, code.n_regs);
  std::vector<const CodeObject*> nested;
  for (std::size_t pc = 0; pc < code.code.size(); ++pc) {
    const Instr& ins = code.code[pc];
    out += std::format("  {:>4}  {:<14} {}, {}, {}\n", pc, op_name(ins.op),
                       ins.a, ins.b, ins.c);
    if (ins.op == Op::MakeFunction && ins.b < (int)code.const_codes.size() &&
        code.const_codes[ins.b])
      nested.push_back(code.const_codes[ins.b]);
  }
  if (recurse)
    for (const CodeObject* child : nested)
      out += "\n" + disassemble(*child, true);
  return out;
}

}  // namespace minpython
