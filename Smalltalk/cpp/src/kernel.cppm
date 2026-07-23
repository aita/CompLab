// Kernel partition — base classes and their primitive methods.
//
// Primitives are leaf operations (arithmetic, identity, new, I/O); none re-enter
// the VM to run a block, so the driver loop never nests and no exceptions are
// needed. Block-taking control flow is inlined by the compiler instead.
module;
#include <cctype>
#include <cstdint>
#include <string>
#include <variant>
#include <vector>

export module st:kernel;

import :objects;
import :vm;
import :heap;

export namespace st {

namespace kdetail {

inline bool as_num(const Value& v, double& out) {
    if (auto* i = std::get_if<std::int64_t>(&v)) { out = static_cast<double>(*i); return true; }
    if (auto* d = std::get_if<double>(&v)) { out = *d; return true; }
    return false;
}
inline std::int64_t as_i(const Value& v) { return std::get<std::int64_t>(v); }

inline Array* oc_items(const Value& r) {
    Instance* inst = as<Instance>(r);
    auto it = inst->ivars.find("items");
    return it == inst->ivars.end() ? nullptr : as<Array>(it->second);
}

inline bool identical(const Value& a, const Value& b) {
    if (is_obj(a) || is_obj(b)) return as_obj(a) == as_obj(b);
    return a == b;
}
inline bool st_equal(VM&, const Value& a, const Value& b) {
    double x, y;
    if (as_num(a, x) && as_num(b, y)) return x == y;
    if (auto* sa = as<String>(a)) { auto* sb = as<String>(b); return sb && sa->data == sb->data; }
    return identical(a, b);
}

}  // namespace kdetail

void build_kernel(VM& vm) {
    using namespace kdetail;
    Heap& heap = vm.heap();

    auto cls = [&](const char* name, Class* super,
                   std::vector<std::string> ivars = {}) -> Class* {
        Class* c = heap.new_class(name);
        c->superclass = super;
        c->ivar_names = std::move(ivars);
        vm.register_class(c);
        return c;
    };
    auto def = [&](Class* c, const char* sel, PrimFn fn) {
        c->methods[sel] = Method{fn, nullptr};
    };
    auto cdef = [&](Class* c, const char* sel, PrimFn fn) {
        c->class_methods[sel] = Method{fn, nullptr};
    };

    Class* Object = cls("Object", nullptr);
    cls("UndefinedObject", Object);
    Class* Boolean = cls("Boolean", Object);
    Class* True = cls("True", Boolean);
    Class* False = cls("False", Boolean);
    cls("Class", Object);
    Class* Magnitude = cls("Magnitude", Object);
    Class* Number = cls("Number", Magnitude);
    Class* Integer = cls("Integer", Number);
    cls("SmallInteger", Integer);
    cls("Float", Number);
    Class* Char = cls("Character", Magnitude);
    Class* Collection = cls("Collection", Object);
    Class* Seq = cls("SequenceableCollection", Collection);
    Class* Array_ = cls("Array", Seq);
    Class* String_ = cls("String", Seq);
    cls("Symbol", String_);
    Class* OrderedCollection = cls("OrderedCollection", Seq, {"items"});
    Class* BlockClosure = cls("BlockClosure", Object);
    Class* Transcript = cls("Transcript", Object);
    cls("Context", Object);

    // --- Object ---
    def(Object, "==", [](VM&, const Value& r, std::vector<Value>& a) -> Value {
        return Value{identical(r, a[0])};
    });
    def(Object, "~~", [](VM&, const Value& r, std::vector<Value>& a) -> Value {
        return Value{!identical(r, a[0])};
    });
    def(Object, "=", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        return Value{st_equal(vm, r, a[0])};
    });
    def(Object, "~=", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        return Value{!st_equal(vm, r, a[0])};
    });
    def(Object, "isNil", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        return Value{is_nil(r)};
    });
    def(Object, "notNil", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        return Value{!is_nil(r)};
    });
    def(Object, "yourself", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        return r;
    });
    def(Object, "class", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        return ref(vm.class_of(r));
    });
    def(Object, "printString", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        return ref(vm.heap().new_string(print_string(r)));
    });
    def(Object, "displayString", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        return ref(vm.heap().new_string(display_string(r)));
    });
    def(Object, "printNl", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        vm.write(print_string(r) + "\n");
        return r;
    });
    def(Object, "displayNl", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        vm.write(display_string(r) + "\n");
        return r;
    });
    def(Object, "error:", [](VM& vm, const Value&, std::vector<Value>& a) -> Value {
        vm.fail(display_string(a[0]));
        return nil();
    });
    def(Object, "isKindOf:", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        Class* c = as<Class>(a[0]);
        return Value{c != nullptr && vm.class_of(r)->is_kind_of(c)};
    });
    cdef(Object, "new", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        return ref(vm.heap().new_instance(as<Class>(r)));
    });
    cdef(Object, "basicNew", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        return ref(vm.heap().new_instance(as<Class>(r)));
    });
    cdef(Object, "name", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        return ref(vm.heap().new_string(as<Class>(r)->name));
    });
    cdef(Object, "superclass", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        Class* s = as<Class>(r)->superclass;
        return s != nullptr ? ref(s) : nil();
    });

    // --- Boolean ---
    def(Boolean, "not", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        return Value{!std::get<bool>(r)};
    });
    def(Boolean, "&", [](VM&, const Value& r, std::vector<Value>& a) -> Value {
        return Value{std::get<bool>(r) && std::get<bool>(a[0])};
    });
    def(Boolean, "|", [](VM&, const Value& r, std::vector<Value>& a) -> Value {
        return Value{std::get<bool>(r) || std::get<bool>(a[0])};
    });
    def(True, "printString", [](VM& vm, const Value&, std::vector<Value>&) -> Value {
        return ref(vm.heap().new_string("true"));
    });
    def(False, "printString", [](VM& vm, const Value&, std::vector<Value>&) -> Value {
        return ref(vm.heap().new_string("false"));
    });

    // --- Number / Integer ---
    def(Number, "+", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        if (is_int(r) && is_int(a[0])) return Value{as_i(r) + as_i(a[0])};
        double x, y; if (as_num(r, x) && as_num(a[0], y)) return Value{x + y};
        vm.fail("+ expects a Number"); return nil();
    });
    def(Number, "-", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        if (is_int(r) && is_int(a[0])) return Value{as_i(r) - as_i(a[0])};
        double x, y; if (as_num(r, x) && as_num(a[0], y)) return Value{x - y};
        vm.fail("- expects a Number"); return nil();
    });
    def(Number, "*", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        if (is_int(r) && is_int(a[0])) return Value{as_i(r) * as_i(a[0])};
        double x, y; if (as_num(r, x) && as_num(a[0], y)) return Value{x * y};
        vm.fail("* expects a Number"); return nil();
    });
    def(Number, "/", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        double x, y;
        if (!as_num(r, x) || !as_num(a[0], y)) { vm.fail("/ expects a Number"); return nil(); }
        if (y == 0) { vm.fail("ZeroDivide"); return nil(); }
        if (is_int(r) && is_int(a[0]) && as_i(a[0]) != 0 && as_i(r) % as_i(a[0]) == 0)
            return Value{as_i(r) / as_i(a[0])};
        return Value{x / y};
    });
    def(Number, "<", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        double x, y; if (as_num(r, x) && as_num(a[0], y)) return Value{x < y};
        vm.fail("< expects a Number"); return nil();
    });
    def(Number, ">", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        double x, y; if (as_num(r, x) && as_num(a[0], y)) return Value{x > y};
        vm.fail("> expects a Number"); return nil();
    });
    def(Number, "<=", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        double x, y; if (as_num(r, x) && as_num(a[0], y)) return Value{x <= y};
        vm.fail("<= expects a Number"); return nil();
    });
    def(Number, ">=", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        double x, y; if (as_num(r, x) && as_num(a[0], y)) return Value{x >= y};
        vm.fail(">= expects a Number"); return nil();
    });
    def(Number, "=", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        return Value{st_equal(vm, r, a[0])};
    });
    def(Number, "negated", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        if (is_int(r)) return Value{-as_i(r)};
        double x; if (as_num(r, x)) return Value{-x};
        vm.fail("negated expects a Number"); return nil();
    });
    def(Number, "abs", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        if (is_int(r)) return Value{as_i(r) < 0 ? -as_i(r) : as_i(r)};
        double x; if (as_num(r, x)) return Value{x < 0 ? -x : x};
        vm.fail("abs expects a Number"); return nil();
    });
    def(Number, "asFloat", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        double x; if (as_num(r, x)) return Value{x};
        vm.fail("asFloat expects a Number"); return nil();
    });
    def(Integer, "factorial", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        if (!is_int(r)) { vm.fail("factorial expects an Integer"); return nil(); }
        std::int64_t n = as_i(r), f = 1;
        for (std::int64_t i = 2; i <= n; ++i) f *= i;
        return Value{f};
    });
    def(Integer, "//", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        if (is_int(r) && is_int(a[0]) && as_i(a[0]) != 0) {
            std::int64_t x = as_i(r), y = as_i(a[0]);
            std::int64_t q = x / y;
            if ((x % y != 0) && ((x < 0) != (y < 0))) --q;  // floor division
            return Value{q};
        }
        vm.fail("// expects Integers"); return nil();
    });
    def(Integer, "\\\\", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        if (is_int(r) && is_int(a[0]) && as_i(a[0]) != 0) {
            std::int64_t x = as_i(r), y = as_i(a[0]);
            std::int64_t m = x % y;
            if (m != 0 && ((m < 0) != (y < 0))) m += y;
            return Value{m};
        }
        vm.fail("\\\\ expects Integers"); return nil();
    });
    def(Integer, "even", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        return Value{as_i(r) % 2 == 0};
    });
    def(Integer, "odd", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        return Value{as_i(r) % 2 != 0};
    });

    // --- String / Symbol ---
    def(String_, ",", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        return ref(vm.heap().new_string(as<String>(r)->data + display_string(a[0])));
    });
    def(String_, "size", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        return Value{static_cast<std::int64_t>(as<String>(r)->data.size())};
    });
    def(String_, "=", [](VM&, const Value& r, std::vector<Value>& a) -> Value {
        auto* b = as<String>(a[0]);
        return Value{b != nullptr && as<String>(r)->data == b->data};
    });
    def(String_, "asUppercase", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        std::string s = as<String>(r)->data;
        for (char& c : s) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
        return ref(vm.heap().new_string(std::move(s)));
    });
    def(String_, "asSymbol", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        return ref(vm.heap().intern_symbol(as<String>(r)->data));
    });
    def(String_, "asString", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        return ref(vm.heap().new_string(display_string(r)));
    });
    def(String_, "at:", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        const std::string& s = as<String>(r)->data;
        std::int64_t i = is_int(a[0]) ? as_i(a[0]) : 0;
        if (i < 1 || i > static_cast<std::int64_t>(s.size())) {
            vm.fail("index out of bounds"); return nil();
        }
        return ref(vm.heap().new_char(s[i - 1]));
    });

    // --- Character ---
    def(Char, "asInteger", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        return Value{static_cast<std::int64_t>(
            static_cast<unsigned char>(as<Character>(r)->value))};
    });
    def(Char, "value", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        return Value{static_cast<std::int64_t>(
            static_cast<unsigned char>(as<Character>(r)->value))};
    });
    def(Char, "asString", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        return ref(vm.heap().new_string(std::string(1, as<Character>(r)->value)));
    });
    def(Char, "asUppercase", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        char c = static_cast<char>(std::toupper(
            static_cast<unsigned char>(as<Character>(r)->value)));
        return ref(vm.heap().new_char(c));
    });
    def(Char, "=", [](VM&, const Value& r, std::vector<Value>& a) -> Value {
        auto* b = as<Character>(a[0]);
        return Value{b != nullptr && as<Character>(r)->value == b->value};
    });
    def(Char, "<", [](VM&, const Value& r, std::vector<Value>& a) -> Value {
        return Value{as<Character>(r)->value < as<Character>(a[0])->value};
    });
    cdef(Char, "value:", [](VM& vm, const Value&, std::vector<Value>& a) -> Value {
        return ref(vm.heap().new_char(static_cast<char>(is_int(a[0]) ? as_i(a[0]) : 0)));
    });

    // --- Array ---
    cdef(Array_, "new", [](VM& vm, const Value&, std::vector<Value>&) -> Value {
        return ref(vm.heap().new_array());
    });
    cdef(Array_, "new:", [](VM& vm, const Value&, std::vector<Value>& a) -> Value {
        Array* arr = vm.heap().new_array();
        arr->items.assign(is_int(a[0]) ? as_i(a[0]) : 0, nil());
        return ref(arr);
    });
    def(Array_, "size", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        return Value{static_cast<std::int64_t>(as<Array>(r)->items.size())};
    });
    def(Array_, "at:", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        auto* arr = as<Array>(r);
        std::int64_t i = is_int(a[0]) ? as_i(a[0]) : 0;
        if (i < 1 || i > static_cast<std::int64_t>(arr->items.size())) {
            vm.fail("index out of bounds"); return nil();
        }
        return arr->items[i - 1];
    });
    def(Array_, "at:put:", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        auto* arr = as<Array>(r);
        std::int64_t i = is_int(a[0]) ? as_i(a[0]) : 0;
        if (i < 1 || i > static_cast<std::int64_t>(arr->items.size())) {
            vm.fail("index out of bounds"); return nil();
        }
        arr->items[i - 1] = a[1];
        return a[1];
    });
    def(Array_, "first", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        auto* arr = as<Array>(r);
        if (arr->items.empty()) { vm.fail("empty"); return nil(); }
        return arr->items.front();
    });
    def(Array_, "last", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        auto* arr = as<Array>(r);
        if (arr->items.empty()) { vm.fail("empty"); return nil(); }
        return arr->items.back();
    });

    // --- OrderedCollection (an Instance whose `items` ivar holds an Array) ---
    cdef(OrderedCollection, "new", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        Instance* oc = vm.heap().new_instance(as<Class>(r));
        oc->ivars["items"] = ref(vm.heap().new_array());
        return ref(oc);
    });
    def(OrderedCollection, "add:", [](VM&, const Value& r, std::vector<Value>& a) -> Value {
        oc_items(r)->items.push_back(a[0]);
        return a[0];
    });
    def(OrderedCollection, "addFirst:", [](VM&, const Value& r, std::vector<Value>& a) -> Value {
        auto& v = oc_items(r)->items;
        v.insert(v.begin(), a[0]);
        return a[0];
    });
    def(OrderedCollection, "removeFirst", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        auto& v = oc_items(r)->items;
        if (v.empty()) { vm.fail("empty"); return nil(); }
        Value f = v.front();
        v.erase(v.begin());
        return f;
    });
    def(OrderedCollection, "size", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        return Value{static_cast<std::int64_t>(oc_items(r)->items.size())};
    });
    def(OrderedCollection, "at:", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        auto& v = oc_items(r)->items;
        std::int64_t i = is_int(a[0]) ? as_i(a[0]) : 0;
        if (i < 1 || i > static_cast<std::int64_t>(v.size())) { vm.fail("index out of bounds"); return nil(); }
        return v[i - 1];
    });
    def(OrderedCollection, "at:put:", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        auto& v = oc_items(r)->items;
        std::int64_t i = is_int(a[0]) ? as_i(a[0]) : 0;
        if (i < 1 || i > static_cast<std::int64_t>(v.size())) { vm.fail("index out of bounds"); return nil(); }
        v[i - 1] = a[1];
        return a[1];
    });
    def(OrderedCollection, "first", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        auto& v = oc_items(r)->items;
        if (v.empty()) { vm.fail("empty"); return nil(); }
        return v.front();
    });
    def(OrderedCollection, "last", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        auto& v = oc_items(r)->items;
        if (v.empty()) { vm.fail("empty"); return nil(); }
        return v.back();
    });
    def(OrderedCollection, "asArray", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        Array* out = vm.heap().new_array();
        out->items = oc_items(r)->items;
        return ref(out);
    });

    // --- BlockClosure ---
    def(BlockClosure, "numArgs", [](VM&, const Value& r, std::vector<Value>&) -> Value {
        return Value{static_cast<std::int64_t>(as<Block>(r)->num_args())};
    });

    // --- Transcript ---
    def(Transcript, "show:", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        vm.write(display_string(a[0]));
        return r;
    });
    def(Transcript, "showCr:", [](VM& vm, const Value& r, std::vector<Value>& a) -> Value {
        vm.write(display_string(a[0]) + "\n");
        return r;
    });
    def(Transcript, "cr", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        vm.write("\n");
        return r;
    });
    def(Transcript, "nl", [](VM& vm, const Value& r, std::vector<Value>&) -> Value {
        vm.write("\n");
        return r;
    });

    vm.globals()["Transcript"] = ref(heap.new_instance(Transcript));
    (void)Array_;
}

}  // namespace st
