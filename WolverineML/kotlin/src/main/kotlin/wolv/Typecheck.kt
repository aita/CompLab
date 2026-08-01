/**
 * The type checker, which also decides which variables escape.
 *
 * Types are monomorphic and there is nothing to infer but the type of a `val`.
 * A `fun` without a result type is a procedure and returns `unit`, which is what
 * makes recursion checkable without inference: every function's signature is
 * known before any body is.
 *
 * The pass has a second job.  A variable read from inside a function nested more
 * deeply than the one that binds it cannot live in a register, because the inner
 * function reaches it through a static link at run time.  Every lookup that
 * crosses a function boundary marks the variable as escaping, and the lowering
 * pass gives those a frame slot instead.
 */

package wolv

import wolv.ast.*

val BUILTIN_SIGS: List<Builtin> = listOf(
    Builtin("print", listOf(StringT), UnitT, "wol_print"),
    Builtin("println", listOf(StringT), UnitT, "wol_println"),
    Builtin("printInt", listOf(IntT), UnitT, "wol_print_int"),
    Builtin("flush", listOf(), UnitT, "wol_flush"),
    Builtin("getChar", listOf(), StringT, "wol_getchar"),
    Builtin("ord", listOf(StringT), IntT, "wol_ord"),
    Builtin("chr", listOf(IntT), StringT, "wol_chr"),
    Builtin("size", listOf(StringT), IntT, "wol_size"),
    Builtin("substring", listOf(StringT, IntT, IntT), StringT, "wol_substring"),
    Builtin("concat", listOf(StringT, StringT), StringT, "wol_concat"),
    Builtin("intToString", listOf(IntT), StringT, "wol_int_to_string"),
    Builtin("stringToInt", listOf(StringT), IntT, "wol_string_to_int"),
    Builtin("exit", listOf(IntT), UnitT, "wol_exit"),
)

val ARITHMETIC: Set<String> = setOf("+", "-", "*", "/", "mod")
val ORDERINGS: Set<String> = setOf("<", "<=", ">", ">=")
val EQUALITIES: Set<String> = setOf("=", "<>")

class Builtin(val name: String, val params: List<Type>, val result: Type, val symbol: String)

/** Type the program in place: every node comes back with its `ty` filled in. */
fun check(prog: Program) {
    Checker().program(prog)
}

private class Scope(
    val types: MutableMap<String, Type> = mutableMapOf(),
    val vals: MutableMap<String, Sym> = mutableMapOf(),
)

private class Checker {
    val scopes: MutableList<Scope> = mutableListOf(prelude())
    var depth = 0
    var loops = 0
    val labels: MutableMap<String, Int> = mutableMapOf()

    fun prelude(): Scope {
        val types: MutableMap<String, Type> = mutableMapOf(
            "int" to IntT,
            "string" to StringT,
            "bool" to BoolT,
            "unit" to UnitT,
        )
        val vals: MutableMap<String, Sym> = mutableMapOf()
        for (sig in BUILTIN_SIGS) {
            vals[sig.name] = FunSym(
                name = sig.name,
                label = sig.symbol,
                params = sig.params.mapIndexed { i, t -> VarSym("a$i", t, false, 0) },
                result = sig.result,
                depth = 0,
                builtin = sig.symbol,
            )
        }
        for (name in listOf("array", "length", "not")) {
            vals[name] = FunSym(name, name, listOf(), UnitT, 0, builtin = name)
        }
        return Scope(types, vals)
    }

    // -- scopes -----------------------------------------------------------

    fun push() = scopes.add(Scope())

    fun pop() = scopes.removeAt(scopes.size - 1)

    fun bindVal(name: String, sym: Sym) {
        scopes.last().vals[name] = sym
    }

    fun bindType(name: String, ty: Type) {
        scopes.last().types[name] = ty
    }

