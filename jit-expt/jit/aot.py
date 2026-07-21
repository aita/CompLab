"""Ahead-of-time backend: compile assembled functions into files on disk.

The Assembler records every instruction it encodes (Assembler.trace), so one
builder function has two backends. `jit.runtime.Runtime` is the just-in-time
one: it maps the encoded bytes into executable memory and hands back an address
to call right now. This module is the ahead-of-time one -- it renders the same
program as GNU-assembler source and drives binutils over it:

    gas source  --as-->  .o  --cc-->  shared library / executable

`load()` closes the loop by building a shared library and opening it with
ctypes, so an ahead-of-time-compiled function is callable from the same Python
process as a JIT-compiled one -- handy for checking that the two agree.

The emitted syntax is gas's Intel mode (`.intel_syntax noprefix`), which makes
the operand order match this assembler's Python API exactly: `a.mov(RAX, RDI)`
prints as `mov rax, rdi`, and `qword(RDI + 8)` as `qword ptr [rdi + 8]`.

Note the output is assembly *source*, not a dump of the JIT's bytes: gas picks
its own encodings and may well emit shorter ones (this assembler always uses
movabs for `mov r64, imm`, for instance). The two backends agree on behaviour,
not on bytes.

Requires binutils and a C driver to link with (`as` and `cc`).

Public API:
    gas_source(functions) -> str           # a .s file, one or more functions
    build_object / build_shared / build_executable(functions, out) -> Path
    load(functions) -> Module           # ... and call them from here
"""

from __future__ import annotations

import ctypes
import shutil
import subprocess
import tempfile
from collections.abc import Callable, Iterable, Mapping
from pathlib import Path
from typing import Any

from .assembler import Assembler, Label, Operand, Symbol, TraceInsn, TraceLabel
from .operands import Mem, Reg, RipRel, Xmm

# The functions to compile, keyed by the public name each gets in the output.
Functions = Mapping[str, Assembler]
AnyPath = str | Path

# --- Rendering ---------------------------------------------------------------


# Memory-operand widths that the operands themselves do not carry. A Mem wrapped
# with byte()/word()/dword()/qword() knows its width, and for most integer
# instructions the other (register) operand fixes it -- but for the SSE ops the
# register is an XMM, which says nothing about how much of it is accessed, and
# for jmp/call the operand is implicitly 64-bit. gas needs `ptr` sizes there.
_MEM_WIDTH: dict[str, int] = {
    "movsd": 64, "addsd": 64, "subsd": 64, "mulsd": 64, "divsd": 64,
    "sqrtsd": 64, "ucomisd": 64, "comisd": 64, "cvtsd2ss": 64, "cvttsd2si": 64,
    "movss": 32, "addss": 32, "subss": 32, "mulss": 32, "divss": 32,
    "sqrtss": 32, "ucomiss": 32, "comiss": 32, "cvtss2sd": 32, "cvttss2si": 32,
    # cvtsi2sd/ss read an *integer* source, which this assembler always encodes
    # with REX.W -- so m64, not the m32/m64 of the float side.
    "cvtsi2sd": 64, "cvtsi2ss": 64,
    "jmp": 64, "call": 64,
}

_WIDTH_NAME: dict[int, str] = {8: "byte", 16: "word", 32: "dword", 64: "qword"}


class _Namer:
    """Maps this program's Labels to assembler-local symbol names.

    Two things have to be fixed up. Labels are named per-Assembler ("c_outer",
    ".L0", ".data0"), so two functions in one file would collide; and a name
    that does not start with `.L` would land in the object file's symbol table
    as a stray global-ish symbol. Both are solved by mangling every label to
    `.L<function>.<label>`, which gas treats as a local, temporary symbol."""

    def __init__(self, func: str):
        self.prefix = f".L{_sanitize(func)}."

    def __call__(self, label: Label) -> str:
        if label.name is None:  # unreachable: Assembler.label() always names
            raise ValueError(f"cannot emit an unnamed label: {label!r}")
        return self.prefix + _sanitize(label.name.lstrip("."))


def _sanitize(name: str) -> str:
    """Keep a name to the characters gas accepts in a symbol."""
    return "".join(c if (c.isalnum() or c in "_.$") else "_" for c in name)


def _mem(mem: Mem, width: int | None, name: _Namer) -> str:
    """Render a memory operand, with a `<width> ptr` prefix when the width is
    known (and needed: lea passes None, since it computes an address rather
    than accessing anything)."""
    size = f"{_WIDTH_NAME[width]} ptr " if width else ""
    if isinstance(mem, RipRel):
        target = (mem.label.name if isinstance(mem.label, Symbol)
                  else name(mem.label))
        return f"{size}[rip + {target}]"
    parts: list[str] = []
    if mem.base is not None:
        parts.append(mem.base.name.lower())
    if mem.index is not None:
        parts.append(f"{mem.index.name.lower()} * {mem.scale}")
    if mem.disp or not parts:
        parts.append(str(mem.disp))
    return size + "[" + " + ".join(parts).replace("+ -", "- ") + "]"


