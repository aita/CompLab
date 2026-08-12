// Compiler partition — AST -> bytecode.
//
// Variables are resolved at compile time (lexical addressing): PushLocal for a
// slot in this activation, PushOuter (depth, slot) for an enclosing block, and
// name-based PushVar for instance vars / globals. Control-flow selectors with
// literal blocks are compiled inline to jumps — including to:do: / timesRepeat:
// (their loop variable is bound to a local slot) so no primitive ever has to
// re-enter the VM to run a block.
export module st:compiler;

import std;
import :bytecode;
import :objects;
import :heap;
import :ast;

export namespace st {

struct Scope {
    Scope* parent;
    std::vector<std::string> names;
    std::unordered_map<std::string, int> index;
    explicit Scope(Scope* p) : parent(p) {}

    int declare(const std::string& n) {
        auto it = index.find(n);
        if (it != index.end()) return it->second;
        int slot = static_cast<int>(names.size());
        index[n] = slot;
        names.push_back(n);
        return slot;
    }
    bool resolve(const std::string& n, int& depth, int& idx) {
        Scope* s = this;
        depth = 0;
        while (s != nullptr) {
            auto it = s->index.find(n);
            if (it != s->index.end()) {
                idx = it->second;
                return true;
            }
            s = s->parent;
            ++depth;
        }
        return false;
    }
};

class Compiler {
public:
    explicit Compiler(Heap& heap) : heap_(heap) {}

    CompiledMethod* compile_method(const MethodNode& node, std::string source = "",
                                   Class* cls = nullptr) {
        Scope root(nullptr);
        begin(&root);
        cls_ = cls;  // enables compile-time instance-variable slot resolution
        for (const auto& p : node.params) root.declare(p);
        for (const auto& t : node.body.temps) root.declare(t);
        sequence_value(node.body, true);
        emit(Op::PushSelf);
        emit(Op::Return);
        CompiledMethod* cm = heap_.new_method();
        cm->selector = node.selector;
        cm->params = node.params;
        cm->local_names = root.names;
        cm->code = std::move(code_);
        cm->literals = std::move(literals_);
        cm->source = std::move(source);
        return cm;
    }

    CompiledMethod* compile_doit(const Sequence& seq, std::string source = "") {
        Scope root(nullptr);
        begin(&root);
        for (const auto& t : seq.temps) root.declare(t);
        sequence_value(seq, true);
        if (seq.statements.empty()) emit(Op::PushNil);
        emit(Op::Return);
        CompiledMethod* cm = heap_.new_method();
        cm->selector = "DoIt";
        cm->local_names = root.names;
        cm->code = std::move(code_);
        cm->literals = std::move(literals_);
        cm->source = std::move(source);
        return cm;
    }

private:
    Heap& heap_;
    std::vector<Instr> code_;
    std::vector<Value> literals_;
    Scope* scope_ = nullptr;
    Class* cls_ = nullptr;  // defining class, for instance-variable resolution
    int gensym_ = 0;

    void begin(Scope* s) {
        code_.clear();
        literals_.clear();
        scope_ = s;
        cls_ = nullptr;
        gensym_ = 0;
    }

    int emit(Op op, int arg = 0, int arg2 = 0, std::string name = "") {
        code_.push_back(Instr{op, arg, arg2, std::move(name)});
        return static_cast<int>(code_.size()) - 1;
    }

    // Precompute a special-selector id so the VM's arithmetic fast path can
    // switch on an int instead of comparing selector strings each send.
    static int special_sel(const std::string& s) {
        if (s == "+") return 1;
        if (s == "-") return 2;
        if (s == "*") return 3;
        if (s == "<") return 4;
        if (s == ">") return 5;
        if (s == "<=") return 6;
        if (s == ">=") return 7;
        if (s == "=") return 8;
        return 0;
    }
    void emit_send(const std::string& sel, int argc) {
        int i = emit(Op::Send, argc, special_sel(sel), sel);
        code_[i].sel = heap_.intern_symbol(sel);
    }
    int here() const { return static_cast<int>(code_.size()); }
    int gentemp() { return scope_->declare("__t" + std::to_string(gensym_++)); }

