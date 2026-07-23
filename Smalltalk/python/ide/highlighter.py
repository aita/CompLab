"""A lightweight Smalltalk syntax highlighter for the IDE editors."""

from __future__ import annotations

import re

from PySide6.QtCore import QRegularExpression
from PySide6.QtGui import (
    QColor,
    QFont,
    QSyntaxHighlighter,
    QTextCharFormat,
    QTextDocument,
)


def _fmt(color: str, *, bold: bool = False, italic: bool = False) -> QTextCharFormat:
    f = QTextCharFormat()
    f.setForeground(QColor(color))
    if bold:
        f.setFontWeight(QFont.Weight.Bold)
    if italic:
        f.setFontItalic(True)
    return f


# A muted, dark-friendly palette.
_PSEUDO = _fmt("#c586c0", bold=True)  # self super true false nil thisContext
_KEYWORD_MSG = _fmt("#4fc1ff")  # at:put:
_BINARY = _fmt("#d4d4d4")
_SYMBOL = _fmt("#4ec9b0")
_STRING = _fmt("#ce9178")
_COMMENT = _fmt("#6a9955", italic=True)
_NUMBER = _fmt("#b5cea8")
_CLASS = _fmt("#4ec9b0", bold=True)
_CHAR = _fmt("#d7ba7d")
_RETURN = _fmt("#c586c0", bold=True)


class SmalltalkHighlighter(QSyntaxHighlighter):
    def __init__(self, document: QTextDocument):
        super().__init__(document)
        self._rules: list[tuple[QRegularExpression, QTextCharFormat]] = []
        add = self._rules.append

        add((QRegularExpression(r"\b\d+\.\d+\b|\b\d+\b"), _NUMBER))
        add((QRegularExpression(r"\b[A-Z]\w*\b"), _CLASS))
        add((QRegularExpression(r"\b[a-zA-Z_]\w*:"), _KEYWORD_MSG))
        add(
            (
                QRegularExpression(
                    r"\b(self|super|true|false|nil|thisContext)\b"
                ),
                _PSEUDO,
            )
        )
        add((QRegularExpression(r"\^"), _RETURN))
        add((QRegularExpression(r"#[A-Za-z_]\w*(:\w*:?)*|#\w+"), _SYMBOL))
        add((QRegularExpression(r"\$."), _CHAR))
        add((QRegularExpression(r"[+\-*/~<>=&|@%,?]+"), _BINARY))
        # strings and comments last so they win over the above
        add((QRegularExpression(r"'[^']*'"), _STRING))
        add((QRegularExpression(r'"[^"]*"'), _COMMENT))

    def highlightBlock(self, text: str) -> None:  # noqa: N802 (Qt signature)
        for rx, fmt in self._rules:
            it = rx.globalMatch(text)
            while it.hasNext():
                m = it.next()
                self.setFormat(m.capturedStart(), m.capturedLength(), fmt)


_ = re  # keep the import available for future word-boundary tweaks
