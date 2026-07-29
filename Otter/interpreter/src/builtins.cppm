module;

#include "builtin_modules.h"

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

// The C-level names are prefixed so that they cannot collide with anything a
// program declares for itself; the modules below wrap them under short names.
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

// The modules that need no file beside the program. Each lives in
// `interpreter/modules` as ordinary Otter source, declaring the host functions
// it needs and re-exporting them under short names, so none of them is a
// special case for the checker or the evaluator.
std::optional<std::string> builtinModuleSource(const std::string& name) {
    for (const detail::BuiltinModuleSource& entry : detail::builtinModuleSources) {
        if (name == entry.name) {
            return std::string(entry.source);
        }
    }
    return std::nullopt;
}

}  // namespace otter