def _operand(op: Operand, width: int | None, name: _Namer) -> str:
    match op:
        case Reg() | Xmm():
            return op.name.lower()
        case Mem():
            return _mem(op, width, name)
        case Label():
            return name(op)
        case Symbol():
            return op.name
        case int():
            return str(op)
        case _:
            raise TypeError(f"cannot render operand {op!r}")


def _width_of(insn: TraceInsn) -> int | None:
    """The `ptr` width to use for a memory operand of this instruction: the one
    the operand carries, else the instruction's fixed width, else the width of
    whatever general-purpose register it is paired with."""
    for op in insn.operands:
        if isinstance(op, Mem) and op.bitsize:
            return op.bitsize
    if insn.mnemonic in _MEM_WIDTH:
        return _MEM_WIDTH[insn.mnemonic]
    for op in insn.operands:
        if isinstance(op, Reg):
            return op.bitsize
    return None


def _insn(insn: TraceInsn, name: _Namer) -> str:
    mnemonic, ops = insn.mnemonic, insn.operands

    # A few calls do not map one-to-one onto their gas spelling.
    match mnemonic, ops:
        case "mov", (Reg() as dst, Symbol() as sym):
            # The JIT loads a symbol's address as an absolute imm64 patched at
            # map time. A linker cannot do that inside position-independent
            # code, so take the address RIP-relatively instead -- same value in
            # the register, and it links in a PIE or a shared library.
            return f"lea {dst.name.lower()}, [rip + {sym.name}]"
        # (Reg subclasses int, so the immediate form has to exclude it.)
        case "imul", (Reg() as dst, int() as imm) if not isinstance(imm, Reg):
            # The encoder uses the three-operand form with dst as the source.
            reg = dst.name.lower()
            return f"imul {reg}, {reg}, {imm}"
        case "movsx", (Reg(), src) if _source_bits(src) == 32:
            mnemonic = "movsxd"  # 63 /r has its own mnemonic in gas
        case "lea", (Reg() as dst, Mem() as src):
            return f"lea {dst.name.lower()}, {_mem(src, None, name)}"

    width = _width_of(insn)
    rendered = ", ".join(_operand(op, width, name) for op in ops)
    return f"{mnemonic} {rendered}".rstrip()


def _source_bits(src: Operand) -> int | None:
    return src.bitsize if isinstance(src, (Reg, Mem)) else None


def _text_section(func: str, asm: Assembler, globl: bool) -> list[str]:
    name = _Namer(func)
    out: list[str] = []
    if globl:
        out.append(f"\t.globl {func}")
    out += [f"\t.type {func}, @function", f"{func}:"]
    for entry in asm.trace:
        if isinstance(entry, TraceLabel):
            out.append(f"{name(entry.label)}:")
        else:
            out.append(f"\t{_insn(entry, name)}")
    out.append(f"\t.size {func}, .-{func}")
    return out


def _rodata_section(func: str, asm: Assembler) -> list[str]:
    """The data blobs and jump tables that finalize() would append after the
    code, as a .rodata section. Jump-table entries stay self-relative (a target's
    distance from the table base), exactly as the JIT builds them, so the
    dispatch sequence in Assembler.jump_table works unchanged."""
    name = _Namer(func)
    out: list[str] = []
    for label, blob, align in asm.data_blobs:
        if align > 1:
            out.append(f"\t.balign {align}")
        out.append(f"{name(label)}:")
        out.append("\t.byte " + ", ".join(f"0x{b:02x}" for b in blob))
    for table, targets in asm.jump_tables:
        out += ["\t.balign 4", f"{name(table)}:"]
        out += [f"\t.long {name(t)} - {name(table)}" for t in targets]
    return out


def gas_source(functions: Functions, *, globl: bool = True) -> str:
    """Render one or more assembled functions as a complete gas source file.

    `functions` maps a public function name to the Assembler that built it.
    Each becomes a `.text` symbol callable from C with that name; every label
    inside it is mangled to a file-local `.L` symbol, so several functions can
    share a file even when they used the same label names."""
    lines = ["\t.intel_syntax noprefix", "\t.text"]
    rodata: list[str] = []
    for func, asm in functions.items():
        lines += _text_section(func, asm, globl) + [""]
        rodata += _rodata_section(func, asm)
    if rodata:
        lines += ["\t.section .rodata", *rodata, ""]
    # Mark the stack non-executable, as every other toolchain-produced object
    # does; without it the linker conservatively keeps an executable stack.
    lines.append('\t.section .note.GNU-stack, "", @progbits')
    return "\n".join(lines) + "\n"


