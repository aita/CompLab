// Value partition — MinPython runtime values.
//
// A Value is a 16-byte tagged POD: a 1-byte tag at offset 0 and an 8-byte
// payload at offset 8 (int64 for Int/Bool, or an Object* for the heap types).
// That fixed layout is what lets the JIT read and write values straight out of
// the register array in machine code -- the type guard is `cmp byte [reg], Int`
// and the unboxed integer is `[reg + 8]`, no boxing at the native boundary.
//
// Object (str / list / function) payloads are owned by an arena on the VM and
// live until the VM is destroyed. MinPython programs are short-lived scripts, so
// this trades a real GC for a few lines of code; the JIT only ever touches Int
// values, so it never has to reason about object lifetimes.
export module minpython:value;

import std;

export namespace minpython {

// A latched error, used instead of exceptions (this project builds with
// -fno-exceptions, matching the sibling Smalltalk C++). The frontend and VM
// share one Diag; the first failure wins and later passes bail early on it.
struct Diag {
  bool failed = false;
  std::string message;
  void fail(std::string m) {
    if (!failed) {
      failed = true;
      message = std::move(m);
    }
  }
};

struct CodeObject;
struct Object;
struct Value;
using Globals = std::unordered_map<std::string, Value>;

enum class Tag : std::uint8_t {
  None = 0,
  Int = 1,
  Bool = 2,
  Str = 3,
  List = 4,
  Func = 5,
};

struct Value {
  Tag tag;
  union {
    std::int64_t i;    // Int, Bool
    Object* obj;  // Str, List, Func
  };

  Value() : tag(Tag::None), i(0) {}

  static Value none() { return Value(); }
  static Value integer(std::int64_t v) {
    Value x;
    x.tag = Tag::Int;
    x.i = v;
    return x;
  }
  static Value boolean(bool v) {
    Value x;
    x.tag = Tag::Bool;
    x.i = v ? 1 : 0;
    return x;
  }
  static Value object(Tag t, Object* o) {
    Value x;
    x.tag = t;
    x.obj = o;
    return x;
  }

  bool is_int_like() const { return tag == Tag::Int || tag == Tag::Bool; }
};

static_assert(sizeof(Value) == 16, "Value must be 16 bytes for the JIT layout");

// Byte offsets the JIT bakes into its loads/stores.
inline constexpr int kValueSize = 16;
inline constexpr int kTagOffset = 0;
inline constexpr int kPayloadOffset = 8;

// A heap object: exactly one of the members is meaningful per `kind`.
struct Object {
  enum class Kind { Str, List, Func };
  Kind kind;
  bool marked = false;      // mark-sweep GC bit
  std::string str;          // Str
  std::vector<Value> list;  // List
  const CodeObject* code;   // Func
  Globals* globals;         // Func
};

inline bool truthy(const Value& v) {
  switch (v.tag) {
    case Tag::None:
      return false;
    case Tag::Int:
    case Tag::Bool:
      return v.i != 0;
    case Tag::Str:
      return !v.obj->str.empty();
    case Tag::List:
      return !v.obj->list.empty();
    case Tag::Func:
      return true;
  }
  return false;
}

}  // namespace minpython
