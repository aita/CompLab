"""Source positions and the one exception every pass raises."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Span:
    """A position in the source, counted from one."""

    line: int
    col: int

    def __str__(self) -> str:
        return f"{self.line}:{self.col}"


NOWHERE = Span(0, 0)


class WolvError(Exception):
    """A user-facing compile error, carrying where it happened."""

    def __init__(self, span: Span, message: str) -> None:
        super().__init__(f"{span}: {message}")
        self.span = span
        self.message = message


class LexError(WolvError):
    pass


class ParseError(WolvError):
    pass


class TypeCheckError(WolvError):
    pass
