export module otter.builtins;

import std;
import otter.diagnostics;
import otter.types;
import otter.value;

namespace otter::detail {

std::string toUtf8(char32_t code) {
    std::string out;
    if (code < 0x80) {
        out += static_cast<char>(code);
    } else if (code < 0x800) {
        out += static_cast<char>(0xC0 | (code >> 6));
        out += static_cast<char>(0x80 | (code & 0x3F));
    } else if (code < 0x10000) {
        out += static_cast<char>(0xE0 | (code >> 12));
        out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (code & 0x3F));
    } else {
        out += static_cast<char>(0xF0 | (code >> 18));
        out += static_cast<char>(0x80 | ((code >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (code & 0x3F));
    }
    return out;
}

const std::string& textOf(const Value& value) { return value.as<StringObject*>()->text; }

// The names are prefixed so that they cannot collide with anything a program
// declares for itself, since a program may bind to one of these by writing a
// function without a body. The built-in modules stand for them under short
// names.
const std::vector<NativeEntry>& nativeTable() {
    static const std::vector<NativeEntry> table = [] {
        std::vector<NativeEntry> entries;

        entries.push_back({"otter_io_print",
                           [](Heap&, std::span<Value> arguments, const Span&) {
                               std::print("{}", textOf(arguments[0]));
                               return Value();
                           }});
        entries.push_back({"otter_io_println",
                           [](Heap&, std::span<Value> arguments, const Span&) {
                               std::println("{}", textOf(arguments[0]));
                               return Value();
                           }});
        entries.push_back({"otter_io_read_line", [](Heap& heap, std::span<Value>, const Span&) {
                               std::string line;
                               if (!std::getline(std::cin, line)) {
                                   line.clear();
                               }
                               return Value(heap.makeString(std::move(line)));
                           }});

        entries.push_back({"otter_str_from_int",
                           [](Heap& heap, std::span<Value> arguments, const Span&) {
                               return Value(heap.makeString(
                                   std::format("{}", arguments[0].as<std::int64_t>())));
                           }});
        entries.push_back({"otter_str_from_float",
                           [](Heap& heap, std::span<Value> arguments, const Span&) {
                               return Value(heap.makeString(
                                   std::format("{}", arguments[0].as<double>())));
                           }});
        entries.push_back({"otter_str_from_bool",
                           [](Heap& heap, std::span<Value> arguments, const Span&) {
                               return Value(heap.makeString(
                                   arguments[0].as<bool>() ? "true" : "false"));
                           }});
        entries.push_back({"otter_str_from_char",
                           [](Heap& heap, std::span<Value> arguments, const Span&) {
                               return Value(
                                   heap.makeString(toUtf8(arguments[0].as<char32_t>())));
                           }});
        entries.push_back({"otter_str_to_int",
                           [](Heap&, std::span<Value> arguments, const Span& span) {
                               const std::string& text = textOf(arguments[0]);
                               std::int64_t value = 0;
                               auto [stop, error] = std::from_chars(
                                   text.data(), text.data() + text.size(), value);
                               if (error != std::errc{} || stop != text.data() + text.size()) {
                                   throw RuntimeError(
                                       span, std::format("`{}` is not a whole number", text));
                               }
                               return Value(value);
                           }});
        entries.push_back({"otter_str_substring",
                           [](Heap& heap, std::span<Value> arguments, const Span& span) {
                               const std::string& text = textOf(arguments[0]);
                               auto start = arguments[1].as<std::int64_t>();
                               auto length = arguments[2].as<std::int64_t>();
                               if (start < 0 || length < 0 ||
                                   start + length > static_cast<std::int64_t>(text.size())) {
                                   throw RuntimeError(
                                       span, std::format("the substring {}..{} lies outside a "
                                                         "string of length {}",
                                                         start, start + length, text.size()));
                               }
                               return Value(heap.makeString(
                                   text.substr(static_cast<std::size_t>(start),
                                               static_cast<std::size_t>(length))));
                           }});
        entries.push_back({"otter_str_index_of",
                           [](Heap&, std::span<Value> arguments, const Span&) {
                               std::size_t found =
                                   textOf(arguments[0]).find(textOf(arguments[1]));
                               return Value(found == std::string::npos
                                                ? std::int64_t{-1}
                                                : static_cast<std::int64_t>(found));
                           }});

        entries.push_back({"otter_math_sqrt",
                           [](Heap&, std::span<Value> arguments, const Span&) {
                               return Value(std::sqrt(arguments[0].as<double>()));
                           }});
        entries.push_back({"otter_math_pow",
                           [](Heap&, std::span<Value> arguments, const Span&) {
                               return Value(std::pow(arguments[0].as<double>(),
                                                     arguments[1].as<double>()));
                           }});
        entries.push_back({"otter_math_floor",
                           [](Heap&, std::span<Value> arguments, const Span&) {
                               return Value(std::floor(arguments[0].as<double>()));
                           }});
        entries.push_back({"otter_math_ceil",
                           [](Heap&, std::span<Value> arguments, const Span&) {
                               return Value(std::ceil(arguments[0].as<double>()));
                           }});
        entries.push_back({"otter_math_abs",
                           [](Heap&, std::span<Value> arguments, const Span&) {
                               auto value = arguments[0].as<std::int64_t>();
                               // The smallest int has no positive counterpart,
                               // so this wraps rather than trapping, the way
                               // every other whole number does.
                               return Value(value < 0
                                                ? static_cast<std::int64_t>(
                                                      0ull - static_cast<std::uint64_t>(value))
                                                : value);
                           }});
        entries.push_back({"otter_math_min",
                           [](Heap&, std::span<Value> arguments, const Span&) {
                               return Value(std::min(arguments[0].as<std::int64_t>(),
                                                     arguments[1].as<std::int64_t>()));
                           }});
        entries.push_back({"otter_math_max",
                           [](Heap&, std::span<Value> arguments, const Span&) {
                               return Value(std::max(arguments[0].as<std::int64_t>(),
                                                     arguments[1].as<std::int64_t>()));
                           }});

        entries.push_back({"otter_gc_collect", [](Heap& heap, std::span<Value>, const Span&) {
                               heap.collect();
                               return Value();
                           }});
        entries.push_back({"otter_gc_live", [](Heap& heap, std::span<Value>, const Span&) {
                               return Value(static_cast<std::int64_t>(heap.live()));
                           }});
        entries.push_back({"otter_gc_collections",
                           [](Heap& heap, std::span<Value>, const Span&) {
                               return Value(static_cast<std::int64_t>(heap.collections()));
                           }});

        return entries;
    }();
    return table;
}

}  // namespace otter::detail

export namespace otter {

// Looks up the host function standing behind a body-less declaration.
const NativeEntry* findNative(const std::string& name) {
    for (const NativeEntry& entry : detail::nativeTable()) {
        if (entry.name == name) {
            return &entry;
        }
    }
    return nullptr;
}

// One function of a built-in module: what it is called there, the host function
// it stands for, and its signature. Every one of these takes and gives types
// that need no argument, so naming the kind is enough.
struct BuiltinFunction {
    std::string name;
    std::string hostName;
    TypeKind result;
    std::vector<TypeKind> parameters;
};

// A module the implementation provides itself, so that it needs no file beside
// the program. `otter.program` turns one of these into an ordinary module whose
// functions have no body, which is what every other body-less function is.
struct BuiltinModule {
    std::string name;
    std::vector<BuiltinFunction> functions;
};

const std::vector<BuiltinModule>& builtinModules() {
    using enum TypeKind;
    static const std::vector<BuiltinModule> modules = {
        {"io",
         {
             {"print", "otter_io_print", Void, {String}},
             {"println", "otter_io_println", Void, {String}},
             {"read_line", "otter_io_read_line", String, {}},
         }},
        {"str",
         {
             {"from_int", "otter_str_from_int", String, {Int}},
             {"from_float", "otter_str_from_float", String, {Float64}},
             {"from_bool", "otter_str_from_bool", String, {Bool}},
             {"from_char", "otter_str_from_char", String, {Char}},
             {"to_int", "otter_str_to_int", Int, {String}},
             {"substring", "otter_str_substring", String, {String, Int, Int}},
             {"index_of", "otter_str_index_of", Int, {String, String}},
         }},
        {"math",
         {
             {"sqrt", "otter_math_sqrt", Float64, {Float64}},
             {"pow", "otter_math_pow", Float64, {Float64, Float64}},
             {"floor", "otter_math_floor", Float64, {Float64}},
             {"ceil", "otter_math_ceil", Float64, {Float64}},
             {"abs", "otter_math_abs", Int, {Int}},
             {"min", "otter_math_min", Int, {Int, Int}},
             {"max", "otter_math_max", Int, {Int, Int}},
         }},
        {"gc",
         {
             {"collect", "otter_gc_collect", Void, {}},
             {"live", "otter_gc_live", Int, {}},
             {"collections", "otter_gc_collections", Int, {}},
         }},
    };
    return modules;
}

const BuiltinModule* findBuiltinModule(const std::string& name) {
    for (const BuiltinModule& entry : builtinModules()) {
        if (entry.name == name) {
            return &entry;
        }
    }
    return nullptr;
}

}  // namespace otter
