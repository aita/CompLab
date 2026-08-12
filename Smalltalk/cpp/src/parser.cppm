// Parser partition — recursive descent, exception-free (errors are reported via
// ParseResult::ok / error). Precedence: unary > binary > keyword.
export module st:parser;

import std;
import :lexer;
import :ast;

export namespace st {

template <class T>
struct Parsed {
    T value;
    bool ok = true;
    std::string error;
};

namespace detail {

class Parser {
public:
    explicit Parser(std::string_view src) {
        LexResult r = tokenize(src);
        toks_ = std::move(r.tokens);
        if (!r.ok) {
            ok_ = false;
            error_ = r.error;
        }
    }

    bool ok() const { return ok_; }
    const std::string& error() const { return error_; }

    Sequence parse_sequence() {
        Sequence seq = sequence();
        if (ok_ && !at(Tok::Eof)) fail("trailing input");
        return seq;
    }

    MethodNode parse_method() {
        MethodNode m;
        message_pattern(m.selector, m.params);
        if (ok_) m.body = sequence();
        if (ok_ && !at(Tok::Eof)) fail("trailing input after method body");
        return m;
    }

private:
    std::vector<Token> toks_;
    std::size_t pos_ = 0;
    bool ok_ = true;
    std::string error_;

    const Token& cur() const { return toks_[pos_]; }
    const Token& peekTok(std::size_t off) const {
        std::size_t j = pos_ + off;
        return j < toks_.size() ? toks_[j] : toks_.back();
    }
    bool at(Tok k) const { return cur().kind == k; }
    bool at_bin(std::string_view text) const {
        return cur().kind == Tok::Binary && cur().text == text;
    }
    const Token& advance() {
        const Token& t = toks_[pos_];
        if (t.kind != Tok::Eof) ++pos_;
        return t;
    }
    void fail(std::string msg) {
        if (!ok_) return;
        ok_ = false;
        error_ = "line " + std::to_string(cur().line) + ": " + std::move(msg);
    }
    void expect(Tok k, const char* what) {
        if (!at(k)) {
            fail(std::string("expected ") + what);
            return;
        }
        advance();
    }

    void message_pattern(std::string& selector, std::vector<std::string>& params) {
        if (at(Tok::Keyword)) {
            while (at(Tok::Keyword) && ok_) {
                selector += advance().text;
                if (!at(Tok::Ident)) { fail("expected argument name"); return; }
                params.push_back(advance().text);
            }
        } else if (at(Tok::Binary)) {
            selector = advance().text;
            if (!at(Tok::Ident)) { fail("expected argument name"); return; }
            params.push_back(advance().text);
        } else if (at(Tok::Ident)) {
            selector = advance().text;
        } else {
            fail("expected a message pattern");
        }
    }

    std::vector<std::string> temps() {
        std::vector<std::string> names;
        if (at_bin("|")) {
            advance();
            while (at(Tok::Ident)) names.push_back(advance().text);
            if (!at_bin("|")) { fail("expected '|'"); return names; }
            advance();
        }
        return names;
    }

    bool seq_end() const {
        return at(Tok::Eof) || at(Tok::RBrack);
    }

    Sequence sequence() {
        Sequence seq;
        seq.temps = temps();
        seq_body(seq);
        return seq;
    }

    void seq_body(Sequence& seq) {
        while (!seq_end() && ok_) {
            if (at(Tok::Return)) {
                advance();
                auto r = std::make_unique<ReturnExpr>();
                r->value = expression();
                seq.statements.push_back(std::move(r));
                if (at(Tok::Dot)) advance();
                break;
            }
            seq.statements.push_back(expression());
            if (at(Tok::Dot)) {
                advance();
            } else {
                break;
            }
        }
    }

    ExprP expression() {
        if (at(Tok::Ident) && peekTok(1).kind == Tok::Assign) {
            auto a = std::make_unique<AssignExpr>();
            a->name = advance().text;
            advance();  // :=
            a->value = expression();
            return a;
        }
        return cascade();
    }

