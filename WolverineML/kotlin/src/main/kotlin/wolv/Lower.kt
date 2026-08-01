/**
 * Lowering: the typed syntax tree becomes a control flow graph.
 *
 * Two things are worth knowing about this pass.
 *
 * It never builds a phi.  A variable written in two branches is written to the
 * same register twice, and `Ssa.kt` is what turns those two writes into one phi.
 * Lowering only has to make sure a definition reaches every use, which structured
 * control flow does for free.
 *
 * It decides where a variable lives.  A variable the checker did not mark as
 * escaping becomes a register; one that escaped becomes a frame slot, reached
 * through `LoadSlot`/`StoreSlot` in its own function and through a chain of
 * static links from a nested one.
 */

package wolv

import wolv.ir.*
import wolv.ast.*
// The two trees share two names.  Lowering reads one and writes the other,
// so the IR keeps the plain name and the syntax gets the qualified one.
import wolv.ast.Bin as AstBin
import wolv.ast.Call as AstCall
import wolv.ir.Bin
import wolv.ir.Call

class Lowering(val checks: Boolean = true)

fun lower(prog: Program, opts: Lowering = Lowering()): Module = Lowerer(opts).program(prog)

/** Owns what the whole module shares: string literals and the function list. */
private class Lowerer(val opts: Lowering) {
val mod = Module()
val stringSymbols: MutableMap<String, String> = mutableMapOf()

fun string(text: String): String = stringSymbols.getOrPut(text) {
    val symbol = ".Lstr${stringSymbols.size}"
    mod.strings[symbol] = text
    symbol
}

fun program(prog: Program): Module {
    val main = FuncLowerer(this, "wol_main", "main", depth = 0)
    main.topLevel(prog.decls)
    return mod
}

fun function(bind: FunBind) {
    val sym = bind.sym!!
    FuncLowerer(this, sym.label, sym.name, depth = sym.depth).functionBody(bind, sym)
}
}

