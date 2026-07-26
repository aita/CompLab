//! The runtime: a bytecode interpreter, plus everything the JIT'd code needs
//! to call back into.

use std::alloc::{self, Layout};
use std::collections::HashMap;
use std::ptr;
use std::rc::Rc;

use crate::bytecode::{Function, JitState, Op, MAX_ARGS};
use crate::jit;
use crate::value::{self, Value};

/// The part of the VM that JIT'd code sees. Mirrors `struct Vm` in
/// `csrc/stencils.c`; the field order and offsets must not change without
/// changing the C side too.
#[repr(C)]
pub struct Shared {
    /// Where `ret` leaves the function's result.
    pub ret: Value,
    /// Non-zero once a stencil has faulted; unwinds the tail-call chain.
    pub error: u32,
    /// Bytecode index of the faulting op.
    pub err_pc: u32,
    pub rt_call: unsafe extern "C" fn(*mut Shared, u32, *mut Value, u32) -> Value,
    pub rt_print: unsafe extern "C" fn(*mut Shared, Value),
}

/// Signature of a compiled function's entry point, matching `STENCIL(...)`.
type EntryFn = unsafe extern "C" fn(*mut Value, *mut Value, *mut Shared, *const Value);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ErrKind {
    /// Shared with `ERR_TYPE` in the C stencils.
    Type = 1,
    /// Shared with `ERR_DIV_ZERO` in the C stencils.
    DivZero = 2,
    Arity = 3,
    Depth = 4,
    StackOverflow = 5,
    NoSuchFunction = 6,
}

impl ErrKind {
    fn from_code(code: u32) -> ErrKind {
        match code {
            2 => ErrKind::DivZero,
            _ => ErrKind::Type,
        }
    }
}

#[derive(Clone, Debug)]
pub struct RuntimeError {
    pub kind: ErrKind,
    pub message: String,
}

impl std::fmt::Display for RuntimeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for RuntimeError {}

#[derive(Clone, Copy, Default, Debug)]
pub struct Stats {
    pub interpreted_ops: u64,
    pub calls: u64,
    pub interpreted_calls: u64,
    pub jit_calls: u64,
    pub jit_functions: usize,
    pub jit_bytes: usize,
}

/// A flat, never-reallocated block of `Value`s used for JIT frames.
///
/// JIT'd code holds raw pointers into this block across nested calls, so the
/// backing allocation must not move; a `Vec` that could grow would not do.
struct Arena {
    ptr: *mut Value,
    len: usize,
    top: usize,
}

impl Arena {
    fn new(len: usize) -> Arena {
        let layout = Layout::array::<Value>(len).expect("arena size overflows");
        // SAFETY: `len` is non-zero, so the layout has non-zero size.
        let ptr = unsafe { alloc::alloc_zeroed(layout) } as *mut Value;
        assert!(!ptr.is_null(), "could not allocate the JIT frame arena");
        Arena { ptr, len, top: 0 }
    }

    fn push(&mut self, n: usize) -> Option<usize> {
        if self.top + n > self.len {
            return None;
        }
        let base = self.top;
        self.top += n;
        Some(base)
    }

    fn pop_to(&mut self, base: usize) {
        self.top = base;
    }

    /// # Safety
    /// `at` must be within the arena.
    unsafe fn slot(&self, at: usize) -> *mut Value {
        self.ptr.add(at)
    }
}

impl Drop for Arena {
    fn drop(&mut self) {
        let layout = Layout::array::<Value>(self.len).expect("same layout as in `new`");
        // SAFETY: `ptr` came from `alloc_zeroed` with this exact layout.
        unsafe { alloc::dealloc(self.ptr as *mut u8, layout) };
    }
}

