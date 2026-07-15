import ctypes
import mmap

import pytest

from jit import (
    AL,
    AX,
    BL,
    CL,
    DL,
    EAX,
    EBX,
    ECX,
    R8,
    R10,
    R12,
    RAX,
    RBX,
    RCX,
    RDX,
    RDI,
    RSI,
    RSP,
    RBP,
    SPL,
    XMM0,
    XMM1,
    XMM2,
    XMM3,
    XMM8,
    XMM9,
    XMM11,
    Assembler,
    Label,
    Mem,
    Reloc,
    RelocKind,
    Runtime,
    Symbol,
    byte,
    dword,
    qword,
    rip,
    word,
)


def encode(build) -> bytes:
    """Run `build(asm)` on a fresh assembler and return the assembled bytes."""
    asm = Assembler()
    build(asm)
    return asm.finalize().code


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
    # Scaled-index (SIB) addressing.
    ("mov rax, [rcx+rdx*4]",
     lambda a: a.mov(RAX, RCX + RDX * 4),               "488b0491"),
    ("mov rax, [rcx+rdx*4+0x10]",
     lambda a: a.mov(RAX, RCX + RDX * 4 + 0x10),        "488b449110"),
    ("mov rax, [rbp+rdx*8]",
     lambda a: a.mov(RAX, RBP + RDX * 8),               "488b44d500"),
    ("mov rax, [r12+rax*2]",
     lambda a: a.mov(RAX, R12 + RAX * 2),               "498b0444"),
    ("mov rax, [rcx+r8*4]",
     lambda a: a.mov(RAX, RCX + R8 * 4),                "4a8b0481"),
    ("mov rax, [rax+rcx]",
     lambda a: a.mov(RAX, RAX + RCX),                   "488b0408"),
    ("mov rax, [rcx+rdx*4+0x1000]",
     lambda a: a.mov(RAX, RCX + RDX * 4 + 0x1000),      "488b849100100000"),
    ("mov [rcx+rdx*8], rax",
     lambda a: a.mov(RCX + RDX * 8, RAX),               "488904d1"),
    ("ret",              lambda a: a.ret(),             "c3"),
    # Calls, stack, and frame teardown.
    ("call rax",         lambda a: a.call(RAX),         "ffd0"),
    ("call r10",         lambda a: a.call(R10),         "41ffd2"),
    ("push rax",         lambda a: a.push(RAX),         "50"),
    ("push r12",         lambda a: a.push(R12),         "4154"),
    ("pop rax",          lambda a: a.pop(RAX),          "58"),
    ("pop r12",          lambda a: a.pop(R12),          "415c"),
    ("leave",            lambda a: a.leave(),           "c9"),
    # Bitwise, unary, test, multiply, and lea.
    ("and rax, rbx",     lambda a: a.and_(RAX, RBX),    "4821d8"),
    ("or rax, rbx",      lambda a: a.or_(RAX, RBX),     "4809d8"),
    ("xor rax, rbx",     lambda a: a.xor(RAX, RBX),     "4831d8"),
    ("xor eax, eax",     lambda a: a.xor(EAX, EAX),     "31c0"),
    ("or rax, 1",        lambda a: a.or_(RAX, 1),       "4883c801"),
    ("not rax",          lambda a: a.not_(RAX),         "48f7d0"),
    ("neg rax",          lambda a: a.neg(RAX),          "48f7d8"),
    ("neg r8",           lambda a: a.neg(R8),           "49f7d8"),
    ("test rax, rax",    lambda a: a.test(RAX, RAX),    "4885c0"),
    ("test eax, eax",    lambda a: a.test(EAX, EAX),    "85c0"),
    ("imul rax, rbx",    lambda a: a.imul(RAX, RBX),    "480fafc3"),
    ("imul rax, [rdi]",  lambda a: a.imul(RAX, RDI + 0), "480faf07"),
    ("imul rax, 3",      lambda a: a.imul(RAX, 3),      "486bc003"),
    ("imul rax, 1000",   lambda a: a.imul(RAX, 1000),   "4869c0e8030000"),
    ("lea rax, [rdi+8]", lambda a: a.lea(RAX, RDI + 8), "488d4708"),
    ("lea rax, [rdi+rsi*4]",
     lambda a: a.lea(RAX, RDI + RSI * 4),               "488d04b7"),
    ("lea rax, [rdi+rsi*4+16]",
     lambda a: a.lea(RAX, RDI + RSI * 4 + 16),          "488d44b710"),
    # Immediate to memory (size given by byte/word/dword/qword).
    ("mov qword [rdi], 5",
     lambda a: a.mov(qword(RDI + 0), 5),                "48c70705000000"),
    ("mov dword [rdi], 5",
     lambda a: a.mov(dword(RDI + 0), 5),                "c70705000000"),
    ("mov word [rdi], 5",
     lambda a: a.mov(word(RDI + 0), 5),                 "66c7070500"),
    ("mov byte [rdi], 5",
     lambda a: a.mov(byte(RDI + 0), 5),                 "c60705"),
    ("add qword [rdi], 5",
     lambda a: a.add(qword(RDI + 0), 5),                "48830705"),
    ("and dword [rdi], 0xff",
     lambda a: a.and_(dword(RDI + 0), 0xFF),            "8127ff000000"),
    ("add qword [rdi+rsi*4+16], 7",
     lambda a: a.add(qword(RDI + RSI * 4 + 16), 7),     "488344b71007"),
    # Shifts by immediate and by CL.
    ("shl rax, 3",       lambda a: a.shl(RAX, 3),       "48c1e003"),
    ("shl eax, 3",       lambda a: a.shl(EAX, 3),       "c1e003"),
    ("shl r8, 5",        lambda a: a.shl(R8, 5),        "49c1e005"),
    ("shl al, 3",        lambda a: a.shl(AL, 3),        "c0e003"),
    ("shl byte [rdi], 3",
     lambda a: a.shl(byte(RDI + 0), 3),                 "c02703"),
    ("shl rax, cl",      lambda a: a.shl(RAX, CL),      "48d3e0"),
    ("shl eax, cl",      lambda a: a.shl(EAX, CL),      "d3e0"),
    ("shr rax, 3",       lambda a: a.shr(RAX, 3),       "48c1e803"),
    ("shr eax, cl",      lambda a: a.shr(EAX, CL),      "d3e8"),
    ("sar r8, 5",        lambda a: a.sar(R8, 5),        "49c1f805"),
    ("sar rax, cl",      lambda a: a.sar(RAX, CL),      "48d3f8"),
    # Increment / decrement.
    ("inc rax",          lambda a: a.inc(RAX),          "48ffc0"),
    ("inc eax",          lambda a: a.inc(EAX),          "ffc0"),
    ("inc r8",           lambda a: a.inc(R8),           "49ffc0"),
    ("inc al",           lambda a: a.inc(AL),           "fec0"),
    ("inc dword [rdi]",  lambda a: a.inc(dword(RDI + 0)), "ff07"),
    ("dec rax",          lambda a: a.dec(RAX),          "48ffc8"),
    ("dec dword [rdi]",  lambda a: a.dec(dword(RDI + 0)), "ff0f"),
    ("dec al",           lambda a: a.dec(AL),           "fec8"),
    # Zero/sign extension.
    ("movzx rax, byte [rdi]",
     lambda a: a.movzx(RAX, byte(RDI + 0)),             "480fb607"),
    ("movzx rax, bl",    lambda a: a.movzx(RAX, BL),    "480fb6c3"),
    ("movzx eax, bl",    lambda a: a.movzx(EAX, BL),    "0fb6c3"),
    ("movzx rax, word [rdi]",
     lambda a: a.movzx(RAX, word(RDI + 0)),             "480fb707"),
    ("movzx rax, ax",    lambda a: a.movzx(RAX, AX),    "480fb7c0"),
    ("movsx rax, byte [rdi]",
     lambda a: a.movsx(RAX, byte(RDI + 0)),             "480fbe07"),
    ("movsx rax, bl",    lambda a: a.movsx(RAX, BL),    "480fbec3"),
    ("movsx rax, ax",    lambda a: a.movsx(RAX, AX),    "480fbfc0"),
    ("movsx eax, al",    lambda a: a.movsx(EAX, AL),    "0fbec0"),
    ("movsxd rax, ecx",  lambda a: a.movsx(RAX, ECX),   "4863c1"),
    # setcc (byte set on condition).
    ("setne al",         lambda a: a.setne(AL),         "0f95c0"),
    ("sete cl",          lambda a: a.sete(CL),          "0f94c1"),
    ("setl dl",          lambda a: a.setl(DL),          "0f9cc2"),
    ("setg bl",          lambda a: a.setg(BL),          "0f9fc3"),
    ("seta al",          lambda a: a.seta(AL),          "0f97c0"),
    ("setb al",          lambda a: a.setb(AL),          "0f92c0"),
    ("setne byte [rdi]", lambda a: a.setne(byte(RDI + 0)), "0f9507"),
    # cmovcc (conditional move).
    ("cmovne rax, rbx",  lambda a: a.cmovne(RAX, RBX),  "480f45c3"),
    ("cmove rax, rbx",   lambda a: a.cmove(RAX, RBX),   "480f44c3"),
    ("cmovl rax, rbx",   lambda a: a.cmovl(RAX, RBX),   "480f4cc3"),
    ("cmovg eax, ebx",   lambda a: a.cmovg(EAX, EBX),   "0f4fc3"),
    ("cmovne rax, [rdi]",
     lambda a: a.cmovne(RAX, RDI + 0),                  "480f4507"),
    # Scalar-double (SSE2) floats. F2 mandatory prefix, then REX, then 0F.
    ("movsd xmm0, xmm1",  lambda a: a.movsd(XMM0, XMM1), "f20f10c1"),
    ("movsd xmm0, [rdi]",
     lambda a: a.movsd(XMM0, RDI + 0),                  "f20f1007"),
    ("movsd [rdi], xmm0",
     lambda a: a.movsd(RDI + 0, XMM0),                  "f20f1107"),
    ("addsd xmm0, xmm1",  lambda a: a.addsd(XMM0, XMM1), "f20f58c1"),
    ("subsd xmm2, xmm3",  lambda a: a.subsd(XMM2, XMM3), "f20f5cd3"),
    ("mulsd xmm0, xmm1",  lambda a: a.mulsd(XMM0, XMM1), "f20f59c1"),
    ("divsd xmm0, xmm1",  lambda a: a.divsd(XMM0, XMM1), "f20f5ec1"),
    # XMM8+ needs REX.R/REX.B, placed after the F2 prefix.
    ("addsd xmm8, xmm9",  lambda a: a.addsd(XMM8, XMM9), "f2450f58c1"),
    ("movsd xmm8, [rdi]",
     lambda a: a.movsd(XMM8, RDI + 0),                  "f2440f1007"),
    # Integer <-> double conversions (REX.W for the 64-bit GP operand).
    ("cvtsi2sd xmm0, rdi",
     lambda a: a.cvtsi2sd(XMM0, RDI),                   "f2480f2ac7"),
    ("cvttsd2si rax, xmm0",
     lambda a: a.cvttsd2si(RAX, XMM0),                  "f2480f2cc0"),
    ("cvttsd2si r10, xmm11",
     lambda a: a.cvttsd2si(R10, XMM11),                 "f24d0f2cd3"),
]


