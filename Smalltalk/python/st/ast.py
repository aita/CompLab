"""AST node definitions for the Smalltalk subset.

An expression is one of the ``*Node`` value types below. A parsed method is a
:class:`MethodNode`; a workspace "do it" is a :class:`SequenceNode` of
statements. Nodes are plain dataclasses walked by the interpreter.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class LiteralNode:
    """A literal: integer, float, String, Symbol, Character, true/false/nil,
    or a literal array ``#(...)``. ``value`` is the ready-made Smalltalk value."""

    value: Any


@dataclass
class VariableNode:
    name: str


@dataclass
class AssignmentNode:
    name: str
    value: ExprNode


@dataclass
class MessageNode:
    """A message send. ``selector`` is the full selector (e.g. ``at:put:``);
    ``args`` matches its keyword/argument count (empty for unary sends)."""

    receiver: ExprNode
    selector: str
    args: list[ExprNode] = field(default_factory=list)


@dataclass
class CascadeNode:
    """``receiver msg1; msg2; msg3`` — the messages share one receiver and the
    whole cascade evaluates to the last message's result."""

    receiver: ExprNode
    messages: list[CascadeMessage] = field(default_factory=list)


@dataclass
class CascadeMessage:
    selector: str
    args: list[ExprNode] = field(default_factory=list)


@dataclass
class BlockNode:
    params: list[str]
    temps: list[str]
    body: SequenceNode


@dataclass
class ReturnNode:
    """``^expr`` — a method return."""

    value: ExprNode


@dataclass
class SequenceNode:
    """A ``.``-separated statement sequence with optional leading ``| temps |``."""

    temps: list[str] = field(default_factory=list)
    statements: list[ExprNode] = field(default_factory=list)


@dataclass
class MethodNode:
    """A parsed method: selector + argument names + body."""

    selector: str
    params: list[str]
    body: SequenceNode


ExprNode = (
    LiteralNode
    | VariableNode
    | AssignmentNode
    | MessageNode
    | CascadeNode
    | BlockNode
    | ReturnNode
)