/// A whole program, ready to run.
///
/// `shared` must stay the first field: JIT'd code is handed a `*mut Shared`
/// and the callbacks cast it straight back to `*mut Vm`.
#[repr(C)]
pub struct Vm {
    shared: Shared,
    funcs: Vec<Rc<Function>>,
    by_name: HashMap<String, usize>,
    depth: usize,
    /// Recursion limit. Must stay low enough that it trips before the native
    /// stack overflows: both tiers use one native frame per call.
    pub max_depth: usize,
    /// Set when a Rust-side call fails underneath JIT'd code, so the error
    /// survives the trip back out through the tail-call chain.
    pending: Option<RuntimeError>,
    frames: Arena,
    /// Compile a function on its Nth entry. `None` disables the JIT.
    pub jit_threshold: Option<u32>,
    pub stats: Stats,
    /// Everything `print` produced, in order.
    pub printed: Vec<String>,
    /// Also write `print` output to stdout.
    pub echo: bool,
    /// First JIT compilation failure, if any. Execution falls back to the
    /// interpreter, so this is a note rather than an error.
    pub jit_warning: Option<String>,
}

impl Vm {
    pub fn new(funcs: Vec<Rc<Function>>) -> Vm {
        let by_name = funcs
            .iter()
            .enumerate()
            .map(|(i, f)| (f.name.clone(), i))
            .collect();
        Vm {
            shared: Shared {
                ret: value::int(0),
                error: 0,
                err_pc: 0,
                rt_call,
                rt_print,
            },
            funcs,
            by_name,
            depth: 0,
            max_depth: 10_000,
            pending: None,
            frames: Arena::new(1 << 20),
            jit_threshold: Some(2),
            stats: Stats::default(),
            printed: Vec::new(),
            echo: true,
            jit_warning: None,
        }
    }

    pub fn functions(&self) -> &[Rc<Function>] {
        &self.funcs
    }

    pub fn index_of(&self, name: &str) -> Option<usize> {
        self.by_name.get(name).copied()
    }

    /// Runs a zero-argument entry point.
    pub fn run(&mut self, entry: &str) -> Result<Value, RuntimeError> {
        let Some(idx) = self.index_of(entry) else {
            return Err(RuntimeError {
                kind: ErrKind::NoSuchFunction,
                message: format!("no function named `{entry}`"),
            });
        };
        if self.funcs[idx].arity != 0 {
            return Err(RuntimeError {
                kind: ErrKind::Arity,
                message: format!("entry point `{entry}` must take no arguments"),
            });
        }
        // The entry point is entered exactly once, so a call counter can never
        // make it hot -- yet for a script (top-level statements compiled into
        // an implicit `main`) it is where all the work is. Compile it up
        // front; one wasted compile is microseconds.
        if self.jit_threshold.is_some() {
            let f = self.funcs[idx].clone();
            self.compile(&f);
        }
        self.call(idx, &[])
    }

    pub fn call(&mut self, fidx: usize, args: &[Value]) -> Result<Value, RuntimeError> {
        let Some(f) = self.funcs.get(fidx).cloned() else {
            return Err(RuntimeError {
                kind: ErrKind::NoSuchFunction,
                message: format!("call to unknown function #{fidx}"),
            });
        };
        if args.len() != f.arity {
            return Err(RuntimeError {
                kind: ErrKind::Arity,
                message: format!(
                    "`{}` takes {} argument(s) but got {}",
                    f.name,
                    f.arity,
                    args.len()
                ),
            });
        }
        if self.depth >= self.max_depth {
            return Err(RuntimeError {
                kind: ErrKind::Depth,
                message: format!(
                    "call depth limit of {} exceeded (infinite recursion in `{}`?)",
                    self.max_depth, f.name
                ),
            });
        }

        self.depth += 1;
        let result = self.enter(fidx, &f, args);
        self.depth -= 1;
        result
    }

    /// Decides between the interpreter and the JIT, compiling on the way if
    /// this function has become hot.
    fn enter(
        &mut self,
        fidx: usize,
        f: &Rc<Function>,
        args: &[Value],
    ) -> Result<Value, RuntimeError> {
        self.stats.calls += 1;
        let count = f.calls.get().saturating_add(1);
        f.calls.set(count);

        let entry = match &*f.jit.borrow() {
            JitState::Ready(code) => Some(code.entry()),
            JitState::Failed => None,
            JitState::Cold => None,
        };
        let entry = match entry {
            Some(p) => Some(p),
            None if self.should_compile(f, count) => self.compile(f),
            None => None,
        };

        match entry {
            Some(p) => {
                self.stats.jit_calls += 1;
                self.run_jit(fidx, f, p, args)
            }
            None => {
                self.stats.interpreted_calls += 1;
                self.run_interpreted(fidx, f, args)
            }
        }
    }

