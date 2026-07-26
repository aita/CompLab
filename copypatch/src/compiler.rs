//! Lowers the AST to stack bytecode.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use crate::ast::{BinOp, Block, Expr, Func, Program, Stmt, UnOp};
use crate::bytecode::{Function, JitState, Op, MAX_ARGS};
use crate::value::{self, Value};

#[derive(Debug, Clone)]
pub struct CompileError {
    pub msg: String,
}

impl std::fmt::Display for CompileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "compile error: {}", self.msg)
    }
}

impl std::error::Error for CompileError {}

fn err<T>(msg: impl Into<String>) -> Result<T, CompileError> {
    Err(CompileError { msg: msg.into() })
}

/// Name -> (function index, arity).
type Globals = HashMap<String, (u32, usize)>;

/// The entry point a program is run from, and the name an implicit `main`
/// gets built under.
pub const ENTRY: &str = "main";

/// Compiles a whole program. Functions may call each other in any order.
///
/// Statements written outside any `fn` are gathered into an implicit `main`,
/// so a script can be a bare sequence of statements.
pub fn compile(program: &Program) -> Result<Vec<Rc<Function>>, CompileError> {
    let mut funcs: Vec<Func> = program.funcs.clone();

    if !program.top_level.is_empty() {
        if let Some(explicit) = funcs.iter().find(|f| f.name == ENTRY) {
            return err(format!(
                "this program has statements outside any `fn`, which become an \
                 implicit `{ENTRY}`, but it also defines `{}` explicitly; \
                 use one or the other",
                explicit.name
            ));
        }
        // Appended, so the explicit functions keep the indices they were
        // written with -- which is what `--dump-bytecode` shows.
        funcs.push(Func {
            name: ENTRY.to_string(),
            params: Vec::new(),
            body: program.top_level.clone(),
        });
    }

    let mut globals: Globals = HashMap::new();
    for (i, f) in funcs.iter().enumerate() {
        if f.params.len() > MAX_ARGS {
            return err(format!(
                "`{}` takes {} parameters, but at most {MAX_ARGS} are supported",
                f.name,
                f.params.len()
            ));
        }
        if globals
            .insert(f.name.clone(), (i as u32, f.params.len()))
            .is_some()
        {
            return err(format!("function `{}` is defined more than once", f.name));
        }
    }

    funcs
        .iter()
        .map(|f| compile_function(f, &globals).map(Rc::new))
        .collect()
}

fn compile_function(f: &Func, globals: &Globals) -> Result<Function, CompileError> {
    let mut c = FnCompiler {
        globals,
        fname: &f.name,
        scopes: vec![Vec::new()],
        n_locals: 0,
        consts: Vec::new(),
        const_map: HashMap::new(),
        code: Vec::new(),
    };

    for p in &f.params {
        c.declare(p)?;
    }
    c.block(&f.body)?;

    // Every function ends in a `return`, so the JIT can rely on the last op
    // having no successor and falling out of the tail-call chain.
    let zero = c.constant(value::int(0));
    c.emit(Op::Const(zero));
    c.emit(Op::Return);

    // Both tiers index straight into `code` with a branch target, and
    // `compute_max_stack` only walks reachable ops, so check every branch --
    // including ones in dead code -- before anyone can run it.
    for (pc, op) in c.code.iter().enumerate() {
        if let Some(t) = op.target() {
            if t >= c.code.len() {
                return err(format!(
                    "`{}`: branch at pc {pc} targets {t}, past the end of the code",
                    f.name
                ));
            }
        }
    }

    let max_stack = compute_max_stack(&f.name, &c.code)?;
    Ok(Function {
        name: f.name.clone(),
        arity: f.params.len(),
        n_locals: c.n_locals,
        max_stack,
        consts: c.consts,
        code: c.code,
        calls: Cell::new(0),
        jit: RefCell::new(JitState::Cold),
    })
}

struct FnCompiler<'a> {
    globals: &'a Globals,
    fname: &'a str,
    /// Innermost scope last; each entry maps a name to its local slot.
    scopes: Vec<Vec<(String, u32)>>,
    n_locals: usize,
    consts: Vec<Value>,
    const_map: HashMap<Value, u32>,
    code: Vec<Op>,
}

impl<'a> FnCompiler<'a> {
    fn emit(&mut self, op: Op) -> usize {
        self.code.push(op);
        self.code.len() - 1
    }

    fn here(&self) -> u32 {
        self.code.len() as u32
    }

    /// Emits a branch with a placeholder destination; fill it in with [`patch`].
    fn emit_jump(&mut self, op: Op) -> usize {
        self.emit(op)
    }

