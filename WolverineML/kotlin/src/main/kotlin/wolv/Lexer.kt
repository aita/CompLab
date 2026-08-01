/** Tokens, and the hand-written scanner that produces them. */

package wolv

import wolv.ir.*

/** A token kind.  The text is what an error message calls it. */
enum class Tok(val text: String) {
    INT("an integer"),
    STRING("a string"),
    IDENT("an identifier"),
    EOF("end of input"),

    AND("and"),
    ANDALSO("andalso"),
    BREAK("break"),
    DO("do"),
    ELSE("else"),
    END("end"),
    FALSE("false"),
    FOR("for"),
    FUN("fun"),
    IF("if"),
    IN("in"),
    LET("let"),
    MOD("mod"),
    NIL("nil"),
    ORELSE("orelse"),
    THEN("then"),
    TO("to"),
    TRUE("true"),
    TYPE("type"),
    VAL("val"),
    VAR("var"),
    WHILE("while"),

    LPAREN("("),
    RPAREN(")"),
    LBRACK("["),
    RBRACK("]"),
    LBRACE("{"),
    RBRACE("}"),
    COMMA(","),
    COLON(":"),
    SEMI(";"),
    DOT("."),
    ASSIGN(":="),
    EQ("="),
    NE("<>"),
    LE("<="),
    LT("<"),
    GE(">="),
    GT(">"),
    PLUS("+"),
    MINUS("-"),
    STAR("*"),
    SLASH("/"),
    CARET("^"),
    TILDE("~"),
}

data class Token(val kind: Tok, val text: String, val span: Span) {
    override fun toString(): String = when (kind) {
        Tok.EOF -> "end of input"
        Tok.STRING -> "\"$text\""
        else -> "`$text`"
    }
}

val KEYWORDS: Map<String, Tok> =
    Tok.entries.filter { it.text.all(Char::isLetter) }.associateBy { it.text }

// Longest first, so that `:=` beats `:` and `<=` beats `<`.
val PUNCTUATION: List<Tok> =
    Tok.entries.filterNot { it.text[0].isLetter() }.sortedByDescending { it.text.length }

val ESCAPES: Map<Int, Char> = mapOf(
    'n'.code to '\n',
    't'.code to '\t',
    'r'.code to '\r',
    '"'.code to '"',
    '\\'.code to '\\',
)

fun lex(source: String): List<Token> = Scanner(source).tokens()

/**
 * Turns source text into a list of tokens, in one pass, no regexes.
 *
 * The scanner reads code points and not UTF-16 units, so a character outside the
 * basic plane is one character everywhere it matters: it is one column, it is a
 * letter if Unicode says it is, and inside a string literal it contributes the
 * UTF-8 bytes of the whole of itself rather than of half a surrogate pair.
 */
private class Scanner(val src: String) {
var pos = 0
var line = 1
var col = 1

fun tokens(): List<Token> {
    val out = mutableListOf<Token>()
    while (true) {
        val tok = next()
        out.add(tok)
        if (tok.kind == Tok.EOF) return out
    }
}

// -- reading code points ----------------------------------------------

val done: Boolean get() = pos >= src.length

/** The code point under the cursor. */
fun here(): Int = src.codePointAt(pos)

/** Move on by `units` UTF-16 units, counting columns in code points. */
fun advance(units: Int) {
    repeat(units) {
        when {
            src[pos] == '\n' -> {
                line += 1
                col = 1
            }
            Character.isLowSurrogate(src[pos]) -> {}
            else -> col += 1
        }
        pos += 1
    }
}

/** Move on by one code point. */
fun step() = advance(Character.charCount(here()))

fun span(): Span = Span(line, col)

// -- the scanner ------------------------------------------------------

fun next(): Token {
    skipTrivia()
    val span = span()
    if (done) return Token(Tok.EOF, "", span)

    val ch = here()
    if (Character.isDigit(ch)) return number(span)
    if (Character.isLetter(ch) || ch == '_'.code) return word(span)
    if (ch == '"'.code) return string(span)
    for (kind in PUNCTUATION) {
        if (src.startsWith(kind.text, pos)) {
            advance(kind.text.length)
            return Token(kind, kind.text, span)
        }
    }
    throw LexError(span, "stray character `${asText(ch)}`")
}

fun number(span: Span): Token {
    val start = pos
    while (!done && Character.isDigit(here())) step()
    val text = src.substring(start, pos)
    if (!done && (Character.isLetter(here()) || here() == '_'.code)) {
        throw LexError(span, "`$text${asText(here())}` is not a number")
    }
    return Token(Tok.INT, text, span)
}

fun word(span: Span): Token {
    val start = pos
    while (!done && (Character.isLetterOrDigit(here()) || here() in WORD_PUNCTUATION)) step()
    val text = src.substring(start, pos)
    return Token(KEYWORDS[text] ?: Tok.IDENT, text, span)
}

/**
 * Scan a string literal, which is a sequence of bytes.
 *
 * `size`, `ord` and `substring` count bytes at run time, so a literal is
 * read as bytes here too: source text contributes its UTF-8 encoding, and
 * `\ddd` names one byte.  Each byte is kept as one character, which is what
 * `escape` writes back out.
 */
fun string(span: Span): Token {
    step()
    val parts = StringBuilder()
    while (true) {
        if (done) throw LexError(span, "unterminated string")
        val ch = here()
        when {
            ch == '"'.code -> {
                step()
                return Token(Tok.STRING, parts.toString(), span)
            }
            ch == '\n'.code -> throw LexError(span(), "a string may not span lines")
            ch == '\\'.code -> {
                step()
                parts.append(escape())
            }
            ch < 0x80 -> {
                step()
                parts.append(ch.toChar())
            }
            else -> {
                // One code point, surrogate pair and all, as its UTF-8 bytes.
                val point = asText(ch)
                step()
                for (byte in point.toByteArray(Charsets.UTF_8)) {
                    parts.append((byte.toInt() and 0xFF).toChar())
                }
            }
        }
    }
}

fun escape(): Char {
    if (done) throw LexError(span(), "unterminated escape")
    val ch = here()
    if (Character.isDigit(ch)) {
        val value = (0 until 3).fold(0) { acc, i ->
            val digit = if (pos + i < src.length) Character.digit(src[pos + i], 10) else -1
            if (acc < 0 || digit < 0) -1 else acc * 10 + digit
        }
        if (value in 0..255) {
            advance(3)
            return value.toChar()
        }
        throw LexError(span(), "a numeric escape is three digits, `\\065`")
    }
    return ESCAPES[ch]?.also { step() }
        ?: throw LexError(span(), "unknown escape `\\${asText(ch)}`")
}

fun skipTrivia() {
    while (!done) {
        if (src[pos] in " \t\r\n") advance(1)
        else if (src.startsWith("(*", pos)) comment()
        else return
    }
}

fun comment() {
    val span = span()
    var depth = 0
    while (!done) {
        if (src.startsWith("(*", pos)) {
            depth += 1
            advance(2)
        } else if (src.startsWith("*)", pos)) {
            depth -= 1
            advance(2)
            if (depth == 0) return
        } else {
            step()
        }
    }
    throw LexError(span, "unterminated comment")
}

companion object {
    val WORD_PUNCTUATION = listOf('_'.code, '\''.code)

    /** One code point written back out, surrogate pair and all. */
    fun asText(codePoint: Int): String = String(Character.toChars(codePoint))
}
}