    fn should_compile(&self, f: &Rc<Function>, count: u32) -> bool {
        matches!(*f.jit.borrow(), JitState::Cold) && self.jit_threshold.is_some_and(|t| count >= t)
    }

    fn compile(&mut self, f: &Rc<Function>) -> Option<*const u8> {
        match jit::compile(f) {
            Ok(code) => {
                self.stats.jit_functions += 1;
                self.stats.jit_bytes += code.len();
                let entry = code.entry();
                *f.jit.borrow_mut() = JitState::Ready(code);
                Some(entry)
            }
            Err(e) => {
                // Fall back to the interpreter, and do not try again.
                *f.jit.borrow_mut() = JitState::Failed;
                if self.jit_warning.is_none() {
                    self.jit_warning = Some(format!("`{}`: {e}", f.name));
                }
                None
            }
        }
    }

    // ------------------------------------------------------------- the JIT

    fn run_jit(
        &mut self,
        fidx: usize,
        f: &Rc<Function>,
        entry: *const u8,
        args: &[Value],
    ) -> Result<Value, RuntimeError> {
        // One contiguous block: locals first, then the operand stack.
        let need = f.n_locals + f.max_stack + 1;
        let Some(base) = self.frames.push(need) else {
            return Err(RuntimeError {
                kind: ErrKind::StackOverflow,
                message: format!(
                    "ran out of JIT frame space in `{}` (deep recursion?)",
                    f.name
                ),
            });
        };

        // SAFETY: `push` reserved `need` slots starting at `base`, so every
        // write below is inside the arena.
        let locals = unsafe { self.frames.slot(base) };
        unsafe {
            for i in 0..f.n_locals {
                *locals.add(i) = value::int(0);
            }
            ptr::copy_nonoverlapping(args.as_ptr(), locals, args.len());
        }
        let stack = unsafe { locals.add(f.n_locals) };

        let consts = f.consts.as_ptr();
        self.shared.error = 0;
        self.shared.ret = value::int(0);
        let shared: *mut Shared = &mut self.shared;

        // SAFETY: `entry` points at a `ret`-terminated chain of stencils that
        // `jit::compile` laid out for exactly this signature, in memory that
        // is mapped read+exec and kept alive by `f.jit`. The `locals` and
        // `stack` pointers cover the slots the compiler sized for this
        // function, and `consts` is `f`'s own constant pool.
        unsafe {
            let entry: EntryFn = std::mem::transmute(entry);
            entry(stack, locals, shared, consts);
        }

        self.frames.pop_to(base);

        if self.shared.error != 0 {
            let code = self.shared.error;
            let pc = self.shared.err_pc as usize;
            self.shared.error = 0;
            return Err(self
                .pending
                .take()
                .unwrap_or_else(|| self.error_at(fidx, pc, ErrKind::from_code(code))));
        }
        Ok(self.shared.ret)
    }

    // ----------------------------------------------------- the interpreter