# --- Driving the toolchain ---------------------------------------------------

# binutils' assembler and the C driver used for linking (which knows where the
# C runtime startup files and the dynamic linker live, so an assembled `main`
# can be linked into a working executable).
_AS = "as"
_CC = "cc"


class ToolchainError(RuntimeError):
    """`as` or `cc` was missing, or exited non-zero."""


def have_toolchain() -> bool:
    """Whether the tools this module drives are installed, so a caller can fall
    back to the JIT backend (or skip a test) instead of failing."""
    return shutil.which(_AS) is not None and shutil.which(_CC) is not None


def _run(argv: list[str]) -> None:
    try:
        proc = subprocess.run(argv, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise ToolchainError(f"{argv[0]} not found; install binutils and a "
                             f"C compiler") from exc
    if proc.returncode != 0:
        raise ToolchainError(f"{' '.join(argv)} failed ({proc.returncode}):\n"
                             f"{proc.stderr.strip()}")


def assemble(source: str, out: AnyPath) -> Path:
    """Assemble gas `source` text into the object file `out`."""
    out = Path(out)
    asm_file = out.with_suffix(".s")
    asm_file.write_text(source)
    _run([_AS, "--64", "-o", str(out), str(asm_file)])
    return out


def build_object(functions: Functions, out: AnyPath) -> Path:
    """Assemble `functions` -- a {name: Assembler} mapping, as taken by
    gas_source() -- into a relocatable object file, ready to be linked into a
    C program like any other .o."""
    return assemble(gas_source(functions), out)


def link(objects: Iterable[AnyPath], out: AnyPath, *, shared: bool = False,
         sources: Iterable[AnyPath] = (),
         extra_args: Iterable[str] = ()) -> Path:
    """Link object files (and optionally C `sources`) into `out`, as a shared
    library when `shared` is set, else an executable."""
    argv = [_CC]
    if shared:
        argv += ["-shared", "-fPIC"]
    argv += ["-o", str(out), *map(str, objects), *map(str, sources),
             *extra_args]
    _run(argv)
    return Path(out)


def build_shared(functions: Functions, out: AnyPath, *,
                 sources: Iterable[AnyPath] = (),
                 extra_args: Iterable[str] = ()) -> Path:
    """Compile `functions` into a shared library at `out`, so any process can
    dlopen it. This is the ahead-of-time counterpart of Runtime.add()."""
    out = Path(out)
    obj = build_object(functions, out.with_suffix(".o"))
    return link([obj], out, shared=True, sources=sources, extra_args=extra_args)


def build_executable(functions: Functions, out: AnyPath, *,
                     sources: Iterable[AnyPath] = (),
                     extra_args: Iterable[str] = ()) -> Path:
    """Compile `functions` into a standalone executable at `out`. One of the
    `functions` (or one of the C `sources`) must provide `main`."""
    out = Path(out)
    obj = build_object(functions, out.with_suffix(".o"))
    return link([obj], out, sources=sources, extra_args=extra_args)


class Module:
    """A compiled shared library, opened for calling from this process.

    Holds on to the loaded library and (when it built one) the temporary
    directory it lives in, so neither is collected while a function of it is
    still callable."""

    def __init__(self, path: AnyPath,
                 _tmpdir: tempfile.TemporaryDirectory[str] | None = None):
        self.path = Path(path)
        self._tmpdir = _tmpdir
        self.lib = ctypes.CDLL(str(path))

    def func(self, name: str, restype: type | None = ctypes.c_int64,
             *argtypes: type) -> Callable[..., Any]:
        """Look up an ahead-of-time-compiled function and give it a C signature.
        Defaults to the `long f(long...)` shape the benchmarks use."""
        fn = getattr(self.lib, name)
        fn.restype = restype
        fn.argtypes = list(argtypes)
        return fn


def load(functions: Functions, *, sources: Iterable[AnyPath] = (),
         extra_args: Iterable[str] = ()) -> Module:
    """Compile `functions` ahead of time and open the result, returning a
    Module whose .func(name, ...) hands back a callable. The library is built
    in a temporary directory that lives as long as the module."""
    tmp = tempfile.TemporaryDirectory(prefix="jitaot_")
    lib = build_shared(functions, Path(tmp.name) / "aot.so", sources=sources,
                       extra_args=extra_args)
    return Module(lib, tmp)
