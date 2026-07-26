//! Syntax tree produced by [`crate::parser`].

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum UnOp {
    Neg,
    Not,
}

impl UnOp {
    pub fn spelling(self) -> &'static str {
        match self {
            UnOp::Neg => "-",
            UnOp::Not => "!",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Lt,
    Le,
    Gt,
    Ge,
    Eq,
    Ne,
    And,
    Or,
}

impl BinOp {
    pub fn spelling(self) -> &'static str {
        match self {
            BinOp::Add => "+",
            BinOp::Sub => "-",
            BinOp::Mul => "*",
            BinOp::Div => "/",
            BinOp::Rem => "%",
            BinOp::Lt => "<",
            BinOp::Le => "<=",
            BinOp::Gt => ">",
            BinOp::Ge => ">=",
            BinOp::Eq => "==",
            BinOp::Ne => "!=",
            BinOp::And => "&&",
            BinOp::Or => "||",
        }
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Expr {
    Int(i64),
    Bool(bool),
    Var(String),
    Unary(UnOp, Box<Expr>),
    Binary(BinOp, Box<Expr>, Box<Expr>),
    /// The callee is an arbitrary expression, so `f(1)(2)` and calling a
    /// function held in a variable both parse.
    Call(Box<Expr>, Vec<Expr>),
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Stmt {
    Let(String, Expr),
    Assign(String, Expr),
    If(Expr, Block, Option<Block>),
    While(Expr, Block),
    Return(Option<Expr>),
    Print(Expr),
    Expr(Expr),
}

pub type Block = Vec<Stmt>;

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Func {
    pub name: String,
    pub params: Vec<String>,
    pub body: Block,
}

/// A whole source file: function definitions plus whatever statements were
/// written outside of any of them.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Program {
    pub funcs: Vec<Func>,
    /// Statements written at the top level, in source order. They become the
    /// body of an implicit `main`.
    pub top_level: Block,
}
