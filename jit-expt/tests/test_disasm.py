"""Tests for the jit.disasm disassembler. Each case assembles known bytes with
the real Assembler, then checks the decoded text mentions the right mnemonic
and operands (without over-specifying spacing/formatting)."""

from jit import (
    Assembler, Label, Symbol,
    RAX, RBX, RCX, RDI, RSI, EAX, R8, XMM0, XMM1, qword,
)
from jit.operands import rip
from jit.disasm import disassemble, format_disassembly


def asm(build):
    a = Assembler()
    build(a)
    return a.finalize().code


def text(build):
    return format_disassembly(asm(build)).lower()


def test_mov_reg_reg():
    t = text(lambda a: a.mov(RAX, RBX))
    assert "mov" in t and "rax" in t and "rbx" in t


def test_mov_reg_imm_movabs():
    t = text(lambda a: a.mov(RAX, 0x1122334455667788))
    assert "movabs" in t and "rax" in t and "1122334455667788" in t


def test_mov_reg_imm32():
    t = text(lambda a: a.mov(EAX, 0x1234))
    assert "mov" in t and "eax" in t and "1234" in t


def test_add_reg_reg():
    t = text(lambda a: a.add(RAX, RBX))
    assert "add" in t and "rax" in t and "rbx" in t


def test_sub_reg_imm():
    t = text(lambda a: a.sub(RAX, 5))
    assert "sub" in t and "rax" in t and "0x5" in t


def test_mem_load():
    t = text(lambda a: a.mov(RAX, RDI + 8))
    assert "mov" in t and "rax" in t and "rdi" in t and "8" in t and "[" in t


def test_mem_store():
    t = text(lambda a: a.mov(RDI + 16, RAX))
    assert "mov" in t and "rdi" in t and "rax" in t and "[" in t


def test_mem_sib():
    t = text(lambda a: a.mov(RAX, RDI + RSI * 4 + 8))
    assert "rdi" in t and "rsi" in t and "*4" in t


def test_lea_rip():
    def build(a):
        lbl = a.data(b"\x01\x02\x03\x04")
        a.lea(RAX, rip(lbl))
    t = text(build)
    assert "lea" in t and "rax" in t and "rip" in t


def test_jmp_rel32():
    def build(a):
        lbl = Label()
        a.jmp(lbl)
        a.nop()
        a.bind(lbl)
        a.ret()
    t = text(build)
    assert "jmp" in t


def test_call_rel32_symbol():
    t = text(lambda a: a.call(Symbol("f")))
    assert "call" in t


def test_call_indirect():
    t = text(lambda a: a.call(RAX))
    assert "call" in t and "rax" in t


def test_jcc():
    def build(a):
        lbl = a.bind(Label())
        a.je(lbl)
    t = text(build)
    assert "je" in t


def test_push_pop():
    assert "push" in text(lambda a: a.push(RBX))
    assert "rbx" in text(lambda a: a.push(RBX))
    assert "pop" in text(lambda a: a.pop(R8))
    assert "r8" in text(lambda a: a.pop(R8))


def test_ret_leave_nop_int3():
    assert text(lambda a: a.ret()).strip().endswith("ret")
    assert "leave" in text(lambda a: a.leave())
    assert "nop" in text(lambda a: a.nop())
    assert "int3" in text(lambda a: a.int3())


def test_shift_imm():
    t = text(lambda a: a.shl(RAX, 3))
    assert "shl" in t and "rax" in t and "0x3" in t


def test_inc_dec():
    assert "inc" in text(lambda a: a.inc(RAX))
    assert "dec" in text(lambda a: a.dec(RCX))


def test_movzx():
    from jit import AL
    t = text(lambda a: a.movzx(RAX, AL))
    assert "movzx" in t and "rax" in t and "al" in t


def test_neg_not():
    assert "neg" in text(lambda a: a.neg(RAX))
    assert "not" in text(lambda a: a.not_(RAX))


def test_imul_reg_reg():
    t = text(lambda a: a.imul(RAX, RBX))
    assert "imul" in t and "rax" in t and "rbx" in t


def test_test_reg_reg():
    t = text(lambda a: a.test(RAX, RAX))
    assert "test" in t and "rax" in t


def test_sse_movsd():
    t = text(lambda a: a.movsd(XMM0, XMM1))
    assert "movsd" in t and "xmm0" in t and "xmm1" in t


def test_sse_addsd():
    t = text(lambda a: a.addsd(XMM0, XMM1))
    assert "addsd" in t and "xmm0" in t and "xmm1" in t


def test_cvtsi2sd():
    t = text(lambda a: a.cvtsi2sd(XMM0, RAX))
    assert "cvtsi2sd" in t and "xmm0" in t and "rax" in t


def test_setcc():
    from jit import AL
    t = text(lambda a: a.sete(AL))
    assert "sete" in t and "al" in t


def test_cmovcc():
    t = text(lambda a: a.cmove(RAX, RBX))
    assert "cmove" in t and "rax" in t and "rbx" in t


def test_disassemble_returns_tuples():
    rows = disassemble(asm(lambda a: a.mov(RAX, RBX)))
    assert len(rows) == 1
    off, raw, txt = rows[0]
    assert off == 0
    assert isinstance(raw, bytes) and len(raw) == 3
    assert "mov" in txt


def test_graceful_fallback_bogus_byte():
    # 0x06 (legacy PUSH ES) is not emitted by this assembler; decode as db.
    rows = disassemble(b"\x06")
    assert len(rows) == 1
    assert rows[0][2] == "db 0x06"


def test_fallback_advances_and_continues():
    # A bogus byte followed by a real instruction: the decoder recovers.
    code = b"\x06" + asm(lambda a: a.ret())
    rows = disassemble(code)
    assert rows[0][2] == "db 0x06"
    assert rows[1][2] == "ret"


def test_origin_offsets():
    t = format_disassembly(asm(lambda a: a.ret()), origin=0x400000)
    assert "400000:" in t


def test_format_shows_hex_bytes():
    t = format_disassembly(asm(lambda a: a.mov(RAX, RBX)))
    # REX.W MOV rax, rbx = 48 89 d8
    assert "48 89 d8" in t
