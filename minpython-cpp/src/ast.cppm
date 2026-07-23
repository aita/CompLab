// AST partition — a "fat node" tree for the MinPython subset.
//
// Rather than a class hierarchy, each Expr/Stmt is one struct with a Kind tag
// and every field any node might need. It wastes a little memory but keeps the
// parser and compiler to a flat switch on `.kind`, which mirrors the Python
// compiler's `match node:` dispatch closely.
export module minpython:ast;

import std;

import :bytecode;

export namespace minpython {

enum class ExprKind {
  ConstInt,
  ConstStr,
  ConstBool,
  ConstNone,
  Name,
  List,
  Subscript,
  BinOp,
  UnaryOp,
  BoolOp,   // and / or
  Compare,  // chained: a < b < c
  IfExp,    // body if test else orelse
  Call,
};

struct Expr {
  ExprKind kind;
  int lineno = 0;

  std::int64_t int_val = 0;    // ConstInt
  std::string str_val;    // ConstStr, Name id, Call callee name
  bool bool_val = false;  // ConstBool

  Op op{};             // BinOp / UnaryOp opcode
  bool is_and = false;  // BoolOp: true for `and`, false for `or`

  std::unique_ptr<Expr> lhs;      // BinOp left, Compare left
  std::unique_ptr<Expr> rhs;      // BinOp right
  std::unique_ptr<Expr> operand;  // UnaryOp
  std::unique_ptr<Expr> obj;      // Subscript object
  std::unique_ptr<Expr> index;    // Subscript index
  std::unique_ptr<Expr> test;     // IfExp condition
  std::unique_ptr<Expr> body;     // IfExp value-if-true
  std::unique_ptr<Expr> orelse;   // IfExp value-if-false

  // List elements / Call args / BoolOp operands / Compare comparators.
  std::vector<std::unique_ptr<Expr>> elts;
  std::vector<Op> ops;  // Compare chain (Eq..Ge), parallel to elts
};

enum class StmtKind {
  FunctionDef,
  Return,
  Assign,
  AugAssign,
  ExprStmt,
  If,
  While,
  Break,
  Continue,
  Pass,
  Global,
};

struct Stmt {
  StmtKind kind;
  int lineno = 0;

  std::string name;                // FunctionDef name
  std::vector<std::string> params;  // FunctionDef params / Global names
  std::vector<std::string> targets;  // Assign / AugAssign target name(s)

  Op op{};                       // AugAssign operator
  std::unique_ptr<Expr> value;   // Return / Assign / AugAssign / ExprStmt / test
  std::vector<std::unique_ptr<Stmt>> body;
  std::vector<std::unique_ptr<Stmt>> orelse;
};

using ExprPtr = std::unique_ptr<Expr>;
using StmtPtr = std::unique_ptr<Stmt>;

}  // namespace minpython
