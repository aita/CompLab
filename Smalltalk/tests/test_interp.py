from __future__ import annotations

import pytest

from st.objects import STError
from st.system import Smalltalk


@pytest.fixture()
def st() -> Smalltalk:
    return Smalltalk()


def ev(st: Smalltalk, src: str) -> str:
    return st.eval_to_string(src)


# --- arithmetic & precedence ---


def test_arithmetic_precedence(st):
    assert ev(st, "3 + 4 * 2") == "14"  # strictly left-to-right binary
    assert ev(st, "3 + (4 * 2)") == "11"


def test_unary_binds_tightest(st):
    assert ev(st, "3 factorial + 1") == "7"


def test_keyword_lowest(st):
    assert ev(st, "1 max: 2 + 5") == "7"


def test_division(st):
    assert ev(st, "10 / 2") == "5"
    assert ev(st, "10 / 4") == "2.5"


def test_float(st):
    assert ev(st, "3.0 + 0.5") == "3.5"


# --- variables & assignment ---


def test_temps_and_assignment(st):
    assert ev(st, "| x y | x := 3. y := 4. x * x + (y * y)") == "25"


def test_workspace_var_persists(st):
    st.eval("counter := 10")
    assert ev(st, "counter + 5") == "15"


# --- blocks & control flow (inlined) ---


def test_if_true_false(st):
    assert ev(st, "3 > 2 ifTrue: ['yes'] ifFalse: ['no']") == "'yes'"
    assert ev(st, "1 > 2 ifTrue: ['yes'] ifFalse: ['no']") == "'no'"


def test_and_or(st):
    assert ev(st, "(3 > 2) and: [5 > 4]") == "true"
    assert ev(st, "(3 > 2) or: [1 / 0]") == "true"  # short-circuit, no ZeroDivide


def test_while_loop(st):
    src = "| i s | i := 1. s := 0. [i <= 5] whileTrue: [s := s + i. i := i + 1]. s"
    assert ev(st, src) == "15"


def test_to_do(st):
    assert ev(st, "| s | s := 0. 1 to: 10 do: [:each | s := s + each]. s") == "55"


def test_timesRepeat(st):
    assert ev(st, "| n | n := 0. 5 timesRepeat: [n := n + 1]. n") == "5"


def test_block_value(st):
    assert ev(st, "[:a :b | a + b] value: 3 value: 4") == "7"


def test_block_closure_captures(st):
    src = "| make add | make := [:n | [:x | x + n]]. add := make value: 10. add value: 5"
    assert ev(st, src) == "15"


# --- collections ---


def test_literal_array(st):
    assert ev(st, "#(1 2 3) size") == "3"
    assert ev(st, "#(10 20 30) at: 2") == "20"


def test_collect_select_inject(st):
    assert ev(st, "#(1 2 3 4) collect: [:x | x * x]") == "(1 4 9 16 )"
    assert ev(st, "#(1 2 3 4 5) select: [:x | x odd]") == "(1 3 5 )"
    assert ev(st, "#(1 2 3 4 5) inject: 0 into: [:a :b | a + b]") == "15"


def test_dynamic_array(st):
    assert ev(st, "{1+1. 2*3. 10-1}") == "(2 6 9 )"


def test_ordered_collection(st):
    src = "| c | c := OrderedCollection new. c add: 1; add: 2; add: 3. c size"
    assert ev(st, src) == "3"
    src2 = "| c | c := OrderedCollection new. c add: 5; addFirst: 1. c first"
    assert ev(st, src2) == "1"


def test_dictionary(st):
    src = "| d | d := Dictionary new. d at: #a put: 1. d at: #b put: 2. d at: #a"
    assert ev(st, src) == "1"


def test_dictionary_print(st):
    src = "| d | d := Dictionary new. d at: #a put: 1. d"
    assert ev(st, src) == "a Dictionary (#a->1 )"


def test_string_ops(st):
    assert ev(st, "'hello' , ' ' , 'world'") == "'hello world'"
    assert ev(st, "'hello' asUppercase") == "'HELLO'"
    assert ev(st, "'hello' size") == "5"


def test_association(st):
    assert ev(st, "#a -> 42") == "#a->42"


def test_point(st):
    assert ev(st, "(1@2) + (3@4)") == "4@6"


# --- string printing / cascades ---


def test_cascade_transcript(st, capsys):
    st.eval("Transcript show: 'a'; show: 'b'; show: 'c'")
    assert capsys.readouterr().out == "abc"


def test_printNl_returns_receiver(st, capsys):
    st.eval("42 printNl")
    assert capsys.readouterr().out == "42\n"


# --- user classes & methods ---


def test_define_class_and_method(st):
    st.define_class("Counter", "Object", ["count"])
    st.define_method("Counter", "initialize count := 0")
    st.define_method("Counter", "increment count := count + 1")
    st.define_method("Counter", "count ^count")
    src = "| c | c := Counter new. c increment; increment; increment. c count"
    assert ev(st, src) == "3"


def test_super_send(st):
    st.define_class("Animal", "Object", [])
    st.define_method("Animal", "speak ^'...'")
    st.define_class("Dog", "Animal", [])
    st.define_method("Dog", "speak ^'woof and ' , super speak")
    assert ev(st, "Dog new speak") == "'woof and ...'"


def test_non_local_return(st):
    st.define_class("Finder", "Object", [])
    st.define_method(
        "Finder",
        "firstEven: aColl "
        "aColl do: [:x | x even ifTrue: [^x]]. ^nil",
    )
    assert ev(st, "Finder new firstEven: #(1 3 5 6 7)") == "6"
    assert ev(st, "Finder new firstEven: #(1 3 5)") == "nil"


def test_does_not_understand(st):
    with pytest.raises(STError):
        st.eval("3 flootberg")


# --- reified contexts (thisContext) ---


def test_this_context_is_a_method_context(st):
    assert ev(st, "thisContext isBlockContext") == "false"
    assert ev(st, "thisContext selector") == "#DoIt"
    assert ev(st, "thisContext class name") == "'MethodContext'"


def test_this_context_receiver(st):
    st.define_class("Widget", "Object", [])
    st.define_method("Widget", "whoAmI ^thisContext receiver")
    assert ev(st, "Widget new whoAmI class name") == "'Widget'"


def test_block_context(st):
    assert ev(st, "[thisContext isBlockContext] value") == "true"


def test_sender_chain(st):
    st.define_class("Probe", "Object", [])
    # the caller of #callerSelector is the DoIt, so sender selector is #DoIt
    st.define_method("Probe", "callerSelector ^thisContext sender selector")
    assert ev(st, "Probe new callerSelector") == "#DoIt"


def test_top_level_sender_is_nil(st):
    assert ev(st, "thisContext sender") == "nil"


def test_polymorphism(st):
    st.define_class("Shape", "Object", [])
    st.define_method("Shape", "area ^0")
    st.define_class("Square", "Shape", ["side"])
    st.define_method("Square", "side: n side := n")
    st.define_method("Square", "area ^side * side")
    src = (
        "| shapes | shapes := OrderedCollection new. "
        "shapes add: (Square new side: 3); add: (Square new side: 4). "
        "shapes inject: 0 into: [:sum :s | sum + s area]"
    )
    assert ev(st, src) == "25"
