// Lexer partition — tokenizes Smalltalk source.
//
// Exception-free: numeric literals are parsed with std::from_chars and errors
// are reported by returning a LexResult with ok == false, never by throwing.
module;
#include <cctype>
#include <charconv>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

export module st:lexer;

export namespace st {

enum class Tok {
    Eof,
    Integer,
    Float,
    String,
    Symbol,
    Char,
    Ident,
    Keyword,  // `foo:`
    Binary,   // + - <= | , @ ...
    Assign,   // :=
    Return,   // ^
    Colon,    // : (block argument marker)
    Dot,
    Semi,
    LParen,
    RParen,
    LBrack,
    RBrack,
    LBrace,
    RBrace,
    HashParen,  // #(
};

struct Token {
    Tok kind;
    std::string text;      // identifier / selector / string contents
    std::int64_t ival = 0;
    double fval = 0.0;
    int line = 1;
};

struct LexResult {
    std::vector<Token> tokens;
    bool ok = true;
    std::string error;
};

std::string_view tok_name(Tok k) {
    switch (k) {
        case Tok::Eof: return "Eof";
        case Tok::Integer: return "Integer";
        case Tok::Float: return "Float";
        case Tok::String: return "String";
        case Tok::Symbol: return "Symbol";
        case Tok::Char: return "Char";
        case Tok::Ident: return "Ident";
        case Tok::Keyword: return "Keyword";
        case Tok::Binary: return "Binary";
        case Tok::Assign: return "Assign";
        case Tok::Return: return "Return";
        case Tok::Colon: return "Colon";
        case Tok::Dot: return "Dot";
        case Tok::Semi: return "Semi";
        case Tok::LParen: return "LParen";
        case Tok::RParen: return "RParen";
        case Tok::LBrack: return "LBrack";
        case Tok::RBrack: return "RBrack";
        case Tok::LBrace: return "LBrace";
        case Tok::RBrace: return "RBrace";
        case Tok::HashParen: return "HashParen";
    }
    return "?";
}

namespace detail {

constexpr std::string_view kBinaryChars = "+-*/~<>=&|@%,?!";

inline bool is_binary(char c) {
    return kBinaryChars.find(c) != std::string_view::npos;
}
inline bool is_ident_start(char c) {
    return (std::isalpha(static_cast<unsigned char>(c)) != 0) || c == '_';
}
inline bool is_ident(char c) {
    return (std::isalnum(static_cast<unsigned char>(c)) != 0) || c == '_';
}

class Lexer {
public:
    explicit Lexer(std::string_view text) : text_(text) {}

    LexResult run() {
        LexResult result;
        while (true) {
            Token t = next(result);
            if (!result.ok) return result;
            bool eof = t.kind == Tok::Eof;
            result.tokens.push_back(std::move(t));
            if (eof) return result;
        }
    }

private:
    std::string_view text_;
    std::size_t i_ = 0;
    int line_ = 1;

    char peek(std::size_t off = 0) const {
        std::size_t j = i_ + off;
        return j < text_.size() ? text_[j] : '\0';
    }
    char advance() {
        char c = text_[i_++];
        if (c == '\n') ++line_;
        return c;
    }
    bool at_end() const { return i_ >= text_.size(); }

    void skip_trivia(LexResult& r) {
        while (!at_end()) {
            char c = peek();
            if (std::isspace(static_cast<unsigned char>(c)) != 0) {
                advance();
            } else if (c == '"') {  // "comment", "" escapes a quote
                advance();
                bool closed = false;
                while (!at_end()) {
                    char d = advance();
                    if (d == '"') {
                        if (peek() == '"') {
                            advance();
                        } else {
                            closed = true;
                            break;
                        }
                    }
                }
                if (!closed) fail(r, "unterminated comment");
                if (!r.ok) return;
            } else {
                break;
            }
        }
    }

    void fail(LexResult& r, std::string msg) {
        r.ok = false;
        r.error = "line " + std::to_string(line_) + ": " + std::move(msg);
    }

    Token make(Tok k) { return Token{.kind = k, .line = line_}; }

    Token next(LexResult& r) {
        skip_trivia(r);
        if (!r.ok) return make(Tok::Eof);
        if (at_end()) return make(Tok::Eof);

        int line = line_;
        char c = peek();

        if (is_ident_start(c)) return ident();
        if (std::isdigit(static_cast<unsigned char>(c)) != 0) return number(r);
        if (c == '\'') return string_literal(r);
        if (c == '#') return hash(r);
        if (c == '$') {
            advance();
            if (at_end()) {
                fail(r, "unterminated character literal");
                return make(Tok::Eof);
            }
            Token t = make(Tok::Char);
            t.text = std::string(1, advance());
            t.line = line;
            return t;
        }
        if (c == ':' && peek(1) == '=') {
            advance();
            advance();
            return make(Tok::Assign);
        }
        if (c == ':') {
            advance();
            return make(Tok::Colon);
        }
        if (c == '^') {
            advance();
            return make(Tok::Return);
        }

        switch (c) {
            case '.': advance(); return make(Tok::Dot);
            case ';': advance(); return make(Tok::Semi);
            case '(': advance(); return make(Tok::LParen);
            case ')': advance(); return make(Tok::RParen);
            case '[': advance(); return make(Tok::LBrack);
            case ']': advance(); return make(Tok::RBrack);
            case '{': advance(); return make(Tok::LBrace);
            case '}': advance(); return make(Tok::RBrace);
            default: break;
        }

        if (is_binary(c)) return binary();

        fail(r, std::string("unexpected character '") + c + "'");
        return make(Tok::Eof);
    }

