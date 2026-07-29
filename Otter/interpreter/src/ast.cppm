export module otter.ast;

import std;
import otter.diagnostics;
import otter.types;

export namespace otter {

struct Expr;
struct Stmt;
struct Block;
struct ValueBlock;
struct FunctionDefinition;
struct FunctionDecl;
struct GlobalDecl;
struct StructDecl;
struct TypeAliasDecl;
struct ModuleAst;

using ExprPtr = std::unique_ptr<Expr>;
using StmtPtr = std::unique_ptr<Stmt>;

// ---------------------------------------------------------------------------
// Type expressions
//
// What the source says a type is, before names have been resolved. The checker
// turns each of these into a Type.
// ---------------------------------------------------------------------------

struct TypeExpr;
using TypeExprPtr = std::unique_ptr<TypeExpr>;

enum class TypeExprKind {
    Named,
    Pointer,
    Function,
};

struct TypeExpr {
    TypeExprKind kind = TypeExprKind::Named;
    Span span;

    // Named: a possibly qualified name, with type arguments for `array<T>`.
    std::vector<std::string> path;
    std::vector<TypeExprPtr> arguments;

    // Pointer: the pointee. Function: the result.
    TypeExprPtr target;

    // Function.
    std::vector<TypeExprPtr> parameters;

    const Type* resolved = nullptr;
};

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

enum class ExprKind {
    Integer,
    Floating,
    String,
    Char,
    Bool,
    Null,
    Name,
    Array,
    StructLiteral,
    Function,
    Call,
    Index,
    Field,
    Unary,
    Cast,
    Binary,
    Assign,
    Conditional,
};

struct Expr {
    explicit Expr(ExprKind kind, Span span) : kind(kind), span(std::move(span)) {}
    virtual ~Expr() = default;

    ExprKind kind;
    Span span;

    // Filled in by the checker.
    const Type* type = nullptr;
};

struct IntegerExpr : Expr {
    IntegerExpr(Span span, std::int64_t value)
        : Expr(ExprKind::Integer, std::move(span)), value(value) {}

    std::int64_t value = 0;
};

struct FloatingExpr : Expr {
    FloatingExpr(Span span, double value)
        : Expr(ExprKind::Floating, std::move(span)), value(value) {}

    double value = 0.0;
};

struct StringExpr : Expr {
    StringExpr(Span span, std::string value)
        : Expr(ExprKind::String, std::move(span)), value(std::move(value)) {}

    std::string value;
};

struct CharExpr : Expr {
    CharExpr(Span span, char32_t value) : Expr(ExprKind::Char, std::move(span)), value(value) {}

    char32_t value = 0;
};

struct BoolExpr : Expr {
    BoolExpr(Span span, bool value) : Expr(ExprKind::Bool, std::move(span)), value(value) {}

    bool value = false;
};

struct NullExpr : Expr {
    explicit NullExpr(Span span) : Expr(ExprKind::Null, std::move(span)) {}
};

// What a bare identifier turned out to name.
enum class NameKind {
    Unresolved,
    Local,
    Global,
    Function,
    Module,
};

struct NameExpr : Expr {
    NameExpr(Span span, std::string name)
        : Expr(ExprKind::Name, std::move(span)), name(std::move(name)) {}

    std::string name;

    NameKind resolution = NameKind::Unresolved;
    const FunctionDecl* function = nullptr;
    const GlobalDecl* global = nullptr;
    const ModuleAst* module = nullptr;
};

// `[a, b, c]`, or `[value; count]` when `repeated` is set.
struct ArrayExpr : Expr {
    explicit ArrayExpr(Span span) : Expr(ExprKind::Array, std::move(span)) {}

    std::vector<ExprPtr> elements;
    ExprPtr count;
    bool repeated = false;
};

struct FieldInit {
    std::string name;
    ExprPtr value;
    Span span;
    int index = -1;
};

struct StructLiteralExpr : Expr {
    explicit StructLiteralExpr(Span span) : Expr(ExprKind::StructLiteral, std::move(span)) {}

    std::vector<std::string> path;
    std::vector<FieldInit> initializers;
    StructInfo* structure = nullptr;
};

struct FunctionExpr : Expr {
    explicit FunctionExpr(Span span) : Expr(ExprKind::Function, std::move(span)) {}
    ~FunctionExpr() override;

    std::unique_ptr<FunctionDefinition> definition;
};

struct CallExpr : Expr {
    explicit CallExpr(Span span) : Expr(ExprKind::Call, std::move(span)) {}