    int literal(const Value& v) {
        literals_.push_back(v);
        return static_cast<int>(literals_.size()) - 1;
    }
    void push_int(std::int64_t n) { emit(Op::PushLiteral, literal(Value{n})); }

    Value materialize(const Literal& lit) {
        switch (lit.k) {
            case Literal::K::Nil: return nil();
            case Literal::K::Bool: return Value{lit.b};
            case Literal::K::Int: return Value{lit.i};
            case Literal::K::Float: return Value{lit.d};
            case Literal::K::Str: return ref(heap_.new_string(lit.s));
            case Literal::K::Sym: return ref(heap_.intern_symbol(lit.s));
            case Literal::K::Char: return ref(heap_.new_char(lit.c));
            case Literal::K::Arr: {
                Array* a = heap_.new_array();
                for (const auto& e : lit.arr) a->items.push_back(materialize(e));
                return ref(a);
            }
        }
        return nil();
    }

    // --- sequences ---

    void sequence_value(const Sequence& seq, bool is_method_body) {
        if (seq.statements.empty()) {
            if (!is_method_body) emit(Op::PushNil);
            return;
        }
        for (std::size_t i = 0; i < seq.statements.size(); ++i) {
            bool last = i + 1 == seq.statements.size();
            Expr* stmt = seq.statements[i].get();
            if (stmt->kind == NK::Return) {
                expr(static_cast<ReturnExpr*>(stmt)->value.get());
                emit(Op::Return);
                return;
            }
            expr(stmt);
            if (!last) emit(Op::Pop);
        }
    }

    void sequence_effect(const Sequence& seq) {
        sequence_value(seq, false);
        emit(Op::Pop);
    }

    // --- expressions ---

    void expr(Expr* node) {
        switch (node->kind) {
            case NK::Literal:
                load_literal(static_cast<LiteralExpr*>(node)->lit);
                break;
            case NK::Variable:
                load(static_cast<VariableExpr*>(node)->name);
                break;
            case NK::Assign: {
                auto* a = static_cast<AssignExpr*>(node);
                expr(a->value.get());
                store(a->name);
                break;
            }
            case NK::Message:
                message(static_cast<MessageExpr*>(node));
                break;
            case NK::Cascade:
                cascade(static_cast<CascadeExpr*>(node));
                break;
            case NK::Block:
                block_literal(static_cast<BlockExpr*>(node));
                break;
            case NK::Return: {
                expr(static_cast<ReturnExpr*>(node)->value.get());
                emit(Op::Return);
                break;
            }
            case NK::DynArray: {
                auto* d = static_cast<DynArrayExpr*>(node);
                for (auto& e : d->elements) expr(e.get());
                emit(Op::MakeArray, static_cast<int>(d->elements.size()));
                break;
            }
        }
    }

    void load_literal(const Literal& lit) {
        if (lit.k == Literal::K::Bool) {
            emit(lit.b ? Op::PushTrue : Op::PushFalse);
        } else if (lit.k == Literal::K::Nil) {
            emit(Op::PushNil);
        } else {
            emit(Op::PushLiteral, literal(materialize(lit)));
        }
    }

    void load(const std::string& name) {
        if (name == "self" || name == "super") {
            emit(Op::PushSelf);
            return;
        }
        if (name == "thisContext") {
            emit(Op::PushContext);
            return;
        }
        int depth = 0, idx = 0;
        if (!scope_->resolve(name, depth, idx)) {
            int slot = cls_ != nullptr ? cls_->ivar_slot(name) : -1;
            if (slot >= 0) emit(Op::PushIvar, slot);
            else emit(Op::PushVar, 0, 0, name);
        } else if (depth == 0) {
            emit(Op::PushLocal, idx);
        } else {
            emit(Op::PushOuter, depth, idx);
        }
    }

    void store(const std::string& name) {
        int depth = 0, idx = 0;
        if (!scope_->resolve(name, depth, idx)) {
            int slot = cls_ != nullptr ? cls_->ivar_slot(name) : -1;
            if (slot >= 0) emit(Op::StoreIvar, slot);
            else emit(Op::StoreVar, 0, 0, name);
        } else if (depth == 0) {
            emit(Op::StoreLocal, idx);
        } else {
            emit(Op::StoreOuter, depth, idx);
        }
    }