    ExprP cascade() {
        ExprP first = keyword_expr();
        if (!at(Tok::Semi) || !ok_) return first;
        if (first->kind != NK::Message) {
            fail("cascade requires a message receiver");
            return first;
        }
        auto* m = static_cast<MessageExpr*>(first.get());
        auto casc = std::make_unique<CascadeExpr>();
        casc->receiver = std::move(m->receiver);
        CascadeMsg first_msg;
        first_msg.selector = m->selector;
        first_msg.args = std::move(m->args);
        casc->messages.push_back(std::move(first_msg));
        while (at(Tok::Semi) && ok_) {
            advance();
            casc->messages.push_back(cascade_message());
        }
        return casc;
    }

    CascadeMsg cascade_message() {
        CascadeMsg msg;
        if (at(Tok::Keyword)) {
            while (at(Tok::Keyword) && ok_) {
                msg.selector += advance().text;
                msg.args.push_back(binary_expr());
            }
        } else if (at(Tok::Binary)) {
            msg.selector = advance().text;
            msg.args.push_back(unary_expr());
        } else if (at(Tok::Ident)) {
            msg.selector = advance().text;
        } else {
            fail("expected a cascade message");
        }
        return msg;
    }

    ExprP keyword_expr() {
        ExprP recv = binary_expr();
        if (!at(Tok::Keyword)) return recv;
        auto m = std::make_unique<MessageExpr>();
        m->receiver = std::move(recv);
        while (at(Tok::Keyword) && ok_) {
            m->selector += advance().text;
            m->args.push_back(binary_expr());
        }
        return m;
    }

    ExprP binary_expr() {
        ExprP left = unary_expr();
        while (at(Tok::Binary) && !at_bin("|") && ok_) {
            auto m = std::make_unique<MessageExpr>();
            m->selector = advance().text;
            m->receiver = std::move(left);
            m->args.push_back(unary_expr());
            left = std::move(m);
        }
        return left;
    }

    ExprP unary_expr() {
        ExprP recv = primary();
        while (at(Tok::Ident) && ok_) {
            auto m = std::make_unique<MessageExpr>();
            m->selector = advance().text;
            m->receiver = std::move(recv);
            recv = std::move(m);
        }
        return recv;
    }

    ExprP primary() {
        const Token& t = cur();
        switch (t.kind) {
            case Tok::Integer: {
                advance();
                auto e = std::make_unique<LiteralExpr>();
                e->lit.k = Literal::K::Int;
                e->lit.i = t.ival;
                return e;
            }
            case Tok::Float: {
                advance();
                auto e = std::make_unique<LiteralExpr>();
                e->lit.k = Literal::K::Float;
                e->lit.d = t.fval;
                return e;
            }
            case Tok::String: {
                std::string s = advance().text;
                auto e = std::make_unique<LiteralExpr>();
                e->lit.k = Literal::K::Str;
                e->lit.s = std::move(s);
                return e;
            }
            case Tok::Symbol: {
                std::string s = advance().text;
                auto e = std::make_unique<LiteralExpr>();
                e->lit.k = Literal::K::Sym;
                e->lit.s = std::move(s);
                return e;
            }
            case Tok::Char: {
                std::string s = advance().text;
                auto e = std::make_unique<LiteralExpr>();
                e->lit.k = Literal::K::Char;
                e->lit.c = s.empty() ? ' ' : s[0];
                return e;
            }
            case Tok::LParen: {
                advance();
                ExprP inner = expression();
                expect(Tok::RParen, "')'");
                return inner;
            }
            case Tok::LBrack:
                return block();
            case Tok::LBrace:
                return dynamic_array();
            case Tok::HashParen:
                return literal_array();
            case Tok::Ident: {
                std::string name = advance().text;
                if (name == "true" || name == "false" || name == "nil") {
                    auto e = std::make_unique<LiteralExpr>();
                    if (name == "nil") {
                        e->lit.k = Literal::K::Nil;
                    } else {
                        e->lit.k = Literal::K::Bool;
                        e->lit.b = (name == "true");
                    }
                    return e;
                }
                return std::make_unique<VariableExpr>(std::move(name));
            }
            default:
                fail("unexpected token in expression");
                return std::make_unique<LiteralExpr>();
        }
    }

