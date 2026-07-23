// VM partition — a non-recursive bytecode stack machine.
//
// One driver loop runs a chain of reified `Context` activations. A compiled
// send pushes a new activation and keeps looping (no host recursion); a block
// `value` send does the same. Primitives are leaf operations that never re-enter
// the loop, so no C++ exceptions are needed for control flow: a `^` return
// unwinds the explicit activation chain, and errors set an error flag that the
// loop checks. GC only runs at the top of the loop, where every live value is
// reachable from the active context or the globals.
module;
#include <cstdint>
#include <print>
#include <span>
#include <string>
#include <unordered_map>
#include <variant>
#include <vector>

export module st:vm;

import :bytecode;
import :objects;
import :heap;

export namespace st {

class VM {
public:
    explicit VM(Heap& heap) : heap_(heap) {}

    Heap& heap() { return heap_; }
    std::unordered_map<std::string, Value>& globals() { return globals_; }
    std::unordered_map<std::string, Class*>& classes() { return classes_; }

    bool errored() const { return errored_; }
    const std::string& error() const { return error_; }
    void clear_error() { errored_ = false; error_.clear(); }
    void fail(std::string msg) {
        if (errored_) return;
        errored_ = true;
        error_ = std::move(msg);
    }

    void write(const std::string& s) { std::print("{}", s); }

    void register_class(Class* c) {
        classes_[c->name] = c;
        globals_[c->name] = ref(c);
        flush_caches();
    }

    // Invalidate all method-lookup caches. Call after any change to a method
    // dictionary or the class hierarchy. Bumping the version invalidates every
    // per-call-site inline cache at once (they store the version they were
    // filled at).
    void flush_caches() {
        ++method_version_;
        for (auto& [name, c] : classes_) c->ivar_count_ = -1;  // ivar layout
    }

    // Disable the inline integer fast path if an arithmetic selector is
    // overridden on a class that SmallInteger inherits from.
    void note_override(Class* cls, const std::string& sel) {
        static const std::string arith[] = {"+", "-", "*", "<", ">", "<=", ">=", "="};
        bool is_arith = false;
        for (const auto& s : arith) is_arith |= (s == sel);
        if (!is_arith) return;
        Class* si = classes_["SmallInteger"];
        if (si != nullptr && si->is_kind_of(cls)) optimize_arithmetic_ = false;
    }
    Class* find_class(const std::string& name) {
        auto it = classes_.find(name);
        return it == classes_.end() ? nullptr : it->second;
    }

    Class* class_of(const Value& v) {
        if (is_nil(v)) return classes_["UndefinedObject"];
        if (is_bool(v)) return classes_[as_bool(v) ? "True" : "False"];
        if (is_int(v)) return classes_["SmallInteger"];
        if (is_float(v)) return classes_["Float"];
        Object* o = as_obj(v);
        switch (o->tag) {
            case Tag::String: return classes_["String"];
            case Tag::Symbol: return classes_["Symbol"];
            case Tag::Character: return classes_["Character"];
            case Tag::Array: return classes_["Array"];
            case Tag::Dictionary: return classes_["Dictionary"];
            case Tag::Class: return classes_["Class"];
            case Tag::Instance: return static_cast<Instance*>(o)->st_class;
            case Tag::Block: return classes_["BlockClosure"];
            default: return classes_["Object"];
        }
    }

    // Top-level send used by the REPL / tests. Runs to completion.
    Value send_message(const Value& recv, const std::string& sel,
                       std::vector<Value> args) {
        if (Block* b = as<Block>(recv)) {
            if (is_value_selector(sel, static_cast<int>(args.size()))) {
                Context* ctx = make_block_frame(b, args);
                if (errored_) return nil();
                ctx->sender = active_context_;
                return run(ctx);
            }
        }
        Method* m = lookup(recv, heap_.intern_symbol(sel), nullptr);
        if (m == nullptr || !m->present()) {
            dnu(recv, sel);
            return nil();
        }
        if (m->is_primitive()) return m->prim(*this, recv, args);
        Context* ctx = make_method_frame(m->compiled, recv, args);
        if (errored_) return nil();
        ctx->sender = active_context_;
        return run(ctx);
    }

