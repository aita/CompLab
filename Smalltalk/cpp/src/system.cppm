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
    System() : vm_(heap_) { build_kernel(vm_); }
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

private:
    Heap heap_;
    VM vm_;
};

}  // namespace st