    fun lookupVal(name: String, span: Span): Sym =
    scopes.asReversed().firstNotNullOfOrNull { it.vals[name] }
    ?: throw TypeCheckError(span, "`$name` is not bound")

    fun lookupType(name: String, span: Span): Type =
    scopes.asReversed().firstNotNullOfOrNull { it.types[name] }
    ?: throw TypeCheckError(span, "`$name` is not a type")

    fun uniqueLabel(name: String): String {
        val n = labels.getOrDefault(name, 0)
        labels[name] = n + 1
        return if (n == 0) "wol_$name" else "wol_$name.$n"
    }

    // -- programs ---------------------------------------------------------

    fun program(prog: Program) {
        push()
        decls(prog.decls)
        pop()
    }

    fun decls(decls: List<Decl>) {
        for (decl in decls) {
            when (decl) {
                is TypeDecl -> typeDecl(decl)
                is ValDecl -> valDecl(decl)
                is FunDecl -> funDecl(decl)
            }
        }
    }

    fun typeDecl(decl: TypeDecl) {
        // Records are bound before any field is resolved, so a group of `type`s
        // may name each other and itself.
        val records = decl.binds.mapNotNull { bind ->
            (bind.ty as? TyRecord)?.let { RecordT(bind.name).also { r -> bindType(bind.name, r) } to it }
        }
        for (bind in decl.binds) {
            if (bind.ty !is TyRecord) bindType(bind.name, resolve(bind.ty))
        }
        for ((rec, syntax) in records) {
            val seen = mutableSetOf<String>()
            for (f in syntax.fields) {
                if (!seen.add(f.name)) throw TypeCheckError(f.span, "duplicate field `${f.name}`")
                rec.fields.add(f.name to resolve(f.ty))
            }
        }
    }

    fun resolve(ty: TyExp): Type = when (ty) {
        is TyName -> lookupType(ty.name, ty.span)
        is TyArray -> ArrayT(resolve(ty.elem))
        is TyRecord ->
        throw TypeCheckError(ty.span, "a record type has to be given a name by `type`")
    }

    fun valDecl(decl: ValDecl) {
        var got = exp(decl.init)
        val want = decl.ty?.let { resolve(it) }
        if (want != null) {
            unify(want, got, decl.init.span, "in this binding")
            got = want
        }
        if (decl.name == null) {
            unify(UnitT, got, decl.init.span, "in `val () =`")
            return
        }
        if (got is NilT) {
            throw TypeCheckError(decl.span, "`${decl.name}` needs a type annotation to hold `nil`")
        }
        val sym = VarSym(decl.name, got, decl.mutable, depth)
        decl.sym = sym
        bindVal(decl.name, sym)
    }

    fun funDecl(decl: FunDecl) {
        for (bind in decl.binds) {
            val seen = mutableSetOf<String>()
            val params = bind.params.map { p ->
                if (!seen.add(p.name)) {
                    throw TypeCheckError(p.span, "duplicate parameter `${p.name}`")
                }
                VarSym(p.name, resolve(p.ty), false, depth + 1).also { p.sym = it }
            }
            val result = bind.result?.let { resolve(it) } ?: UnitT
            bind.sym = FunSym(
                name = bind.name,
                label = uniqueLabel(bind.name),
                params = params,
                result = result,
                depth = depth + 1,
            )
            bindVal(bind.name, bind.sym!!)
        }
        for (bind in decl.binds) {
            val signature = bind.sym!!
            depth += 1
            val outer = loops
            loops = 0
            push()
            for (p in bind.params) bindVal(p.name, p.sym!!)
            val got = exp(bind.body)
            unify(signature.result, got, bind.body.span, "in the body of `${bind.name}`")
            pop()
            loops = outer
            depth -= 1
        }
    }

    // -- expressions ------------------------------------------------------

    fun unify(want: Type, got: Type, span: Span, where: String) {
        if (!compatible(want, got)) {
            throw TypeCheckError(span, "expected `$want`, found `$got` $where")
        }
    }