    fn run_interpreted(
        &mut self,
        fidx: usize,
        f: &Rc<Function>,
        args: &[Value],
    ) -> Result<Value, RuntimeError> {
        let mut locals = vec![value::int(0); f.n_locals];
        locals[..args.len()].copy_from_slice(args);
        let mut stack: Vec<Value> = Vec::with_capacity(f.max_stack + 1);
        let mut pc = 0usize;

        loop {
            let op = f.code[pc];
            self.stats.interpreted_ops += 1;

            match op {
                Op::Const(k) => stack.push(f.consts[k as usize]),
                Op::LoadLocal(i) => stack.push(locals[i as usize]),
                Op::StoreLocal(i) => locals[i as usize] = pop(&mut stack),
                Op::Pop => {
                    pop(&mut stack);
                }

                Op::Neg | Op::Not => {
                    let a = pop(&mut stack);
                    match unary(op, a) {
                        Ok(v) => stack.push(v),
                        Err(kind) => return Err(self.error_at(fidx, pc, kind)),
                    }
                }

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
                | Op::Ne => {
                    let b = pop(&mut stack);
                    let a = pop(&mut stack);
                    match binary(op, a, b) {
                        Ok(v) => stack.push(v),
                        Err(kind) => return Err(self.error_at(fidx, pc, kind)),
                    }
                }

                Op::Jump(t) => {
                    pc = t as usize;
                    continue;
                }
                Op::JumpIfFalse(t) => {
                    let a = pop(&mut stack);
                    if !value::is_bool(a) {
                        return Err(self.error_at(fidx, pc, ErrKind::Type));
                    }
                    if a == value::FALSE {
                        pc = t as usize;
                        continue;
                    }
                }

                Op::Call { func, argc } => {
                    let n = argc as usize;
                    let at = stack.len() - n;
                    let mut buf = [value::FALSE; MAX_ARGS];
                    buf[..n].copy_from_slice(&stack[at..]);
                    stack.truncate(at);
                    let r = self.call(func as usize, &buf[..n])?;
                    stack.push(r);
                }

                Op::CallValue { argc } => {
                    let n = argc as usize;
                    let at = stack.len() - n;
                    // The callee sits just below its arguments.
                    let callee = stack[at - 1];
                    if !value::is_func(callee) {
                        return Err(self.error_at(fidx, pc, ErrKind::Type));
                    }
                    let mut buf = [value::FALSE; MAX_ARGS];
                    buf[..n].copy_from_slice(&stack[at..]);
                    stack.truncate(at - 1);
                    let r = self.call(value::as_func(callee) as usize, &buf[..n])?;
                    stack.push(r);
                }

                Op::Return => return Ok(pop(&mut stack)),
                Op::Print => {
                    let v = pop(&mut stack);
                    self.emit_print(v);
                }
            }
            pc += 1;
        }
    }

    // ----------------------------------------------------------- plumbing

    /// Renders a value, naming function references from the function table.
    pub fn show(&self, v: Value) -> String {
        value::show_with(v, |i| {
            self.funcs
                .get(i as usize)
                .map(|f| format!("{}/{}", f.name, f.arity))
        })
    }

    fn emit_print(&mut self, v: Value) {
        let s = self.show(v);
        if self.echo {
            println!("{s}");
        }
        self.printed.push(s);
    }

    /// Builds the message for a fault at a known bytecode position. Both
    /// execution tiers route through this, so an interpreted run and a JIT'd
    /// run report the same text.
    fn error_at(&self, fidx: usize, pc: usize, kind: ErrKind) -> RuntimeError {
        let f = &self.funcs[fidx];
        let op = f.code.get(pc).copied();
        let what = match kind {
            ErrKind::DivZero => "division by zero".to_string(),
            ErrKind::Type => match op {
                Some(Op::JumpIfFalse(_)) => "condition must be a bool".to_string(),
                Some(Op::CallValue { .. }) => "the called value is not a function".to_string(),
                Some(o) => match o.source_operator() {
                    Some(sym) => format!("`{sym}` needs {}", operand_requirement(o)),
                    None => "type error".to_string(),
                },
                None => "type error".to_string(),
            },
            other => format!("{other:?}"),
        };
        RuntimeError {
            kind,
            message: format!(
                "runtime error in `{}` at pc {pc} ({}): {what}",
                f.name,
                op.map_or("?", |o| o.mnemonic())
            ),
        }
    }
}

fn operand_requirement(op: Op) -> &'static str {
    match op {
        Op::Not => "a bool",
        _ => "int operands",
    }
}

fn pop(stack: &mut Vec<Value>) -> Value {
    stack.pop().expect("the compiler sized this stack")
}