def test_memory_immediate_needs_size():
    with pytest.raises(ValueError, match="needs a size"):
        encode(lambda a: a.mov(RDI + 0, 5))  # no byte/word/dword/qword


def test_call_label_encoding():
    # call to a label placed right after: E8 rel32 = 0.
    def build(a):
        target = Label("target")
        a.call(target)
        a.bind(target)
    assert encode(build).hex() == "e800000000"


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


def _jump_sequence(a):
    # back: jmp back; jmp fwd; fwd: je/jne/jl/jge/jle/jg t2; t2:
    back = a.bind(Label("back"))
    a.jmp(back)
    fwd = Label("fwd")
    a.jmp(fwd)
    a.bind(fwd)
    t2 = Label("t2")
    for j in (a.je, a.jne, a.jl, a.jge, a.jle, a.jg):
        j(t2)
    a.bind(t2)


def test_jump_encodings():
    # rel32 displacements verified against nasm.
    expected = (
        "e9fbffffff" "e900000000"           # jmp back (-5), jmp fwd (0)
        "0f841e000000" "0f8518000000"        # je, jne
        "0f8c12000000" "0f8d0c000000"        # jl, jge
        "0f8e06000000" "0f8f00000000"        # jle, jg
    )
    assert encode(_jump_sequence).hex() == expected


