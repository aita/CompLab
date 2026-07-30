"""Tokens, and the hand-written scanner that produces them."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Final

from wolv.diag import LexError, Span


class Tok(Enum):
    """A token kind.  The value is what an error message calls it."""

    INT = "an integer"
    STRING = "a string"
    IDENT = "an identifier"
    EOF = "end of input"

    AND = "and"
    ANDALSO = "andalso"
    BREAK = "break"
    DO = "do"
    ELSE = "else"
    END = "end"
    FALSE = "false"
    FOR = "for"
    FUN = "fun"
    IF = "if"
    IN = "in"
    LET = "let"
    MOD = "mod"
    NIL = "nil"
    ORELSE = "orelse"
    THEN = "then"
    TO = "to"
    TRUE = "true"
    TYPE = "type"
    VAL = "val"
    VAR = "var"
    WHILE = "while"

    LPAREN = "("
    RPAREN = ")"
    LBRACK = "["
    RBRACK = "]"
    LBRACE = "{"
    RBRACE = "}"
    COMMA = ","
    COLON = ":"
    SEMI = ";"
    DOT = "."
    ASSIGN = ":="
    EQ = "="
    NE = "<>"
    LE = "<="
    LT = "<"
    GE = ">="
    GT = ">"
    PLUS = "+"
    MINUS = "-"
    STAR = "*"
    SLASH = "/"
    CARET = "^"
    TILDE = "~"


KEYWORDS: Final[dict[str, Tok]] = {
    tok.value: tok
    for tok in Tok
    if tok.value.isalpha() and tok not in (Tok.INT, Tok.STRING, Tok.IDENT)
}

# Longest first, so that `:=` beats `:` and `<=` beats `<`.
PUNCTUATION: Final[tuple[tuple[str, Tok], ...]] = tuple(
    sorted(
        ((tok.value, tok) for tok in Tok if not tok.value[0].isalpha()),
        key=lambda pair: -len(pair[0]),
    )
)

ESCAPES: Final[dict[str, str]] = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    '"': '"',
    "\\": "\\",
}


@dataclass(frozen=True, slots=True)
class Token:
    kind: Tok
    text: str
    span: Span

    def __str__(self) -> str:
        match self.kind:
            case Tok.EOF:
                return "end of input"
            case Tok.STRING:
                return f'"{self.text}"'
            case _:
                return f"`{self.text}`"


class Lexer:
    """Turns source text into a list of tokens, in one pass, no regexes."""

    def __init__(self, source: str) -> None:
        self.src = source
        self.pos = 0
        self.line = 1
        self.col = 1

    def tokens(self) -> list[Token]:
        out: list[Token] = []
        while True:
            tok = self._next()
            out.append(tok)
            if tok.kind is Tok.EOF:
                return out

    # -- the scanner ------------------------------------------------------

    def _next(self) -> Token:
        self._skip_trivia()
        span = self._span()
        if self.pos >= len(self.src):
            return Token(Tok.EOF, "", span)

        ch = self.src[self.pos]
        if ch.isdigit():
            return self._number(span)
        if ch.isalpha() or ch == "_":
            return self._word(span)
        if ch == '"':
            return self._string(span)
        for text, kind in PUNCTUATION:
            if self.src.startswith(text, self.pos):
                self._advance(len(text))
                return Token(kind, text, span)
        raise LexError(span, f"stray character `{ch}`")

    def _number(self, span: Span) -> Token:
        start = self.pos
        while self.pos < len(self.src) and self.src[self.pos].isdigit():
            self._advance(1)
        text = self.src[start : self.pos]
        if self.pos < len(self.src) and (
            self.src[self.pos].isalpha() or self.src[self.pos] == "_"
        ):
            raise LexError(span, f"`{text}{self.src[self.pos]}` is not a number")
        return Token(Tok.INT, text, span)

    def _word(self, span: Span) -> Token:
        start = self.pos
        while self.pos < len(self.src) and (
            self.src[self.pos].isalnum() or self.src[self.pos] in "_'"
        ):
            self._advance(1)
        text = self.src[start : self.pos]
        return Token(KEYWORDS.get(text, Tok.IDENT), text, span)

    def _string(self, span: Span) -> Token:
        """Scan a string literal, which is a sequence of bytes.

        `size`, `ord` and `substring` count bytes at run time, so a literal is
        read as bytes here too: source text contributes its UTF-8 encoding, and
        `\\ddd` names one byte.  Each byte is kept as one character, which is
        what `emit.escape` writes back out.
        """
        self._advance(1)
        parts: list[str] = []
        while True:
            if self.pos >= len(self.src):
                raise LexError(span, "unterminated string")
            ch = self.src[self.pos]
            if ch == '"':
                self._advance(1)
                return Token(Tok.STRING, "".join(parts), span)
            if ch == "\n":
                raise LexError(self._span(), "a string may not span lines")
            if ch == "\\":
                self._advance(1)
                parts.append(self._escape())
                continue
            self._advance(1)
            parts.append(ch if ch.isascii() else ch.encode().decode("latin-1"))

    def _escape(self) -> str:
        if self.pos >= len(self.src):
            raise LexError(self._span(), "unterminated escape")
        ch = self.src[self.pos]
        if ch.isdigit():
            digits = self.src[self.pos : self.pos + 3]
            if len(digits) == 3 and digits.isdigit() and int(digits) < 256:
                self._advance(3)
                return chr(int(digits))
            raise LexError(self._span(), "a numeric escape is three digits, `\\065`")
        if ch in ESCAPES:
            self._advance(1)
            return ESCAPES[ch]
        raise LexError(self._span(), f"unknown escape `\\{ch}`")

    def _skip_trivia(self) -> None:
        while self.pos < len(self.src):
            ch = self.src[self.pos]
            if ch in " \t\r\n":
                self._advance(1)
            elif self.src.startswith("(*", self.pos):
                self._comment()
            else:
                return

    def _comment(self) -> None:
        span = self._span()
        depth = 0
        while self.pos < len(self.src):
            if self.src.startswith("(*", self.pos):
                depth += 1
                self._advance(2)
            elif self.src.startswith("*)", self.pos):
                depth -= 1
                self._advance(2)
                if depth == 0:
                    return
            else:
                self._advance(1)
        raise LexError(span, "unterminated comment")

    def _advance(self, n: int) -> None:
        for _ in range(n):
            if self.src[self.pos] == "\n":
                self.line += 1
                self.col = 1
            else:
                self.col += 1
            self.pos += 1

    def _span(self) -> Span:
        return Span(self.line, self.col)


def lex(source: str) -> list[Token]:
    return Lexer(source).tokens()