    // Top-level entry: run a compiled method to completion.
    Value activate(CompiledMethod* m, const Value& recv, std::vector<Value> args) {
        Context* ctx = make_method_frame(m, recv, args);
        if (errored_) return nil();
        ctx->sender = active_context_;
        return run(ctx);
    }

    Context* make_method_frame(CompiledMethod* m, const Value& recv,
                               std::span<Value> args) {
        if (static_cast<int>(args.size()) != m->num_args()) {
            fail("#" + m->selector + " wrong argument count");
            return nullptr;
        }
        Context* ctx = heap_.new_context();
        ctx->receiver = recv;
        ctx->method = m;
        ctx->stack.reserve(8);
        ctx->locals.assign(m->local_names.size(), nil());
        for (std::size_t i = 0; i < args.size(); ++i) ctx->locals[i] = args[i];
        return ctx;
    }

    Context* make_block_frame(Block* b, std::span<Value> args) {
        CompiledBlock* tmpl = b->tmpl;
        if (static_cast<int>(args.size()) != tmpl->num_args()) {
            fail("block wrong argument count");
            return nullptr;
        }
        Context* ctx = heap_.new_context();
        ctx->method = tmpl;
        ctx->is_block = true;
        ctx->outer = b->outer;
        ctx->home = b->home;
        ctx->receiver = b->home != nullptr ? b->home->receiver : nil();
        ctx->locals.assign(tmpl->local_names.size(), nil());
        for (std::size_t i = 0; i < args.size(); ++i) ctx->locals[i] = args[i];
        return ctx;
    }

private:
    Heap& heap_;
    std::unordered_map<std::string, Value> globals_;
    std::unordered_map<std::string, Class*> classes_;
    Context* active_context_ = nullptr;
    bool errored_ = false;
    bool optimize_arithmetic_ = true;
    std::uint64_t method_version_ = 1;  // bumped on any (re)definition
    std::string error_;

    static bool is_value_selector(const std::string& s, int argc) {
        switch (argc) {
            case 0: return s == "value";
            case 1: return s == "value:";
            case 2: return s == "value:value:";
            case 3: return s == "value:value:value:";
            default: return false;
        }
    }

    Method* lookup(const Value& recv, Symbol* sel, Class* super_start) {
        if (super_start != nullptr) return super_start->lookup(sel);
        if (Class* cls = as<Class>(recv)) {
            Method* m = cls->lookup_class(sel);
            if (m == nullptr) m = classes_["Class"]->lookup(sel);
            return m;
        }
        return class_of(recv)->lookup(sel);
    }

    void dnu(const Value& recv, const std::string& sel) {
        std::string cls = as<Class>(recv) != nullptr
                              ? (as<Class>(recv)->name + " class")
                              : class_of(recv)->name;
        fail(cls + " does not understand #" + sel);
    }

    Class* defining_class(Context* ctx) {
        Object* m = ctx->method;
        if (m->tag == Tag::CompiledMethod) return static_cast<CompiledMethod*>(m)->defined_in;
        if (ctx->home != nullptr && ctx->home->method->tag == Tag::CompiledMethod)
            return static_cast<CompiledMethod*>(ctx->home->method)->defined_in;
        return nullptr;
    }

    // Instance variables are resolved to slots at compile time (PushIvar /
    // StoreIvar); PushVar / StoreVar only reach globals.
    Value read_var(const std::string& name) {
        auto g = globals_.find(name);
        if (g != globals_.end()) return g->second;
        fail("undeclared variable " + name);
        return nil();
    }

    void write_var(const std::string& name, const Value& v) {
        globals_[name] = v;  // auto-declare a workspace global
    }

    void gc() {
        std::vector<Value> roots;
        roots.reserve(globals_.size() + 1);
        for (auto& [name, v] : globals_) roots.push_back(v);
        if (active_context_ != nullptr) roots.push_back(ref(active_context_));
        heap_.collect(roots);
    }

