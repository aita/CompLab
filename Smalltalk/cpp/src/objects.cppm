// Object model partition — every value type of the interpreter.
//
// Immediate values (nil / Boolean / SmallInteger / Float) live inline in
// `Value`; everything else is a GC-managed `Object*` owned by the Heap (see the
// :heap partition). Activations (`Context`) and closures (`Block`) are objects
// too, so a captured frame stays alive as long as a closure references it —
// no shared_ptr, no reference counting.
module;
#include <cstdint>
#include <cstring>
#include <functional>
#include <span>
#include <string>
#include <unordered_map>
#include <vector>

export module st:objects;

import :bytecode;

export namespace st {

class VM;  // forward: primitives take a VM&

struct Object;

// A Smalltalk value, NaN-boxed into 8 bytes. A real double is stored directly;
// everything else is encoded in the payload of a quiet NaN. We require *two*
// high mantissa bits (bits 50-51) set to mark a boxed value, so ordinary
// hardware NaNs / infinities (only bit 51) still read back as doubles.
//
//   double   : (bits & QNAN) != QNAN
//   object   : sign + QNAN, payload = 48-bit pointer
//   int      : QNAN + INT_TAG, payload = 49-bit signed (SmallInteger range)
//   nil/bool : QNAN + a small constant
//
// SmallInteger is therefore ~48-bit; arithmetic that would exceed it raises a
// Smalltalk error rather than silently wrapping.
inline constexpr std::uint64_t kQNaN = 0x7ffc000000000000ULL;
inline constexpr std::uint64_t kSign = 0x8000000000000000ULL;
inline constexpr std::uint64_t kIntTag = 0x0002000000000000ULL;      // bit 49
inline constexpr std::uint64_t kIntPayload = 0x0001ffffffffffffULL;  // bits 0-48
inline constexpr std::uint64_t kPtrMask = 0x0000ffffffffffffULL;     // bits 0-47
inline constexpr std::uint64_t kNilBits = kQNaN | 1;
inline constexpr std::uint64_t kFalseBits = kQNaN | 2;
inline constexpr std::uint64_t kTrueBits = kQNaN | 3;

inline constexpr std::int64_t kSmallIntMax = (1LL << 48) - 1;
inline constexpr std::int64_t kSmallIntMin = -(1LL << 48);
inline constexpr bool fits_smallint(std::int64_t v) {
    return v >= kSmallIntMin && v <= kSmallIntMax;
}

class Value {
public:
    constexpr Value() : bits_(kNilBits) {}
    Value(bool b) : bits_(b ? kTrueBits : kFalseBits) {}
    Value(std::int64_t v)
        : bits_(kQNaN | kIntTag | (static_cast<std::uint64_t>(v) & kIntPayload)) {}
    Value(double d) { std::memcpy(&bits_, &d, sizeof(bits_)); }
    Value(Object* o)
        : bits_(kSign | kQNaN | (reinterpret_cast<std::uint64_t>(o) & kPtrMask)) {}

