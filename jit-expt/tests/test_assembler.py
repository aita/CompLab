import ctypes
import mmap

import pytest

from jit import (
    AL,
    AX,
    EAX,
    R8,
    RAX,
    RBX,
    RDI,
    RSI,
    RSP,
    RBP,
    SPL,
    Assembler,
    CodeBuffer,
    Runtime,
)


def encode(build) -> bytes:
    """Run `build(asm)` on a fresh assembler and return the emitted bytes."""
    code = CodeBuffer()
    build(Assembler(code))
    return bytes(code.code)


# Expected encodings independently verified with `nasm` + `objdump`.
# Note this assembler always uses the movabs (imm64) form for `mov r64, imm`
# and the ModR/M imm32 form for ALU ops, rather than nasm's shorter defaults.
ENCODINGS = [
    ("mov rax, 1",       lambda a: a.mov(RAX, 1),      "48b80100000000000000"),
    ("mov eax, 1",       lambda a: a.mov(EAX, 1),      "b801000000"),
    ("mov rbx, 1",       lambda a: a.mov(RBX, 1),      "48bb0100000000000000"),
    ("mov ax, 1",        lambda a: a.mov(AX, 1),       "66b80100"),
    ("mov al, 5",        lambda a: a.mov(AL, 5),       "b005"),
    ("mov r8, 1",        lambda a: a.mov(R8, 1),       "49b80100000000000000"),
    ("mov spl, 5",       lambda a: a.mov(SPL, 5),      "40b405"),
    ("mov rax, -1",      lambda a: a.mov(RAX, -1),     "48b8ffffffffffffffff"),
    ("mov rax, rdi",     lambda a: a.mov(RAX, RDI),    "4889f8"),
    ("add rax, rbx",     lambda a: a.add(RAX, RBX),    "4801d8"),
    ("add rax, rsi",     lambda a: a.add(RAX, RSI),    "4801f0"),
    ("add eax, 5",       lambda a: a.add(EAX, 5),      "83c005"),
    ("add eax, 1000",    lambda a: a.add(EAX, 1000),   "81c0e8030000"),
    ("sub eax, 5",       lambda a: a.sub(EAX, 5),      "83e805"),
    ("cmp eax, 5",       lambda a: a.cmp(EAX, 5),      "83f805"),
    ("mov rax, [rdi]",   lambda a: a.mov(RAX, RDI + 0), "488b07"),
    ("mov rax, [rdi+8]", lambda a: a.mov(RAX, RDI + 8), "488b4708"),
    ("mov rax, [rdi-8]", lambda a: a.mov(RAX, RDI - 8), "488b47f8"),
    ("mov rax, [rdi+0x1000]",
     lambda a: a.mov(RAX, RDI + 0x1000),                "488b8700100000"),
    ("mov [rdi], rax",   lambda a: a.mov(RDI + 0, RAX), "488907"),
    ("mov rax, [rsp]",   lambda a: a.mov(RAX, RSP + 0), "488b0424"),
    ("mov rax, [rbp]",   lambda a: a.mov(RAX, RBP + 0), "488b4500"),
    ("ret",              lambda a: a.ret(),             "c3"),
]


@pytest.mark.parametrize("name, build, expected",
                         ENCODINGS, ids=[c[0] for c in ENCODINGS])
def test_encoding(name, build, expected):
    assert encode(build).hex() == expected


def test_size_mismatch_raises():
    with pytest.raises(ValueError, match="operand size mismatch"):
        encode(lambda a: a.mov(RAX, EAX))


@pytest.mark.parametrize("build", [
    lambda a: a.mov(AL, 300),          # > imm8 max (255)
    lambda a: a.mov(AL, -200),         # < imm8 min (-128)
    lambda a: a.mov(EAX, 1 << 32),     # > imm32 unsigned max
    lambda a: a.add(EAX, 1 << 40),     # ALU imm exceeds 32-bit field
])
def test_immediate_out_of_range_raises(build):
    with pytest.raises(ValueError, match="out of range"):
        encode(build)


@pytest.mark.parametrize("build", [
    lambda a: a.mov(5, RAX),           # int destination
    lambda a: a.add(1, 2),             # two ints
])
def test_unsupported_operands_raise(build):
    with pytest.raises(TypeError):
        encode(build)


# --- Functional tests: assemble, map executable, and actually run it. ---

def run(build, restype, *argtypes, args=()):
    code = CodeBuffer()
    build(Assembler(code))
    rt = Runtime()  # keep alive: it owns the executable mmap until fn() returns
    addr = rt.add(code)
    fn = ctypes.CFUNCTYPE(restype, *argtypes)(addr)
    return fn(*args)


def test_run_constant():
    def build(a):
        a.mov(RAX, 42)
        a.ret()

    assert run(build, ctypes.c_int64) == 42


def test_run_add_two_args():
    # SysV AMD64: first two integer args arrive in RDI, RSI.
    def build(a):
        a.mov(RAX, RDI)
        a.add(RAX, RSI)
        a.ret()

    result = run(build, ctypes.c_int64, ctypes.c_int64, ctypes.c_int64,
                 args=(3, 4))
    assert result == 7


def test_run_load_from_memory():
    def build(a):
        a.mov(RAX, RDI + 0)  # RAX = *RDI
        a.ret()

    cell = ctypes.c_int64(1234)
    result = run(build, ctypes.c_int64, ctypes.c_void_p,
                 args=(ctypes.addressof(cell),))
    assert result == 1234


def test_run_store_to_memory():
    def build(a):
        a.mov(RDI + 0, RSI)  # *RDI = RSI
        a.ret()

    cell = ctypes.c_int64(0)
    run(build, None, ctypes.c_void_p, ctypes.c_int64,
        args=(ctypes.addressof(cell), 99))
    assert cell.value == 99


def _const_fn(value):
    def build(a):
        a.mov(RAX, value)
        a.ret()

    return build


def test_runtime_pools_functions_into_one_page():
    # Many small functions should share pages, not take one page each, and
    # every one must stay executable after later additions flip protections.
    rt = Runtime()
    sig = ctypes.CFUNCTYPE(ctypes.c_int64)

    fns = []
    pages = set()
    for value in range(50):
        code = CodeBuffer()
        _const_fn(value)(Assembler(code))
        addr = rt.add(code)
        fns.append((sig(addr), value))
        pages.add(addr & ~(mmap.PAGESIZE - 1))

    assert len(pages) < 50  # packed, not one page per function

    # Call them in reverse so the earliest-added (most re-protected) run last.
    for fn, value in reversed(fns):
        assert fn() == value


def test_entries_are_aligned():
    rt = Runtime(align=16)
    code = CodeBuffer()
    _const_fn(1)(Assembler(code))  # 10 bytes (movabs) + 1 (ret) = 11
    first = rt.add(code)

    code = CodeBuffer()
    _const_fn(2)(Assembler(code))
    second = rt.add(code)

    assert first % 16 == 0
    assert second % 16 == 0
    assert second - first == 16  # 11 bytes rounded up to the alignment