    ExprPtr callee;
    std::vector<ExprPtr> arguments;
};

struct IndexExpr : Expr {
    explicit IndexExpr(Span span) : Expr(ExprKind::Index, std::move(span)) {}

    ExprPtr subject;
    ExprPtr index;
};

// What `a.b` turned out to mean.
enum class FieldKind {
    Unresolved,
    StructField,
    Length,
    ModuleFunction,
    ModuleGlobal,
    ModuleStruct,
};

struct FieldExpr : Expr {
    FieldExpr(Span span, std::string name)
        : Expr(ExprKind::Field, std::move(span)), name(std::move(name)) {}

    ExprPtr subject;
    std::string name;

    FieldKind resolution = FieldKind::Unresolved;
    int index = -1;
    // Set when the subject is a pointer to a struct and the field was reached
    // through it.
    bool throughPointer = false;
    const FunctionDecl* function = nullptr;
    const GlobalDecl* global = nullptr;
};

enum class UnaryOp {
    Plus,
    Minus,
    Not,
    Complement,
    Dereference,
    AddressOf,
};

struct UnaryExpr : Expr {
    UnaryExpr(Span span, UnaryOp op) : Expr(ExprKind::Unary, std::move(span)), op(op) {}

    UnaryOp op;
    ExprPtr operand;
};

struct CastExpr : Expr {
    explicit CastExpr(Span span) : Expr(ExprKind::Cast, std::move(span)) {}

    ExprPtr operand;
    TypeExprPtr target;
};

enum class BinaryOp {
    Multiply,
    Divide,
    Remainder,
    Add,
    Subtract,
    Less,
    LessEqual,
    Greater,
    GreaterEqual,
    Equal,
    NotEqual,
    And,
    Or,
};

struct BinaryExpr : Expr {
    BinaryExpr(Span span, BinaryOp op) : Expr(ExprKind::Binary, std::move(span)), op(op) {}

    BinaryOp op;
    ExprPtr left;
    ExprPtr right;

    // The type both operands were brought to; for comparisons this is not the
    // type of the expression itself.
    const Type* operandType = nullptr;
};

struct AssignExpr : Expr {
    explicit AssignExpr(Span span) : Expr(ExprKind::Assign, std::move(span)) {}

    ExprPtr target;
    ExprPtr value;
};

// `if (c) { ...; value } else { ...; other }`. Both arms are required, and an
// `else if` arrives as an alternative whose only content is another one of
// these.
struct IfExpr : Expr {
    explicit IfExpr(Span span) : Expr(ExprKind::Conditional, std::move(span)) {}
    ~IfExpr() override;

    ExprPtr condition;
    std::unique_ptr<ValueBlock> consequent;
    std::unique_ptr<ValueBlock> alternative;
};

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

enum class StmtKind {
    VariableDeclaration,
    NestedFunction,
    Return,
    If,
    While,
    For,
    Break,
    Continue,
    Expression,
    Block,
};

struct Stmt {
    explicit Stmt(StmtKind kind, Span span) : kind(kind), span(std::move(span)) {}
    virtual ~Stmt() = default;

    StmtKind kind;
    Span span;
};

struct VarStmt : Stmt {
    VarStmt(Span span, std::string name)
        : Stmt(StmtKind::VariableDeclaration, std::move(span)), name(std::move(name)) {}

    std::string name;
    TypeExprPtr declaredType;
    ExprPtr initializer;
    const Type* type = nullptr;
};

struct ReturnStmt : Stmt {
    explicit ReturnStmt(Span span) : Stmt(StmtKind::Return, std::move(span)) {}

    ExprPtr value;
};

struct IfStmt : Stmt {
    explicit IfStmt(Span span) : Stmt(StmtKind::If, std::move(span)) {}

    ExprPtr condition;
    StmtPtr consequent;
    StmtPtr alternative;
};

struct WhileStmt : Stmt {
    explicit WhileStmt(Span span) : Stmt(StmtKind::While, std::move(span)) {}

    ExprPtr condition;
    StmtPtr body;
};

// Any of the three parts may be absent. The initialiser is either a variable
// declaration or an expression statement.
struct ForStmt : Stmt {
    explicit ForStmt(Span span) : Stmt(StmtKind::For, std::move(span)) {}