/// The interpreter's arithmetic, written to match the stencils bit for bit.
fn binary(op: Op, a: Value, b: Value) -> Result<Value, ErrKind> {
    let both_int = (a & b) & 1 == 1;
    match op {
        // Equality works on the tagged bits directly: no int is ever
        // bit-equal to a bool, so mixed comparisons are simply false.
        Op::Eq => return Ok(value::boolean(a == b)),
        Op::Ne => return Ok(value::boolean(a != b)),
        _ if !both_int => return Err(ErrKind::Type),
        _ => {}
    }
    let (ia, ib) = (a as i64, b as i64);
    Ok(match op {
        Op::Add => a.wrapping_add(b).wrapping_sub(1),
        Op::Sub => a.wrapping_sub(b).wrapping_add(1),
        Op::Mul => value::int((ia >> 1).wrapping_mul(ib >> 1)),
        Op::Div => {
            if ib >> 1 == 0 {
                return Err(ErrKind::DivZero);
            }
            value::int((ia >> 1).wrapping_div(ib >> 1))
        }
        Op::Rem => {
            if ib >> 1 == 0 {
                return Err(ErrKind::DivZero);
            }
            value::int((ia >> 1).wrapping_rem(ib >> 1))
        }
        Op::Lt => value::boolean(ia < ib),
        Op::Le => value::boolean(ia <= ib),
        Op::Gt => value::boolean(ia > ib),
        Op::Ge => value::boolean(ia >= ib),
        other => unreachable!("not a binary op: {other:?}"),
    })
}

fn unary(op: Op, a: Value) -> Result<Value, ErrKind> {
    match op {
        Op::Neg if value::is_int(a) => Ok(2u64.wrapping_sub(a)),
        Op::Not if value::is_bool(a) => Ok(a ^ value::TRUE),
        Op::Neg | Op::Not => Err(ErrKind::Type),
        other => unreachable!("not a unary op: {other:?}"),
    }
}

// --------------------------------------------------- callbacks from JIT code

/// # Safety
/// Called only by JIT'd code, which passes the `*mut Shared` it was handed and
/// a pointer to `argc` argument slots on its own operand stack.
unsafe extern "C" fn rt_call(shared: *mut Shared, fidx: u32, args: *mut Value, argc: u32) -> Value {
    // `Shared` is the first field of `Vm`, so this recovers the whole VM.
    let vm = &mut *(shared as *mut Vm);
    let n = (argc as usize).min(MAX_ARGS);
    let mut buf = [value::FALSE; MAX_ARGS];
    ptr::copy_nonoverlapping(args, buf.as_mut_ptr(), n);

    match vm.call(fidx as usize, &buf[..n]) {
        Ok(v) => v,
        Err(e) => {
            // Non-zero `error` makes the calling stencil bail out instead of
            // tail-calling onwards; `pending` carries the real message.
            vm.shared.error = e.kind as u32;
            vm.pending = Some(e);
            value::FALSE
        }
    }
}

/// # Safety
/// See [`rt_call`].
unsafe extern "C" fn rt_print(shared: *mut Shared, v: Value) {
    let vm = &mut *(shared as *mut Vm);
    vm.emit_print(v);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_layout_matches_the_c_struct() {
        // csrc/stencils.c hard-codes these offsets through struct member
        // access; if they drift, the JIT writes into the wrong fields.
        assert_eq!(std::mem::offset_of!(Shared, ret), 0x00);
        assert_eq!(std::mem::offset_of!(Shared, error), 0x08);
        assert_eq!(std::mem::offset_of!(Shared, err_pc), 0x0c);
        assert_eq!(std::mem::offset_of!(Shared, rt_call), 0x10);
        assert_eq!(std::mem::offset_of!(Shared, rt_print), 0x18);
        assert_eq!(std::mem::offset_of!(Vm, shared), 0);
    }

    #[test]
    fn error_codes_match_the_c_enum() {
        assert_eq!(ErrKind::Type as u32, 1);
        assert_eq!(ErrKind::DivZero as u32, 2);
    }
}
