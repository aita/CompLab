// System partition — the facade tying the pipeline together: parse -> compile
// -> run, plus class/method definition. Owns the Heap and the VM.
module;
#include <string>
#include <string_view>
#include <vector>

export module st:system;

import :objects;
import :heap;
import :vm;
import :parser;
import :compiler;
import :kernel;

export namespace st {

class System {
public:
    System() : vm_(heap_) {
        build_kernel(vm_);
        install_prelude();
    }
    System(const System&) = delete;
    System& operator=(const System&) = delete;

    VM& vm() { return vm_; }
    Heap& heap() { return heap_; }

    // Evaluate a workspace expression; check vm().errored() afterwards.
    Value eval(std::string_view src) {
        vm_.clear_error();
        Parsed<Sequence> p = parse_sequence(src);
        if (!p.ok) {
            vm_.fail(p.error);
            return nil();
        }
        Compiler comp(heap_);
        CompiledMethod* m = comp.compile_doit(p.value, std::string(src));
        return vm_.activate(m, nil(), {});
    }

    // printString of a value, honouring user overrides (top-level send).
    std::string print_value(const Value& v) {
        Value s = vm_.send_message(v, "printString", {});
        if (auto* str = as<String>(s)) return str->data;
        return print_string(v);
    }

    Class* define_class(const std::string& name, const std::string& super,
                        std::vector<std::string> ivars) {
        Class* sup = vm_.find_class(super);
        if (sup == nullptr) {
            vm_.fail("unknown superclass " + super);
            return nullptr;
        }
        if (Class* existing = vm_.find_class(name)) {
            existing->superclass = sup;
            existing->ivar_names = std::move(ivars);
            return existing;
        }
        Class* c = heap_.new_class(name);
        c->superclass = sup;
        c->ivar_names = std::move(ivars);
        vm_.register_class(c);
        return c;
    }

    CompiledMethod* define_method(const std::string& class_name,
                                  std::string_view src) {
        Class* c = vm_.find_class(class_name);
        if (c == nullptr) {
            vm_.fail("unknown class " + class_name);
            return nullptr;
        }
        Parsed<MethodNode> p = parse_method(src);
        if (!p.ok) {
            vm_.fail(p.error);
            return nullptr;
        }
        Compiler comp(heap_);
        CompiledMethod* m = comp.compile_method(p.value, std::string(src));
        m->defined_in = c;
        c->methods[m->selector] = Method{nullptr, m};
        return m;
    }

    // Higher-order collection protocol, written in Smalltalk so block sends and
    // non-local returns flow through the single VM loop (no primitive re-enters
    // the VM). Installed on SequenceableCollection; Array/String/OrderedCollection
    // inherit it and supply at:/size primitively.
    void install_prelude() {
        struct Def { const char* cls; const char* src; };
        static const Def defs[] = {
            {"SequenceableCollection",
             "do: aBlock\n"
             "  | i n | i := 1. n := self size.\n"
             "  [i <= n] whileTrue: [aBlock value: (self at: i). i := i + 1]"},
            {"SequenceableCollection",
             "do: aBlock separatedBy: sepBlock\n"
             "  | i n | i := 1. n := self size.\n"
             "  [i <= n] whileTrue: [\n"
             "    i > 1 ifTrue: [sepBlock value].\n"
             "    aBlock value: (self at: i). i := i + 1]"},
            {"SequenceableCollection",
             "collect: aBlock\n"
             "  | r i n | n := self size. r := Array new: n. i := 1.\n"
             "  [i <= n] whileTrue: [r at: i put: (aBlock value: (self at: i)). i := i + 1]. ^r"},
            {"SequenceableCollection",
             "select: aBlock\n"
             "  | r | r := OrderedCollection new.\n"
             "  self do: [:e | (aBlock value: e) ifTrue: [r add: e]]. ^r"},
            {"SequenceableCollection",
             "reject: aBlock\n"
             "  | r | r := OrderedCollection new.\n"
             "  self do: [:e | (aBlock value: e) ifFalse: [r add: e]]. ^r"},
            {"SequenceableCollection",
             "detect: aBlock\n"
             "  ^self detect: aBlock ifNone: [self error: 'not found']"},
            {"SequenceableCollection",
             "detect: aBlock ifNone: noneBlock\n"
             "  self do: [:e | (aBlock value: e) ifTrue: [^e]].\n"
             "  ^noneBlock value"},
            {"SequenceableCollection",
             "inject: acc into: aBlock\n"
             "  | a | a := acc.\n"
             "  self do: [:e | a := aBlock value: a value: e]. ^a"},
            {"SequenceableCollection",
             "includes: anObject\n"
             "  self do: [:e | e = anObject ifTrue: [^true]]. ^false"},
            {"SequenceableCollection", "isEmpty\n  ^self size = 0"},
            {"SequenceableCollection", "notEmpty\n  ^self size > 0"},
            {"SequenceableCollection",
             "asOrderedCollection\n"
             "  | r | r := OrderedCollection new. self do: [:e | r add: e]. ^r"},
        };
        for (const Def& d : defs) define_method(d.cls, d.src);
    }

private:
    Heap heap_;
    VM vm_;
};

}  // namespace st