    StmtPtr initializer;
    ExprPtr condition;
    ExprPtr step;
    StmtPtr body;
};

struct NestedFunctionStmt : Stmt {
    explicit NestedFunctionStmt(Span span) : Stmt(StmtKind::NestedFunction, std::move(span)) {}
    ~NestedFunctionStmt() override;

    std::unique_ptr<FunctionDefinition> definition;
};

struct BreakStmt : Stmt {
    explicit BreakStmt(Span span) : Stmt(StmtKind::Break, std::move(span)) {}
};

struct ContinueStmt : Stmt {
    explicit ContinueStmt(Span span) : Stmt(StmtKind::Continue, std::move(span)) {}
};

struct ExprStmt : Stmt {
    explicit ExprStmt(Span span) : Stmt(StmtKind::Expression, std::move(span)) {}

    ExprPtr value;
};

struct Block : Stmt {
    explicit Block(Span span) : Stmt(StmtKind::Block, std::move(span)) {}

    std::vector<StmtPtr> statements;
};

// A block that stands for a value: statements, and then the expression it
// yields. Only an if expression has these.
struct ValueBlock {
    Span span;
    std::vector<StmtPtr> statements;
    ExprPtr value;
};

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

struct Parameter {
    std::string name;
    TypeExprPtr declaredType;
    Span span;
    const Type* type = nullptr;
};

// The parts shared by a named function and an anonymous one.
struct FunctionDefinition {
    std::string name;
    std::vector<Parameter> parameters;
    TypeExprPtr declaredResult;
    // Absent when the host supplies the function.
    std::unique_ptr<Block> body;
    Span span;

    const Type* resultType = nullptr;
    const Type* type = nullptr;
    // Names the body reads from an enclosing function, in declaration order.
    std::vector<std::string> captures;
};

struct StructDecl {
    std::string name;
    bool exported = false;
    Span span;
    std::vector<std::string> fieldNames;
    std::vector<TypeExprPtr> fieldTypes;
    std::vector<Span> fieldSpans;

    StructInfo* structure = nullptr;
    const Type* type = nullptr;
};

struct FunctionDecl {
    std::unique_ptr<FunctionDefinition> definition;
    bool exported = false;
    ModuleAst* owner = nullptr;
};

// `type Name = Type;`. Aliases are transparent: the name and what it stands
// for are the same type, not two that convert.
struct TypeAliasDecl {
    std::string name;
    bool exported = false;
    Span span;
    TypeExprPtr target;
    ModuleAst* owner = nullptr;

    const Type* resolved = nullptr;
    bool resolving = false;
};

struct GlobalDecl {
    std::string name;
    bool exported = false;
    Span span;
    TypeExprPtr declaredType;
    ExprPtr initializer;
    const Type* type = nullptr;
    ModuleAst* owner = nullptr;
};

struct Import {
    std::string name;
    Span span;
    ModuleAst* target = nullptr;
};

struct ModuleAst {
    std::string name;
    std::string file;
    Span span;

    std::vector<Import> imports;
    std::vector<std::unique_ptr<StructDecl>> structs;
    std::vector<std::unique_ptr<TypeAliasDecl>> aliases;
    std::vector<std::unique_ptr<FunctionDecl>> functions;
    std::vector<std::unique_ptr<GlobalDecl>> globals;

    bool checked = false;

    const Import* findImport(const std::string& importName) const {
        for (const Import& entry : imports) {
            if (entry.name == importName) {
                return &entry;
            }
        }
        return nullptr;
    }

    const StructDecl* findStruct(const std::string& structName) const {
        for (const auto& entry : structs) {
            if (entry->name == structName) {
                return entry.get();
            }
        }
        return nullptr;
    }

    TypeAliasDecl* findAlias(const std::string& aliasName) const {
        for (const auto& entry : aliases) {
            if (entry->name == aliasName) {
                return entry.get();
            }
        }
        return nullptr;
    }

    const FunctionDecl* findFunction(const std::string& functionName) const {
        for (const auto& entry : functions) {
            if (entry->definition->name == functionName) {
                return entry.get();
            }
        }
        return nullptr;
    }

    const GlobalDecl* findGlobal(const std::string& globalName) const {
        for (const auto& entry : globals) {
            if (entry->name == globalName) {
                return entry.get();
            }
        }
        return nullptr;
    }
};

FunctionExpr::~FunctionExpr() = default;
NestedFunctionStmt::~NestedFunctionStmt() = default;
IfExpr::~IfExpr() = default;

}  // namespace otter