    // The driver: run until `root` returns past its sender (the boundary).
    Value run(Context* root) {
        Context* boundary = root->sender;
        active_context_ = root;
        Context* ctx = root;
        std::vector<Instr>* code = &code_of(ctx->method);
        std::vector<Value>* lits = &literals_of(ctx->method);
        std::vector<Value>* stk = &ctx->stack;

        auto load_ctx = [&](Context* c) {
            ctx = c;
            active_context_ = c;
            code = &code_of(c->method);
            lits = &literals_of(c->method);
            stk = &c->stack;
        };

        while (true) {
            if (heap_.should_collect()) gc();
            Instr& ins = (*code)[ctx->ip++];  // non-const: inline cache is mutated
            switch (ins.op) {
                case Op::PushLiteral: stk->push_back((*lits)[ins.arg]); break;
                case Op::PushSelf: stk->push_back(ctx->receiver); break;
                case Op::PushContext: stk->push_back(ref(ctx)); break;
                case Op::PushNil: stk->push_back(nil()); break;
                case Op::PushTrue: stk->push_back(Value{true}); break;
                case Op::PushFalse: stk->push_back(Value{false}); break;
                case Op::PushLocal: stk->push_back(ctx->locals[ins.arg]); break;
                case Op::StoreLocal: ctx->locals[ins.arg] = stk->back(); break;
                case Op::PushOuter: {
                    Context* f = ctx->outer;
                    for (int k = 1; k < ins.arg; ++k) f = f->outer;
                    stk->push_back(f->locals[ins.arg2]);
                    break;
                }
                case Op::StoreOuter: {
                    Context* f = ctx->outer;
                    for (int k = 1; k < ins.arg; ++k) f = f->outer;
                    f->locals[ins.arg2] = stk->back();
                    break;
                }
                case Op::PushIvar:
                    stk->push_back(static_cast<Instance*>(as_obj(ctx->receiver))->slots[ins.arg]);
                    break;
                case Op::StoreIvar:
                    static_cast<Instance*>(as_obj(ctx->receiver))->slots[ins.arg] = stk->back();
                    break;
                case Op::PushVar:
                    stk->push_back(read_var(ins.name));
                    if (errored_) return nil();
                    break;
                case Op::StoreVar: write_var(ins.name, stk->back()); break;
                case Op::Pop: stk->pop_back(); break;
                case Op::Dup: stk->push_back(stk->back()); break;
                case Op::MakeArray: {
                    Array* a = heap_.new_array();
                    int n = ins.arg;
                    a->items.assign(stk->end() - n, stk->end());
                    stk->erase(stk->end() - n, stk->end());
                    stk->push_back(ref(a));
                    break;
                }
                case Op::PushBlock: {
                    auto* tmpl = static_cast<CompiledBlock*>(as_obj((*lits)[ins.arg]));
                    Context* home = ctx->is_block ? ctx->home : ctx;
                    stk->push_back(ref(heap_.new_block(tmpl, ctx, home)));
                    break;
                }
                case Op::Jump: ctx->ip = ins.arg; break;
                case Op::JumpTrue:
                case Op::JumpFalse: {
                    Value c = stk->back();
                    stk->pop_back();
                    if (!is_bool(c)) {
                        fail("condition must be a Boolean");
                        return nil();
                    }
                    bool want = ins.op == Op::JumpTrue;
                    if (as_bool(c) == want) ctx->ip = ins.arg;
                    break;
                }
                case Op::Send:
                case Op::SendSuper: {
                    int argc = ins.arg;

                    // inline fast path: SmallInteger arithmetic/compare, keyed
                    // by a precomputed special-selector id. Operands are read in
                    // place (no args vector, no allocation) and the result
                    // replaces them on the stack.
                    if (ins.op == Op::Send && optimize_arithmetic_ && ins.arg2 != 0 &&
                        argc == 1) {
                        Value& rv = *(stk->end() - 2);
                        Value& av = stk->back();
                        if (is_int(rv) && is_int(av)) {
                            std::int64_t x = as_int(rv), y = as_int(av);
                            if (ins.arg2 >= 4) {  // comparisons
                                bool res = ins.arg2 == 4   ? x < y
                                           : ins.arg2 == 5 ? x > y
                                           : ins.arg2 == 6 ? x <= y
                                           : ins.arg2 == 7 ? x >= y
                                                           : x == y;
                                stk->pop_back();
                                stk->back() = Value{res};
                                break;
                            }
                            std::int64_t r = 0;
                            bool ov = ins.arg2 == 3 ? __builtin_mul_overflow(x, y, &r)
                                      : (r = ins.arg2 == 1 ? x + y : x - y, false);
                            if (ov || !fits_smallint(r)) {
                                fail("SmallInteger overflow");
                                return nil();
                            }
                            stk->pop_back();
                            stk->back() = Value{r};
                            break;
                        }
                    }

                    // args are a span over the stack; the receiver sits just
                    // below them. Nothing is popped until the callee/primitive
                    // has consumed the span (frames copy it into their locals).
                    std::size_t sp_base = stk->size() - argc;
                    std::span<Value> args(stk->data() + sp_base, argc);
                    Value receiver = (*stk)[sp_base - 1];

                    if (ins.op == Op::Send) {
                        if (Block* blk = as<Block>(receiver)) {
                            if (is_value_selector(ins.name, argc)) {
                                Context* nc = make_block_frame(blk, args);
                                if (errored_) return nil();
                                stk->resize(sp_base - 1);
                                nc->sender = ctx;
                                load_ctx(nc);
                                break;
                            }
                        }
                    }

                    // resolve the method, with a monomorphic inline cache for
                    // ordinary (non-super, non-class-receiver) sends
                    Method* m = nullptr;
                    bool class_recv = is_obj(receiver) && as_obj(receiver)->tag == Tag::Class;
                    if (ins.op == Op::Send && !class_recv) {
                        Class* rc = class_of(receiver);
                        void* key = static_cast<void*>(rc);
                        if (ins.ic_version != method_version_) {
                            // stale: reset the 2-way cache and resolve
                            m = lookup(receiver, static_cast<Symbol*>(ins.sel), nullptr);
                            ins.ic_class = key;
                            ins.ic_method = m;
                            ins.ic_class2 = nullptr;
                            ins.ic_method2 = nullptr;
                            ins.ic_version = method_version_;
                        } else if (ins.ic_class == key) {
                            m = static_cast<Method*>(ins.ic_method);
                        } else if (ins.ic_class2 == key) {
                            m = static_cast<Method*>(ins.ic_method2);
                        } else {
                            m = lookup(receiver, static_cast<Symbol*>(ins.sel), nullptr);
                            // insert as MRU; demote the old first entry
                            ins.ic_class2 = ins.ic_class;
                            ins.ic_method2 = ins.ic_method;
                            ins.ic_class = key;
                            ins.ic_method = m;
                        }
                    } else {
                        Class* super_start =
                            ins.op == Op::SendSuper
                                ? (defining_class(ctx) != nullptr
                                       ? defining_class(ctx)->superclass
                                       : nullptr)
                                : nullptr;
                        m = lookup(receiver, static_cast<Symbol*>(ins.sel), super_start);
                    }
                    if (m == nullptr || !m->present()) {
                        dnu(receiver, ins.name);
                        return nil();
                    }
                    if (m->is_primitive()) {
                        Value r = m->prim(*this, receiver, args);
                        if (errored_) return nil();
                        stk->resize(sp_base - 1);
                        stk->push_back(r);
                    } else {
                        Context* nc = make_method_frame(m->compiled, receiver, args);
                        if (errored_) return nil();
                        stk->resize(sp_base - 1);
                        nc->sender = ctx;
                        load_ctx(nc);
                    }
                    break;
                }
                case Op::Return:
                case Op::BlockReturn: {
                    Value value = stk->back();
                    stk->pop_back();
                    Context* target = nullptr;
                    if (ins.op == Op::Return && ctx->is_block) {
                        Context* home = ctx->home;
                        if (!is_live(home, boundary)) {
                            fail("non-local return from a dead context");
                            return nil();
                        }
                        target = home->sender;
                    } else {
                        target = ctx->sender;
                    }
                    if (target == boundary) {
                        active_context_ = boundary;
                        return value;
                    }
                    target->stack.push_back(value);
                    load_ctx(target);
                    break;
                }
            }
        }
    }

    bool is_live(Context* home, Context* boundary) {
        for (Context* c = active_context_; c != nullptr && c != boundary; c = c->sender) {
            if (c == home) return true;
        }
        return false;
    }
};

}  // namespace st
