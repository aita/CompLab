/**
 * A Pratt parser.
 *
 * Every expression form is either a prefix form (`nud`, in `atom`) or an infix
 * one (`led`, in `exp`), and the table below is the whole of the precedence.
 * The prefix forms that end in an expression — `if`, `while`, `for`, `:=` — take
 * their tail at binding power 0, so `if c then x := 1 else x := 2` reads the way
 * it looks.
 */

package wolv

import wolv.ast.*

val BP: Map<Tok, Pair<Int, Int>> = mapOf(
    Tok.ASSIGN to (2 to 1),
    Tok.ORELSE to (4 to 5),
    Tok.ANDALSO to (6 to 7),
    Tok.EQ to (8 to 9),
    Tok.NE to (8 to 9),
    Tok.LT to (8 to 9),
    Tok.LE to (8 to 9),
    Tok.GT to (8 to 9),
    Tok.GE to (8 to 9),
    Tok.CARET to (10 to 11),
    Tok.PLUS to (12 to 13),
    Tok.MINUS to (12 to 13),
    Tok.STAR to (14 to 15),
    Tok.SLASH to (14 to 15),
    Tok.MOD to (14 to 15),
)

const val UNARY_BP = 16

val BINOPS: Map<Tok, String> = mapOf(
    Tok.PLUS to "+",
    Tok.MINUS to "-",
    Tok.STAR to "*",
    Tok.SLASH to "/",
    Tok.MOD to "mod",
    Tok.CARET to "^",
    Tok.EQ to "=",
    Tok.NE to "<>",
    Tok.LT to "<",
    Tok.LE to "<=",
    Tok.GT to ">",
    Tok.GE to ">=",
)

val DECL_STARTERS: Set<Tok> = setOf(Tok.VAL, Tok.VAR, Tok.FUN, Tok.TYPE)

fun parse(source: String): Program = Parse(lex(source)).program()

/** Parse a single expression — the tests use it, the compiler does not. */
fun parseExp(source: String): Exp {
    val p = Parse(lex(source))
    val e = p.exp(0)
    if (!p.at(Tok.EOF)) throw ParseError(p.cur.span, "unexpected ${p.cur} after the expression")
    return e
}

