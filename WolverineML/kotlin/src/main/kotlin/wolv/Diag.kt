/** Source positions, and the one exception every pass raises. */

package wolv

import wolv.ir.*

/** A position in the source, counted from one. */
data class Span(val line: Int, val col: Int) {
    override fun toString(): String = "$line:$col"
}

/** A user-facing compile error, carrying where it happened. */
open class WolvError(val span: Span, override val message: String) : Exception() {
    override fun toString(): String = "$span: $message"
}

class LexError(span: Span, message: String) : WolvError(span, message)

class ParseError(span: Span, message: String) : WolvError(span, message)

class TypeCheckError(span: Span, message: String) : WolvError(span, message)
