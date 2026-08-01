/**
 * Semantic types, and the symbols that carry them.
 *
 * Types are monomorphic.  Records are nominal — two record types with the same
 * fields are different types — and everything else is structural, which for this
 * language means arrays compare by their element type.
 */

package wolv

import wolv.ir.*

sealed interface Type

data object IntT : Type {
    override fun toString(): String = "int"
}

data object StringT : Type {
    override fun toString(): String = "string"
}

data object BoolT : Type {
    override fun toString(): String = "bool"
}

data object UnitT : Type {
    override fun toString(): String = "unit"
}

/** The type of `nil` before it is known which record it stands for. */
data object NilT : Type {
    override fun toString(): String = "nil"
}

class RecordT(val name: String) : Type {
    val fields: MutableList<Pair<String, Type>> = mutableListOf()

    fun index(name: String): Int = fields.indexOfFirst { it.first == name }

    fun fieldType(name: String): Type? = fields.firstOrNull { it.first == name }?.second

    override fun toString(): String = name
}

class ArrayT(val elem: Type) : Type {
    override fun toString(): String = "$elem array"
}

/** Type equality: nominal for records, structural for arrays. */
fun same(a: Type, b: Type): Boolean = when {
    a is RecordT && b is RecordT -> a === b
    a is ArrayT && b is ArrayT -> same(a.elem, b.elem)
    else -> a::class == b::class
}

/** Equality, but `nil` stands in for any record. */
fun compatible(a: Type, b: Type): Boolean = when {
    a is NilT && (b is RecordT || b is NilT) -> true
    (a is RecordT || a is NilT) && b is NilT -> true
    else -> same(a, b)
}

// -- symbols ------------------------------------------------------------------

/** What a name can be bound to: a variable, or a function. */
sealed interface Sym

/**
 * One binding occurrence of a variable.
 *
 * `depth` is the static nesting depth of the function that binds it.  A variable
 * read from a deeper function escapes, and then it lives in a frame slot instead
 * of a register.
 */
class VarSym(
    val name: String,
    val ty: Type,
    val mutable: Boolean,
    val depth: Int,
) : Sym {
    var escapes: Boolean = false
    var slot: Int = -1
    var reg: Int = -1

    override fun toString(): String = name
}

/** A function.  Functions are not values, so there is no function type. */
class FunSym(
    val name: String,
    val label: String,
    val params: List<VarSym>,
    val result: Type,
    val depth: Int,
    val builtin: String? = null,
) : Sym {
    override fun toString(): String = name
}