    static constexpr Value from_bits(std::uint64_t b) { return Value(b, Raw{}); }
    std::uint64_t bits() const { return bits_; }
    bool operator==(const Value& o) const { return bits_ == o.bits_; }

private:
    struct Raw {};
    constexpr Value(std::uint64_t b, Raw) : bits_(b) {}
    std::uint64_t bits_;
};

constexpr Value nil() { return Value::from_bits(kNilBits); }
inline Value ref(Object* o) { return Value{o}; }

// --- immediate accessors ---
inline bool is_double(const Value& v) { return (v.bits() & kQNaN) != kQNaN; }
inline bool is_obj(const Value& v) {
    return (v.bits() & (kSign | kQNaN)) == (kSign | kQNaN);
}
inline Object* as_obj(const Value& v) {
    return is_obj(v) ? reinterpret_cast<Object*>(v.bits() & kPtrMask) : nullptr;
}
inline bool is_int(const Value& v) {
    return (v.bits() & (kSign | kQNaN | kIntTag)) == (kQNaN | kIntTag);
}
inline bool is_float(const Value& v) { return is_double(v); }
inline bool is_bool(const Value& v) {
    return v.bits() == kTrueBits || v.bits() == kFalseBits;
}
inline bool is_nil(const Value& v) { return v.bits() == kNilBits; }

inline bool as_bool(const Value& v) { return v.bits() == kTrueBits; }
inline std::int64_t as_int(const Value& v) {
    std::uint64_t p = v.bits() & kIntPayload;  // 49-bit, sign at bit 48
    return static_cast<std::int64_t>(p << 15) >> 15;
}
inline double as_double(const Value& v) {
    double d;
    std::uint64_t b = v.bits();
    std::memcpy(&d, &b, sizeof(d));
    return d;
}

enum class Tag {
    String,
    Symbol,
    Character,
    Array,
    Dictionary,
    Class,
    Instance,
    CompiledMethod,
    CompiledBlock,
    Block,
    Context,
};

struct Object {
    Tag tag;
    bool marked = false;
    Object* gc_next = nullptr;
    explicit Object(Tag t) : tag(t) {}
    Object(const Object&) = delete;
    Object& operator=(const Object&) = delete;
    virtual ~Object() = default;
};

// Downcast a Value to a specific object type, or nullptr.
template <class T>
T* as(const Value& v) {
    Object* o = as_obj(v);
    return (o != nullptr && o->tag == T::TAG) ? static_cast<T*>(o) : nullptr;
}

struct String : Object {
    static constexpr Tag TAG = Tag::String;
    std::string data;
    explicit String(std::string s) : Object(TAG), data(std::move(s)) {}
};

struct Symbol : Object {
    static constexpr Tag TAG = Tag::Symbol;
    std::string data;
    explicit Symbol(std::string s) : Object(TAG), data(std::move(s)) {}
};

struct Character : Object {
    static constexpr Tag TAG = Tag::Character;
    char value;
    explicit Character(char c) : Object(TAG), value(c) {}
};

struct Array : Object {
    static constexpr Tag TAG = Tag::Array;
    std::vector<Value> items;
    Array() : Object(TAG) {}
};

// Hash/equality for Dictionary keys: numbers by value, Strings by content,
// Symbols/Characters by content (symbols are interned), other objects by
// identity. Keys of different immediate kinds never compare equal.
struct ValueHash {
    std::size_t operator()(const Value& v) const {
        if (Object* o = as_obj(v)) {
            if (o->tag == Tag::String) return std::hash<std::string>{}(static_cast<String*>(o)->data);
            if (o->tag == Tag::Character) return std::hash<char>{}(static_cast<Character*>(o)->value);
            return std::hash<std::uint64_t>{}(v.bits());  // symbol/other: identity
        }
        return std::hash<std::uint64_t>{}(v.bits());  // nil/bool/int/double
    }
};
struct ValueEq {
    bool operator()(const Value& a, const Value& b) const {
        Object* oa = as_obj(a);
        Object* ob = as_obj(b);
        if (oa != nullptr && ob != nullptr) {
            if (oa->tag != ob->tag) return false;
            if (oa->tag == Tag::String)
                return static_cast<String*>(oa)->data == static_cast<String*>(ob)->data;
            if (oa->tag == Tag::Character)
                return static_cast<Character*>(oa)->value == static_cast<Character*>(ob)->value;
            return oa == ob;  // symbols (interned) and other objects: identity
        }
        if (oa != nullptr || ob != nullptr) return false;
        return a.bits() == b.bits();  // both immediates: nil/bool/int/double
    }
};

struct Dict : Object {
    static constexpr Tag TAG = Tag::Dictionary;
    std::unordered_map<Value, Value, ValueHash, ValueEq> map;
    Dict() : Object(TAG) {}
};

struct CompiledMethod;

// A method is a C++ primitive or a compiled bytecode method. Arguments are a
// span over the caller's operand stack — no per-send vector is allocated.
using PrimFn = Value (*)(VM&, const Value&, std::span<Value>);

struct Method {
    PrimFn prim = nullptr;
    CompiledMethod* compiled = nullptr;
    bool is_primitive() const { return prim != nullptr; }
    bool present() const { return prim != nullptr || compiled != nullptr; }
};

struct Class : Object {
    static constexpr Tag TAG = Tag::Class;
    std::string name;
    Class* superclass = nullptr;
    std::vector<std::string> ivar_names;
    // Method dictionaries are keyed by interned Symbol identity (pointer), so
    // lookup hashes a pointer, not a string. The VM's per-call-site inline
    // cache sits on top of this for the hot path.
    std::unordered_map<Symbol*, Method> methods;
    std::unordered_map<Symbol*, Method> class_methods;

    explicit Class(std::string n) : Object(TAG), name(std::move(n)) {}

