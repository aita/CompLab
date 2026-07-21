import ctypes
import struct

import pytest

from jit import (
    AL,
    CL,
    EAX,
    R8,
    R9,
    RAX,
    RCX,
    RDI,
    RDX,
    RSI,
    XMM0,
    XMM1,
    Assembler,
    Runtime,
    Symbol,
    aot,
    byte,
    dword,
    gas_source,
    qword,
    rip,
)
from jit.operands import ARG_REGS

ARG0 = ARG_REGS[0]  # the first integer argument register for this platform


def source(build, name="f") -> str:
    """Render `build(asm)` as gas source text."""
    asm = Assembler()
    build(asm)
    return gas_source({name: asm})


def body(text: str) -> list[str]:
    """The instruction/label lines of a rendered function, stripped."""
    lines = [ln.strip() for ln in text.splitlines()]
    start = lines.index("f:") + 1
    end = next(i for i, ln in enumerate(lines) if ln.startswith(".size"))
    return lines[start:end]


# --- Rendering ---------------------------------------------------------------


def test_operand_order_is_intel_syntax():
    text = source(lambda a: (a.mov(RAX, RDI), a.add(RAX, 3), a.ret()))
    assert "\t.intel_syntax noprefix" in text.splitlines()
    assert body(text) == ["mov rax, rdi", "add rax, 3", "ret"]


def test_memory_operands_carry_a_ptr_size():
    text = source(lambda a: (
        a.mov(RAX, RDI + 8),                 # size from the register operand
        a.mov(qword(RDI + 16), 5),           # size from qword()
        a.add(dword(RDI + RSI * 4 - 4), 7),
        a.movzx(RAX, byte(RDI + 0)),
        a.lea(RAX, RDI + RSI * 2 + 1),       # lea takes an address, not a size
    ))
    assert body(text) == [
        "mov rax, qword ptr [rdi + 8]",
        "mov qword ptr [rdi + 16], 5",
        "add dword ptr [rdi + rsi * 4 - 4], 7",
        "movzx rax, byte ptr [rdi]",
        "lea rax, [rdi + rsi * 2 + 1]",
    ]


def test_sse_memory_width_comes_from_the_mnemonic():
    # An XMM operand does not say how much of it is accessed, so the width has
    # to come from the instruction itself.
    text = source(lambda a: (
        a.movsd(XMM0, RDI + 0),
        a.addss(XMM1, RSI + 4),
        a.cvtsi2sd(XMM0, RDI + 0),   # integer source: m64
        a.cvttss2si(RAX, RSI + 0),   # float source: m32
    ))
    assert body(text) == [
        "movsd xmm0, qword ptr [rdi]",
        "addss xmm1, dword ptr [rsi + 4]",
        "cvtsi2sd xmm0, qword ptr [rdi]",
        "cvttss2si rax, dword ptr [rsi]",
    ]


def test_mnemonics_that_differ_from_the_python_api():
    text = source(lambda a: (
        a.and_(RAX, 1),          # the keyword-dodging underscore is dropped
        a.imul(RAX, 10),         # encoded as the three-operand form
        a.imul(RAX, RCX),        # ... but the register form has two
        a.movsx(RAX, EAX),       # 63 /r is spelled movsxd
        a.movsx(RAX, AL),
        a.shl(RAX, CL),
    ))
    assert body(text) == [
        "and rax, 1",
        "imul rax, rax, 10",
        "imul rax, rcx",
        "movsxd rax, eax",
        "movsx rax, al",
        "shl rax, cl",
    ]


def test_symbol_address_is_taken_rip_relatively():
    # The JIT patches an absolute imm64 at map time; a linker cannot do that in
    # position-independent code, so the AOT spelling is a RIP-relative lea.
    text = source(lambda a: (a.mov(RAX, Symbol("puts")), a.call(Symbol("puts"))))
    assert body(text) == ["lea rax, [rip + puts]", "call puts"]


def test_labels_are_mangled_per_function():
    a, b = Assembler(), Assembler()
    for asm in (a, b):
        loop = asm.label("loop")
        asm.bind(loop)
        asm.jmp(loop)
    text = gas_source({"one": a, "two": b})
    assert ".Lone.loop:" in text and "jmp .Lone.loop" in text
    assert ".Ltwo.loop:" in text and "jmp .Ltwo.loop" in text
    # Both functions are callable by their public names.
    assert "\t.globl one" in text and "\t.globl two" in text


def test_data_and_jump_tables_land_in_rodata():
    a = Assembler()
    blob = a.data(b"\x01\x02", align=8)
    h0, h1 = a.label("h0"), a.label("h1")
    table = a.jump_table([h0, h1])
    a.mov(RAX, rip(blob))
    a.lea(RCX, rip(table))
    a.bind(h0)
    a.bind(h1)
    a.ret()
    text = gas_source({"f": a})
    rodata = text.split("\t.section .rodata\n")[1]
    assert "mov rax, qword ptr [rip + .Lf.data0]" in text
    assert "\t.balign 8\n.Lf.data0:\n\t.byte 0x01, 0x02" in rodata
    # Entries stay self-relative, exactly as the JIT builds them.
    assert "\t.long .Lf.h0 - .Lf.jt0" in rodata


