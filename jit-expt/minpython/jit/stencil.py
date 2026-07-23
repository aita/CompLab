"""A baseline (stencil) JIT whose value-op stencils are compiled from C.

Baseline tier: it stitches together pre-built per-opcode machine-code *stencils*
and patches in the operands, so compilation is little more than `memcpy` plus a
few field writes -- fast to compile, stack-slot code quality. (This stitch-and-
patch technique is called "copy-and-patch" in the literature; it is what
CPython 3.13's JIT uses.)

The stencils are compiled from C, the robust way: write each opcode as a C
template, compile it once with a C compiler, and read the machine code plus its
*relocations* out of the object file. The relocations say exactly where the
patchable holes are -- no fragile byte-pattern scanning.

The frame pointer is pinned to `rbx` (a callee-saved register, so it survives
the native `call` a recursive function makes) via a GCC global register
variable; each VM register `r` lives at `[rbx + r*8]`. A C template like
`A = B + C` where `A/B/C` dereference `rbx + (extern symbol)` compiles to
`mov`/`add` with a `R_X86_64_32S` relocation on each displacement -- that disp32
is the hole, patched at compile time with the real slot offset `r*8`.

Only the operand-slot value ops come from C (arithmetic, comparison, move).
LOAD_CONST needs a true 64-bit immediate and the control-flow ops need jumps and
calls to patched targets -- awkward in portable C -- so those are emitted
directly here, all using the same `rbx`-relative frame. Same int-only, self-
recursion-only subset as the other function compilers (`method.feasible`).

If no C toolchain is available the whole thing degrades to None, and callers
fall back to another compiler or the interpreter.
"""

from __future__ import annotations

import ctypes
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

from jit import (ARG_REGS, RAX, RBX, RSP, Assembler, ObjectCode, Runtime,
                 qword)

from ..bytecode import CodeObject, Op
from .method import _cfunctype, feasible

# --- the C templates --------------------------------------------------------
#
# One function per value op. `F` is the frame base, pinned to rbx. `_a/_b/_c`
# are extern symbols whose *addresses* are used as byte offsets into the frame;
# the compiler emits a relocation for each, which we read to find the hole and
# then overwrite with the real slot offset. `>>` on a signed long is arithmetic
# (matches Python's floor shift); `!B` gives NOT.

_C_SOURCE = r"""
register long *F asm("rbx");
extern char _a[], _b[], _c[];
#define A (*(long *)((char *)F + (long)_a))
#define B (*(long *)((char *)F + (long)_b))
#define C (*(long *)((char *)F + (long)_c))
void op_move(void) { A = B; }
void op_add(void)  { A = B + C; }
void op_sub(void)  { A = B - C; }
void op_mul(void)  { A = B * C; }
void op_and(void)  { A = B & C; }
void op_or(void)   { A = B | C; }
void op_xor(void)  { A = B ^ C; }
void op_shl(void)  { A = B << C; }
void op_shr(void)  { A = B >> C; }
void op_neg(void)  { A = -B; }
void op_inv(void)  { A = ~B; }
void op_lnot(void) { A = !B; }
void op_eq(void)   { A = (B == C); }
void op_ne(void)   { A = (B != C); }
void op_lt(void)   { A = (B < C); }
void op_le(void)   { A = (B <= C); }
void op_gt(void)   { A = (B > C); }
void op_ge(void)   { A = (B >= C); }
"""

_FUNC_OP = {
    "op_move": Op.MOVE, "op_add": Op.ADD, "op_sub": Op.SUB, "op_mul": Op.MUL,
    "op_and": Op.BIT_AND, "op_or": Op.BIT_OR, "op_xor": Op.BIT_XOR,
    "op_shl": Op.LSHIFT, "op_shr": Op.RSHIFT, "op_neg": Op.NEG,
    "op_inv": Op.INVERT, "op_lnot": Op.NOT,
    "op_eq": Op.EQ, "op_ne": Op.NE, "op_lt": Op.LT, "op_le": Op.LE,
    "op_gt": Op.GT, "op_ge": Op.GE,
}

_CFLAGS = ["-O2", "-c", "-fno-pic", "-fno-asynchronous-unwind-tables",
           "-fcf-protection=none", "-fomit-frame-pointer", "-mcmodel=small",
           "-ffreestanding"]

# R_X86_64_32S -- the relocation kind GCC uses for the [rbx + disp32] holes.
_R_X86_64_32S = 11