def _ujump_sequence(a):
    # ja/jae/jb/jbe/js/jns t; t:
    t = Label("t")
    for j in (a.ja, a.jae, a.jb, a.jbe, a.js, a.jns):
        j(t)
    a.bind(t)


def test_unsigned_jump_encodings():
    expected = (
        "0f871e000000" "0f8318000000"        # ja, jae
        "0f8212000000" "0f860c000000"        # jb, jbe
        "0f8806000000" "0f8900000000"        # js, jns
    )
    assert encode(_ujump_sequence).hex() == expected


def test_run_unsigned_min():
    # return min(rdi, rsi) treating both as unsigned
    def build(a):
        first = Label("first")
        a.mov(RAX, RDI)
        a.cmp(RDI, RSI)
        a.jbe(first)       # rdi <= rsi (unsigned) -> keep rdi
        a.mov(RAX, RSI)
        a.bind(first)
        a.ret()

    # -1 as unsigned is the largest 64-bit value, so min(-1, 5) == 5
    for x, y in [(3, 7), (7, 3), (-1, 5)]:
        result = run(build, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_uint64,
                     args=(x & 0xFFFFFFFFFFFFFFFF, y))
        assert result == min(x & 0xFFFFFFFFFFFFFFFF, y)


def test_finalize_unbound_label_raises():
    a = Assembler()
    a.jmp(Label("nowhere"))  # target never bound
    with pytest.raises(ValueError, match="unbound label"):
        a.finalize()


