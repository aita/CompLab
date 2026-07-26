//! nom-based parser for the copypatch surface syntax.
//!
//! ```text
//! program := item*
//! item    := fn | stmt        -- loose statements become an implicit `main`
//! fn      := "fn" name "(" (name ("," name)*)? ")" block
//! block   := "{" stmt* "}"
//! stmt    := "let" name "=" expr ";"
//!          | name "=" expr ";"
//!          | "if" expr block ("else" (block | if-stmt))?
//!          | "while" expr block
//!          | "return" expr? ";"
//!          | "print" expr ";"
//!          | expr ";"
//! ```
//!
//! Expression precedence, loosest first: `||`, `&&`, `== !=`,
//! `< <= > >=`, `+ -`, `* / %`, prefix `- !`, call, atom.

use nom::branch::alt;
use nom::bytes::complete::{tag, take_while};
use nom::character::complete::{digit1, multispace0, satisfy};
use nom::combinator::{map, opt, recognize};
use nom::error::{ErrorKind, ParseError as NomParseError};
use nom::multi::{many0, separated_list0};
use nom::sequence::{pair, preceded};
use nom::IResult;

use crate::ast::{BinOp, Block, Expr, Func, Program, Stmt, UnOp};
use crate::value;

/// A parse error that optionally carries a human-readable expectation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PErr<'a> {
    input: &'a str,
    msg: Option<&'static str>,
}

impl<'a> NomParseError<&'a str> for PErr<'a> {
    fn from_error_kind(input: &'a str, _: ErrorKind) -> Self {
        PErr { input, msg: None }
    }
    fn append(_: &'a str, _: ErrorKind, other: Self) -> Self {
        other
    }
}

type In<'a> = &'a str;
type R<'a, T> = IResult<In<'a>, T, PErr<'a>>;

/// Unrecoverable error: stops `alt`/`many0` from backtracking past a point
/// where we already know what the user meant.
fn cut<'a, T>(i: In<'a>, msg: &'static str) -> R<'a, T> {
    Err(nom::Err::Failure(PErr {
        input: i,
        msg: Some(msg),
    }))
}

fn soft<T>(i: In<'_>) -> R<'_, T> {
    Err(nom::Err::Error(PErr {
        input: i,
        msg: None,
    }))
}

// ------------------------------------------------------------------ lexing

/// Whitespace and `//` line comments.
fn ws(mut i: In) -> R<()> {
    loop {
        let (rest, _) = multispace0(i)?;
        match rest.strip_prefix("//") {
            Some(after) => {
                let end = after.find('\n').map_or(after.len(), |p| p + 1);
                i = &after[end..];
            }
            None => return Ok((rest, ())),
        }
    }
}

/// A literal operator or punctuator, with leading whitespace skipped.
fn op<'a>(t: &'static str) -> impl Fn(In<'a>) -> R<'a, &'a str> {
    move |i| preceded(ws, tag(t))(i)
}

/// `=` that is not the start of `==`.
fn assign_op(i: In) -> R<()> {
    let (rest, _) = op("=")(i)?;
    if rest.starts_with('=') {
        return soft(i);
    }
    Ok((rest, ()))
}

fn require<'a>(t: &'static str, msg: &'static str, i: In<'a>) -> R<'a, ()> {
    match op(t)(i) {
        Ok((rest, _)) => Ok((rest, ())),
        Err(_) => cut(i, msg),
    }
}

const KEYWORDS: &[&str] = &[
    "fn", "let", "if", "else", "while", "return", "print", "true", "false",
];

fn ident(i: In) -> R<&str> {
    preceded(
        ws,
        recognize(pair(
            satisfy(|c| c.is_ascii_alphabetic() || c == '_'),
            take_while(|c: char| c.is_ascii_alphanumeric() || c == '_'),
        )),
    )(i)
}

/// An identifier that is not a reserved word.
fn name(i: In) -> R<String> {
    let (rest, s) = ident(i)?;
    if KEYWORDS.contains(&s) {
        return soft(i);
    }
    Ok((rest, s.to_string()))
}

