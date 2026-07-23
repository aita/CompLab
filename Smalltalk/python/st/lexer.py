"""Tokenizer for the Smalltalk subset.

Token kinds:
  IDENT     foo            an identifier / variable name
  KEYWORD   at:            an identifier immediately followed by ':'
  BINARY    + - <= , @ ... a run of binary selector characters
  INTEGER   42             (also radix form 16r1F)
  FLOAT     3.14
  STRING    'hi'           value has the quotes/escapes resolved
  SYMBOL    #foo #at:put:  value is the symbol text without '#'
  CHAR      $a             value is the single character
  ASSIGN    :=
  RETURN    ^
  DOT ; ( ) [ ] { } | !    structural tokens
  EOF
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Token:
    kind: str
    value: object
    pos: int
    line: int


class LexError(Exception):
    pass


BINARY_CHARS = set("+-*/~<>=&|@%,?!")
# Characters that may legally follow a run to still be "binary". Note '|' and
# '!' are also structural; disambiguated below.


class Lexer:
    def __init__(self, text: str):
        self.text = text
        self.i = 0
        self.line = 1

    def error(self, msg: str) -> LexError:
        return LexError(f"line {self.line}: {msg}")

    def _peek(self, offset: int = 0) -> str:
        j = self.i + offset
        return self.text[j] if j < len(self.text) else ""

    def _advance(self) -> str:
        ch = self.text[self.i]
        self.i += 1
        if ch == "\n":
            self.line += 1
        return ch

    def _skip_ws_and_comments(self) -> None:
        while self.i < len(self.text):
            ch = self.text[self.i]
            if ch.isspace():
                self._advance()
            elif ch == '"':  # comment: "..." with "" as an escaped quote
                self._advance()
                while self.i < len(self.text):
                    c = self._advance()
                    if c == '"':
                        if self._peek() == '"':
                            self._advance()
                        else:
                            break
                else:
                    raise self.error("unterminated comment")
            else:
                break

    def tokens(self) -> list[Token]:
        out: list[Token] = []
        while True:
            tok = self.next_token()
            out.append(tok)
            if tok.kind == "EOF":
                return out

    def next_token(self) -> Token:
        self._skip_ws_and_comments()
        start = self.i
        line = self.line
        if self.i >= len(self.text):
            return Token("EOF", None, start, line)

        ch = self.text[self.i]

        if ch.isalpha() or ch == "_":
            return self._ident(start, line)
        if ch.isdigit():
            return self._number(start, line)
        if ch == "'":
            return self._string(start, line)
        if ch == "#":
            return self._symbol_or_array(start, line)
        if ch == "$":
            self._advance()
            if self.i >= len(self.text):
                raise self.error("unterminated character literal")
            c = self._advance()
            return Token("CHAR", c, start, line)
        if ch == ":" and self._peek(1) == "=":
            self._advance()
            self._advance()
            return Token("ASSIGN", ":=", start, line)
        if ch == ":":  # block argument marker, as in [:a :b | ...]
            self._advance()
            return Token("COLON", ":", start, line)
        if ch == "^":
            self._advance()
            return Token("RETURN", "^", start, line)

        # Structural single-char tokens.
        simple = {
            ".": "DOT",
            ";": "SEMI",
            "(": "LPAREN",
            ")": "RPAREN",
            "[": "LBRACK",
            "]": "RBRACK",
            "{": "LBRACE",
            "}": "RBRACE",
        }
        if ch in simple:
            self._advance()
            return Token(simple[ch], ch, start, line)
        if ch == "!":
            self._advance()
            return Token("BANG", "!", start, line)

        if ch in BINARY_CHARS:
            return self._binary(start, line)

        raise self.error(f"unexpected character {ch!r}")

    def _ident(self, start: int, line: int) -> Token:
        while self.i < len(self.text) and (
            self.text[self.i].isalnum() or self.text[self.i] == "_"
        ):
            self._advance()
        name = self.text[start : self.i]
        if self._peek() == ":" and self._peek(1) != "=":
            self._advance()  # consume ':'
            return Token("KEYWORD", name + ":", start, line)
        return Token("IDENT", name, start, line)

    def _number(self, start: int, line: int) -> Token:
        while self.i < len(self.text) and self.text[self.i].isdigit():
            self._advance()
        # radix: 16rFF
        if self._peek() == "r":
            radix = int(self.text[start : self.i])
            self._advance()  # 'r'
            digits_start = self.i
            while self.i < len(self.text) and self.text[self.i].isalnum():
                self._advance()
            value = int(self.text[digits_start : self.i], radix)
            return Token("INTEGER", value, start, line)
        # float: digits '.' digits (dot must be followed by a digit, else it is
        # a statement separator)
        if self._peek() == "." and self._peek(1).isdigit():
            self._advance()  # '.'
            while self.i < len(self.text) and self.text[self.i].isdigit():
                self._advance()
            # optional exponent
            if self._peek() in ("e", "E"):
                self._advance()
                if self._peek() in ("+", "-"):
                    self._advance()
                while self.i < len(self.text) and self.text[self.i].isdigit():
                    self._advance()
            return Token("FLOAT", float(self.text[start : self.i]), start, line)
        if self._peek() in ("e", "E") and self._peek(1).isdigit():
            self._advance()
            while self.i < len(self.text) and self.text[self.i].isdigit():
                self._advance()
            return Token("FLOAT", float(self.text[start : self.i]), start, line)
        return Token("INTEGER", int(self.text[start : self.i]), start, line)

    def _string(self, start: int, line: int) -> Token:
        self._advance()  # opening quote
        chars: list[str] = []
        while self.i < len(self.text):
            c = self._advance()
            if c == "'":
                if self._peek() == "'":
                    self._advance()
                    chars.append("'")
                else:
                    return Token("STRING", "".join(chars), start, line)
            else:
                chars.append(c)
        raise self.error("unterminated string literal")

    def _symbol_or_array(self, start: int, line: int) -> Token:
        self._advance()  # '#'
        nxt = self._peek()
        if nxt == "(":
            self._advance()
            return Token("HASHPAREN", "#(", start, line)
        if nxt == "'":
            tok = self._string(self.i, line)
            return Token("SYMBOL", tok.value, start, line)
        if nxt.isalpha() or nxt == "_":
            # keyword symbol like #at:put: or unary #foo
            sym_start = self.i
            while self.i < len(self.text) and (
                self.text[self.i].isalnum()
                or self.text[self.i] in ("_", ":")
            ):
                self._advance()
            return Token("SYMBOL", self.text[sym_start : self.i], start, line)
        if nxt in BINARY_CHARS:
            sym_start = self.i
            while self.i < len(self.text) and self.text[self.i] in BINARY_CHARS:
                self._advance()
            return Token("SYMBOL", self.text[sym_start : self.i], start, line)
        raise self.error("malformed symbol literal")

    def _binary(self, start: int, line: int) -> Token:
        # A binary selector is a run of 1-2 binary characters. Keep it greedy
        # but stop so that e.g. '|' used as a temp delimiter still works: a lone
        # '|' surrounded by spaces is handled by the parser via BINARY value.
        while self.i < len(self.text) and self.text[self.i] in BINARY_CHARS:
            self._advance()
        return Token("BINARY", self.text[start : self.i], start, line)
