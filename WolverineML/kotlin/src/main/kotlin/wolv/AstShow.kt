/** An indented dump of the typed syntax tree, for `wolv emit -s ast`. */

package wolv

import wolv.ast.*

fun showProgram(prog: Program): String {
    val lines = mutableListOf<String>()
    for (decl in prog.decls) decl(decl, 0, lines)
    return lines.joinToString("\n") + "\n"
}

private fun put(lines: MutableList<String>, depth: Int, text: String) {
    lines.add("  ".repeat(depth) + text)
}

private fun ty(e: Exp): String = e.ty?.let { " : $it" } ?: ""

/**
 * A string literal, written the way the Python tree writes it, so that a dump
 * taken from either is the same dump.  Every character of one is a byte, and
 * a byte that stands for nothing printable is shown as `\xNN`.
 */
private fun quoted(text: String): String {
    val quote = if ('\'' in text && '"' !in text) '"' else '\''
    val out = StringBuilder().append(quote)
    for (ch in text) {
        when {
            ch == quote || ch == '\\' -> out.append('\\').append(ch)
            ch == '\n' -> out.append("\\n")
            ch == '\r' -> out.append("\\r")
            ch == '\t' -> out.append("\\t")
            printable(ch) -> out.append(ch)
            else -> out.append("\\x%02x".format(ch.code))
        }
    }
    return out.append(quote).toString()
}

/** What Python calls printable: anything but a control, a format or a stray space. */
private fun printable(ch: Char): Boolean = when (Character.getType(ch).toByte()) {
    Character.CONTROL, Character.FORMAT, Character.SURROGATE, Character.PRIVATE_USE,
    Character.UNASSIGNED, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR,
    Character.SPACE_SEPARATOR,
    -> ch == ' '
    else -> true
}

private fun decl(decl: Decl, depth: Int, lines: MutableList<String>) {
    when (decl) {
        is TypeDecl -> for (t in decl.binds) put(lines, depth, "type ${t.name}")
        is ValDecl -> {
            val keyword = if (decl.mutable) "var" else "val"
            val home = if (decl.sym?.escapes == true) " (escapes)" else ""
            put(lines, depth, "$keyword ${decl.name ?: "()"}$home")
            exp(decl.init, depth + 1, lines)
        }
        is FunDecl -> for (f in decl.binds) {
            val params = f.params.joinToString(", ") {
                it.name + if (it.sym?.escapes == true) " (escapes)" else ""
            }
            val result = f.sym?.result ?: "?"
            put(lines, depth, "fun ${f.name}($params) : $result")
            exp(f.body, depth + 1, lines)
        }
    }
}

private fun exp(e: Exp, depth: Int, lines: MutableList<String>) {
    when (e) {
        is IntLit -> put(lines, depth, "int ${e.value}")
        is StrLit -> put(lines, depth, "string ${quoted(e.value)}")
        is BoolLit -> put(lines, depth, "bool ${if (e.value) "true" else "false"}")
        is NilLit -> put(lines, depth, "nil")
        is UnitLit -> put(lines, depth, "()")
        is Var -> put(lines, depth, "var ${e.name}${ty(e)}")
        is Call -> {
            put(lines, depth, "call ${e.name}${ty(e)}")
            for (a in e.args) exp(a, depth + 1, lines)
        }
        is RecordLit -> {
            put(lines, depth, "record ${e.tyname}${ty(e)}")
            for (f in e.fields) {
                put(lines, depth + 1, "${f.name} =")
                exp(f.value, depth + 2, lines)
            }
        }
        is Index -> {
            put(lines, depth, "index${ty(e)}")
            exp(e.array, depth + 1, lines)
            exp(e.index, depth + 1, lines)
        }
        is Field -> {
            put(lines, depth, "field .${e.name}${ty(e)}")
            exp(e.record, depth + 1, lines)
        }
        is Neg -> {
            put(lines, depth, "neg")
            exp(e.operand, depth + 1, lines)
        }
        is Bin -> {
            put(lines, depth, "${e.op}${ty(e)}")
            exp(e.lhs, depth + 1, lines)
            exp(e.rhs, depth + 1, lines)
        }
        is Logic -> {
            put(lines, depth, "${e.op}${ty(e)}")
            exp(e.lhs, depth + 1, lines)
            exp(e.rhs, depth + 1, lines)
        }
        is Assign -> {
            put(lines, depth, ":=")
            exp(e.target, depth + 1, lines)
            exp(e.value, depth + 1, lines)
        }
        is If -> {
            put(lines, depth, "if${ty(e)}")
            exp(e.cond, depth + 1, lines)
            exp(e.then, depth + 1, lines)
            e.els?.let { exp(it, depth + 1, lines) }
        }
        is While -> {
            put(lines, depth, "while")
            exp(e.cond, depth + 1, lines)
            exp(e.body, depth + 1, lines)
        }
        is For -> {
            val escapes = if (e.sym?.escapes == true) " (escapes)" else ""
            put(lines, depth, "for ${e.name}$escapes")
            exp(e.lo, depth + 1, lines)
            exp(e.hi, depth + 1, lines)
            exp(e.body, depth + 1, lines)
        }
        is Break -> put(lines, depth, "break")
        is Seq -> {
            put(lines, depth, "seq${ty(e)}")
            for (item in e.items) exp(item, depth + 1, lines)
        }
        is Let -> {
            put(lines, depth, "let${ty(e)}")
            for (d in e.decls) decl(d, depth + 1, lines)
            put(lines, depth, "in")
            exp(e.body, depth + 1, lines)
        }
    }
}