/// A specific reserved word. Matches whole identifiers only, so `iffy` is not
/// an `if`.
fn kw<'a>(k: &'static str) -> impl Fn(In<'a>) -> R<'a, ()> {
    move |i| {
        let (rest, s) = ident(i)?;
        if s == k {
            Ok((rest, ()))
        } else {
            soft(i)
        }
    }
}

// -------------------------------------------------------------- expressions

/// A digit run, already given its sign. Signed rather than negated after the
/// fact so the most negative integer can still be written as a literal.
fn signed_int_lit(i: In, negative: bool) -> R<Expr> {
    let (rest, digits) = preceded(ws, digit1)(i)?;
    let parsed = digits
        .parse::<i64>()
        .ok()
        .map(|n| if negative { n.wrapping_neg() } else { n });
    match parsed {
        Some(n) if value::fits(n) => Ok((rest, Expr::Int(n))),
        _ => cut(i, "integer literal is out of range (63-bit signed)"),
    }
}

fn int_lit(i: In) -> R<Expr> {
    signed_int_lit(i, false)
}

fn primary(i: In) -> R<Expr> {
    alt((
        int_lit,
        map(kw("true"), |_| Expr::Bool(true)),
        map(kw("false"), |_| Expr::Bool(false)),
        map(name, Expr::Var),
        paren,
    ))(i)
}

fn paren(i: In) -> R<Expr> {
    let (i, _) = op("(")(i)?;
    let (i, e) = expr(i)?;
    let (i, _) = require(")", "expected `)`", i)?;
    Ok((i, e))
}

/// A primary followed by any number of argument lists. Calls are a postfix
/// operator on an arbitrary expression, so `f(1)(2)` and `(pick(n))(3)` work.
fn atom(i: In) -> R<Expr> {
    let (mut i, mut e) = primary(i)?;
    loop {
        let Ok((rest, _)) = op("(")(i) else {
            return Ok((i, e));
        };
        let (rest, args) = separated_list0(op(","), expr)(rest)?;
        let (rest, _) = require(")", "expected `)` to close the argument list", rest)?;
        e = Expr::Call(Box::new(e), args);
        i = rest;
    }
}

fn unary(i: In) -> R<Expr> {
    if let Ok((rest, _)) = op("!")(i) {
        let (rest, e) = unary(rest)?;
        return Ok((rest, Expr::Unary(UnOp::Not, Box::new(e))));
    }
    if let Ok((rest, _)) = op("-")(i) {
        // A minus directly in front of digits is part of the literal, so
        // -4611686018427387904 is writable even though its magnitude is not.
        if let Ok((rest, lit)) = signed_int_lit(rest, true) {
            return Ok((rest, lit));
        }
        let (rest, e) = unary(rest)?;
        return Ok((rest, Expr::Unary(UnOp::Neg, Box::new(e))));
    }
    atom(i)
}

/// One left-associative precedence level. Operators are tried in the order
/// given, so longer spellings (`<=`) must precede their prefixes (`<`).
fn chain<'a>(
    i: In<'a>,
    sub: fn(In<'a>) -> R<'a, Expr>,
    ops: &[(&'static str, BinOp)],
) -> R<'a, Expr> {
    let (mut i, mut lhs) = sub(i)?;
    'next: loop {
        for (text, bop) in ops {
            let Ok((rest, _)) = op(text)(i) else { continue };
            // The operator committed us: a missing right operand is a hard error.
            let (rest, rhs) = match sub(rest) {
                Ok(ok) => ok,
                Err(nom::Err::Failure(e)) => return Err(nom::Err::Failure(e)),
                Err(_) => return cut(rest, "expected an expression after this operator"),
            };
            lhs = Expr::Binary(*bop, Box::new(lhs), Box::new(rhs));
            i = rest;
            continue 'next;
        }
        return Ok((i, lhs));
    }
}

fn factor(i: In) -> R<Expr> {
    chain(
        i,
        unary,
        &[("*", BinOp::Mul), ("/", BinOp::Div), ("%", BinOp::Rem)],
    )
}

fn term(i: In) -> R<Expr> {
    chain(i, factor, &[("+", BinOp::Add), ("-", BinOp::Sub)])
}

fn comparison(i: In) -> R<Expr> {
    chain(
        i,
        term,
        &[
            ("<=", BinOp::Le),
            (">=", BinOp::Ge),
            ("<", BinOp::Lt),
            (">", BinOp::Gt),
        ],
    )
}

fn equality(i: In) -> R<Expr> {
    chain(i, comparison, &[("==", BinOp::Eq), ("!=", BinOp::Ne)])
}

fn conjunction(i: In) -> R<Expr> {
    chain(i, equality, &[("&&", BinOp::And)])
}

pub fn expr(i: In) -> R<Expr> {
    chain(i, conjunction, &[("||", BinOp::Or)])
}

// --------------------------------------------------------------- statements

fn block(i: In) -> R<Block> {
    let (i, _) = op("{")(i)?;
    let (i, stmts) = many0(stmt)(i)?;
    let (i, _) = require("}", "expected `}` or another statement", i)?;
    Ok((i, stmts))
}

fn stmt(i: In) -> R<Stmt> {
    alt((
        let_stmt,
        if_stmt,
        while_stmt,
        return_stmt,
        print_stmt,
        assign_stmt,
        expr_stmt,
    ))(i)
}

fn semi(i: In<'_>) -> R<'_, ()> {
    require(";", "expected `;`", i)
}

fn let_stmt(i: In) -> R<Stmt> {
    let (i, _) = kw("let")(i)?;
    let Ok((i, n)) = name(i) else {
        return cut(i, "expected a variable name after `let`");
    };
    let (i, _) = require("=", "expected `=` in a `let` binding", i)?;
    let (i, e) = expr(i)?;
    let (i, _) = semi(i)?;
    Ok((i, Stmt::Let(n, e)))
}

fn assign_stmt(i: In) -> R<Stmt> {
    let (rest, n) = name(i)?;
    let (rest, _) = assign_op(rest)?;
    let (rest, e) = expr(rest)?;
    let (rest, _) = semi(rest)?;
    Ok((rest, Stmt::Assign(n, e)))
}

fn if_stmt(i: In) -> R<Stmt> {
    let (i, _) = kw("if")(i)?;
    let (i, cond) = expr(i)?;
    let (i, then) = block(i)?;
    let (i, els) = opt(preceded(
        kw("else"),
        alt((block, map(if_stmt, |s| vec![s]))),
    ))(i)?;
    Ok((i, Stmt::If(cond, then, els)))
}

fn while_stmt(i: In) -> R<Stmt> {
    let (i, _) = kw("while")(i)?;
    let (i, cond) = expr(i)?;
    let (i, body) = block(i)?;
    Ok((i, Stmt::While(cond, body)))
}

fn return_stmt(i: In) -> R<Stmt> {
    let (i, _) = kw("return")(i)?;
    let (i, e) = opt(expr)(i)?;
    let (i, _) = semi(i)?;
    Ok((i, Stmt::Return(e)))
}

fn print_stmt(i: In) -> R<Stmt> {
    let (i, _) = kw("print")(i)?;
    let (i, e) = expr(i)?;
    let (i, _) = semi(i)?;
    Ok((i, Stmt::Print(e)))
}

fn expr_stmt(i: In) -> R<Stmt> {
    let (i, e) = expr(i)?;
    let (i, _) = semi(i)?;
    Ok((i, Stmt::Expr(e)))
}

fn func(i: In) -> R<Func> {
    let (i, _) = kw("fn")(i)?;
    let Ok((i, n)) = name(i) else {
        return cut(i, "expected a function name after `fn`");
    };
    let (i, _) = require("(", "expected `(` after the function name", i)?;
    let (i, params) = separated_list0(op(","), name)(i)?;
    let (i, _) = require(")", "expected `)` to close the parameter list", i)?;
    let (i, body) = match block(i) {
        Ok(ok) => ok,
        Err(nom::Err::Failure(e)) => return Err(nom::Err::Failure(e)),
        Err(_) => return cut(i, "expected `{` to open the function body"),
    };
    Ok((
        i,
        Func {
            name: n,
            params,
            body,
        },
    ))
}

// ------------------------------------------------------------- entry point

/// A parse failure, resolved to a source position.
#[derive(Debug, Clone)]
pub struct ParseError {
    pub line: usize,
    pub col: usize,
    pub msg: String,
    pub excerpt: String,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "parse error at line {}, column {}: {}\n  |\n  | {}\n  | {}^",
            self.line,
            self.col,
            self.msg,
            self.excerpt,
            " ".repeat(self.col.saturating_sub(1))
        )
    }
}

