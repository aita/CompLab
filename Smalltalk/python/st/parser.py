"""Recursive-descent parser for the Smalltalk subset.

Message precedence, tightest first: unary > binary > keyword. Two public
entry points:

  parse_sequence(src)  -> SequenceNode   (a workspace "do it" / method body)
  parse_method(src)    -> MethodNode     (message pattern + body)
"""

from __future__ import annotations

from st import ast
from st.lexer import Lexer, Token
from st.objects import STChar, STSymbol, nil


class ParseError(Exception):
    pass


class Parser:
    def __init__(self, text: str):
        self.text = text
        self.toks = Lexer(text).tokens()
        self.pos = 0

    # --- token helpers ---

    @property
    def cur(self) -> Token:
        return self.toks[self.pos]

    def _at(self, kind: str, value: object = None) -> bool:
        t = self.cur
        if t.kind != kind:
            return False
        return value is None or t.value == value

    def _advance(self) -> Token:
        t = self.toks[self.pos]
        if t.kind != "EOF":
            self.pos += 1
        return t

    def _expect(self, kind: str, value: object = None) -> Token:
        if not self._at(kind, value):
            want = value if value is not None else kind
            raise ParseError(
                f"line {self.cur.line}: expected {want!r}, got "
                f"{self.cur.kind} {self.cur.value!r}"
            )
        return self._advance()

    # --- public entry points ---

    def parse_sequence(self) -> ast.SequenceNode:
        seq = self._sequence()
        if not self._at("EOF") and not self._at("BANG"):
            raise ParseError(
                f"line {self.cur.line}: trailing input "
                f"{self.cur.kind} {self.cur.value!r}"
            )
        return seq

    def parse_method(self) -> ast.MethodNode:
        selector, params = self._message_pattern()
        body = self._sequence()
        if not self._at("EOF") and not self._at("BANG"):
            raise ParseError(
                f"line {self.cur.line}: trailing input after method body"
            )
        return ast.MethodNode(selector=selector, params=params, body=body)

    # --- method pattern ---

    def _message_pattern(self) -> tuple[str, list[str]]:
        if self._at("KEYWORD"):
            parts: list[str] = []
            params: list[str] = []
            while self._at("KEYWORD"):
                parts.append(str(self._advance().value))
                params.append(str(self._expect("IDENT").value))
            return "".join(parts), params
        if self._at("BINARY"):
            sel = str(self._advance().value)
            param = str(self._expect("IDENT").value)
            return sel, [param]
        # unary
        sel = str(self._expect("IDENT").value)
        return sel, []

    # --- sequences and statements ---

    def _temps(self) -> list[str]:
        # optional  | a b c |
        if self._at("BINARY", "|"):
            self._advance()
            names: list[str] = []
            while self._at("IDENT"):
                names.append(str(self._advance().value))
            self._expect("BINARY", "|")
            return names
        return []

    def _sequence(self) -> ast.SequenceNode:
        temps = self._temps()
        statements: list[ast.ExprNode] = []
        while not self._sequence_end():
            if self._at("RETURN"):
                self._advance()
                statements.append(ast.ReturnNode(self._expression()))
                if self._at("DOT"):
                    self._advance()
                break  # a return ends the sequence
            statements.append(self._expression())
            if self._at("DOT"):
                self._advance()
            else:
                break
        return ast.SequenceNode(temps=temps, statements=statements)

    def _sequence_end(self) -> bool:
        return self.cur.kind in ("EOF", "RBRACK", "BANG")

    # --- expressions ---

    def _expression(self) -> ast.ExprNode:
        # assignment?  IDENT ':=' expression
        if self._at("IDENT") and self.toks[self.pos + 1].kind == "ASSIGN":
            name = str(self._advance().value)
            self._advance()  # ':='
            return ast.AssignmentNode(name, self._expression())
        return self._cascade()

    def _cascade(self) -> ast.ExprNode:
        first = self._keyword_expr()
        if not self._at("SEMI"):
            return first
        if not isinstance(first, ast.MessageNode):
            raise ParseError(
                f"line {self.cur.line}: cascade requires a message receiver"
            )
        receiver = first.receiver
        messages = [ast.CascadeMessage(first.selector, first.args)]
        while self._at("SEMI"):
            self._advance()
            messages.append(self._cascade_message())
        return ast.CascadeNode(receiver=receiver, messages=messages)

    def _cascade_message(self) -> ast.CascadeMessage:
        if self._at("KEYWORD"):
            parts: list[str] = []
            args: list[ast.ExprNode] = []
            while self._at("KEYWORD"):
                parts.append(str(self._advance().value))
                args.append(self._binary_expr())
            return ast.CascadeMessage("".join(parts), args)
        if self._at("BINARY"):
            sel = str(self._advance().value)
            return ast.CascadeMessage(sel, [self._unary_expr()])
        sel = str(self._expect("IDENT").value)
        return ast.CascadeMessage(sel, [])

    def _keyword_expr(self) -> ast.ExprNode:
        receiver = self._binary_expr()
        if self._at("KEYWORD"):
            parts: list[str] = []
            args: list[ast.ExprNode] = []
            while self._at("KEYWORD"):
                parts.append(str(self._advance().value))
                args.append(self._binary_expr())
            return ast.MessageNode(receiver, "".join(parts), args)
        return receiver

    def _binary_expr(self) -> ast.ExprNode:
        left = self._unary_expr()
        while self._at("BINARY") and not self._at("BINARY", "|"):
            sel = str(self._advance().value)
            right = self._unary_expr()
            left = ast.MessageNode(left, sel, [right])
        return left

    def _unary_expr(self) -> ast.ExprNode:
        recv = self._primary()
        while self._at("IDENT"):
            sel = str(self._advance().value)
            recv = ast.MessageNode(recv, sel, [])
        return recv

    # --- primaries ---

    def _primary(self) -> ast.ExprNode:
        t = self.cur
        match t.kind:
            case "INTEGER" | "FLOAT" | "STRING":
                self._advance()
                return ast.LiteralNode(t.value)
            case "SYMBOL":
                self._advance()
                return ast.LiteralNode(STSymbol(str(t.value)))
            case "CHAR":
                self._advance()
                return ast.LiteralNode(STChar(str(t.value)))
            case "HASHPAREN":
                return self._literal_array()
            case "LBRACE":
                return self._dynamic_array()
            case "LBRACK":
                return self._block()
            case "LPAREN":
                self._advance()
                inner = self._expression()
                self._expect("RPAREN")
                return inner
            case "IDENT":
                self._advance()
                name = str(t.value)
                match name:
                    case "true":
                        return ast.LiteralNode(True)
                    case "false":
                        return ast.LiteralNode(False)
                    case "nil":
                        return ast.LiteralNode(nil)
                    case _:
                        return ast.VariableNode(name)
            case _:
                raise ParseError(
                    f"line {t.line}: unexpected {t.kind} {t.value!r} in expression"
                )

    def _literal_array(self) -> ast.LiteralNode:
        self._expect("HASHPAREN")
        elements: list[object] = []
        while not self._at("RPAREN"):
            elements.append(self._literal_array_element())
        self._expect("RPAREN")
        return ast.LiteralNode(elements)

    def _literal_array_element(self) -> object:
        t = self.cur
        match t.kind:
            case "INTEGER" | "FLOAT" | "STRING":
                self._advance()
                return t.value
            case "SYMBOL":
                self._advance()
                return STSymbol(str(t.value))
            case "CHAR":
                self._advance()
                return STChar(str(t.value))
            case "HASHPAREN":
                return self._literal_array().value
            case "LPAREN":  # nested array without leading '#'
                self._advance()
                nested: list[object] = []
                while not self._at("RPAREN"):
                    nested.append(self._literal_array_element())
                self._expect("RPAREN")
                return nested
            case "IDENT":
                # bare identifiers become symbols inside a literal array;
                # true/false/nil keep their meaning
                self._advance()
                name = str(t.value)
                match name:
                    case "true":
                        return True
                    case "false":
                        return False
                    case "nil":
                        return nil
                    case _:
                        return STSymbol(name)
            case "KEYWORD":
                # e.g. #(at:put:) — combine adjacent keywords into one symbol
                parts: list[str] = []
                while self._at("KEYWORD"):
                    parts.append(str(self._advance().value))
                return STSymbol("".join(parts))
            case "BINARY":
                self._advance()
                return STSymbol(str(t.value))
            case _:
                raise ParseError(
                    f"line {t.line}: bad literal-array element "
                    f"{t.kind} {t.value!r}"
                )

    def _dynamic_array(self) -> ast.MessageNode:
        # { a . b . c } -> array built at runtime from expressions
        self._expect("LBRACE")
        elements: list[ast.ExprNode] = []
        while not self._at("RBRACE"):
            elements.append(self._expression())
            if self._at("DOT"):
                self._advance()
        self._expect("RBRACE")
        # Represent as a special message the interpreter understands.
        return ast.MessageNode(
            ast.VariableNode("Array"), "__brace__", elements
        )

    def _block(self) -> ast.BlockNode:
        self._expect("LBRACK")
        params: list[str] = []
        # block args: [:a :b | ...] — a leading run of COLON IDENT pairs
        # terminated by '|'. With no args there is no leading '|'.
        if self._at("COLON"):
            while self._at("COLON"):
                self._advance()
                params.append(str(self._expect("IDENT").value))
            self._expect("BINARY", "|")
        temps = self._temps()
        body = self._sequence_no_temps()
        body.temps = temps
        self._expect("RBRACK")
        return ast.BlockNode(params=params, temps=temps, body=body)

    def _sequence_no_temps(self) -> ast.SequenceNode:
        statements: list[ast.ExprNode] = []
        while not self._sequence_end():
            if self._at("RETURN"):
                self._advance()
                statements.append(ast.ReturnNode(self._expression()))
                if self._at("DOT"):
                    self._advance()
                break
            statements.append(self._expression())
            if self._at("DOT"):
                self._advance()
            else:
                break
        return ast.SequenceNode(temps=[], statements=statements)


def parse_sequence(text: str) -> ast.SequenceNode:
    return Parser(text).parse_sequence()


def parse_method(text: str) -> ast.MethodNode:
    return Parser(text).parse_method()