def test_run_countdown_loop():
    # sum = 0; while (rdi != 0) { sum += rdi; rdi -= 1; } return sum
    def build(a):
        top = Label("top")
        end = Label("end")
        a.mov(RAX, 0)
        a.bind(top)
        a.cmp(RDI, 0)
        a.je(end)
        a.add(RAX, RDI)
        a.sub(RDI, 1)
        a.jmp(top)
        a.bind(end)
        a.ret()

    for n in (0, 1, 5, 10):
        result = run(build, ctypes.c_int64, ctypes.c_int64, args=(n,))
        assert result == n * (n + 1) // 2


def test_run_max_conditional():
    # return (rdi >= rsi) ? rdi : rsi
    def build(a):
        done = Label("done")
        a.mov(RAX, RDI)
        a.cmp(RDI, RSI)
        a.jge(done)
        a.mov(RAX, RSI)
        a.bind(done)
        a.ret()

    for x, y in [(3, 7), (7, 3), (5, 5), (-2, -9)]:
        result = run(build, ctypes.c_int64, ctypes.c_int64, ctypes.c_int64,
                     args=(x, y))
        assert result == max(x, y)


def test_rsp_index_rejected():
    with pytest.raises(ValueError, match="index register"):
        Mem(RAX, index=RSP)


def test_invalid_scale_rejected():
    with pytest.raises(ValueError, match="scale"):
        Mem(RAX, index=RDX, scale=3)


# --- Functional tests: assemble, map executable, and actually run it. ---

def run(build, restype, *argtypes, args=()):
    asm = Assembler()
    build(asm)
    rt = Runtime()  # keep alive: it owns the executable mmap until fn() returns
    addr = rt.add(asm.finalize())  # explicit finalize resolves jump fixups
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


def test_run_scaled_index_load():
    # int64 arr[]; return arr[idx] via [RDI + RSI*8].  (RDI=arr, RSI=idx)
    def build(a):
        a.mov(RAX, RDI + RSI * 8)
        a.ret()

    arr = (ctypes.c_int64 * 4)(10, 20, 30, 40)
    load = ctypes.cast(arr, ctypes.c_void_p)
    for idx in range(4):
        result = run(build, ctypes.c_int64, ctypes.c_void_p, ctypes.c_int64,
                     args=(load, idx))
        assert result == arr[idx]


def test_run_scaled_index_store():
    # arr[idx] = val via [RDI + RSI*8] = RDX.  (RDI=arr, RSI=idx, RDX=val)
    def build(a):
        a.mov(RDI + RSI * 8, RDX)
        a.ret()

    arr = (ctypes.c_int64 * 3)(0, 0, 0)
    base = ctypes.cast(arr, ctypes.c_void_p)
    run(build, None, ctypes.c_void_p, ctypes.c_int64, ctypes.c_int64,
        args=(base, 2, 777))
    assert list(arr) == [0, 0, 777]


def test_run_calls_c_function():
    # Call a C function (a ctypes callback) from JIT'd code and return its
    # result. The push rbp / mov rbp, rsp frame realigns rsp to 16 bytes,
    # which the SysV ABI requires at the call.
    sig = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)
    callback = sig(lambda x: x * 3)
    cb_addr = ctypes.cast(callback, ctypes.c_void_p).value

    def build(a):
        a.push(RBP)
        a.mov(RBP, RSP)     # frame; now rsp is 16-byte aligned
        a.mov(RAX, cb_addr)
        a.call(RAX)         # rax = callback(rdi)
        a.leave()
        a.ret()

    assert run(build, ctypes.c_int64, ctypes.c_int64, args=(7,)) == 21
    assert callback  # keep the callback alive until after the call


def test_run_calls_another_jit_function():
    rt = Runtime()  # keep alive: owns the executable pages for both functions

    # callee(x) = x + 1
    callee = Assembler()
    callee.mov(RAX, RDI)
    callee.add(RAX, 1)
    callee.ret()
    callee_addr = rt.add(callee.finalize())

    # caller(x) = callee(x)
    caller = Assembler()
    caller.push(RBP)
    caller.mov(RBP, RSP)
    caller.mov(RAX, callee_addr)
    caller.call(RAX)
    caller.leave()
    caller.ret()
    caller_addr = rt.add(caller.finalize())

    fn = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(caller_addr)
    assert fn(41) == 42


