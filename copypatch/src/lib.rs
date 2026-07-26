//! A tiny dynamically-typed language with a stack VM and a copy-and-patch
//! baseline JIT.
//!
//! The pipeline is `source -> nom parser -> AST -> bytecode -> (interpreter |
//! machine code)`. The JIT contains no assembler: its machine code was
//! emitted by clang at build time and is patched at run time. See
//! [`jit`] and `csrc/stencils.c`.

pub mod ast;
pub mod bytecode;
pub mod compiler;
pub mod jit;
pub mod parser;
pub mod value;
pub mod vm;

use std::rc::Rc;

use bytecode::Function;

/// Anything that can go wrong before the program starts running.
#[derive(Debug)]
pub enum BuildError {
    Parse(parser::ParseError),
    Compile(compiler::CompileError),
}

impl std::fmt::Display for BuildError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BuildError::Parse(e) => write!(f, "{e}"),
            BuildError::Compile(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for BuildError {}

/// Parses and compiles a program to bytecode.
pub fn build(src: &str) -> Result<Vec<Rc<Function>>, BuildError> {
    let ast = parser::parse(src).map_err(BuildError::Parse)?;
    compiler::compile(&ast).map_err(BuildError::Compile)
}
