"""A Pratt parser.

Every expression form is either a prefix form (`nud`, in `_atom`) or an infix
one (`led`, in `_exp`), and the table below is the whole of the precedence.
The prefix forms that end in an expression — `if`, `while`, `for`, `:=` — take
their tail at binding power 0, so `if c then x := 1 else x := 2` reads the way
it looks.
"""

from __future__ import annotations

from typing import Final

from wolv import ast
from wolv.diag import ParseError
from wolv.lexer import Tok, Token, lex

BP: Final[dict[Tok, tuple[int, int]]] = {
    Tok.ASSIGN: (2, 1),
    Tok.ORELSE: (4, 5),
    Tok.ANDALSO: (6, 7),
    Tok.EQ: (8, 9),
    Tok.NE: (8, 9),
    Tok.LT: (8, 9),
    Tok.LE: (8, 9),
    Tok.GT: (8, 9),
    Tok.GE: (8, 9),
    Tok.CARET: (10, 11),
    Tok.PLUS: (12, 13),
    Tok.MINUS: (12, 13),
    Tok.STAR: (14, 15),
    Tok.SLASH: (14, 15),
    Tok.MOD: (14, 15),
}

UNARY_BP: Final = 16

BINOPS: Final[dict[Tok, str]] = {
    Tok.PLUS: "+",
    Tok.MINUS: "-",
    Tok.STAR: "*",
    Tok.SLASH: "/",
    Tok.MOD: "mod",
    Tok.CARET: "^",
    Tok.EQ: "=",
    Tok.NE: "<>",
    Tok.LT: "<",
    Tok.LE: "<=",
    Tok.GT: ">",
    Tok.GE: ">=",
}

DECL_STARTERS: Final[frozenset[Tok]] = frozenset(
    {Tok.VAL, Tok.VAR, Tok.FUN, Tok.TYPE}
)