def test_mov_symbol_is_abs64_reloc():
    a = Assembler()
    a.mov(RAX, Symbol("foo"))
    obj = a.finalize()
    assert obj.code.hex() == "48b80000000000000000"  # movabs rax, 0 (placeholder)
    assert obj.relocs == (Reloc(offset=2, symbol="foo", kind=RelocKind.ABS64),)


def test_call_symbol_is_rel32_reloc():
    a = Assembler()
    a.call(Symbol("bar"))
    obj = a.finalize()
    assert obj.code.hex() == "e800000000"  # E8 + 4-byte rel32 placeholder
    assert obj.relocs == (Reloc(offset=1, symbol="bar", kind=RelocKind.REL32),)


def test_symbol_requires_64bit_register():
    with pytest.raises(ValueError, match="64-bit register"):
        encode(lambda a: a.mov(EAX, Symbol("x")))


def test_add_unresolved_symbol_raises():
    a = Assembler()
    a.mov(RAX, Symbol("missing"))
    a.ret()
    with pytest.raises(KeyError, match="missing"):
        Runtime().add(a.finalize())


def test_run_calls_c_function_by_symbol():
    # A C function can be far away, so load its absolute address (ABS64) into a
    # register and call indirectly. Its address is registered with define().
    sig = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)
    callback = sig(lambda x: x + 100)
    cb_addr = ctypes.cast(callback, ctypes.c_void_p).value

    a = Assembler()
    a.push(RBP)
    a.mov(RBP, RSP)
    a.mov(RAX, Symbol("cb"))    # ABS64 reloc, resolved from the symbol table
    a.call(RAX)
    a.leave()
    a.ret()

    rt = Runtime()
    rt.define("cb", cb_addr)
    addr = rt.add(a.finalize())
    fn = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(addr)
    assert fn(5) == 105
    assert callback  # keep alive


def test_run_jit_calls_jit_by_symbol():
    rt = Runtime()

    # square(x) = x * x, added under a name so callers can reference it
    square = Assembler()
    square.mov(RAX, RDI)
    square.imul(RAX, RDI)
    square.ret()
    rt.add(square.finalize(), name="square")

    # caller makes a direct rel32 call to the pooled square (no dict needed)
    caller = Assembler()
    caller.sub(RSP, 8)             # 16-byte align for the call
    caller.call(Symbol("square"))
    caller.add(RSP, 8)
    caller.ret()
    caller_addr = rt.add(caller.finalize())

    fn = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(caller_addr)
    assert fn(9) == 81


def test_run_recursion_by_symbol():
    # fact(n) = n <= 1 ? 1 : n * fact(n-1), calling itself by symbol. Adding
    # with name="fact" registers the address before relocs resolve, so the
    # self-reference binds.
    rt = Runtime()
    a = Assembler()
    recurse, done = Label("recurse"), Label("done")
    a.push(RBP)
    a.mov(RBP, RSP)
    a.push(RBX)
    a.sub(RSP, 8)           # save rbx (callee-saved) and keep 16-byte alignment
    a.mov(RBX, RDI)         # rbx = n, preserved across the recursive call
    a.cmp(RDI, 1)
    a.jg(recurse)
    a.mov(RAX, 1)
    a.jmp(done)
    a.bind(recurse)
    a.mov(RDI, RBX)
    a.sub(RDI, 1)
    a.call(Symbol("fact"))  # rax = fact(n-1)
    a.imul(RAX, RBX)        # n * fact(n-1)
    a.bind(done)
    a.add(RSP, 8)
    a.pop(RBX)
    a.leave()
    a.ret()
    addr = rt.add(a.finalize(), name="fact")

    fn = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(addr)
    assert fn(5) == 120
    assert fn(10) == 3628800


def test_run_mutual_recursion_by_symbol():
    # is_even/is_odd call each other by symbol. Neither address is known before
    # the other is placed, so both are staged (registering both names) and then
    # linked together to resolve the cross-references.
    rt = Runtime()

    def build_even(a):
        done = Label("done")
        a.push(RBP)
        a.mov(RBP, RSP)
        a.cmp(RDI, 0)
        a.je(done)
        a.sub(RDI, 1)
        a.call(Symbol("is_odd"))
        a.leave()
        a.ret()
        a.bind(done)
        a.mov(RAX, 1)
        a.leave()
        a.ret()

    def build_odd(a):
        done = Label("done")
        a.push(RBP)
        a.mov(RBP, RSP)
        a.cmp(RDI, 0)
        a.je(done)
        a.sub(RDI, 1)
        a.call(Symbol("is_even"))
        a.leave()
        a.ret()
        a.bind(done)
        a.mov(RAX, 0)
        a.leave()
        a.ret()

    even = Assembler()
    build_even(even)
    odd = Assembler()
    build_odd(odd)

    even_addr = rt.stage(even.finalize(), name="is_even")
    odd_addr = rt.stage(odd.finalize(), name="is_odd")
    rt.link()

    is_even = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(even_addr)
    is_odd = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(odd_addr)

    for n in range(12):
        assert is_even(n) == (1 if n % 2 == 0 else 0)
        assert is_odd(n) == (1 if n % 2 == 1 else 0)
    assert is_even(10) == 1
    assert is_even(7) == 0
    assert is_odd(7) == 1
    assert is_odd(4) == 0