    /// Points a previously emitted branch at the current end of the code.
    fn patch(&mut self, at: usize) {
        let here = self.here();
        match &mut self.code[at] {
            Op::Jump(t) | Op::JumpIfFalse(t) => *t = here,
            other => unreachable!("patching a non-branch op: {other:?}"),
        }
    }

    fn constant(&mut self, v: Value) -> u32 {
        if let Some(&k) = self.const_map.get(&v) {
            return k;
        }
        let k = self.consts.len() as u32;
        self.consts.push(v);
        self.const_map.insert(v, k);
        k
    }

    fn declare(&mut self, name: &str) -> Result<u32, CompileError> {
        let scope = self.scopes.last_mut().expect("at least one scope");
        if scope.iter().any(|(n, _)| n == name) {
            return err(format!(
                "`{name}` is already declared in this scope (in `{}`)",
                self.fname
            ));
        }
        let slot = self.n_locals as u32;
        self.n_locals += 1;
        scope.push((name.to_string(), slot));
        Ok(slot)
    }

    /// The local slot `name` binds to, innermost scope first.
    fn local(&self, name: &str) -> Option<u32> {
        self.scopes
            .iter()
            .rev()
            .find_map(|scope| scope.iter().rev().find(|(n, _)| n == name))
            .map(|(_, slot)| *slot)
    }

    fn lookup(&self, name: &str) -> Result<u32, CompileError> {
        self.local(name).ok_or_else(|| CompileError {
            msg: format!("unknown variable `{name}` in `{}`", self.fname),
        })
    }

    fn block(&mut self, b: &Block) -> Result<(), CompileError> {
        self.scopes.push(Vec::new());
        let r = b.iter().try_for_each(|s| self.stmt(s));
        self.scopes.pop();
        r
    }

    fn stmt(&mut self, s: &Stmt) -> Result<(), CompileError> {
        match s {
            // The initialiser is evaluated before the name comes into scope,
            // so `let x = x;` reads the outer `x`.
            Stmt::Let(name, e) => {
                self.expr(e)?;
                let slot = self.declare(name)?;
                self.emit(Op::StoreLocal(slot));
            }
            Stmt::Assign(name, e) => {
                self.expr(e)?;
                let slot = self.lookup(name)?;
                self.emit(Op::StoreLocal(slot));
            }
            Stmt::If(cond, then, els) => {
                self.expr(cond)?;
                let to_else = self.emit_jump(Op::JumpIfFalse(0));
                self.block(then)?;
                match els {
                    Some(els) => {
                        let to_end = self.emit_jump(Op::Jump(0));
                        self.patch(to_else);
                        self.block(els)?;
                        self.patch(to_end);
                    }
                    None => self.patch(to_else),
                }
            }
            Stmt::While(cond, body) => {
                let top = self.here();
                self.expr(cond)?;
                let to_end = self.emit_jump(Op::JumpIfFalse(0));
                self.block(body)?;
                self.emit(Op::Jump(top));
                self.patch(to_end);
            }
            Stmt::Return(e) => {
                match e {
                    Some(e) => self.expr(e)?,
                    None => {
                        let k = self.constant(value::int(0));
                        self.emit(Op::Const(k));
                    }
                }
                self.emit(Op::Return);
            }
            Stmt::Print(e) => {
                self.expr(e)?;
                self.emit(Op::Print);
            }
            Stmt::Expr(e) => {
                self.expr(e)?;
                self.emit(Op::Pop);
            }
        }
        Ok(())
    }

