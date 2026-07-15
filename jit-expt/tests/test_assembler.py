import ctypes
import mmap

import pytest

from jit import (
    AL,
    AX,
    EAX,
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
    Assembler,
    Label,
    Mem,
    Reloc,
    Runtime,
    Symbol,
    byte,
    dword,
    qword,
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


def test_symbol_movabs_reloc():
    a = Assembler()
    a.mov(RAX, Symbol("foo"))
    obj = a.finalize()
    assert obj.code.hex() == "48b80000000000000000"  # movabs rax, 0 (placeholder)
    assert obj.relocs == (Reloc(offset=2, symbol="foo"),)


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
    sig = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)
    callback = sig(lambda x: x + 100)
    cb_addr = ctypes.cast(callback, ctypes.c_void_p).value

    a = Assembler()
    a.push(RBP)
    a.mov(RBP, RSP)
    a.mov(RAX, Symbol("cb"))    # address resolved at load time
    a.call(RAX)
    a.leave()
    a.ret()

    rt = Runtime()
    addr = rt.add(a.finalize(), symbols={"cb": cb_addr})
    fn = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(addr)
    assert fn(5) == 105
    assert callback  # keep alive


def test_run_jit_calls_jit_by_symbol():
    rt = Runtime()

    # square(x) = x * x, added first so its address is known
    callee = Assembler()
    callee.mov(RAX, RDI)
    callee.imul(RAX, RDI)
    callee.ret()
    square_addr = rt.add(callee.finalize())

    caller = Assembler()
    caller.push(RBP)
    caller.mov(RBP, RSP)
    caller.mov(RAX, Symbol("square"))
    caller.call(RAX)
    caller.leave()
    caller.ret()
    caller_addr = rt.add(caller.finalize(), symbols={"square": square_addr})

    fn = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(caller_addr)
    assert fn(9) == 81


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