def test_stack_is_marked_non_executable():
    assert source(lambda a: a.ret()).rstrip().endswith(
        '.section .note.GNU-stack, "", @progbits')


# --- Ahead-of-time compilation -----------------------------------------------

needs_toolchain = pytest.mark.skipif(not aot.have_toolchain(),
                                     reason="needs `as` and `cc`")


def sum_to_n(a):
    """long f(long n): 1 + 2 + ... + n, via a loop with a backward branch."""
    loop, done = a.label("loop"), a.label("done")
    a.mov(R8, ARG0)
    a.xor(RAX, RAX)
    a.mov(R9, 1)
    a.bind(loop)
    a.cmp(R9, R8)
    a.jg(done)
    a.add(RAX, R9)
    a.inc(R9)
    a.jmp(loop)
    a.bind(done)
    a.ret()


def dispatch(a):
    """long f(long i): i-th entry of a jump table, plus a constant read
    RIP-relatively out of the data section -- the two things that live after
    the code in the JIT and in .rodata ahead of time."""
    blob = a.data(struct.pack("<q", 1000), align=8)
    h0, h1, h2 = a.label("h0"), a.label("h1"), a.label("h2")
    table = a.jump_table([h0, h1, h2])
    a.mov(RCX, ARG0)
    a.lea(RAX, rip(table))
    a.movsx(RDX, dword(RAX + RCX * 4))
    a.add(RAX, RDX)
    a.jmp(RAX)
    a.bind(h0)
    a.mov(RAX, rip(blob))
    a.ret()
    a.bind(h1)
    a.mov(RAX, 11)
    a.ret()
    a.bind(h2)
    a.mov(RAX, 22)
    a.ret()


def scaled(a):
    """double f(double x): x * 2 + 1, using the scalar-SSE path."""
    two = a.data(struct.pack("<d", 2.0), align=8)
    one = a.data(struct.pack("<d", 1.0), align=8)
    a.mulsd(XMM0, rip(two))
    a.addsd(XMM0, rip(one))
    a.ret()


PROGRAMS = {"sum_to_n": sum_to_n, "dispatch": dispatch, "scaled": scaled}

SIGNATURES = {
    "sum_to_n": (ctypes.c_int64, ctypes.c_int64),
    "dispatch": (ctypes.c_int64, ctypes.c_int64),
    "scaled": (ctypes.c_double, ctypes.c_double),
}

CASES = [("sum_to_n", 10), ("sum_to_n", 100), ("dispatch", 0), ("dispatch", 1),
         ("dispatch", 2), ("scaled", 2.5)]


@pytest.fixture(scope="module")
def aot_module():
    if not aot.have_toolchain():
        pytest.skip("needs `as` and `cc`")
    built = {}
    for name, build in PROGRAMS.items():
        built[name] = asm = Assembler()
        build(asm)
    return aot.load(built)


@pytest.fixture(scope="module")
def runtime():
    # Module-scoped: the Runtime owns the executable pages, so it has to
    # outlive every function called out of them.
    return Runtime()


@needs_toolchain
@pytest.mark.parametrize("name,arg", CASES)
def test_aot_agrees_with_jit(aot_module, runtime, name, arg):
    # The same builder through both backends: encoded into memory and called,
    # and assembled by `as`, linked into a shared library and dlopen'd.
    asm = Assembler()
    PROGRAMS[name](asm)
    restype, argtype = SIGNATURES[name]
    jitted = ctypes.CFUNCTYPE(restype, argtype)(runtime.add(asm.finalize()))
    assert aot_module.func(name, restype, argtype)(arg) == jitted(arg)


@needs_toolchain
def test_build_executable_runs(tmp_path):
    import subprocess

    a = Assembler()
    a.mov(RAX, 7)  # main() { return 7; }
    a.ret()
    exe = aot.build_executable({"main": a}, tmp_path / "seven")
    assert subprocess.run([str(exe)]).returncode == 7


@needs_toolchain
def test_object_links_against_c(tmp_path):
    # An assembled function is an ordinary .o: a C file can call it by name.
    a = Assembler()
    a.mov(RAX, ARG0)
    a.imul(RAX, 3)
    a.ret()
    main_c = tmp_path / "main.c"
    main_c.write_text("long triple(long);\n"
                      "int main(void) { return triple(5) == 15 ? 0 : 1; }\n")
    import subprocess

    exe = aot.build_executable({"triple": a}, tmp_path / "prog",
                               sources=[main_c])
    assert subprocess.run([str(exe)]).returncode == 0


@needs_toolchain
def test_toolchain_error_reports_the_assembler_message(tmp_path):
    with pytest.raises(aot.ToolchainError, match="failed"):
        aot.assemble("\tthis is not assembly\n", tmp_path / "bad.o")