def test_link_unresolved_symbol_raises():
    # Staging a function that calls a never-registered symbol must fail at
    # link() with KeyError, just like the eager add() path.
    rt = Runtime()
    a = Assembler()
    a.sub(RSP, 8)
    a.call(Symbol("nonexistent"))
    a.add(RSP, 8)
    a.ret()
    rt.stage(a.finalize(), name="caller")
    with pytest.raises(KeyError, match="nonexistent"):
        rt.link()


def test_link_no_pending_is_noop():
    rt = Runtime()
    rt.link()  # nothing staged
    rt.link()


def test_run_far_call_uses_veneer():
    # A rel32 call reaches only +-2GB. Map a target far below the JIT pages so
    # call(Symbol) must route through a movabs+jmp veneer.
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mmap.restype = ctypes.c_void_p
    libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                          ctypes.c_int, ctypes.c_int, ctypes.c_long]
    MAP_FIXED_NOREPLACE = 0x100000
    flags = mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS | MAP_FIXED_NOREPLACE
    far = None
    for hint in (0x40000000, 0x50000000, 0x60000000, 0x30000000):
        if libc.mmap(ctypes.c_void_p(hint), 4096, 1 | 2 | 4, flags, -1, 0) == hint:
            far = hint
            break
    if far is None:
        pytest.skip("could not map a far executable page")
    ctypes.memmove(far, bytes([0xB8, 99, 0, 0, 0, 0xC3]), 6)  # mov eax, 99; ret

    rt = Runtime()
    rt.define("far", far)
    a = Assembler()
    a.sub(RSP, 8)
    a.call(Symbol("far"))
    a.add(RSP, 8)
    a.ret()
    addr = rt.add(a.finalize())
    assert abs(addr - far) > (1 << 31)  # confirm the target really is far
    assert rt._veneers                  # a veneer was created for it
    fn = ctypes.CFUNCTYPE(ctypes.c_int64)(addr)
    assert fn() == 99


def test_run_multiply():
    # return rdi * rsi
    def build(a):
        a.mov(RAX, RDI)
        a.imul(RAX, RSI)
        a.ret()

    result = run(build, ctypes.c_int64, ctypes.c_int64, ctypes.c_int64,
                 args=(6, 7))
    assert result == 42


def test_run_lea_address_math():
    # return rdi + rsi*4 + 8, computed purely with lea (no memory access)
    def build(a):
        a.lea(RAX, RDI + RSI * 4 + 8)
        a.ret()

    result = run(build, ctypes.c_int64, ctypes.c_int64, ctypes.c_int64,
                 args=(10, 3))
    assert result == 30


def test_run_bitwise_mask():
    # return rdi & 0xff
    def build(a):
        a.mov(RAX, RDI)
        a.and_(RAX, 0xFF)
        a.ret()

    for x in (0x1234, 0xFF, 0x100, 0):
        result = run(build, ctypes.c_int64, ctypes.c_int64, args=(x,))
        assert result == (x & 0xFF)


def test_run_test_and_branch():
    # return 0 if rdi == 0 else 1, using `test rdi, rdi; je`
    def build(a):
        zero = Label("zero")
        a.xor(RAX, RAX)        # rax = 0  (the classic zeroing idiom)
        a.test(RDI, RDI)
        a.je(zero)
        a.mov(RAX, 1)
        a.bind(zero)
        a.ret()

    assert run(build, ctypes.c_int64, ctypes.c_int64, args=(0,)) == 0
    assert run(build, ctypes.c_int64, ctypes.c_int64, args=(42,)) == 1


def test_run_store_immediate():
    # *(int64*)rdi = 12345;  then bump it by 100 with add qword [rdi], 100
    def build(a):
        a.mov(qword(RDI + 0), 12345)
        a.add(qword(RDI + 0), 100)
        a.ret()

    cell = ctypes.c_int64(0)
    run(build, None, ctypes.c_void_p, args=(ctypes.addressof(cell),))
    assert cell.value == 12445


