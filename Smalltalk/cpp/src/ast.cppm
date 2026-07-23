// AST partition. Compile-time only: nodes are owned by std::unique_ptr (not
// shared_ptr) and freed once a method is compiled. Literals are described
// structurally here and materialized into GC values by the compiler.
module;
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

export module st:ast;

export namespace st {

// A source-level literal (materialized into a runtime Value by the compiler).
struct Literal {
    enum class K { Nil, Bool, Int, Float, Str, Sym, Char, Arr };
    K k = K::Nil;
    bool b = false;
    std::int64_t i = 0;
    double d = 0.0;
    std::string s;  // Str / Sym text
    char c = 0;
    std::vector<Literal> arr;  // for K::Arr
};

enum class NK { Literal, Variable, Assign, Message, Cascade, Block, Return, DynArray };

struct Expr {
    NK kind;
    explicit Expr(NK k) : kind(k) {}
    Expr(const Expr&) = delete;
    Expr& operator=(const Expr&) = delete;
    virtual ~Expr() = default;
};
using ExprP = std::unique_ptr<Expr>;

struct Sequence {
    std::vector<std::string> temps;
    std::vector<ExprP> statements;
};

struct LiteralExpr : Expr {
    Literal lit;
    LiteralExpr() : Expr(NK::Literal) {}
};

struct VariableExpr : Expr {
    std::string name;
    explicit VariableExpr(std::string n) : Expr(NK::Variable), name(std::move(n)) {}
};

struct AssignExpr : Expr {
    std::string name;
    ExprP value;
    AssignExpr() : Expr(NK::Assign) {}
};

struct MessageExpr : Expr {
    ExprP receiver;
    std::string selector;
    std::vector<ExprP> args;
    MessageExpr() : Expr(NK::Message) {}
};

struct CascadeMsg {
    std::string selector;
    std::vector<ExprP> args;
};

struct CascadeExpr : Expr {
    ExprP receiver;
    std::vector<CascadeMsg> messages;
    CascadeExpr() : Expr(NK::Cascade) {}
};

struct BlockExpr : Expr {
    std::vector<std::string> params;
    std::vector<std::string> temps;
    Sequence body;
    BlockExpr() : Expr(NK::Block) {}
};

struct ReturnExpr : Expr {
    ExprP value;
    ReturnExpr() : Expr(NK::Return) {}
};

struct DynArrayExpr : Expr {
    std::vector<ExprP> elements;
    DynArrayExpr() : Expr(NK::DynArray) {}
};

struct MethodNode {
    std::string selector;
    std::vector<std::string> params;
    Sequence body;
};

}  // namespace st