class Parser:
    def __init__(self, tokens: list[Token]) -> None:
        self.toks = tokens
        self.pos = 0

    # -- token plumbing ---------------------------------------------------

    @property
    def cur(self) -> Token:
        return self.toks[self.pos]

    def peek(self, n: int = 1) -> Token:
        i = min(self.pos + n, len(self.toks) - 1)
        return self.toks[i]

    def at(self, kind: Tok) -> bool:
        return self.cur.kind is kind

    def take(self, kind: Tok) -> Token | None:
        if self.cur.kind is kind:
            tok = self.cur
            self.pos += 1
            return tok
        return None

    def expect(self, kind: Tok) -> Token:
        tok = self.take(kind)
        if tok is None:
            raise ParseError(self.cur.span, f"expected `{kind.value}`, found {self.cur}")
        return tok

    def expect_ident(self) -> Token:
        tok = self.take(Tok.IDENT)
        if tok is None:
            raise ParseError(self.cur.span, f"expected a name, found {self.cur}")
        return tok

    # -- programs and declarations ----------------------------------------

    def program(self) -> ast.Program:
        decls: list[ast.Decl] = []
        while not self.at(Tok.EOF):
            decls.append(self.decl())
        return ast.Program(decls)

    def decl(self) -> ast.Decl:
        match self.cur.kind:
            case Tok.TYPE:
                return self.type_decl()
            case Tok.VAL | Tok.VAR:
                return self.val_decl()
            case Tok.FUN:
                return self.fun_decl()
            case _:
                raise ParseError(
                    self.cur.span,
                    f"expected a declaration (`val`, `var`, `fun`, `type`), "
                    f"found {self.cur}",
                )

    def type_decl(self) -> ast.TypeDecl:
        span = self.expect(Tok.TYPE).span
        binds = [self.type_bind()]
        while self.take(Tok.AND) is not None:
            binds.append(self.type_bind())
        return ast.TypeDecl(span, binds)

    def type_bind(self) -> ast.TypeBind:
        name = self.expect_ident()
        self.expect(Tok.EQ)
        return ast.TypeBind(name.text, self.ty(), name.span)

    def val_decl(self) -> ast.ValDecl:
        mutable = self.cur.kind is Tok.VAR
        span = self.cur.span
        self.pos += 1
        name: str | None
        if self.take(Tok.LPAREN) is not None:
            self.expect(Tok.RPAREN)
            name = None
        else:
            name = self.expect_ident().text
        ty = self.ty() if self.take(Tok.COLON) is not None else None
        self.expect(Tok.EQ)
        return ast.ValDecl(span, name, ty, self.exp(0), mutable)

    def fun_decl(self) -> ast.FunDecl:
        span = self.expect(Tok.FUN).span
        binds = [self.fun_bind()]
        while self.take(Tok.AND) is not None:
            binds.append(self.fun_bind())
        return ast.FunDecl(span, binds)

    def fun_bind(self) -> ast.FunBind:
        name = self.expect_ident()
        self.expect(Tok.LPAREN)
        params: list[ast.Param] = []
        if self.take(Tok.RPAREN) is None:
            while True:
                pname = self.expect_ident()
                self.expect(Tok.COLON)
                params.append(ast.Param(pname.text, self.ty(), pname.span))
                if self.take(Tok.COMMA) is None:
                    break
            self.expect(Tok.RPAREN)
        result = self.ty() if self.take(Tok.COLON) is not None else None
        self.expect(Tok.EQ)
        return ast.FunBind(name.text, params, result, self.exp(0), name.span)

    # -- types ------------------------------------------------------------

    def ty(self) -> ast.TyExp:
        span = self.cur.span
        base: ast.TyExp
        if self.take(Tok.LBRACE) is not None:
            fields: list[ast.TyField] = []
            if self.take(Tok.RBRACE) is None:
                while True:
                    fname = self.expect_ident()
                    self.expect(Tok.COLON)
                    fields.append(ast.TyField(fname.text, self.ty(), fname.span))
                    if self.take(Tok.COMMA) is None:
                        break
                self.expect(Tok.RBRACE)
            base = ast.TyRecord(span, fields)
        elif self.take(Tok.LPAREN) is not None:
            base = self.ty()
            self.expect(Tok.RPAREN)
        else:
            base = ast.TyName(span, self.expect_ident().text)
        while self.cur.kind is Tok.IDENT and self.cur.text == "array":
            self.pos += 1
            base = ast.TyArray(span, base)
        return base

    # -- expressions ------------------------------------------------------

    def exp(self, min_bp: int) -> ast.Exp:
        left = self.atom()
        while True:
            bp = BP.get(self.cur.kind)
            if bp is None or bp[0] < min_bp:
                return left
            tok = self.cur
            self.pos += 1
            match tok.kind:
                case Tok.ASSIGN:
                    self.check_lvalue(left)
                    left = ast.Assign(tok.span, left, self.exp(bp[1]))
                case Tok.ANDALSO | Tok.ORELSE:
                    left = ast.Logic(tok.span, tok.text, left, self.exp(bp[1]))
                case _:
                    left = ast.Bin(tok.span, BINOPS[tok.kind], left, self.exp(bp[1]))

    def check_lvalue(self, e: ast.Exp) -> None:
        match e:
            case ast.Var() | ast.Index() | ast.Field():
                return
            case _:
                raise ParseError(e.span, "the left of `:=` is not assignable")

    def atom(self) -> ast.Exp:
        tok = self.cur
        span = tok.span
        match tok.kind:
            case Tok.INT:
                self.pos += 1
                return self.postfix(ast.IntLit(span, int(tok.text)))
            case Tok.STRING:
                self.pos += 1
                return self.postfix(ast.StrLit(span, tok.text))
            case Tok.TRUE | Tok.FALSE:
                self.pos += 1
                return ast.BoolLit(span, tok.kind is Tok.TRUE)
            case Tok.NIL:
                self.pos += 1
                return ast.NilLit(span)
            case Tok.BREAK:
                self.pos += 1
                return ast.Break(span)
            case Tok.TILDE:
                self.pos += 1
                return ast.Neg(span, self.exp(UNARY_BP))
            case Tok.MINUS:
                raise ParseError(span, "negation is written `~`, not `-`")
            case Tok.LPAREN:
                return self.postfix(self.parens())
            case Tok.IDENT:
                return self.postfix(self.named())
            case Tok.IF:
                return self.if_exp()
            case Tok.WHILE:
                return self.while_exp()
            case Tok.FOR:
                return self.for_exp()
            case Tok.LET:
                return self.let_exp()
            case _:
                raise ParseError(span, f"expected an expression, found {self.cur}")

    def parens(self) -> ast.Exp:
        span = self.expect(Tok.LPAREN).span
        if self.take(Tok.RPAREN) is not None:
            return ast.UnitLit(span)
        items = self.sequence(Tok.RPAREN)
        self.expect(Tok.RPAREN)
        return items[0] if len(items) == 1 else ast.Seq(span, items)

    def sequence(self, end: Tok) -> list[ast.Exp]:
        items = [self.exp(0)]
        while self.take(Tok.SEMI) is not None:
            if self.at(end):
                break
            items.append(self.exp(0))
        return items

    def named(self) -> ast.Exp:
        tok = self.expect_ident()
        match self.cur.kind:
            case Tok.LPAREN:
                self.pos += 1
                args: list[ast.Exp] = []
                if self.take(Tok.RPAREN) is None:
                    while True:
                        args.append(self.exp(0))
                        if self.take(Tok.COMMA) is None:
                            break
                    self.expect(Tok.RPAREN)
                return ast.Call(tok.span, tok.text, args)
            case Tok.LBRACE:
                self.pos += 1
                fields: list[ast.FieldInit] = []
                if self.take(Tok.RBRACE) is None:
                    while True:
                        fname = self.expect_ident()
                        self.expect(Tok.EQ)
                        fields.append(
                            ast.FieldInit(fname.text, self.exp(0), fname.span)
                        )
                        if self.take(Tok.COMMA) is None:
                            break
                    self.expect(Tok.RBRACE)
                return ast.RecordLit(tok.span, tok.text, fields)
            case _:
                return ast.Var(tok.span, tok.text)

    def postfix(self, base: ast.Exp) -> ast.Exp:
        while True:
            match self.cur.kind:
                case Tok.LBRACK:
                    span = self.cur.span
                    self.pos += 1
                    index = self.exp(0)
                    self.expect(Tok.RBRACK)
                    base = ast.Index(span, base, index)
                case Tok.DOT:
                    span = self.cur.span
                    self.pos += 1
                    base = ast.Field(span, base, self.expect_ident().text)
                case _:
                    return base

    def if_exp(self) -> ast.Exp:
        span = self.expect(Tok.IF).span
        cond = self.exp(0)
        self.expect(Tok.THEN)
        then = self.exp(0)
        els = self.exp(0) if self.take(Tok.ELSE) is not None else None
        return ast.If(span, cond, then, els)

    def while_exp(self) -> ast.Exp:
        span = self.expect(Tok.WHILE).span
        cond = self.exp(0)
        self.expect(Tok.DO)
        return ast.While(span, cond, self.exp(0))

    def for_exp(self) -> ast.Exp:
        span = self.expect(Tok.FOR).span
        name = self.expect_ident()
        self.expect(Tok.EQ)
        lo = self.exp(0)
        self.expect(Tok.TO)
        hi = self.exp(0)
        self.expect(Tok.DO)
        return ast.For(span, name.text, lo, hi, self.exp(0))

    def let_exp(self) -> ast.Exp:
        span = self.expect(Tok.LET).span
        decls: list[ast.Decl] = []
        while self.cur.kind in DECL_STARTERS:
            decls.append(self.decl())
        self.expect(Tok.IN)
        body: ast.Exp
        if self.at(Tok.END):
            body = ast.UnitLit(span)
        else:
            items = self.sequence(Tok.END)
            body = items[0] if len(items) == 1 else ast.Seq(span, items)
        self.expect(Tok.END)
        return ast.Let(span, decls, body)


def parse(source: str) -> ast.Program:
    return Parser(lex(source)).program()


def parse_exp(source: str) -> ast.Exp:
    """Parse a single expression — the tests use it, the compiler does not."""
    p = Parser(lex(source))
    e = p.exp(0)
    if not p.at(Tok.EOF):
        raise ParseError(p.cur.span, f"unexpected {p.cur} after the expression")
    return e