class _Stencil:
    __slots__ = ("code", "holes")

    def __init__(self, code: bytes, holes: list[tuple[int, str]]):
        self.code = code                 # machine code, trailing `ret` stripped
        self.holes = holes               # [(offset, role in {'a','b','c'})]


# --- minimal ELF64 relocatable-object reader --------------------------------


def _parse_object(data: bytes) -> dict[str, _Stencil]:
    """Extract each `op_*` function's code + slot-offset holes from a relocatable
    ELF64 object. Returns {opcode-name: _Stencil}."""
    if data[:4] != b"\x7fELF" or data[4] != 2:      # ELF64 little-endian only
        raise ValueError("not an ELF64 object")
    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3a)

    sections = []
    for i in range(e_shnum):
        base = e_shoff + i * e_shentsize
        name, stype, flags, addr, off, size, link, info, align, entsize = \
            struct.unpack_from("<IIQQQQIIQQ", data, base)
        sections.append(dict(name=name, type=stype, off=off, size=size,
                             link=link, entsize=entsize))

    def sec_name(sh) -> str:
        strtab = sections[e_shstrndx]
        start = strtab["off"] + sh["name"]
        end = data.index(b"\x00", start)
        return data[start:end].decode()

    by_name = {sec_name(s): s for s in sections}
    text = by_name[".text"]
    text_bytes = data[text["off"]:text["off"] + text["size"]]
    text_index = sections.index(text)

    symtab = by_name[".symtab"]
    symstr = sections[symtab["link"]]

    def str_at(strsec, off) -> str:
        start = strsec["off"] + off
        return data[start:data.index(b"\x00", start)].decode()

    # symbols: index -> (name, shndx, value, size)
    syms = []
    for i in range(symtab["size"] // symtab["entsize"]):
        base = symtab["off"] + i * symtab["entsize"]
        st_name, st_info, st_other, st_shndx, st_value, st_size = \
            struct.unpack_from("<IBBHQQ", data, base)
        syms.append((str_at(symstr, st_name), st_shndx, st_value, st_size))

    # functions defined in .text: name -> (offset, size)
    funcs = {name: (value, size) for (name, shndx, value, size) in syms
             if shndx == text_index and name in _FUNC_OP}

    # relocations against .text, grouped by which function they land in
    rela = by_name.get(".rela.text")
    relocs: list[tuple[int, int, str]] = []   # (offset, type, symbol-name)
    if rela is not None:
        for i in range(rela["size"] // rela["entsize"]):
            base = rela["off"] + i * rela["entsize"]
            r_offset, r_info, r_addend = struct.unpack_from("<QQq", data, base)
            r_type = r_info & 0xFFFFFFFF
            r_sym = r_info >> 32
            relocs.append((r_offset, r_type, syms[r_sym][0]))

    stencils: dict[str, _Stencil] = {}
    for fname, (foff, fsize) in funcs.items():
        body = text_bytes[foff:foff + fsize]
        if not body or body[-1] != 0xC3:            # must end in `ret`
            raise ValueError(f"{fname}: expected trailing ret")
        body = body[:-1]                            # strip it for fall-through
        holes: list[tuple[int, str]] = []
        for r_offset, r_type, sym in relocs:
            if foff <= r_offset < foff + fsize and sym in ("_a", "_b", "_c"):
                if r_type != _R_X86_64_32S:
                    raise ValueError(f"{fname}: unexpected reloc {r_type}")
                holes.append((r_offset - foff, sym[1]))   # '_a' -> 'a'
        stencils[fname] = _Stencil(bytes(body), holes)
    return stencils


# --- build the stencil table once -------------------------------------------

_TABLE: dict[Op, _Stencil] | None = None
_BUILD_TRIED = False


def _compiler() -> str | None:
    return shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")


def _build() -> dict[Op, _Stencil] | None:
    global _TABLE, _BUILD_TRIED
    if _BUILD_TRIED:
        return _TABLE
    _BUILD_TRIED = True
    cc = _compiler()
    if cc is None:
        return None
    try:
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "stencils.c"
            obj = Path(d) / "stencils.o"
            src.write_text(_C_SOURCE)
            subprocess.run([cc, *_CFLAGS, str(src), "-o", str(obj)],
                           check=True, capture_output=True)
            by_func = _parse_object(obj.read_bytes())
        _TABLE = {_FUNC_OP[name]: st for name, st in by_func.items()}
    except Exception:
        _TABLE = None
    return _TABLE


def available() -> bool:
    return _build() is not None


# --- the compiler ------------------------------------------------------------


def _slot(r: int):
    return qword(RBX + r * 8)


def _bytes(*emit) -> bytes:
    a = Assembler()
    for fn in emit:
        fn(a)
    return bytes(a.finalize().code)


def compile_stencil(code: CodeObject, rt: Runtime):
    """Compile `code` by stitching C-compiled value stencils (baseline tier),
    or return None if outside the subset or no toolchain is available."""
    table = _build()
    if table is None:
        return None
    reachable = feasible(code)
    if reachable is None:
        return None

    n_regs = code.n_regs
    frame = ((n_regs * 8 + 15) // 16) * 16

    # Each reachable pc -> (piece bytes, rel-hole offset within piece or None).
    # rbx = frame base; a slot for VM register r is [rbx + r*8].
    def piece(pc: int) -> tuple[bytes, int | None]:
        ins = code.code[pc]
        op = ins.op
        if op == Op.LOAD_GLOBAL:
            return b"", None                        # self-call callee: elided
        if op == Op.LOAD_CONST:
            return _bytes(lambda a: a.mov(RAX, int(code.consts[ins.b])),
                          lambda a: a.mov(_slot(ins.a), RAX)), None
        if op == Op.RETURN:
            return _bytes(lambda a: a.mov(RAX, _slot(ins.a)),
                          lambda a: a.add(RSP, frame),
                          lambda a: a.pop(RBX),
                          lambda a: a.ret()), None
        if op == Op.JUMP:
            b = _bytes(lambda a: (lbl := a.label(), a.jmp(lbl), a.bind(lbl)))
            return b, len(b) - 4
        if op in (Op.JUMP_IF_FALSE, Op.JUMP_IF_TRUE):
            jcc = "jz" if op == Op.JUMP_IF_FALSE else "jnz"
            b = _bytes(lambda a: a.mov(RAX, _slot(ins.a)),
                       lambda a: a.test(RAX, RAX),
                       lambda a: (lbl := a.label(),
                                  getattr(a, jcc)(lbl), a.bind(lbl)))
            return b, len(b) - 4
        if op == Op.CALL:
            arg_base = ins.b + 1
            emits = [(lambda a, i=i: a.mov(ARG_REGS[i], _slot(arg_base + i)))
                     for i in range(ins.c)]
            emits.append(lambda a: (lbl := a.label(), a.call(lbl), a.bind(lbl)))
            emits.append(lambda a: a.mov(_slot(ins.a), RAX))
            b = _bytes(*emits)
            return b, b.index(0xE8) + 1              # the sole 0xE8 is the call
        # a value op: copy the compiled stencil, patch its slot holes
        st = table[op]
        buf = bytearray(st.code)
        for off, role in st.holes:
            reg = {"a": ins.a, "b": ins.b, "c": ins.c}[role]
            buf[off:off + 4] = (reg * 8).to_bytes(4, "little", signed=True)
        return bytes(buf), None

    # Prologue: save rbx, carve the frame, point rbx at it, spill params.
    prologue = _bytes(
        lambda a: a.push(RBX),
        lambda a: a.sub(RSP, frame),
        lambda a: a.mov(RBX, RSP),
        *[(lambda a, i=i: a.mov(_slot(i), ARG_REGS[i]))
          for i in range(len(code.params))])

    order = sorted(reachable)
    pieces = {pc: piece(pc) for pc in order}
    offset: dict[int, int] = {}
    pos = len(prologue)
    for pc in order:
        offset[pc] = pos
        pos += len(pieces[pc][0])

    blob = bytearray(prologue)
    for pc in order:
        blob += pieces[pc][0]

    for pc in order:                                # patch jump / call targets
        body, rel = pieces[pc]
        if rel is None:
            continue
        ins = code.code[pc]
        field = offset[pc] + rel
        if ins.op == Op.CALL:
            target = 0                              # entry (self-recursion)
        elif ins.op == Op.JUMP:
            target = offset[ins.a]
        else:
            target = offset[ins.b]
        blob[field:field + 4] = (target - (field + 4)).to_bytes(
            4, "little", signed=True)

    addr = rt.add(ObjectCode(bytes(blob)))
    return _cfunctype(len(code.params))(addr)