    Token ident() {
        int line = line_;
        std::size_t start = i_;
        while (!at_end() && is_ident(peek())) advance();
        std::string name(text_.substr(start, i_ - start));
        if (peek() == ':' && peek(1) != '=') {
            advance();  // consume ':'
            Token t = make(Tok::Keyword);
            t.text = std::move(name) + ":";
            t.line = line;
            return t;
        }
        Token t = make(Tok::Ident);
        t.text = std::move(name);
        t.line = line;
        return t;
    }

    Token number(LexResult& r) {
        int line = line_;
        std::size_t start = i_;
        while (!at_end() && (std::isdigit(static_cast<unsigned char>(peek())) != 0)) {
            advance();
        }
        bool is_float = false;
        // a '.' is only a decimal point if a digit follows it
        if (peek() == '.' && (std::isdigit(static_cast<unsigned char>(peek(1))) != 0)) {
            is_float = true;
            advance();
            while (!at_end() && (std::isdigit(static_cast<unsigned char>(peek())) != 0)) {
                advance();
            }
        }
        if (peek() == 'e' || peek() == 'E') {
            is_float = true;
            advance();
            if (peek() == '+' || peek() == '-') advance();
            while (!at_end() && (std::isdigit(static_cast<unsigned char>(peek())) != 0)) {
                advance();
            }
        }
        std::string_view lexeme = text_.substr(start, i_ - start);
        Token t = make(is_float ? Tok::Float : Tok::Integer);
        t.line = line;
        const char* begin = lexeme.data();
        const char* end = begin + lexeme.size();
        if (is_float) {
            auto [ptr, ec] = std::from_chars(begin, end, t.fval);
            if (ec != std::errc{} || ptr != end) fail(r, "malformed float literal");
        } else {
            auto [ptr, ec] = std::from_chars(begin, end, t.ival);
            if (ec != std::errc{} || ptr != end) fail(r, "malformed integer literal");
        }
        return t;
    }

    Token string_literal(LexResult& r) {
        int line = line_;
        advance();  // opening quote
        std::string out;
        while (!at_end()) {
            char d = advance();
            if (d == '\'') {
                if (peek() == '\'') {
                    advance();
                    out.push_back('\'');
                } else {
                    Token t = make(Tok::String);
                    t.text = std::move(out);
                    t.line = line;
                    return t;
                }
            } else {
                out.push_back(d);
            }
        }
        fail(r, "unterminated string literal");
        return make(Tok::Eof);
    }

    Token hash(LexResult& r) {
        int line = line_;
        advance();  // '#'
        char c = peek();
        if (c == '(') {
            advance();
            Token t = make(Tok::HashParen);
            t.line = line;
            return t;
        }
        if (c == '\'') {
            Token s = string_literal(r);
            s.kind = Tok::Symbol;
            s.line = line;
            return s;
        }
        if (is_ident_start(c)) {
            std::size_t start = i_;
            while (!at_end() && (is_ident(peek()) || peek() == ':')) advance();
            Token t = make(Tok::Symbol);
            t.text = std::string(text_.substr(start, i_ - start));
            t.line = line;
            return t;
        }
        if (is_binary(c)) {
            std::size_t start = i_;
            while (!at_end() && is_binary(peek())) advance();
            Token t = make(Tok::Symbol);
            t.text = std::string(text_.substr(start, i_ - start));
            t.line = line;
            return t;
        }
        fail(r, "malformed symbol literal");
        return make(Tok::Eof);
    }

    Token binary() {
        int line = line_;
        std::size_t start = i_;
        while (!at_end() && is_binary(peek())) advance();
        Token t = make(Tok::Binary);
        t.text = std::string(text_.substr(start, i_ - start));
        t.line = line;
        return t;
    }
};

}  // namespace detail

LexResult tokenize(std::string_view source) {
    return detail::Lexer(source).run();
}

std::string token_desc(const Token& t) {
    std::string s(tok_name(t.kind));
    if (t.kind == Tok::Integer) return s + "(" + std::to_string(t.ival) + ")";
    if (t.kind == Tok::Float) return s + "(" + std::to_string(t.fval) + ")";
    if (!t.text.empty()) return s + "(" + t.text + ")";
    return s;
}

}  // namespace st
