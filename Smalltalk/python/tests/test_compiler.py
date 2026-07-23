from __future__ import annotations

from st.bytecode import Op
from st.compiler import compile_doit
from st.parser import parse_sequence


def ops(source: str) -> list[Op]:
    cm = compile_doit(parse_sequence(source))
    return [ins.op for ins in cm.code]


def test_ifTrue_is_inlined_to_jumps():
    o = ops("1 > 2 ifTrue: [10] ifFalse: [20]")
    assert Op.JUMP_FALSE in o
    assert Op.JUMP in o
    assert Op.SEND not in o[o.index(Op.JUMP_FALSE):]  # branches carry no send


def test_and_short_circuits_with_jump():
    o = ops("true and: [false]")
    assert Op.JUMP_FALSE in o


def test_whileTrue_is_a_backward_jump():
    cm = compile_doit(parse_sequence("[1 < 2] whileTrue: [1]"))
    jumps = [ins for ins in cm.code if ins.op == Op.JUMP]
    # the loop's back-edge targets an earlier instruction
    assert any(ins.arg == 0 for ins in jumps)


def test_non_literal_block_falls_back_to_send():
    # receiver is a block held in a variable, so ifTrue: cannot be inlined
    o = ops("| b | b := [10]. true ifTrue: b")
    assert Op.SEND in o


def test_block_literal_becomes_push_block():
    o = ops("[:x | x + 1]")
    assert Op.PUSH_BLOCK in o


def test_temps_compile_to_local_slots():
    # `| a b | a := 1. b := 2. a + b`  → all locals addressed by slot
    o = ops("| a b | a := 1. b := 2. a + b")
    assert Op.STORE_LOCAL in o
    assert Op.PUSH_LOCAL in o
    assert Op.PUSH_VAR not in o and Op.STORE_VAR not in o


def test_globals_stay_name_based():
    # `Transcript` is not a local → name-based PUSH_VAR
    o = ops("Transcript")
    assert Op.PUSH_VAR in o
    assert Op.PUSH_LOCAL not in o


def test_closure_uses_push_outer():
    from st.bytecode import CompiledBlock

    cm = compile_doit(parse_sequence("| n | n := 1. [:x | x + n]"))
    inner = next(lit for lit in cm.literals if isinstance(lit, CompiledBlock))
    inner_ops = [ins.op for ins in inner.code]
    assert Op.PUSH_LOCAL in inner_ops  # x (this block's arg)
    assert Op.PUSH_OUTER in inner_ops  # n (enclosing doit's temp)