    fun exp(e: Exp): Type {
        val ty = infer(e)
        e.ty = ty
        return ty
    }

    fun infer(e: Exp): Type = when (e) {
        is IntLit -> IntT
        is StrLit -> StringT
        is BoolLit -> BoolT
        is NilLit -> NilT
        is UnitLit -> UnitT
        is Var -> variable(e)
        is Call -> call(e)
        is RecordLit -> recordLit(e)
        is Index -> index(e)
        is Field -> field(e)
        is Neg -> {
            unify(IntT, exp(e.operand), e.span, "in a negation")
            IntT
        }
        is Bin -> binop(e)
        is Logic -> {
            unify(BoolT, exp(e.lhs), e.lhs.span, "on the left of `${e.op}`")
            unify(BoolT, exp(e.rhs), e.rhs.span, "on the right of `${e.op}`")
            BoolT
        }
        is Assign -> assign(e)
        is If -> ifExp(e)
        is While -> {
            unify(BoolT, exp(e.cond), e.cond.span, "as a `while` condition")
            loops += 1
            unify(UnitT, exp(e.body), e.body.span, "in a `while` body")
            loops -= 1
            UnitT
        }
        is For -> forExp(e)
        is Break -> {
            if (loops == 0) throw TypeCheckError(e.span, "`break` is outside any loop")
            UnitT
        }
        is Seq -> {
            var ty: Type = UnitT
            for (item in e.items) ty = exp(item)
            ty
        }
        is Let -> {
            push()
            decls(e.decls)
            val ty = exp(e.body)
            pop()
            ty
        }
    }

    fun variable(e: Var): Type {
        val sym = lookupVal(e.name, e.span)
        if (sym is FunSym) {
            throw TypeCheckError(e.span, "`${e.name}` is a function, and functions are not values")
        }
        val v = sym as VarSym
        if (v.depth < depth) v.escapes = true
        e.sym = v
        return v.ty
    }

    fun call(e: Call): Type {
        val sym = lookupVal(e.name, e.span)
        if (sym is VarSym) {
            throw TypeCheckError(e.span, "`${e.name}` is a variable, not a function")
        }
        val f = sym as FunSym
        e.sym = f
        when (f.builtin) {
            "array" -> return arrayCall(e)
            "length" -> return lengthCall(e)
            "not" -> {
                arity(e, 1)
                unify(BoolT, exp(e.args[0]), e.span, "in a call to `not`")
                return BoolT
            }
        }
        arity(e, f.params.size)
        for ((arg, param) in e.args.zip(f.params)) {
            unify(param.ty, exp(arg), arg.span, "in a call to `${e.name}`")
        }
        return f.result
    }

    fun arity(e: Call, want: Int) {
        if (e.args.size != want) {
            val plural = if (want == 1) "" else "s"
            throw TypeCheckError(
                e.span,
                "`${e.name}` takes $want argument$plural, given ${e.args.size}",
            )
        }
    }

    fun arrayCall(e: Call): Type {
        arity(e, 2)
        unify(IntT, exp(e.args[0]), e.args[0].span, "as an array length")
        val elem = exp(e.args[1])
        if (elem is NilT) {
            throw TypeCheckError(
                e.args[1].span,
                "`array` cannot tell which record `nil` stands for",
            )
        }
        return ArrayT(elem)
    }

    fun lengthCall(e: Call): Type {
        arity(e, 1)
        val arg = exp(e.args[0])
        if (arg !is ArrayT) {
            throw TypeCheckError(e.args[0].span, "`length` wants an array, found `$arg`")
        }
        return IntT
    }

