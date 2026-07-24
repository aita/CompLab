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

  // Mark-sweep: set the GC bit on this value's object, and on everything it
  // holds. Which tags carry an object, and that a list has children, is the
  // value's own knowledge -- the collector only supplies the roots. Body is
  // below, once Object is a complete type.
  void gc_mark() const;
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

inline void Value::gc_mark() const {
  if (tag != Tag::Str && tag != Tag::List && tag != Tag::Func) return;
  if (obj->marked) return;       // already reached: ends cycles and sharing
  obj->marked = true;
  if (tag == Tag::List)
    for (const Value& e : obj->list) e.gc_mark();
}

// Where a List's elements live inside an Object, so the JIT can inline the fast
// path of `xs[i]` / `len(xs)` instead of calling back into C++.
//
// A std::vector's first two pointer-sized words are its begin and end pointers
// on both libstdc++ and libc++ -- but that is an implementation detail, so it is
// measured at run time on a real object and then *verified*. If the check ever
// fails, `ok` stays false and the JITs simply keep calling the helper.
struct ListLayout {
  std::size_t list_off = 0;  // offsetof(Object, list)
  bool ok = false;
  ListLayout();
};

inline const ListLayout& list_layout() {
  static const ListLayout layout;
  return layout;
}

inline ListLayout::ListLayout() {
  Object probe;
  probe.kind = Object::Kind::List;
  probe.list.resize(3);
  const char* base = reinterpret_cast<const char*>(&probe);
  list_off = static_cast<std::size_t>(
      reinterpret_cast<const char*>(&probe.list) - base);
  Value* const* words =
      reinterpret_cast<Value* const*>(base + list_off);
  ok = words[0] == probe.list.data() &&
       words[1] == probe.list.data() + probe.list.size();
}

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
