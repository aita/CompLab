from __future__ import annotations

from st.lexer import Lexer
from st.objects import STSymbol


def kinds(src: str) -> list[str]:
    return [t.kind for t in Lexer(src).tokens()]


def test_basic_kinds():
    assert kinds("3 + 4") == ["INTEGER", "BINARY", "INTEGER", "EOF"]


def test_keyword_and_assign():
    ks = kinds("x := arr at: 1 put: 2")
    assert ks == [
        "IDENT",
        "ASSIGN",
        "IDENT",
        "KEYWORD",
        "INTEGER",
        "KEYWORD",
        "INTEGER",
        "EOF",
    ]


def test_numbers():
    toks = Lexer("42 3.14 16rFF 1e3").tokens()
    assert toks[0].kind == "INTEGER" and toks[0].value == 42
    assert toks[1].kind == "FLOAT" and toks[1].value == 3.14
    assert toks[2].kind == "INTEGER" and toks[2].value == 255
    assert toks[3].kind == "FLOAT" and toks[3].value == 1000.0


def test_dot_after_int_is_statement_sep():
    toks = Lexer("1. 2").tokens()
    assert [t.kind for t in toks] == ["INTEGER", "DOT", "INTEGER", "EOF"]


def test_string_with_escaped_quote():
    toks = Lexer("'it''s'").tokens()
    assert toks[0].kind == "STRING" and toks[0].value == "it's"


def test_symbols_and_chars():
    toks = Lexer("#foo #at:put: $a").tokens()
    assert toks[0].kind == "SYMBOL" and toks[0].value == "foo"
    assert toks[1].kind == "SYMBOL" and toks[1].value == "at:put:"
    assert toks[2].kind == "CHAR" and toks[2].value == "a"


def test_comment_skipped():
    toks = Lexer('1 "a comment" 2').tokens()
    assert [t.kind for t in toks] == ["INTEGER", "INTEGER", "EOF"]


def test_symbol_interning():
    assert STSymbol("abc") is STSymbol("abc")
