/**
 * The syntax tree.
 *
 * The tree the parser builds is untyped; the checker fills in the `ty` and `sym`
 * fields as it goes, and everything after it reads them.
 */

package wolv.ast

import wolv.FunSym
import wolv.Span
import wolv.Type
import wolv.VarSym

// -- types as they are written --------------------------------------------

sealed class TyExp(val span: Span)

class TyName(span: Span, val name: String) : TyExp(span)

class TyArray(span: Span, val elem: TyExp) : TyExp(span)

class TyField(val name: String, val ty: TyExp, val span: Span)

class TyRecord(span: Span, val fields: List<TyField>) : TyExp(span)

// -- expressions ----------------------------------------------------------

sealed class Exp(val span: Span) {
    var ty: Type? = null
}

class IntLit(span: Span, val value: Long) : Exp(span)

class StrLit(span: Span, val value: String) : Exp(span)

class BoolLit(span: Span, val value: Boolean) : Exp(span)

class NilLit(span: Span) : Exp(span)

class UnitLit(span: Span) : Exp(span)

class Var(span: Span, val name: String) : Exp(span) {
    var sym: VarSym? = null
}

class Call(span: Span, val name: String, val args: List<Exp>) : Exp(span) {
    var sym: FunSym? = null
}

class FieldInit(val name: String, val value: Exp, val span: Span)

class RecordLit(span: Span, val tyname: String, var fields: List<FieldInit>) : Exp(span)

class Index(span: Span, val array: Exp, val index: Exp) : Exp(span)

class Field(span: Span, val record: Exp, val name: String) : Exp(span) {
    /** Which word of the record this reads.  Null until the checker knows. */
    var offset: Int? = null
}

class Neg(span: Span, val operand: Exp) : Exp(span)

class Bin(span: Span, val op: String, val lhs: Exp, val rhs: Exp) : Exp(span)

/** `andalso` and `orelse`, which are control flow, not operators. */
class Logic(span: Span, val op: String, val lhs: Exp, val rhs: Exp) : Exp(span)

class Assign(span: Span, val target: Exp, val value: Exp) : Exp(span)

class If(span: Span, val cond: Exp, val then: Exp, val els: Exp?) : Exp(span)

class While(span: Span, val cond: Exp, val body: Exp) : Exp(span)

class For(span: Span, val name: String, val lo: Exp, val hi: Exp, val body: Exp) : Exp(span) {
    var sym: VarSym? = null
}

class Break(span: Span) : Exp(span)

class Seq(span: Span, val items: List<Exp>) : Exp(span)

class Let(span: Span, val decls: List<Decl>, val body: Exp) : Exp(span)

// -- declarations ---------------------------------------------------------

sealed class Decl(val span: Span)

class TypeBind(val name: String, val ty: TyExp, val span: Span)

class TypeDecl(span: Span, val binds: List<TypeBind>) : Decl(span)

class ValDecl(
    span: Span,
    val name: String?,
    val ty: TyExp?,
    val init: Exp,
    val mutable: Boolean,
) : Decl(span) {
    var sym: VarSym? = null
}

class Param(val name: String, val ty: TyExp, val span: Span) {
    var sym: VarSym? = null
}

class FunBind(
    val name: String,
    val params: List<Param>,
    val result: TyExp?,
    val body: Exp,
    val span: Span,
) {
    var sym: FunSym? = null
}

class FunDecl(span: Span, val binds: List<FunBind>) : Decl(span)

class Program(val decls: List<Decl>)