    fn expr(&mut self, e: &Expr) -> Result<(), CompileError> {
        match e {
            Expr::Int(n) => {
                let k = self.constant(value::int(*n));
                self.emit(Op::Const(k));
            }
            Expr::Bool(b) => {
                let k = self.constant(value::boolean(*b));
                self.emit(Op::Const(k));
            }
            // A bare name is a local if one is in scope, otherwise a
            // reference to a function -- which is a compile-time constant.
            Expr::Var(name) => match self.local(name) {
                Some(slot) => {
                    self.emit(Op::LoadLocal(slot));
                }
                None => {
                    let Some(&(idx, _)) = self.globals.get(name) else {
                        return err(format!(
                            "unknown variable or function `{name}` in `{}`",
                            self.fname
                        ));
                    };
                    let k = self.constant(value::func(idx));
                    self.emit(Op::Const(k));
                }
            },
            Expr::Unary(op, inner) => {
                self.expr(inner)?;
                self.emit(match op {
                    UnOp::Neg => Op::Neg,
                    UnOp::Not => Op::Not,
                });
            }
            // `&&` and `||` short-circuit, so they compile to branches rather
            // than to an op.
            Expr::Binary(BinOp::And, a, b) => {
                self.expr(a)?;
                let to_false = self.emit_jump(Op::JumpIfFalse(0));
                self.expr(b)?;
                let to_end = self.emit_jump(Op::Jump(0));
                self.patch(to_false);
                let k = self.constant(value::FALSE);
                self.emit(Op::Const(k));
                self.patch(to_end);
            }
            Expr::Binary(BinOp::Or, a, b) => {
                self.expr(a)?;
                let to_rhs = self.emit_jump(Op::JumpIfFalse(0));
                let k = self.constant(value::TRUE);
                self.emit(Op::Const(k));
                let to_end = self.emit_jump(Op::Jump(0));
                self.patch(to_rhs);
                self.expr(b)?;
                self.patch(to_end);
            }
            Expr::Binary(op, a, b) => {
                self.expr(a)?;
                self.expr(b)?;
                self.emit(match op {
                    BinOp::Add => Op::Add,
                    BinOp::Sub => Op::Sub,
                    BinOp::Mul => Op::Mul,
                    BinOp::Div => Op::Div,
                    BinOp::Rem => Op::Rem,
                    BinOp::Lt => Op::Lt,
                    BinOp::Le => Op::Le,
                    BinOp::Gt => Op::Gt,
                    BinOp::Ge => Op::Ge,
                    BinOp::Eq => Op::Eq,
                    BinOp::Ne => Op::Ne,
                    BinOp::And | BinOp::Or => unreachable!("handled above"),
                });
            }
            Expr::Call(callee, args) => {
                if args.len() > MAX_ARGS {
                    return err(format!(
                        "a call may pass at most {MAX_ARGS} arguments, but {} were given (in `{}`)",
                        args.len(),
                        self.fname
                    ));
                }

                // When the callee names a function directly -- and no local
                // shadows that name -- bake the index into the op. This keeps
                // the common case a static call whose target the JIT can patch
                // in as an immediate, and lets arity be checked here.
                let direct = match &**callee {
                    Expr::Var(name) if self.local(name).is_none() => self
                        .globals
                        .get(name)
                        .map(|&(idx, arity)| (name, idx, arity)),
                    _ => None,
                };

                if let Some((name, idx, arity)) = direct {
                    if args.len() != arity {
                        return err(format!(
                            "`{name}` takes {arity} argument(s) but {} were given (in `{}`)",
                            args.len(),
                            self.fname
                        ));
                    }
                    for a in args {
                        self.expr(a)?;
                    }
                    self.emit(Op::Call {
                        func: idx,
                        argc: args.len() as u32,
                    });
                } else {
                    // Indirect: the callee goes on the stack under the
                    // arguments, and both its type and its arity are checked
                    // at run time.
                    self.expr(callee)?;
                    for a in args {
                        self.expr(a)?;
                    }
                    self.emit(Op::CallValue {
                        argc: args.len() as u32,
                    });
                }
            }
        }
        Ok(())
    }
}

