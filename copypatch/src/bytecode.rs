//! Stack bytecode: the shared input of the interpreter and the JIT.

use std::cell::{Cell, RefCell};

use crate::jit::JitCode;
use crate::value::Value;

/// The most arguments a call may pass. Bounded so `rt_call` can marshal
/// arguments through a fixed stack buffer instead of allocating.
pub const MAX_ARGS: usize = 16;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Op {
    /// Push `consts[k]`.
    Const(u32),
    /// Push `locals[i]`.
    LoadLocal(u32),
    /// Pop into `locals[i]`.
    StoreLocal(u32),
    Pop,

    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Neg,
    Not,

    Lt,
    Le,
    Gt,
    Ge,
    Eq,
    Ne,

    Jump(u32),
    /// Pop a bool; jump if it is false.
    JumpIfFalse(u32),
    /// Pop `argc` arguments, call `func`, push the result.
    Call {
        func: u32,
        argc: u32,
    },
    /// Pop `argc` arguments and, below them, the callee; call it and push the
    /// result. The callee must be a function reference.
    CallValue {
        argc: u32,
    },
    /// Pop the result and leave the function.
    Return,
    Print,
}

impl Op {
    /// The branch destination, for ops that have one.
    pub fn target(self) -> Option<usize> {
        match self {
            Op::Jump(t) | Op::JumpIfFalse(t) => Some(t as usize),
            _ => None,
        }
    }

    /// Does control ever reach the following instruction?
    pub fn falls_through(self) -> bool {
        !matches!(self, Op::Jump(_) | Op::Return)
    }

    /// How the operand stack depth changes across this op.
    pub fn stack_effect(self) -> isize {
        match self {
            Op::Const(_) | Op::LoadLocal(_) => 1,
            Op::StoreLocal(_) | Op::Pop | Op::JumpIfFalse(_) | Op::Return | Op::Print => -1,
            Op::Neg | Op::Not | Op::Jump(_) => 0,
            Op::Add
            | Op::Sub
            | Op::Mul
            | Op::Div
            | Op::Rem
            | Op::Lt
            | Op::Le
            | Op::Gt
            | Op::Ge
            | Op::Eq
            | Op::Ne => -1,
            Op::Call { argc, .. } => 1 - argc as isize,
            // The callee sits one slot below the arguments and is replaced by
            // the result.
            Op::CallValue { argc } => -(argc as isize),
        }
    }

    /// Short label used in disassembly and error messages.
    pub fn mnemonic(self) -> &'static str {
        match self {
            Op::Const(_) => "const",
            Op::LoadLocal(_) => "load",
            Op::StoreLocal(_) => "store",
            Op::Pop => "pop",
            Op::Add => "add",
            Op::Sub => "sub",
            Op::Mul => "mul",
            Op::Div => "div",
            Op::Rem => "rem",
            Op::Neg => "neg",
            Op::Not => "not",
            Op::Lt => "lt",
            Op::Le => "le",
            Op::Gt => "gt",
            Op::Ge => "ge",
            Op::Eq => "eq",
            Op::Ne => "ne",
            Op::Jump(_) => "jump",
            Op::JumpIfFalse(_) => "jump_if_false",
            Op::Call { .. } => "call",
            Op::CallValue { .. } => "call_value",
            Op::Return => "return",
            Op::Print => "print",
        }
    }

    /// The source operator this op implements, for error messages.
    pub fn source_operator(self) -> Option<&'static str> {
        Some(match self {
            Op::Add => "+",
            Op::Sub => "-",
            Op::Mul => "*",
            Op::Div => "/",
            Op::Rem => "%",
            Op::Neg => "unary -",
            Op::Not => "!",
            Op::Lt => "<",
            Op::Le => "<=",
            Op::Gt => ">",
            Op::Ge => ">=",
            _ => return None,
        })
    }
}

/// Where a function stands with the JIT.
pub enum JitState {
    /// Not compiled yet.
    Cold,
    /// Compilation was refused; stay in the interpreter and do not retry.
    Failed,
    Ready(JitCode),
}

/// A compiled function.
pub struct Function {
    pub name: String,
    pub arity: usize,
    /// Slots reserved for parameters and `let` bindings.
    pub n_locals: usize,
    /// High-water mark of the operand stack.
    pub max_stack: usize,
    pub consts: Vec<Value>,
    pub code: Vec<Op>,
    /// How many times this function has been entered.
    pub calls: Cell<u32>,
    /// Machine code, once the JIT has compiled it.
    pub jit: RefCell<JitState>,
}

impl Function {
    pub fn disassemble(&self) -> String {
        use std::fmt::Write;
        let mut s = String::new();
        let _ = writeln!(
            s,
            "fn {}/{}  locals={} max_stack={} consts={}",
            self.name,
            self.arity,
            self.n_locals,
            self.max_stack,
            self.consts.len()
        );
        for (pc, op) in self.code.iter().enumerate() {
            let detail = match *op {
                Op::Const(k) => format!("{k}  ; {}", crate::value::show(self.consts[k as usize])),
                Op::LoadLocal(i) | Op::StoreLocal(i) => format!("{i}"),
                Op::Jump(t) | Op::JumpIfFalse(t) => format!("-> {t}"),
                Op::Call { func, argc } => format!("fn#{func}, {argc} args"),
                Op::CallValue { argc } => format!("{argc} args"),
                _ => String::new(),
            };
            let _ = writeln!(s, "  {pc:4}  {:<14} {detail}", op.mnemonic());
        }
        s
    }
}