private class FuncLowerer(val up: Lowerer, label: String, name: String, depth: Int) {
val opts = up.opts
val func = Func(label = label, name = name, params = mutableListOf(), depth = depth)
var cur: Block = func.addBlock("entry")
val breaks: MutableList<String> = mutableListOf()
var counter = 0
var hasChildren = false

init {
    if (depth > 0) func.staticLinkSlot = func.newSlot()
    up.mod.funcs.add(func)
}

// -- block plumbing ---------------------------------------------------

fun fresh(hint: String): Block {
    counter += 1
    return func.addBlock("$hint$counter")
}

fun emit(instr: Instr) {
    cur.instrs.add(instr)
}

fun terminate(term: Terminator) {
    emit(term)
    cur = fresh("dead")
}

fun jump(block: Block) = terminate(Jmp(block.label))

fun branch(cond: Reg, yes: Block, no: Block) = terminate(CBr(cond, yes.label, no.label))

fun reg(): Reg = func.newReg()

fun const(value: Long): Reg {
    val r = reg()
    emit(Const(r, value))
    return r
}

// -- function bodies --------------------------------------------------

fun topLevel(decls: List<Decl>) {
    decls(decls)
    terminate(Ret(null))
    finish()
}

fun functionBody(bind: FunBind, sym: FunSym) {
    if (func.depth > 0) {
        val link = reg()
        func.params.add(link)
        emit(StoreSlot(func.staticLinkSlot, link))
    }
    val first = func.params.size
    for ((offset, psym) in sym.params.withIndex()) {
        val index = first + offset
        if (index >= ARGUMENT_REGISTERS) {
            psym.escapes = true
            psym.slot = -(index - ARGUMENT_REGISTERS + 1)
            continue
        }
        val r = reg()
        func.params.add(r)
        if (psym.escapes) {
            psym.slot = func.newSlot()
            emit(StoreSlot(psym.slot, r))
        } else {
            psym.reg = r
        }
    }
    val value = exp(bind.body)
    val returns = sym.result !is UnitT
    terminate(Ret(if (returns) value else null))
    finish()
}

fun finish() {
    func.dropUnreachable()
    dropUnusedStaticLink()
}

/**
 * A function nobody nests inside, and that never looks outward, keeps no
 * static link: the slot goes, and every later slot moves down one.
 */
fun dropUnusedStaticLink() {
    val slot = func.staticLinkSlot
    if (slot < 0 || hasChildren) return
    val reads = func.walk().any { block ->
        block.instrs.any { it is LoadSlot && it.slot == slot }
    }
    if (reads) return
    for (block in func.walk()) {
        val kept = mutableListOf<Instr>()
        for (instr in block.instrs) {
            when {
                instr is StoreSlot && instr.slot == slot -> continue
                instr is StoreSlot && instr.slot > slot -> instr.slot -= 1
                instr is LoadSlot && instr.slot > slot -> instr.slot -= 1
            }
            kept.add(instr)
        }
        block.instrs = kept
    }
    func.nslots -= 1
    func.staticLinkSlot = -1
}

// -- declarations -----------------------------------------------------

fun decls(decls: List<Decl>) {
    for (decl in decls) {
        when (decl) {
            is TypeDecl -> {}
            is ValDecl -> valDecl(decl)
            is FunDecl -> {
                hasChildren = true
                for (bind in decl.binds) up.function(bind)
            }
        }
    }
}

fun valDecl(decl: ValDecl) {
    val value = exp(decl.init)
    val sym = decl.sym ?: return
    if (sym.ty is UnitT) return
    bind(sym, value!!)
}

/** Give a variable its home, and put the initial value in it. */
fun bind(sym: VarSym, value: Reg) {
    if (sym.escapes) {
        sym.slot = func.newSlot()
        emit(StoreSlot(sym.slot, value))
    } else {
        sym.reg = reg()
        emit(Move(sym.reg, value))
    }
}

// -- reaching variables and frames ------------------------------------

/** A register holding the frame pointer of the function at `depth`. */
fun frameAt(depth: Int): Reg {
    var r = reg()
    if (depth == func.depth) {
        emit(FrameAddr(r))
        return r
    }
    emit(LoadSlot(r, func.staticLinkSlot))
    var here = func.depth - 1
    while (here > depth) {
        val next = reg()
        emit(Load(next, r, slotOffset(0)))
        r = next
        here -= 1
    }
    return r
}

fun readVar(sym: VarSym): Reg {
    if (!sym.escapes) return sym.reg
    if (sym.depth == func.depth) {
        val r = reg()
        emit(LoadSlot(r, sym.slot))
        return r
    }
    val base = frameAt(sym.depth)
    val r = reg()
    emit(Load(r, base, slotOffset(sym.slot)))
    return r
}

fun writeVar(sym: VarSym, value: Reg) {
    if (!sym.escapes) {
        emit(Move(sym.reg, value))
    } else if (sym.depth == func.depth) {
        emit(StoreSlot(sym.slot, value))
    } else {
        val base = frameAt(sym.depth)
        emit(Store(base, slotOffset(sym.slot), value))
    }
}

// -- expressions ------------------------------------------------------

fun value(e: Exp): Reg =
    exp(e) ?: throw AssertionError("expected a value from ${e::class.simpleName}")

fun exp(e: Exp): Reg? = when (e) {
    is IntLit -> const(e.value)
    is BoolLit -> const(if (e.value) 1 else 0)
    is NilLit -> const(0)
    is UnitLit -> null
    is StrLit -> {
        val r = reg()
        emit(StrConst(r, up.string(e.value)))
        r
    }
    is Var -> readVar(e.sym!!)
    is AstCall -> call(e)
    is RecordLit -> record(e)
    is Index -> index(e)
    is Field -> field(e)
    is Neg -> binop("-", const(0), value(e.operand))
    is AstBin -> bin(e)
    is Logic -> logic(e)
    is Assign -> {
        assign(e)
        null
    }
    is If -> ifExp(e)
    is While -> {
        whileExp(e)
        null
    }
    is For -> {
        forExp(e)
        null
    }
    is Break -> {
        terminate(Jmp(breaks.last()))
        null
    }
    is Seq -> {
        var last: Reg? = null
        for (item in e.items) last = exp(item)
        last
    }
    is Let -> {
        decls(e.decls)
        exp(e.body)
    }
}

fun binop(op: String, lhs: Reg, rhs: Reg): Reg {
    val r = reg()
    emit(Bin(r, op, lhs, rhs))
    return r
}

fun compare(op: String, lhs: Reg, rhs: Reg): Reg {
    val r = reg()
    emit(Cmp(r, op, lhs, rhs))
    return r
}

fun callRuntime(name: String, args: List<Reg>): Reg {
    val r = reg()
    emit(Call(r, name, args))
    return r
}

fun bin(e: AstBin): Reg {
    val lhs = value(e.lhs)
    val rhs = value(e.rhs)
    if (e.op == "^") return callRuntime("wol_concat", listOf(lhs, rhs))
    if (e.op == "/" || e.op == "mod") {
        checkNonzero(rhs)
        if (e.op == "/") return binop("/", lhs, rhs)
        // The remainder is spelled out rather than left to the emitter: the
        // quotient it needs in between is a value like any other, and the
        // allocator can find it a register.  The emitter fuses the last two
        // back into one `msub`.
        val quotient = binop("/", lhs, rhs)
        val product = binop("*", quotient, rhs)
        return binop("-", lhs, product)
    }
    if (e.op in listOf("+", "-", "*")) return binop(e.op, lhs, rhs)
    if (e.lhs.ty is StringT) {
        val order = callRuntime("wol_string_cmp", listOf(lhs, rhs))
        return compare(e.op, order, const(0))
    }
    return compare(e.op, lhs, rhs)
}

/** `andalso` and `orelse` are branches, so the result needs a register. */
fun logic(e: Logic): Reg {
    val result = reg()
    val rhsBlock = fresh("logic")
    val join = fresh("logicjoin")
    val lhs = value(e.lhs)
    emit(Move(result, lhs))
    if (e.op == "andalso") branch(lhs, rhsBlock, join) else branch(lhs, join, rhsBlock)
    cur = rhsBlock
    emit(Move(result, value(e.rhs)))
    jump(join)
    cur = join
    return result
}

fun call(e: AstCall): Reg? {
    val sym = e.sym!!
    when (sym.builtin) {
        "not" -> return binop("xor", value(e.args[0]), const(1))
        "array" -> {
            val n = value(e.args[0])
            val init = value(e.args[1])
            return callRuntime("wol_array", listOf(n, init))
        }
        "length" -> {
            val arr = value(e.args[0])
            checkNotNil(arr)
            val r = reg()
            emit(Load(r, arr, 0))
            return r
        }
    }
    var args = e.args.map { value(it) }
    if (sym.builtin == null) args = listOf(frameAt(sym.depth - 1)) + args
    if (sym.result is UnitT) {
        emit(Call(null, sym.label, args))
        return null
    }
    return callRuntime(sym.label, args)
}

fun record(e: RecordLit): Reg {
    val rec = e.ty as RecordT
    val size = const((WORD * maxOf(rec.fields.size, 1)).toLong())
    val base = callRuntime("wol_alloc", listOf(size))
    for ((i, f) in e.fields.withIndex()) {
        emit(Store(base, WORD * i, value(f.value)))
    }
    return base
}

fun index(e: Index): Reg {
    val addr = elementAddress(e)
    val r = reg()
    emit(Load(r, addr, WORD))
    return r
}

/**
 * The address of `a[i]`, without the length word the elements follow.
 *
 * The selector turns this into one `add` with a shifted operand, and the word
 * is the load's displacement, so the two instructions that come out are the
 * two the machine has.
 */
fun elementAddress(e: Index): Reg {
    val base = value(e.array)
    val idx = value(e.index)
    checkNotNil(base)
    checkBounds(base, idx)
    return binop("+", base, binop("shl", idx, const(3)))
}

fun field(e: Field): Reg {
    val base = value(e.record)
    checkNotNil(base)
    val r = reg()
    emit(Load(r, base, WORD * e.offset))
    return r
}

fun assign(e: Assign) {
    when (val target = e.target) {
        is Var -> writeVar(target.sym!!, value(e.value))
        is Index -> {
            val addr = elementAddress(target)
            emit(Store(addr, WORD, value(e.value)))
        }
        is Field -> {
            val base = value(target.record)
            checkNotNil(base)
            emit(Store(base, WORD * target.offset, value(e.value)))
        }
        else -> throw AssertionError("assignment to something that is not a place")
    }
}

fun ifExp(e: If): Reg? {
    val wantsValue = e.ty !is UnitT
    val result = if (wantsValue) reg() else null
    val yes = fresh("then")
    val no = fresh("else")
    val join = fresh("join")
    branch(value(e.cond), yes, no)

    cur = yes
    var taken = exp(e.then)
    if (result != null && taken != null) emit(Move(result, taken))
    jump(join)

    cur = no
    if (e.els != null) {
        taken = exp(e.els)
        if (result != null && taken != null) emit(Move(result, taken))
    }
    jump(join)

    cur = join
    return result
}

fun whileExp(e: While) {
    val test = fresh("test")
    val body = fresh("body")
    val done = fresh("done")
    jump(test)
    cur = test
    branch(value(e.cond), body, done)
    cur = body
    breaks.add(done.label)
    exp(e.body)
    breaks.removeAt(breaks.size - 1)
    jump(test)
    cur = done
}

/** `for i = lo to hi` counts up, and stops before overflowing at `hi`. */
fun forExp(e: For) {
    val sym = e.sym!!
    val lo = value(e.lo)
    val hiValue = value(e.hi)
    val hi = reg()
    emit(Move(hi, hiValue))
    bind(sym, lo)
    val body = fresh("forbody")
    val step = fresh("forstep")
    val done = fresh("fordone")
    branch(compare("<=", lo, hi), body, done)

    cur = body
    breaks.add(done.label)
    exp(e.body)
    breaks.removeAt(breaks.size - 1)
    val i = readVar(sym)
    branch(compare("<", i, hi), step, done)

    cur = step
    writeVar(sym, binop("+", readVar(sym), const(1)))
    jump(body)

    cur = done
}

// -- run-time checks --------------------------------------------------

fun checkNotNil(base: Reg) {
    if (!opts.checks) return
    val bad = fresh("nil")
    val ok = fresh("ok")
    branch(compare("=", base, const(0)), bad, ok)
    cur = bad
    emit(Call(null, "wol_nil_error", listOf()))
    jump(ok)
    cur = ok
}

fun checkBounds(base: Reg, idx: Reg) {
    if (!opts.checks) return
    val length = reg()
    emit(Load(length, base, 0))
    val bad = fresh("oob")
    val ok = fresh("ok")
    branch(compare("u<", idx, length), ok, bad)
    cur = bad
    emit(Call(null, "wol_bounds_error", listOf(idx, length)))
    jump(ok)
    cur = ok
}

fun checkNonzero(rhs: Reg) {
    if (!opts.checks) return
    val bad = fresh("divzero")
    val ok = fresh("ok")
    branch(compare("=", rhs, const(0)), bad, ok)
    cur = bad
    emit(Call(null, "wol_div_error", listOf()))
    jump(ok)
    cur = ok
}
}