    ExprP block() {
        expect(Tok::LBrack, "'['");
        auto blk = std::make_unique<BlockExpr>();
        if (at(Tok::Colon)) {
            while (at(Tok::Colon) && ok_) {
                advance();
                if (!at(Tok::Ident)) { fail("expected block argument"); break; }
                blk->params.push_back(advance().text);
            }
            if (!at_bin("|")) { fail("expected '|' after block arguments"); return blk; }
            advance();
        }
        blk->temps = temps();
        // body (no leading temps; already consumed)
        while (!seq_end() && ok_) {
            if (at(Tok::Return)) {
                advance();
                auto r = std::make_unique<ReturnExpr>();
                r->value = expression();
                blk->body.statements.push_back(std::move(r));
                if (at(Tok::Dot)) advance();
                break;
            }
            blk->body.statements.push_back(expression());
            if (at(Tok::Dot)) {
                advance();
            } else {
                break;
            }
        }
        expect(Tok::RBrack, "']'");
        return blk;
    }

    ExprP dynamic_array() {
        expect(Tok::LBrace, "'{'");
        auto arr = std::make_unique<DynArrayExpr>();
        while (!at(Tok::RBrace) && ok_) {
            arr->elements.push_back(expression());
            if (at(Tok::Dot)) advance();
        }
        expect(Tok::RBrace, "'}'");
        return arr;
    }

    ExprP literal_array() {
        expect(Tok::HashParen, "'#('");
        auto e = std::make_unique<LiteralExpr>();
        e->lit.k = Literal::K::Arr;
        while (!at(Tok::RParen) && ok_) {
            e->lit.arr.push_back(literal_element());
        }
        expect(Tok::RParen, "')'");
        return e;
    }

    Literal literal_element() {
        const Token& t = cur();
        Literal lit;
        switch (t.kind) {
            case Tok::Integer: lit.k = Literal::K::Int; lit.i = advance().ival; break;
            case Tok::Float: lit.k = Literal::K::Float; lit.d = advance().fval; break;
            case Tok::String: lit.k = Literal::K::Str; lit.s = advance().text; break;
            case Tok::Symbol: lit.k = Literal::K::Sym; lit.s = advance().text; break;
            case Tok::Char: {
                std::string s = advance().text;
                lit.k = Literal::K::Char;
                lit.c = s.empty() ? ' ' : s[0];
                break;
            }
            case Tok::Ident: {
                std::string n = advance().text;
                if (n == "true") { lit.k = Literal::K::Bool; lit.b = true; }
                else if (n == "false") { lit.k = Literal::K::Bool; lit.b = false; }
                else if (n == "nil") { lit.k = Literal::K::Nil; }
                else { lit.k = Literal::K::Sym; lit.s = std::move(n); }
                break;
            }
            case Tok::Keyword: {
                std::string s;
                while (at(Tok::Keyword) && ok_) s += advance().text;
                lit.k = Literal::K::Sym;
                lit.s = std::move(s);
                break;
            }
            case Tok::Binary: lit.k = Literal::K::Sym; lit.s = advance().text; break;
            default: fail("bad literal-array element"); break;
        }
        return lit;
    }
};

}  // namespace detail

Parsed<Sequence> parse_sequence(std::string_view src) {
    detail::Parser p(src);
    Sequence seq = p.parse_sequence();
    return Parsed<Sequence>{std::move(seq), p.ok(), p.error()};
}

Parsed<MethodNode> parse_method(std::string_view src) {
    detail::Parser p(src);
    MethodNode m = p.parse_method();
    return Parsed<MethodNode>{std::move(m), p.ok(), p.error()};
}

}  // namespace st
