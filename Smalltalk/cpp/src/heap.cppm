// Heap partition — a mark-and-sweep garbage collector.
//
// The Heap owns every object via raw pointers threaded on an intrusive list
// (`gc_next`). `collect(roots)` marks everything reachable from the roots (and
// the interned symbols) and frees the rest. Marking is iterative (an explicit
// worklist) so a deep object graph can't overflow the C++ stack. No shared_ptr
// / reference counting; no exceptions.
export module st:heap;

import std;
import :objects;

export namespace st {

class Heap {
public:
    Heap() = default;
    Heap(const Heap&) = delete;
    Heap& operator=(const Heap&) = delete;
    ~Heap() {
        Object* o = head_;
        while (o != nullptr) {
            Object* next = o->gc_next;
            delete o;
            o = next;
        }
    }

    template <class T, class... A>
    T* make(A&&... args) {
        auto* obj = new T(std::forward<A>(args)...);
        obj->gc_next = head_;
        head_ = obj;
        ++count_;
        ++since_gc_;
        return obj;
    }

    String* new_string(std::string s) { return make<String>(std::move(s)); }
    Character* new_char(char c) { return make<Character>(c); }
    Array* new_array() { return make<Array>(); }
    Dict* new_dict() { return make<Dict>(); }
    Class* new_class(std::string name) { return make<Class>(std::move(name)); }
    Instance* new_instance(Class* c) {
        Instance* inst = make<Instance>(c);
        inst->slots.assign(c->ivar_count(), nil());
        return inst;
    }
    CompiledMethod* new_method() { return make<CompiledMethod>(); }
    CompiledBlock* new_block_template() { return make<CompiledBlock>(); }
    Block* new_block(CompiledBlock* t, Context* outer, Context* home) {
        return make<Block>(t, outer, home);
    }
    Context* new_context() { return make<Context>(); }

    Symbol* intern_symbol(const std::string& s) {
        auto it = interned_.find(s);
        if (it != interned_.end()) return it->second;
        Symbol* obj = make<Symbol>(s);
        interned_.emplace(s, obj);
        return obj;
    }

    bool should_collect() const { return since_gc_ > kThreshold; }
    std::size_t live_count() const { return count_; }

    void collect(std::span<const Value> roots) {
        std::vector<Object*> work;
        for (const Value& v : roots) push(work, as_obj(v));
        for (auto& [text, sym] : interned_) push(work, sym);

        while (!work.empty()) {
            Object* o = work.back();
            work.pop_back();
            trace(o, work);
        }

        Object** link = &head_;
        while (*link != nullptr) {
            Object* o = *link;
            if (o->marked) {
                o->marked = false;
                link = &o->gc_next;
            } else {
                *link = o->gc_next;
                delete o;
                --count_;
            }
        }
        since_gc_ = 0;
    }

private:
    static constexpr std::size_t kThreshold = 100000;

    Object* head_ = nullptr;
    std::size_t count_ = 0;
    std::size_t since_gc_ = 0;
    std::unordered_map<std::string, Symbol*> interned_;

    static void push(std::vector<Object*>& work, Object* o) {
        if (o != nullptr && !o->marked) {
            o->marked = true;
            work.push_back(o);
        }
    }
    static void push_value(std::vector<Object*>& work, const Value& v) {
        push(work, as_obj(v));
    }

    static void trace(Object* o, std::vector<Object*>& work) {
        switch (o->tag) {
            case Tag::String:
            case Tag::Symbol:
            case Tag::Character:
                break;
            case Tag::Array:
                for (const Value& e : static_cast<Array*>(o)->items)
                    push_value(work, e);
                break;
            case Tag::Dictionary:
                for (const auto& [k, v] : static_cast<Dict*>(o)->map) {
                    push_value(work, k);
                    push_value(work, v);
                }
                break;
            case Tag::Class: {
                auto* c = static_cast<Class*>(o);
                push(work, c->superclass);
                for (auto& [sel, m] : c->methods) push(work, m.compiled);
                for (auto& [sel, m] : c->class_methods) push(work, m.compiled);
                break;
            }
            case Tag::Instance: {
                auto* inst = static_cast<Instance*>(o);
                push(work, inst->st_class);
                for (const Value& v : inst->slots) push_value(work, v);
                break;
            }
            case Tag::CompiledMethod: {
                auto* m = static_cast<CompiledMethod*>(o);
                for (const Value& v : m->literals) push_value(work, v);
                push(work, m->defined_in);
                break;
            }
            case Tag::CompiledBlock:
                for (const Value& v : static_cast<CompiledBlock*>(o)->literals)
                    push_value(work, v);
                break;
            case Tag::Block: {
                auto* b = static_cast<Block*>(o);
                push(work, b->tmpl);
                push(work, b->outer);
                push(work, b->home);
                break;
            }
            case Tag::Context: {
                auto* ctx = static_cast<Context*>(o);
                push_value(work, ctx->receiver);
                push(work, ctx->method);
                for (const Value& v : ctx->locals) push_value(work, v);
                for (const Value& v : ctx->stack) push_value(work, v);
                push(work, ctx->outer);
                push(work, ctx->sender);
                push(work, ctx->home);
                break;
            }
        }
    }
};

}  // namespace st