def test_run_store_immediate_bytes():
    # write two bytes at [rdi] and [rdi+1]
    def build(a):
        a.mov(byte(RDI + 0), 0xAB)
        a.mov(byte(RDI + 1), 0xCD)
        a.ret()

    buf = (ctypes.c_uint8 * 2)(0, 0)
    run(build, None, ctypes.c_void_p, args=(ctypes.cast(buf, ctypes.c_void_p),))
    assert list(buf) == [0xAB, 0xCD]


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
        asm = Assembler()
        _const_fn(value)(asm)
        addr = rt.add(asm.finalize())
        fns.append((sig(addr), value))
        pages.add(addr & ~(mmap.PAGESIZE - 1))

    assert len(pages) < 50  # packed, not one page per function

    # Call them in reverse so the earliest-added (most re-protected) run last.
    for fn, value in reversed(fns):
        assert fn() == value


def test_run_shift_multiply_divide():
    # return (rdi << 3) then (>> 1): multiply by 8, then halve -> rdi * 4
    def build(a):
        a.mov(RAX, RDI)
        a.shl(RAX, 3)      # * 8
        a.shr(RAX, 1)      # unsigned / 2
        a.ret()

    for x in (1, 5, 100, 0):
        result = run(build, ctypes.c_uint64, ctypes.c_uint64, args=(x,))
        assert result == (x << 3) >> 1


def test_run_sar_signed():
    # arithmetic shift right by rsi (in CL) preserves sign: floor(rdi / 2^n)
    def build(a):
        a.mov(RAX, RDI)
        a.mov(RCX, RSI)    # CL = shift amount
        a.sar(RAX, CL)
        a.ret()

    for x, n in [(-16, 2), (16, 2), (-1, 1), (255, 3)]:
        result = run(build, ctypes.c_int64, ctypes.c_int64, ctypes.c_int64,
                     args=(x, n))
        assert result == (x >> n)


def test_run_inc_dec():
    # return rdi + 1 - 1 - 1 == rdi - 1
    def build(a):
        a.mov(RAX, RDI)
        a.inc(RAX)
        a.dec(RAX)
        a.dec(RAX)
        a.ret()

    for x in (0, 41, -5):
        assert run(build, ctypes.c_int64, ctypes.c_int64, args=(x,)) == x - 1


def test_run_setcc_returns_bool():
    # return (rdi == rsi) ? 1 : 0, via cmp + sete
    def build(a):
        a.xor(EAX, EAX)     # clear the upper bits; sete only writes AL
        a.cmp(RDI, RSI)
        a.sete(AL)
        a.ret()

    for x, y in [(3, 3), (3, 4), (0, 0), (-1, -1), (-1, 1)]:
        result = run(build, ctypes.c_int64, ctypes.c_int64, ctypes.c_int64,
                     args=(x, y))
        assert result == (1 if x == y else 0)


def test_run_cmov_selects_max():
    # return max(rdi, rsi) with cmp + cmovl (no branch)
    def build(a):
        a.mov(RAX, RDI)
        a.cmp(RAX, RSI)
        a.cmovl(RAX, RSI)   # if rax < rsi, take rsi
        a.ret()

    for x, y in [(3, 7), (7, 3), (5, 5), (-2, -9)]:
        result = run(build, ctypes.c_int64, ctypes.c_int64, ctypes.c_int64,
                     args=(x, y))
        assert result == max(x, y)


def test_run_movzx_loads_byte():
    # zero-extend the byte at [rdi] into a 64-bit result
    def build(a):
        a.movzx(RAX, byte(RDI + 0))
        a.ret()

    buf = (ctypes.c_uint8 * 1)(0xFE)
    result = run(build, ctypes.c_uint64, ctypes.c_void_p,
                 args=(ctypes.cast(buf, ctypes.c_void_p),))
    assert result == 0xFE


def test_run_movsx_sign_extends_byte():
    # sign-extend the byte at [rdi]: 0xFE -> -2
    def build(a):
        a.movsx(RAX, byte(RDI + 0))
        a.ret()

    buf = (ctypes.c_uint8 * 1)(0xFE)
    result = run(build, ctypes.c_int64, ctypes.c_void_p,
                 args=(ctypes.cast(buf, ctypes.c_void_p),))
    assert result == -2


# --- Read-only data section + RIP-relative addressing. ---

def test_rip_lea_encoding():
    # lea rax, [rip+disp32] = 48 8d 05 <disp32>. The data is appended right
    # after the 7-byte instruction, so disp32 = data_off - end = 7 - 7 = 0.
    def build(a):
        L = a.data(b"\x88\x77\x66\x55\x44\x33\x22\x11")
        a.lea(RAX, rip(L))

    assert encode(build).hex() == "488d0500000000" "8877665544332211"


