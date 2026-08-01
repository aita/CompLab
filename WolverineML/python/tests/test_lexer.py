from __future__ import annotations

import pytest

from wolv.diag import LexError
from wolv.lexer import Tok, lex


def kinds(source: str) -> list[Tok]:
    return [t.kind for t in lex(source)]


def test_keywords_are_not_identifiers() -> None:
    assert kinds("let val") == [Tok.LET, Tok.VAL, Tok.EOF]
    assert kinds("letter") == [Tok.IDENT, Tok.EOF]


def test_longest_punctuation_wins() -> None:
    assert kinds(":= : <= < <> >=") == [
        Tok.ASSIGN,
        Tok.COLON,
        Tok.LE,
        Tok.LT,
        Tok.NE,
        Tok.GE,
        Tok.EOF,
    ]


def test_comments_nest() -> None:
    assert kinds("(* a (* b *) c *) 1") == [Tok.INT, Tok.EOF]


def test_unterminated_comment() -> None:
    with pytest.raises(LexError, match="unterminated comment"):
        lex("(* forever")


def test_string_escapes() -> None:
    tokens = lex(r'"a\nb\t\"\\\065"')
    assert tokens[0].text == 'a\nb\t"\\A'


def test_a_string_is_bytes() -> None:
    """Source text contributes its UTF-8; `\\ddd` names one byte of it."""
    assert lex('"日"')[0].text == "日".encode().decode("latin-1")
    assert lex(r'"\230\151\165"')[0].text == lex('"日"')[0].text
    assert len(lex('"日本語"')[0].text) == 9


def test_a_numeric_escape_is_three_digits() -> None:
    with pytest.raises(LexError, match="three digits"):
        lex(r'"\65"')


def test_string_may_not_span_lines() -> None:
    with pytest.raises(LexError, match="may not span lines"):
        lex('"one\ntwo"')


def test_spans_count_from_one() -> None:
    tokens = lex("val\n  x")
    assert (tokens[0].span.line, tokens[0].span.col) == (1, 1)
    assert (tokens[1].span.line, tokens[1].span.col) == (2, 3)


def test_a_number_may_not_run_into_a_name() -> None:
    with pytest.raises(LexError, match="is not a number"):
        lex("12ab")


def test_stray_character() -> None:
    with pytest.raises(LexError, match="stray character"):
        lex("a ? b")