/// Walks the control-flow graph to find the deepest the operand stack ever
/// gets, so each frame can be sized exactly once on entry.
fn compute_max_stack(fname: &str, code: &[Op]) -> Result<usize, CompileError> {
    let mut depth: Vec<Option<isize>> = vec![None; code.len()];
    let mut work = vec![0usize];
    depth[0] = Some(0);
    let mut high = 0isize;

    while let Some(pc) = work.pop() {
        let d = depth[pc].expect("queued pcs have a known depth");
        let op = code[pc];
        let after = d + op.stack_effect();
        if after < 0 {
            return err(format!("`{fname}`: operand stack underflows at pc {pc}"));
        }
        // A call with no arguments writes its result one slot above `d`.
        high = high.max(d).max(after);

        let mut go = |to: usize, want: isize| -> Result<(), CompileError> {
            if to >= code.len() {
                return err(format!("`{fname}`: branch out of range at pc {pc}"));
            }
            match depth[to] {
                Some(seen) if seen != want => err(format!(
                    "`{fname}`: inconsistent stack depth {seen} vs {want} at pc {to}"
                )),
                Some(_) => Ok(()),
                None => {
                    depth[to] = Some(want);
                    work.push(to);
                    Ok(())
                }
            }
        };

        if let Some(t) = op.target() {
            go(t, after)?;
        }
        if op.falls_through() {
            go(pc + 1, after)?;
        }
    }

    Ok(high as usize)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser;

    fn build(src: &str) -> Vec<Rc<Function>> {
        compile(&parser::parse(src).expect("parses")).expect("compiles")
    }

    #[test]
    fn every_function_ends_in_return() {
        let fs = build("fn a() { } fn b() { while true { } }");
        for f in &fs {
            assert_eq!(*f.code.last().unwrap(), Op::Return, "in `{}`", f.name);
        }
    }

    #[test]
    fn branch_targets_are_in_range() {
        let fs = build(
            "fn f(n) { if n < 0 { return 1; } else { return 2; } while n > 0 { n = n - 1; } }",
        );
        for f in &fs {
            for (pc, op) in f.code.iter().enumerate() {
                if let Some(t) = op.target() {
                    assert!(t < f.code.len(), "pc {pc} jumps to {t}, out of range");
                }
            }
        }
    }

    #[test]
    fn constants_are_deduplicated() {
        let fs = build("fn f() { return 7 + 7 + 7; }");
        assert_eq!(
            fs[0].consts.iter().filter(|v| **v == value::int(7)).count(),
            1
        );
    }

    #[test]
    fn arity_and_name_errors_are_reported() {
        let bad = |src: &str| {
            let ast = parser::parse(src).expect("parses");
            match compile(&ast) {
                Ok(_) => panic!("expected a compile error for: {src}"),
                Err(e) => e.msg,
            }
        };
        // An unknown callee is reported by name resolution, since it could
        // have been a variable holding a function.
        assert!(bad("fn f() { return g(); }").contains("unknown variable or function `g`"));
        assert!(bad("fn g(a) { return a; } fn f() { return g(); }").contains("takes 1 argument"));
        assert!(bad("fn f() { return x; }").contains("unknown variable or function `x`"));
        assert!(bad("fn f() { } fn f() { }").contains("more than once"));
        assert!(bad("fn f() { let x = 1; let x = 2; return x; }").contains("already declared"));
    }

    #[test]
    fn inner_scopes_shadow_without_clobbering() {
        let fs = build("fn f() { let x = 1; if true { let x = 2; print x; } return x; }");
        // Shadowing allocates a fresh slot rather than reusing the outer one.
        assert_eq!(fs[0].n_locals, 2);
    }

    #[test]
    fn named_calls_stay_direct_but_others_go_through_a_value() {
        let has = |src: &str, want: fn(&Op) -> bool| {
            build(src)
                .iter()
                .find(|f| f.name == ENTRY)
                .expect("main")
                .code
                .iter()
                .any(want)
        };
        let direct = |op: &Op| matches!(op, Op::Call { .. });
        let indirect = |op: &Op| matches!(op, Op::CallValue { .. });

        // A plain named call keeps the callee as an immediate.
        assert!(has("fn g() { return 1; } return g();", direct));
        assert!(!has("fn g() { return 1; } return g();", indirect));

        // Parentheses are transparent in the AST, so they do not deoptimise.
        assert!(has("fn g() { return 1; } return (g)();", direct));

        // Anything that only names the callee at run time -- a variable, a
        // local shadowing the function, a chained call -- goes indirect.
        assert!(has("fn g() { return 1; } let f = g; return f();", indirect));
        assert!(has("fn g() { return g; } return g()();", indirect));
        assert!(has(
            "fn g() { return 1; } fn h() { return 2; } let g2 = h; return g2();",
            indirect
        ));
    }

    #[test]
    fn a_function_name_used_as_a_value_becomes_a_constant() {
        let fs = build("fn g(a) { return a; } let f = g; return f(1);");
        let main = fs.iter().find(|f| f.name == ENTRY).expect("main");
        let g = fs.iter().position(|f| f.name == "g").expect("g") as u32;
        assert!(
            main.consts.contains(&value::func(g)),
            "expected a function constant for `g` in {:?}",
            main.consts
        );
    }

    #[test]
    fn loose_statements_become_an_implicit_main() {
        let fs = build("fn helper() { return 1; } print helper(); let x = 2;");
        let main = fs.iter().find(|f| f.name == ENTRY).expect("implicit main");
        assert_eq!(main.arity, 0);
        assert_eq!(main.n_locals, 1, "`let x` is a local of the implicit main");
        // The explicit functions keep the indices they were written with.
        assert_eq!(fs[0].name, "helper");
    }

    #[test]
    fn a_program_of_only_definitions_gets_no_implicit_main() {
        let fs = build("fn helper() { return 1; }");
        assert!(fs.iter().all(|f| f.name != ENTRY));
    }

    #[test]
    fn loose_statements_clash_with_an_explicit_main() {
        let ast = parser::parse("fn main() { return 1; } print 2;").expect("parses");
        let Err(e) = compile(&ast) else {
            panic!("expected a clash to be reported")
        };
        assert!(e.msg.contains("implicit `main`"), "got: {}", e.msg);
    }

    #[test]
    fn max_stack_covers_nested_expressions() {
        let fs = build("fn f() { return (1 + 2) * (3 + 4 * (5 + 6)); }");
        assert!(fs[0].max_stack >= 3, "got {}", fs[0].max_stack);
    }
}