def test_rip_mov_encoding():
    # mov rax, [rip+disp32] = 48 8b 05 <disp32>, disp32 = 0 (data right after).
    def build(a):
        L = a.data((0x1122334455667788).to_bytes(8, "little"))
        a.mov(RAX, rip(L))

    assert encode(build).hex() == "488b0500000000" "8877665544332211"


def test_rip_disp_points_at_data():
    # With preceding code the disp32 must equal data_off - end_of_instruction.
    def build(a):
        L = a.data(b"ABCD")
        a.mov(RAX, 0)          # 10 bytes (movabs)
        a.mov(RAX, rip(L))     # 7 bytes: 48 8b 05 <disp32> at offsets 10..16

    code = encode(build)
    # data begins at offset 17 (10 + 7); disp32 field ends at offset 17.
    assert code[10:13].hex() == "488b05"
    disp = int.from_bytes(code[13:17], "little", signed=True)
    assert disp == 0
    assert code[17:].decode() == "ABCD"


def test_run_returns_constant_from_data():
    # A function that loads a 64-bit constant embedded in the data section.
    def build(a):
        L = a.data((12345).to_bytes(8, "little"))
        a.mov(RAX, rip(L))
        a.ret()

    assert run(build, ctypes.c_int64) == 12345


def test_run_rip_lookup_table():
    # lea the table's address RIP-relatively, then index it: proves RIP-relative
    # addressing composes with an indexed [base + index*8] load.
    table = [10, 20, 30, 40]

    def build(a):
        L = a.data(b"".join(v.to_bytes(8, "little") for v in table))
        a.lea(RAX, rip(L))
        a.mov(RAX, RAX + RDI * 8)
        a.ret()

    for i in range(4):
        assert run(build, ctypes.c_int64, ctypes.c_int64, args=(i,)) == table[i]


def test_run_rip_data_alignment():
    # Alignment pads the data to the requested boundary; the load still resolves.
    def build(a):
        L = a.data((777).to_bytes(8, "little"), align=16)
        a.mov(RAX, rip(L))
        a.ret()

    assert run(build, ctypes.c_int64) == 777


# --- Scalar-double (SSE2) functional tests. ---

def test_run_addsd():
    # SysV passes the first two doubles in XMM0/XMM1 and returns in XMM0.
    def build(a):
        a.addsd(XMM0, XMM1)
        a.ret()

    assert run(build, ctypes.c_double, ctypes.c_double, ctypes.c_double,
               args=(1.5, 2.25)) == 3.75


def test_run_subsd():
    def build(a):
        a.subsd(XMM0, XMM1)
        a.ret()

    assert run(build, ctypes.c_double, ctypes.c_double, ctypes.c_double,
               args=(5.0, 1.25)) == 3.75


def test_run_mulsd():
    def build(a):
        a.mulsd(XMM0, XMM1)
        a.ret()

    assert run(build, ctypes.c_double, ctypes.c_double, ctypes.c_double,
               args=(1.5, 3.0)) == 4.5


def test_run_divsd():
    def build(a):
        a.divsd(XMM0, XMM1)
        a.ret()

    assert run(build, ctypes.c_double, ctypes.c_double, ctypes.c_double,
               args=(9.0, 4.0)) == 2.25


def test_run_int_to_double():
    def build(a):
        a.cvtsi2sd(XMM0, RDI)  # convert the int arg (RDI) into the XMM0 return
        a.ret()

    assert run(build, ctypes.c_double, ctypes.c_int64, args=(7,)) == 7.0


def test_run_double_to_int():
    def build(a):
        a.cvttsd2si(RAX, XMM0)  # truncate the double arg (XMM0) into RAX
        a.ret()

    assert run(build, ctypes.c_int64, ctypes.c_double, args=(3.9,)) == 3


def test_run_scalar_double_across_registers():
    # (a * b) + a, exercising mul/add and movsd across several XMM registers.
    def build(a):
        a.movsd(XMM2, XMM0)   # keep a
        a.mulsd(XMM0, XMM1)   # a*b
        a.addsd(XMM0, XMM2)   # + a
        a.ret()

    result = run(build, ctypes.c_double, ctypes.c_double, ctypes.c_double,
                 args=(2.5, 4.0))
    assert result == (2.5 * 4.0) + 2.5


def test_entries_are_aligned():
    rt = Runtime(align=16)
    asm = Assembler()
    _const_fn(1)(asm)  # 10 bytes (movabs) + 1 (ret) = 11
    first = rt.add(asm.finalize())

    asm = Assembler()
    _const_fn(2)(asm)
    second = rt.add(asm.finalize())

    assert first % 16 == 0
    assert second % 16 == 0
    assert second - first == 16  # 11 bytes rounded up to the alignment