    void cascade(CascadeExpr* node) {
        expr(node->receiver.get());
        for (std::size_t i = 0; i < node->messages.size(); ++i) {
            bool last = i + 1 == node->messages.size();
            CascadeMsg& msg = node->messages[i];
            if (!last) emit(Op::Dup);
            for (auto& a : msg.args) expr(a.get());
            emit_send(msg.selector, static_cast<int>(msg.args.size()));
            if (!last) emit(Op::Pop);
        }
    }

    void message(MessageExpr* node) {
        if (try_inline(node)) return;

        if (node->receiver->kind == NK::Variable &&
            static_cast<VariableExpr*>(node->receiver.get())->name == "super") {
            emit(Op::PushSelf);
            for (auto& a : node->args) expr(a.get());
            {
                int i = emit(Op::SendSuper, static_cast<int>(node->args.size()), 0,
                             node->selector);
                code_[i].sel = heap_.intern_symbol(node->selector);
            }
            return;
        }
        expr(node->receiver.get());
        for (auto& a : node->args) expr(a.get());
        emit_send(node->selector, static_cast<int>(node->args.size()));
    }

    // --- inlined control flow ---

    static BlockExpr* zero_block(Expr* e) {
        if (e->kind == NK::Block) {
            auto* b = static_cast<BlockExpr*>(e);
            if (b->params.empty()) return b;
        }
        return nullptr;
    }
    static BlockExpr* one_block(Expr* e) {
        if (e->kind == NK::Block) {
            auto* b = static_cast<BlockExpr*>(e);
            if (b->params.size() == 1) return b;
        }
        return nullptr;
    }
    void inline_body(BlockExpr* b) {
        for (const auto& t : b->temps) scope_->declare(t);
        sequence_value(b->body, false);
    }
    void inline_effect(BlockExpr* b) {
        for (const auto& t : b->temps) scope_->declare(t);
        sequence_effect(b->body);
    }

    bool try_inline(MessageExpr* n) {
        const std::string& s = n->selector;
        if (s == "ifTrue:" || s == "ifFalse:" || s == "ifTrue:ifFalse:" ||
            s == "ifFalse:ifTrue:")
            return inline_cond(n);
        if (s == "and:" || s == "or:") return inline_logic(n);
        if (s == "whileTrue:" || s == "whileFalse:") return inline_while2(n);
        if (s == "whileTrue" || s == "whileFalse") return inline_while0(n);
        if (s == "repeat") return inline_repeat(n);
        if (s == "to:do:") return inline_to_do(n);
        if (s == "timesRepeat:") return inline_times(n);
        return false;
    }

    bool inline_cond(MessageExpr* n) {
        std::vector<BlockExpr*> blocks;
        for (auto& a : n->args) {
            BlockExpr* b = zero_block(a.get());
            if (b == nullptr) return false;
            blocks.push_back(b);
        }
        const std::string& s = n->selector;
        BlockExpr* t = nullptr;
        BlockExpr* f = nullptr;
        if (s == "ifTrue:") t = blocks[0];
        else if (s == "ifFalse:") f = blocks[0];
        else if (s == "ifTrue:ifFalse:") { t = blocks[0]; f = blocks[1]; }
        else { t = blocks[1]; f = blocks[0]; }

        expr(n->receiver.get());
        int j_false = emit(Op::JumpFalse);
        if (t != nullptr) inline_body(t); else emit(Op::PushNil);
        int j_end = emit(Op::Jump);
        code_[j_false].arg = here();
        if (f != nullptr) inline_body(f); else emit(Op::PushNil);
        code_[j_end].arg = here();
        return true;
    }

    bool inline_logic(MessageExpr* n) {
        BlockExpr* b = zero_block(n->args[0].get());
        if (b == nullptr) return false;
        expr(n->receiver.get());
        if (n->selector == "and:") {
            int j = emit(Op::JumpFalse);
            inline_body(b);
            int j_end = emit(Op::Jump);
            code_[j].arg = here();
            emit(Op::PushFalse);
            code_[j_end].arg = here();
        } else {
            int j = emit(Op::JumpTrue);
            inline_body(b);
            int j_end = emit(Op::Jump);
            code_[j].arg = here();
            emit(Op::PushTrue);
            code_[j_end].arg = here();
        }
        return true;
    }