class Parse(private val toks: List<Token>) {
private var pos = 0

// -- token plumbing ---------------------------------------------------

val cur: Token get() = toks[pos]

fun at(kind: Tok): Boolean = cur.kind == kind

fun take(kind: Tok): Token? {
    if (cur.kind != kind) return null
    return cur.also { pos += 1 }
}

fun expect(kind: Tok): Token =
    take(kind) ?: throw ParseError(cur.span, "expected `${kind.text}`, found $cur")

fun expectIdent(): Token =
    take(Tok.IDENT) ?: throw ParseError(cur.span, "expected a name, found $cur")

// -- programs and declarations ----------------------------------------

fun program(): Program {
    val decls = mutableListOf<Decl>()
    while (!at(Tok.EOF)) decls.add(decl())
    return Program(decls)
}

fun decl(): Decl = when (cur.kind) {
    Tok.TYPE -> typeDecl()
    Tok.VAL, Tok.VAR -> valDecl()
    Tok.FUN -> funDecl()
    else -> throw ParseError(
        cur.span,
        "expected a declaration (`val`, `var`, `fun`, `type`), found $cur",
    )
}

fun typeDecl(): TypeDecl {
    val span = expect(Tok.TYPE).span
    val binds = mutableListOf(typeBind())
    while (take(Tok.AND) != null) binds.add(typeBind())
    return TypeDecl(span, binds)
}

fun typeBind(): TypeBind {
    val name = expectIdent()
    expect(Tok.EQ)
    return TypeBind(name.text, ty(), name.span)
}

fun valDecl(): ValDecl {
    val mutable = cur.kind == Tok.VAR
    val span = cur.span
    pos += 1
    val name: String?
    if (take(Tok.LPAREN) != null) {
        expect(Tok.RPAREN)
        name = null
    } else {
        name = expectIdent().text
    }
    val ty = if (take(Tok.COLON) != null) ty() else null
    expect(Tok.EQ)
    return ValDecl(span, name, ty, exp(0), mutable)
}

fun funDecl(): FunDecl {
    val span = expect(Tok.FUN).span
    val binds = mutableListOf(funBind())
    while (take(Tok.AND) != null) binds.add(funBind())
    return FunDecl(span, binds)
}

fun funBind(): FunBind {
    val name = expectIdent()
    expect(Tok.LPAREN)
    val params = mutableListOf<Param>()
    if (take(Tok.RPAREN) == null) {
        while (true) {
            val pname = expectIdent()
            expect(Tok.COLON)
            params.add(Param(pname.text, ty(), pname.span))
            if (take(Tok.COMMA) == null) break
        }
        expect(Tok.RPAREN)
    }
    val result = if (take(Tok.COLON) != null) ty() else null
    expect(Tok.EQ)
    return FunBind(name.text, params, result, exp(0), name.span)
}

// -- types ------------------------------------------------------------

fun ty(): TyExp {
    val span = cur.span
    var base: TyExp
    if (take(Tok.LBRACE) != null) {
        val fields = mutableListOf<TyField>()
        if (take(Tok.RBRACE) == null) {
            while (true) {
                val fname = expectIdent()
                expect(Tok.COLON)
                fields.add(TyField(fname.text, ty(), fname.span))
                if (take(Tok.COMMA) == null) break
            }
            expect(Tok.RBRACE)
        }
        base = TyRecord(span, fields)
    } else if (take(Tok.LPAREN) != null) {
        base = ty()
        expect(Tok.RPAREN)
    } else {
        base = TyName(span, expectIdent().text)
    }
    while (cur.kind == Tok.IDENT && cur.text == "array") {
        pos += 1
        base = TyArray(span, base)
    }
    return base
}

// -- expressions ------------------------------------------------------

fun exp(minBp: Int): Exp {
    var left = atom()
    while (true) {
        val bp = BP[cur.kind]
        if (bp == null || bp.first < minBp) return left
        val tok = cur
        pos += 1
        left = when (tok.kind) {
            Tok.ASSIGN -> {
                checkLvalue(left)
                Assign(tok.span, left, exp(bp.second))
            }
            Tok.ANDALSO, Tok.ORELSE -> Logic(tok.span, tok.text, left, exp(bp.second))
            else -> Bin(tok.span, BINOPS.getValue(tok.kind), left, exp(bp.second))
        }
    }
}

fun checkLvalue(e: Exp) {
    when (e) {
        is Var, is Index, is Field -> return
        else -> throw ParseError(e.span, "the left of `:=` is not assignable")
    }
}

fun atom(): Exp {
    val tok = cur
    val span = tok.span
    return when (tok.kind) {
        Tok.INT -> {
            pos += 1
            postfix(IntLit(span, integer(tok)))
        }
        Tok.STRING -> {
            pos += 1
            postfix(StrLit(span, tok.text))
        }
        Tok.TRUE, Tok.FALSE -> {
            pos += 1
            BoolLit(span, tok.kind == Tok.TRUE)
        }
        Tok.NIL -> {
            pos += 1
            NilLit(span)
        }
        Tok.BREAK -> {
            pos += 1
            Break(span)
        }
        Tok.TILDE -> {
            pos += 1
            Neg(span, exp(UNARY_BP))
        }
        Tok.MINUS -> throw ParseError(span, "negation is written `~`, not `-`")
        Tok.LPAREN -> postfix(parens())
        Tok.IDENT -> postfix(named())
        Tok.IF -> ifExp()
        Tok.WHILE -> whileExp()
        Tok.FOR -> forExp()
        Tok.LET -> letExp()
        else -> throw ParseError(span, "expected an expression, found $cur")
    }
}

/** Integers are 64 bits and wrap, so `9223372036854775808` is `~9223372036854775808`. */
fun integer(tok: Token): Long =
    tok.text.toULongOrNull()?.toLong()
        ?: throw ParseError(tok.span, "`${tok.text}` does not fit in 64 bits")

fun parens(): Exp {
    val span = expect(Tok.LPAREN).span
    if (take(Tok.RPAREN) != null) return UnitLit(span)
    val items = sequence(Tok.RPAREN)
    expect(Tok.RPAREN)
    return if (items.size == 1) items[0] else Seq(span, items)
}

fun sequence(end: Tok): List<Exp> {
    val items = mutableListOf(exp(0))
    while (take(Tok.SEMI) != null) {
        if (at(end)) break
        items.add(exp(0))
    }
    return items
}

fun named(): Exp {
    val tok = expectIdent()
    return when (cur.kind) {
        Tok.LPAREN -> {
            pos += 1
            val args = mutableListOf<Exp>()
            if (take(Tok.RPAREN) == null) {
                while (true) {
                    args.add(exp(0))
                    if (take(Tok.COMMA) == null) break
                }
                expect(Tok.RPAREN)
            }
            Call(tok.span, tok.text, args)
        }
        Tok.LBRACE -> {
            pos += 1
            val fields = mutableListOf<FieldInit>()
            if (take(Tok.RBRACE) == null) {
                while (true) {
                    val fname = expectIdent()
                    expect(Tok.EQ)
                    fields.add(FieldInit(fname.text, exp(0), fname.span))
                    if (take(Tok.COMMA) == null) break
                }
                expect(Tok.RBRACE)
            }
            RecordLit(tok.span, tok.text, fields)
        }
        else -> Var(tok.span, tok.text)
    }
}

fun postfix(start: Exp): Exp {
    var base = start
    while (true) {
        when (cur.kind) {
            Tok.LBRACK -> {
                val span = cur.span
                pos += 1
                val index = exp(0)
                expect(Tok.RBRACK)
                base = Index(span, base, index)
            }
            Tok.DOT -> {
                val span = cur.span
                pos += 1
                base = Field(span, base, expectIdent().text)
            }
            else -> return base
        }
    }
}

fun ifExp(): Exp {
    val span = expect(Tok.IF).span
    val cond = exp(0)
    expect(Tok.THEN)
    val then = exp(0)
    val els = if (take(Tok.ELSE) != null) exp(0) else null
    return If(span, cond, then, els)
}

fun whileExp(): Exp {
    val span = expect(Tok.WHILE).span
    val cond = exp(0)
    expect(Tok.DO)
    return While(span, cond, exp(0))
}

fun forExp(): Exp {
    val span = expect(Tok.FOR).span
    val name = expectIdent()
    expect(Tok.EQ)
    val lo = exp(0)
    expect(Tok.TO)
    val hi = exp(0)
    expect(Tok.DO)
    return For(span, name.text, lo, hi, exp(0))
}

fun letExp(): Exp {
    val span = expect(Tok.LET).span
    val decls = mutableListOf<Decl>()
    while (cur.kind in DECL_STARTERS) decls.add(decl())
    expect(Tok.IN)
    val body: Exp = if (at(Tok.END)) {
        UnitLit(span)
    } else {
        val items = sequence(Tok.END)
        if (items.size == 1) items[0] else Seq(span, items)
    }
    expect(Tok.END)
    return Let(span, decls, body)
}
}
