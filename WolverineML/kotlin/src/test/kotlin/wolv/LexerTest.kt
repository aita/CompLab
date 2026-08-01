package wolv

import wolv.allocator.*
import wolv.ir.*
import wolv.ast.*

import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class LexerTest {
    private fun kinds(source: String): List<Tok> = lex(source).map { it.kind }

    private fun refuses(source: String, message: String) {
        val error = assertFailsWith<LexError> { lex(source) }
        assertContains(error.message, message)
    }

    @Test
    fun `keywords are not identifiers`() {
        assertEquals(listOf(Tok.LET, Tok.VAL, Tok.EOF), kinds("let val"))
        assertEquals(listOf(Tok.IDENT, Tok.EOF), kinds("letter"))
    }

    @Test
    fun `longest punctuation wins`() {
        assertEquals(
            listOf(Tok.ASSIGN, Tok.COLON, Tok.LE, Tok.LT, Tok.NE, Tok.GE, Tok.EOF),
            kinds(":= : <= < <> >="),
        )
    }

    @Test
    fun `comments nest`() {
        assertEquals(listOf(Tok.INT, Tok.EOF), kinds("(* a (* b *) c *) 1"))
    }

    @Test
    fun `an unterminated comment is caught`() = refuses("(* forever", "unterminated comment")

    @Test
    fun `string escapes`() {
        assertEquals("a\nb\t\"\\A", lex("\"a\\nb\\t\\\"\\\\\\065\"")[0].text)
    }

    @Test
    fun `a string is bytes`() {
        // Source text contributes its UTF-8; `\ddd` names one byte of it.
        val japanese = "日".toByteArray(Charsets.UTF_8)
            .map { (it.toInt() and 0xFF).toChar() }
            .joinToString("")
        assertEquals(japanese, lex("\"日\"")[0].text)
        assertEquals(japanese, lex("\"\\230\\151\\165\"")[0].text)
        assertEquals(9, lex("\"日本語\"")[0].text.length)
    }

    @Test
    fun `a character outside the basic plane is four bytes and one column`() {
        val emoji = "\uD83D\uDE00" // U+1F600, a surrogate pair in UTF-16
        assertEquals(4, lex("\"$emoji\"")[0].text.length)
        assertEquals(
            emoji.toByteArray(Charsets.UTF_8).map { (it.toInt() and 0xFF).toChar() }.joinToString(""),
            lex("\"$emoji\"")[0].text,
        )
        // The pair is one character, so a column counts it once: `(*x*) x` would
        // put the name in the same place.
        assertEquals(Span(1, 7), lex("(*$emoji*) x")[0].span)
    }

    @Test
    fun `a name may be written in any script`() {
        assertEquals(listOf(Tok.IDENT, Tok.EOF), kinds("名前"))
    }

    @Test
    fun `a numeric escape is three digits`() = refuses("\"\\65\"", "three digits")

    @Test
    fun `a string may not span lines`() = refuses("\"one\ntwo\"", "may not span lines")

    @Test
    fun `spans count from one`() {
        val tokens = lex("val\n  x")
        assertEquals(Span(1, 1), tokens[0].span)
        assertEquals(Span(2, 3), tokens[1].span)
    }

    @Test
    fun `a number may not run into a name`() = refuses("12ab", "is not a number")

    @Test
    fun `a stray character is caught`() = refuses("a ? b", "stray character")
}