    Method* lookup(Symbol* sel) {
        for (Class* c = this; c != nullptr; c = c->superclass) {
            auto it = c->methods.find(sel);
            if (it != c->methods.end()) return &it->second;
        }
        return nullptr;
    }
    Method* lookup_class(Symbol* sel) {
        for (Class* c = this; c != nullptr; c = c->superclass) {
            auto it = c->class_methods.find(sel);
            if (it != c->class_methods.end()) return &it->second;
        }
        return nullptr;
    }
    bool is_kind_of(Class* other) {
        for (Class* c = this; c != nullptr; c = c->superclass) {
            if (c == other) return true;
        }
        return false;
    }
    std::vector<std::string> all_ivars() {
        std::vector<Class*> chain;
        for (Class* c = this; c != nullptr; c = c->superclass) chain.push_back(c);
        std::vector<std::string> out;
        for (auto it = chain.rbegin(); it != chain.rend(); ++it) {
            for (const auto& n : (*it)->ivar_names) out.push_back(n);
        }
        return out;
    }
};

struct Instance : Object {
    static constexpr Tag TAG = Tag::Instance;
    Class* st_class;
    std::unordered_map<std::string, Value> ivars;
    explicit Instance(Class* c) : Object(TAG), st_class(c) {}
};

struct CompiledMethod : Object {
    static constexpr Tag TAG = Tag::CompiledMethod;
    std::string selector;
    std::vector<std::string> params;
    std::vector<std::string> local_names;
    std::vector<Instr> code;
    std::vector<Value> literals;
    std::string source;
    Class* defined_in = nullptr;
    CompiledMethod() : Object(TAG) {}
    int num_args() const { return static_cast<int>(params.size()); }
};

struct CompiledBlock : Object {
    static constexpr Tag TAG = Tag::CompiledBlock;
    std::vector<std::string> params;
    std::vector<std::string> local_names;
    std::vector<Instr> code;
    std::vector<Value> literals;
    CompiledBlock() : Object(TAG) {}
    int num_args() const { return static_cast<int>(params.size()); }
};

struct Context;

struct Block : Object {
    static constexpr Tag TAG = Tag::Block;
    CompiledBlock* tmpl;
    Context* outer;
    Context* home;
    Block(CompiledBlock* t, Context* o, Context* h)
        : Object(TAG), tmpl(t), outer(o), home(h) {}
    int num_args() const { return tmpl->num_args(); }
};

// A method or block activation, reified as an object so closures keep it alive.
struct Context : Object {
    static constexpr Tag TAG = Tag::Context;
    Value receiver = nil();
    Object* method = nullptr;  // CompiledMethod* or CompiledBlock*
    std::vector<Value> locals;
    std::vector<Value> stack;
    Context* outer = nullptr;
    Context* sender = nullptr;
    Context* home = nullptr;
    int ip = 0;
    bool is_block = false;
    Context() : Object(TAG) {}
};

inline std::vector<Instr>& code_of(Object* method) {
    return method->tag == Tag::CompiledMethod
               ? static_cast<CompiledMethod*>(method)->code
               : static_cast<CompiledBlock*>(method)->code;
}
inline std::vector<Value>& literals_of(Object* method) {
    return method->tag == Tag::CompiledMethod
               ? static_cast<CompiledMethod*>(method)->literals
               : static_cast<CompiledBlock*>(method)->literals;
}

// --- printing ---

std::string print_string(const Value& v);

inline std::string print_object(Object* o) {
    switch (o->tag) {
        case Tag::String:
            return "'" + static_cast<String*>(o)->data + "'";
        case Tag::Symbol:
            return "#" + static_cast<Symbol*>(o)->data;
        case Tag::Character:
            return std::string("$") + static_cast<Character*>(o)->value;
        case Tag::Array: {
            std::string s = "(";
            for (const auto& e : static_cast<Array*>(o)->items)
                s += print_string(e) + " ";
            return s + ")";
        }
        case Tag::Dictionary: {
            std::string s = "a Dictionary (";
            for (const auto& [k, v] : static_cast<Dict*>(o)->map)
                s += print_string(k) + "->" + print_string(v) + " ";
            return s + ")";
        }
        case Tag::Class:
            return static_cast<Class*>(o)->name;
        case Tag::Instance: {
            auto* inst = static_cast<Instance*>(o);
            const std::string& n = inst->st_class->name;
            if (n == "OrderedCollection") {
                std::string s = "OrderedCollection (";
                auto it = inst->ivars.find("items");
                if (it != inst->ivars.end())
                    if (auto* arr = as<Array>(it->second))
                        for (const auto& e : arr->items) s += print_string(e) + " ";
                return s + ")";
            }
            bool vowel = !n.empty() &&
                         std::string("AEIOU").find(n[0]) != std::string::npos;
            return (vowel ? "an " : "a ") + n;
        }
        case Tag::Block:
            return "a BlockClosure";
        default:
            return "an Object";
    }
}

inline std::string print_string(const Value& v) {
    if (is_nil(v)) return "nil";
    if (is_bool(v)) return as_bool(v) ? "true" : "false";
    if (is_int(v)) return std::to_string(as_int(v));
    if (is_double(v)) return std::to_string(as_double(v));
    return print_object(as_obj(v));
}

inline std::string display_string(const Value& v) {
    if (auto* s = as<String>(v)) return s->data;
    if (auto* y = as<Symbol>(v)) return y->data;
    if (auto* c = as<Character>(v)) return std::string(1, c->value);
    return print_string(v);
}

}  // namespace st