    fun recordLit(e: RecordLit): Type {
        val rec = lookupType(e.tyname, e.span)
        if (rec !is RecordT) throw TypeCheckError(e.span, "`${e.tyname}` is not a record type")
        val given = mutableMapOf<String, FieldInit>()
        for (f in e.fields) {
            if (f.name in given) throw TypeCheckError(f.span, "field `${f.name}` is given twice")
            if (rec.index(f.name) < 0) {
                throw TypeCheckError(f.span, "`${rec.name}` has no field `${f.name}`")
            }
            given[f.name] = f
        }
        val ordered = mutableListOf<FieldInit>()
        for ((name, ty) in rec.fields) {
            val init = given[name] ?: throw TypeCheckError(e.span, "field `$name` is missing")
            unify(ty, exp(init.value), init.span, "in field `$name`")
            ordered.add(init)
        }
        e.fields = ordered
        return rec
    }

    fun index(e: Index): Type {
        val arr = exp(e.array)
        if (arr !is ArrayT) throw TypeCheckError(e.span, "`$arr` is not an array")
        unify(IntT, exp(e.index), e.index.span, "as an array index")
        return arr.elem
    }

    fun field(e: Field): Type {
        val rec = exp(e.record)
        if (rec !is RecordT) throw TypeCheckError(e.span, "`$rec` is not a record")
        val ty = rec.fieldType(e.name)
        ?: throw TypeCheckError(e.span, "`${rec.name}` has no field `${e.name}`")
        e.offset = rec.index(e.name)
        return ty
    }

    fun binop(e: Bin): Type {
        val lhs = exp(e.lhs)
        val rhs = exp(e.rhs)
        if (e.op in ARITHMETIC) {
            unify(IntT, lhs, e.lhs.span, "on the left of `${e.op}`")
            unify(IntT, rhs, e.rhs.span, "on the right of `${e.op}`")
            return IntT
        }
        if (e.op == "^") {
            unify(StringT, lhs, e.lhs.span, "on the left of `^`")
            unify(StringT, rhs, e.rhs.span, "on the right of `^`")
            return StringT
        }
        if (e.op in ORDERINGS) {
            if (lhs is IntT || lhs is StringT) {
                unify(lhs, rhs, e.rhs.span, "on the right of `${e.op}`")
                return BoolT
            }
            throw TypeCheckError(e.span, "`${e.op}` compares int or string, not `$lhs`")
        }
        if (e.op in EQUALITIES) {
            if (lhs is UnitT || rhs is UnitT) {
                throw TypeCheckError(e.span, "`${e.op}` cannot compare `unit`")
            }
            if (!compatible(lhs, rhs)) {
                throw TypeCheckError(e.span, "`${e.op}` compares `$lhs` with `$rhs`")
            }
            return BoolT
        }
        throw TypeCheckError(e.span, "unknown operator `${e.op}`")
    }

    fun assign(e: Assign): Type {
        val target = exp(e.target)
        val sym = (e.target as? Var)?.sym
        if (sym != null && !sym.mutable) {
            throw TypeCheckError(e.span, "`${sym.name}` is a `val`, so it cannot be assigned")
        }
        unify(target, exp(e.value), e.value.span, "in an assignment")
        return UnitT
    }

    fun ifExp(e: If): Type {
        unify(BoolT, exp(e.cond), e.cond.span, "as an `if` condition")
        val then = exp(e.then)
        if (e.els == null) {
            unify(UnitT, then, e.then.span, "in an `if` with no `else`")
            return UnitT
        }
        val els = exp(e.els)
        if (!compatible(then, els)) {
            throw TypeCheckError(e.span, "the branches differ: `$then` and `$els`")
        }
        return if (then is NilT) els else then
    }

    fun forExp(e: For): Type {
        unify(IntT, exp(e.lo), e.lo.span, "as a `for` bound")
        unify(IntT, exp(e.hi), e.hi.span, "as a `for` bound")
        val sym = VarSym(e.name, IntT, false, depth)
        e.sym = sym
        push()
        bindVal(e.name, sym)
        loops += 1
        unify(UnitT, exp(e.body), e.body.span, "in a `for` body")
        loops -= 1
        pop()
        return UnitT
    }
}
