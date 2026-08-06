#!/usr/bin/env python3
"""Count the lines of each port that are code rather than comment.

A line counts as code when it is not blank, does not begin with a line-comment
marker, and is not inside a block comment or a docstring.  Comments at the end
of a line of code do not take that line away, which is the ordinary meaning of
"lines of code".

Classification is by line, not by token, on purpose: a string that happens to
contain `(*` or `//` cannot be mistaken for a comment unless it is the first
thing on its line, which never happens in this tree.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).parent

# Which files each port's compiler is, and how its comments are written.
#
#   line     markers that comment out the rest of a line
#   block    (open, close, nestable) for comments that span lines
#   doc      triple-quoted strings that stand where a comment would
PORTS = [
    ("python",     "python/wolv",              "**/*.py",   "py"),
    ("kotlin",     "kotlin/src/main/kotlin",   "**/*.kt",   "c"),
    ("go",         "go",                       "*.go",      "c"),
    ("ocaml",      "ocaml",                    "src/*.ml",  "ml"),
    ("typescript", "typescript/src",           "**/*.ts",   "c"),
    ("haxe",       "haxe/src",                 "**/*.hx",   "c"),
    ("racket",     "racket/src",               "*.rkt",     "rkt"),
    ("ruby",       "ruby/lib/wolv",            "*.rb",      "rb"),
    ("haskell",    "haskell/src/Wolv",         "*.hs",      "hs"),
    ("lisp",       "lisp/src",                 "*.lisp",    "lisp"),
    ("prolog",     "prolog/src",               "*.pl",      "pl"),
    ("guile",      "guile/src/wolv",           "*.scm",     "rkt"),
    ("clojure",    "clojure/src/wolv",         "*.clj",     "clj"),
]

SYNTAX = {
    "py":   {"line": ["#"], "block": None, "doc": ['"""', "'''"]},
    "c":    {"line": ["//"], "block": ("/*", "*/", False), "doc": []},
    "ml":   {"line": [], "block": ("(*", "*)", True), "doc": []},
    # A Common Lisp docstring is a string where a comment would be, so it is
    # counted as one -- otherwise the comparison would charge Lisp for its
    # documentation and let Python's docstrings off.
    "lisp": {"line": [";"], "block": ("#|", "|#", True), "doc": ['"']},
    # Racket and Guile have no docstrings of the kind that stands where a
    # comment would, so a line that begins with a quote there is a string
    # literal and is code.
    "rkt":  {"line": [";"], "block": ("#|", "|#", True), "doc": []},
    # Clojure's docstrings are Common Lisp's, and counted the same way.  A
    # string literal that happens to start a line -- a row of an instruction
    # table, a line of the usage message -- is counted as a comment by that
    # rule, which costs this port about thirty lines of the four thousand.
    "clj":  {"line": [";"], "block": None, "doc": ['"']},
    "rb":   {"line": ["#"], "block": ("=begin", "=end", False), "doc": []},
    "hs":   {"line": ["--"], "block": ("{-", "-}", True), "doc": []},
    "pl":   {"line": ["%"], "block": ("/*", "*/", False), "doc": []},
}

# The Python tree carries both register allocators; every other port carries
# one, so the second is counted separately to keep the comparison honest.
EXTRA_TO_PYTHON = {"python/wolv/allocator/chordal.py"}


def classify(lines: list[str], syntax: dict) -> tuple[int, int]:
    """(code, comment) line counts.  Blank lines are neither."""
    return measure(lines, syntax)[:2]


def measure(lines: list[str], syntax: dict) -> tuple[int, int, int]:
    """(code lines, comment lines, characters of code).

    The characters are counted with the indentation stripped, so that a
    language whose convention is to wrap at column 60 is not charged for it and
    one that indents eight spaces is not charged either.  Lines are a
    convention; characters are closer to the work.
    """
    code = comment = chars = 0
    depth = 0            # how deep inside a block comment
    doc: str | None = None   # which triple quote a docstring is waiting for
    opener = closer = None
    nestable = False
    if syntax["block"]:
        opener, closer, nestable = syntax["block"]

    for raw in lines:
        text = raw.strip()
        if doc is not None:
            comment += 1
            if doc in text:
                doc = None
            continue
        if depth:
            comment += 1
            if nestable and opener in text:
                depth += 1
            if closer in text:
                depth -= 1
            continue
        if not text:
            continue
        if any(text.startswith(m) for m in syntax["line"]):
            comment += 1
            continue
        for quote in syntax["doc"]:
            if text.startswith(quote):
                comment += 1
                # Two markers on one line means it opened and closed there.
                if text.count(quote) < 2:
                    doc = quote
                break
        else:
            if opener and text.startswith(opener):
                comment += 1
                if closer not in text[len(opener):]:
                    depth = 1
                continue
            code += 1
            chars += len(text)
            continue
        continue
    return code, comment, chars


def main() -> None:
    rows = []
    for name, directory, pattern, kind in PORTS:
        paths = sorted((ROOT / directory).glob(pattern))
        paths = [p for p in paths if not p.name.endswith("_test.go")]
        code = comment = total = files = chars = 0
        extra_code = 0
        for path in paths:
            lines = path.read_text(encoding="utf-8").splitlines()
            c, m, ch = measure(lines, SYNTAX[kind])
            relative = str(path.relative_to(ROOT))
            if relative in EXTRA_TO_PYTHON:
                extra_code += c
                continue
            files += 1
            code += c
            comment += m
            chars += ch
            total += len(lines)
        rows.append((name, files, code, comment, total, chars, extra_code))

    smallest = min(r[5] for r in rows)
    print(f"{'port':<11}{'code':>7}{'chars':>9}{'chars/line':>12}{'vs least':>10}")
    for name, files, code, comment, total, chars, extra in sorted(rows, key=lambda r: r[5]):
        note = "  (+ the second allocator)" if extra else ""
        print(f"{name:<11}{code:>7}{chars:>9}{chars / code:>12.1f}"
              f"{chars / smallest:>9.2f}x{note}")


if __name__ == "__main__":
    main()