impl std::error::Error for ParseError {}

fn locate(src: &str, rest: &str, msg: Option<&'static str>) -> ParseError {
    let offset = (rest.as_ptr() as usize).saturating_sub(src.as_ptr() as usize);
    let offset = offset.min(src.len());
    let before = &src[..offset];
    let line = before.matches('\n').count() + 1;
    let line_start = before.rfind('\n').map_or(0, |p| p + 1);
    let col = offset - line_start + 1;
    let line_end = src[line_start..]
        .find('\n')
        .map_or(src.len(), |p| line_start + p);
    ParseError {
        line,
        col,
        msg: msg.unwrap_or("unexpected input").to_string(),
        excerpt: src[line_start..line_end].to_string(),
    }
}

/// A top-level entry: either a definition or a loose statement.
enum Item {
    Func(Func),
    Stmt(Stmt),
}

fn item(i: In) -> R<Item> {
    // `fn` is reserved, so a statement can never begin with it and the two
    // alternatives cannot both match.
    alt((map(func, Item::Func), map(stmt, Item::Stmt)))(i)
}

/// Parses a whole program.
pub fn parse(src: &str) -> Result<Program, ParseError> {
    let (rest, items) = match many0(item)(src) {
        Ok(ok) => ok,
        Err(nom::Err::Error(e) | nom::Err::Failure(e)) => return Err(locate(src, e.input, e.msg)),
        Err(nom::Err::Incomplete(_)) => unreachable!("no streaming parsers are used"),
    };
    let (rest, _) = ws(rest).unwrap_or((rest, ()));
    if !rest.is_empty() {
        return Err(locate(
            src,
            rest,
            Some("expected a `fn` definition or a statement"),
        ));
    }

    let mut program = Program::default();
    for item in items {
        match item {
            Item::Func(f) => program.funcs.push(f),
            Item::Stmt(s) => program.top_level.push(s),
        }
    }
    Ok(program)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_expr(s: &str) -> Expr {
        let src = format!("fn f() {{ return {s}; }}");
        let funcs = parse(&src).expect("should parse");
        match &funcs.funcs[0].body[0] {
            Stmt::Return(Some(e)) => e.clone(),
            other => panic!("unexpected statement {other:?}"),
        }
    }

    #[test]
    fn precedence_binds_tighter_inside_out() {
        // 1 + 2 * 3 < 4 == true  ==>  ((1 + (2 * 3)) < 4) == true
        let e = parse_expr("1 + 2 * 3 < 4 == true");
        let Expr::Binary(BinOp::Eq, lhs, _) = e else {
            panic!("expected `==` at the root")
        };
        let Expr::Binary(BinOp::Lt, lhs, _) = *lhs else {
            panic!("expected `<` below `==`")
        };
        let Expr::Binary(BinOp::Add, _, rhs) = *lhs else {
            panic!("expected `+` below `<`")
        };
        assert!(matches!(*rhs, Expr::Binary(BinOp::Mul, _, _)));
    }

    #[test]
    fn longer_operators_win_over_their_prefixes() {
        assert!(matches!(
            parse_expr("1 <= 2"),
            Expr::Binary(BinOp::Le, _, _)
        ));
        assert!(matches!(
            parse_expr("1 >= 2"),
            Expr::Binary(BinOp::Ge, _, _)
        ));
        assert!(matches!(
            parse_expr("1 != 2"),
            Expr::Binary(BinOp::Ne, _, _)
        ));
    }

    #[test]
    fn keywords_are_not_identifier_prefixes() {
        let src = "fn f() { let iffy = 1; return iffy; }";
        assert!(parse(src).is_ok(), "`iffy` should not lex as `if`");
    }

    #[test]
    fn comments_and_else_if_chains() {
        let src = "
            // leading comment
            fn f(x) {
                if x < 0 { return 0; }      // negative
                else if x < 10 { return 1; }
                else { return 2; }
            }
        ";
        let funcs = parse(src).expect("should parse");
        assert_eq!(funcs.funcs.len(), 1);
        let Stmt::If(_, _, Some(els)) = &funcs.funcs[0].body[0] else {
            panic!("expected an if/else")
        };
        assert!(matches!(els[0], Stmt::If(..)), "`else if` should nest");
    }

    #[test]
    fn assignment_is_not_confused_with_equality() {
        let src = "fn f() { let x = 1; x = x + 1; x == 2; return x; }";
        let funcs = parse(src).expect("should parse");
        assert!(matches!(funcs.funcs[0].body[1], Stmt::Assign(..)));
        assert!(matches!(funcs.funcs[0].body[2], Stmt::Expr(..)));
    }

    #[test]
    fn errors_point_at_the_offending_line() {
        let err = parse("fn f() { let x = 1 }").unwrap_err();
        assert_eq!(err.line, 1);
        assert!(err.msg.contains(';'), "unexpected message: {}", err.msg);
    }

    #[test]
    fn out_of_range_literals_are_rejected() {
        let err = parse("fn f() { return 9223372036854775807; }").unwrap_err();
        assert!(err.msg.contains("out of range"), "got: {}", err.msg);
    }

    #[test]
    fn calls_are_a_postfix_operator() {
        // `f(1)(2)` is a call of a call, not a syntax error.
        let Expr::Call(inner, outer_args) = parse_expr("f(1)(2)") else {
            panic!("expected a call at the root")
        };
        assert_eq!(outer_args.len(), 1);
        let Expr::Call(callee, inner_args) = *inner else {
            panic!("expected the callee to be another call")
        };
        assert_eq!(*callee, Expr::Var("f".to_string()));
        assert_eq!(inner_args.len(), 1);

        // A parenthesised expression can be called too.
        assert!(matches!(parse_expr("(f)(1)"), Expr::Call(..)));
        // And a bare name is just a name.
        assert_eq!(parse_expr("f"), Expr::Var("f".to_string()));
    }

    #[test]
    fn statements_may_sit_outside_any_function() {
        let program = parse(
            "print 1;
             fn f() { return 2; }
             let x = f();
             while x > 0 { x = x - 1; }
             fn g() { return 3; }
             print g();",
        )
        .expect("should parse");

        assert_eq!(program.funcs.len(), 2);
        assert_eq!(program.funcs[0].name, "f");
        assert_eq!(program.funcs[1].name, "g");
        // Loose statements keep their source order even across definitions.
        assert!(matches!(program.top_level[0], Stmt::Print(_)));
        assert!(matches!(program.top_level[1], Stmt::Let(..)));
        assert!(matches!(program.top_level[2], Stmt::While(..)));
        assert!(matches!(program.top_level[3], Stmt::Print(_)));
    }

    #[test]
    fn a_program_may_be_only_definitions_or_only_statements() {
        assert!(parse("fn f() { return 1; }")
            .expect("parses")
            .top_level
            .is_empty());
        assert!(parse("print 1;").expect("parses").funcs.is_empty());
        assert_eq!(parse("").expect("parses"), Program::default());
    }
}