    bool inline_while2(MessageExpr* n) {
        BlockExpr* cond = zero_block(n->receiver.get());
        BlockExpr* body = zero_block(n->args[0].get());
        if (cond == nullptr || body == nullptr) return false;
        int start = here();
        sequence_value(cond->body, false);
        int jexit = emit(n->selector == "whileTrue:" ? Op::JumpFalse : Op::JumpTrue);
        inline_effect(body);
        int j = emit(Op::Jump);
        code_[j].arg = start;
        code_[jexit].arg = here();
        emit(Op::PushNil);
        return true;
    }

    bool inline_while0(MessageExpr* n) {
        BlockExpr* cond = zero_block(n->receiver.get());
        if (cond == nullptr) return false;
        int start = here();
        sequence_value(cond->body, false);
        int jexit = emit(n->selector == "whileTrue" ? Op::JumpFalse : Op::JumpTrue);
        int j = emit(Op::Jump);
        code_[j].arg = start;
        code_[jexit].arg = here();
        emit(Op::PushNil);
        return true;
    }

    bool inline_repeat(MessageExpr* n) {
        BlockExpr* body = zero_block(n->receiver.get());
        if (body == nullptr) return false;
        int start = here();
        inline_effect(body);
        int j = emit(Op::Jump);
        code_[j].arg = start;
        emit(Op::PushNil);
        return true;
    }

    bool inline_to_do(MessageExpr* n) {
        BlockExpr* body = one_block(n->args[1].get());
        if (body == nullptr) return false;
        int i_slot = scope_->declare(body->params[0]);
        int limit_slot = gentemp();
        expr(n->receiver.get());
        emit(Op::StoreLocal, i_slot);
        emit(Op::Pop);
        expr(n->args[0].get());
        emit(Op::StoreLocal, limit_slot);
        emit(Op::Pop);
        int start = here();
        emit(Op::PushLocal, i_slot);
        emit(Op::PushLocal, limit_slot);
        emit_send("<=", 1);
        int jexit = emit(Op::JumpFalse);
        inline_effect(body);
        emit(Op::PushLocal, i_slot);
        push_int(1);
        emit_send("+", 1);
        emit(Op::StoreLocal, i_slot);
        emit(Op::Pop);
        int j = emit(Op::Jump);
        code_[j].arg = start;
        code_[jexit].arg = here();
        emit(Op::PushNil);
        return true;
    }

    bool inline_times(MessageExpr* n) {
        BlockExpr* body = zero_block(n->args[0].get());
        if (body == nullptr) return false;
        int limit_slot = gentemp();
        int i_slot = gentemp();
        expr(n->receiver.get());
        emit(Op::StoreLocal, limit_slot);
        emit(Op::Pop);
        push_int(0);
        emit(Op::StoreLocal, i_slot);
        emit(Op::Pop);
        int start = here();
        emit(Op::PushLocal, i_slot);
        emit(Op::PushLocal, limit_slot);
        emit_send("<", 1);
        int jexit = emit(Op::JumpFalse);
        inline_effect(body);
        emit(Op::PushLocal, i_slot);
        push_int(1);
        emit_send("+", 1);
        emit(Op::StoreLocal, i_slot);
        emit(Op::Pop);
        int j = emit(Op::Jump);
        code_[j].arg = start;
        code_[jexit].arg = here();
        emit(Op::PushNil);
        return true;
    }

    // --- non-inlined blocks -> closures ---

    void block_literal(BlockExpr* node) {
        Scope block_scope(scope_);
        for (const auto& p : node->params) block_scope.declare(p);
        for (const auto& t : node->temps) block_scope.declare(t);

        Compiler sub(heap_);
        sub.begin(&block_scope);
        sub.cls_ = cls_;  // blocks reach the home method's instance variables
        sub.sequence_value(node->body, false);
        sub.emit(Op::BlockReturn);

        CompiledBlock* blk = heap_.new_block_template();
        blk->params = node->params;
        blk->local_names = block_scope.names;
        blk->code = std::move(sub.code_);
        blk->literals = std::move(sub.literals_);
        emit(Op::PushBlock, literal(ref(blk)));
    }
};

}  // namespace st
