package wolv;

import haxe.Int64;
import wolv.Ast;
import wolv.Ir;
import wolv.Types;

/* Lowering: the typed syntax tree becomes a control flow graph.
 *
 * Two things are worth knowing about this pass.
 *
 * It never builds a phi.  A variable written in two branches is written to the
 * same register twice, and Ssa.hx is what turns those two writes into one phi.
 * Lowering only has to make sure a definition reaches every use, which structured
 * control flow does for free.
 *
 * It decides where a variable lives.  A variable the checker did not mark as
 * escaping becomes a register; one that escaped becomes a frame slot, reached
 * through `LoadSlot`/`StoreSlot` in its own function and through a chain of
 * static links from a nested one. */

class Lowering {
  public final checks:Bool;

  public function new(checks = true) {
    this.checks = checks;
  }
}

function lower(prog:Program, ?opts:Lowering):Module {
  final shared = new Shared(opts == null ? new Lowering() : opts);
  final main = new Lowerer(shared, "wol_main", "main", 0);
  main.decls(prog.decls);
  main.terminate(Ret(null));
  main.finish();
  return shared.modul;
}

/** What the whole module shares: string literals and the function list. */
private class Shared {
  public final opts:Lowering;
  public final modul = new Module();

  /** text -> symbol, so a repeated literal is emitted once. */
  final symbols = new Map<String, String>();

  var count = 0;

  public function new(opts:Lowering) {
    this.opts = opts;
  }

  public function literal(text:String):String {
    final found = symbols.get(text);
    if (found != null) return found;
    final symbol = '.Lstr$count';
    count += 1;
    symbols.set(text, symbol);
    modul.strings.push(new StringLit(symbol, text));
    return symbol;
  }
}

private class Lowerer {
  final up:Shared;
  public final fn:Func;

  var cur:Block;
  final breaks:Array<String> = [];
  var counter = 0;
  var hasChildren = false;

  public function new(up:Shared, label:String, name:String, depth:Int) {
    this.up = up;
    fn = new Func(label, name, depth);
    cur = fn.addBlock("entry");
    if (depth > 0) fn.linkSlot = fn.newSlot();
    up.modul.funcs.push(fn);
  }

  /* -- block plumbing ------------------------------------------------------- */

  function fresh(hint:String):Block {
    counter += 1;
    return fn.addBlock('$hint$counter');
  }

  function put(i:Instr):Void cur.instrs.push(i);

  public function terminate(term:Instr):Void {
    put(term);
    cur = fresh("dead");
  }

  function jump(b:Block):Void terminate(Jmp(b.label));

  function branch(cond:Reg, yes:Block, no:Block):Void {
    terminate(CBr(cond, yes.label, no.label, ""));
  }

  function reg():Reg return fn.newReg();

  function constant(value:Int64):Reg {
    final r = reg();
    put(Const(r, value));
    return r;
  }

  function binop(op:String, lhs:Reg, rhs:Reg):Reg {
    final r = reg();
    put(Bin(r, op, lhs, rhs));
    return r;
  }

  function compare(op:String, lhs:Reg, rhs:Reg):Reg {
    final r = reg();
    put(Cmp(r, op, lhs, rhs));
    return r;
  }

  function callRuntime(name:String, args:Array<Reg>):Reg {
    final r = reg();
    put(Call(r, name, args));
    return r;
  }

  /* -- run-time checks ------------------------------------------------------ */

  function checkNotNil(base:Reg):Void {
    if (!up.opts.checks) return;
    final bad = fresh("nil");
    final ok = fresh("ok");
    branch(compare("=", base, constant(Int64.ofInt(0))), bad, ok);
    cur = bad;
    put(Call(null, "wol_nil_error", []));
    jump(ok);
    cur = ok;
  }

  function checkBounds(base:Reg, idx:Reg):Void {
    if (!up.opts.checks) return;
    final length = reg();
    put(Load(length, base, 0));
    final bad = fresh("oob");
    final ok = fresh("ok");
    branch(compare("u<", idx, length), ok, bad);
    cur = bad;
    put(Call(null, "wol_bounds_error", [idx, length]));
    jump(ok);
    cur = ok;
  }

  function checkNonzero(rhs:Reg):Void {
    if (!up.opts.checks) return;
    final bad = fresh("divzero");
    final ok = fresh("ok");
    branch(compare("=", rhs, constant(Int64.ofInt(0))), bad, ok);
    cur = bad;
    put(Call(null, "wol_div_error", []));
    jump(ok);
    cur = ok;
  }

  /* -- reaching variables and frames ---------------------------------------- */

  /** A register holding the frame pointer of the function at `depth`. */
  function frameAt(depth:Int):Reg {
    final r = reg();
    if (depth == fn.depth) {
      put(FrameAddr(r));
      return r;
    }
    put(LoadSlot(r, fn.linkSlot));
    var at = r;
    var here = fn.depth - 1;
    while (here > depth) {
      final next = reg();
      put(Load(next, at, Ir.slotOffset(0)));
      at = next;
      here -= 1;
    }
    return at;
  }

  function readVar(sym:VarSym):Reg {
    if (!sym.escapes) return sym.reg;
    if (sym.depth == fn.depth) {
      final r = reg();
      put(LoadSlot(r, sym.slot));
      return r;
    }
    final base = frameAt(sym.depth);
    final r = reg();
    put(Load(r, base, Ir.slotOffset(sym.slot)));
    return r;
  }

  function writeVar(sym:VarSym, value:Reg):Void {
    if (!sym.escapes) put(Move(sym.reg, value));
    else if (sym.depth == fn.depth) put(StoreSlot(sym.slot, value));
    else {
      final base = frameAt(sym.depth);
      put(Store(base, Ir.slotOffset(sym.slot), value));
    }
  }

  /** Gives a variable its home, and puts the initial value in it. */
  function bind(sym:VarSym, value:Reg):Void {
    if (sym.escapes) {
      sym.slot = fn.newSlot();
      put(StoreSlot(sym.slot, value));
    } else {
      sym.reg = reg();
      put(Move(sym.reg, value));
    }
  }

  /* -- expressions ---------------------------------------------------------- */

  function exp(e:Exp):Null<Reg> {
    return switch e.def {
      case EInt(v): constant(v);
      case EBool(b): constant(Int64.ofInt(b ? 1 : 0));
      case ENil: constant(Int64.ofInt(0));
      case EUnit: null;

      case EStr(text):
        final r = reg();
        put(StrConst(r, up.literal(text)));
        r;

      case EVar(_): readVar(e.variable());
      case ECall(_, args): callExp(e, args);
      case ERecord(_, fields): record(e, fields);

      case EIndex(array, index):
        final addr = elementAddress(array, index);
        final r = reg();
        put(Load(r, addr, Ir.WORD));
        r;

      case EField(rec, _):
        final base = value(rec);
        checkNotNil(base);
        final r = reg();
        put(Load(r, base, Ir.WORD * e.offset));
        r;

      case ENeg(operand):
        final zero = constant(Int64.ofInt(0));
        binop("-", zero, value(operand));

      case EBin(op, lhs, rhs): bin(op, lhs, rhs);
      case ELogic(op, lhs, rhs): logic(op, lhs, rhs);

      case EAssign(target, v):
        assign(target, v);
        null;

      case EIf(cond, then, els): ifExp(e, cond, then, els);

      case EWhile(cond, body):
        whileExp(cond, body);
        null;

      case EFor(_, lo, hi, body):
        forExp(e.variable(), lo, hi, body);
        null;

      case EBreak:
        terminate(Jmp(breaks[0]));
        null;

      case ESeq(items):
        var last:Null<Reg> = null;
        for (item in items) last = exp(item);
        last;

      case ELet(ds, body):
        decls(ds);
        exp(body);
    }
  }

  function value(e:Exp):Reg {
    final r = exp(e);
    if (r == null) throw "expected a value";
    return r;
  }

  function bin(op:String, lhs:Exp, rhs:Exp):Reg {
    final a = value(lhs);
    final b = value(rhs);
    switch op {
      case "^":
        return callRuntime("wol_concat", [a, b]);
      case "/" | "mod":
        checkNonzero(b);
        if (op == "/") return binop("/", a, b);
        // The remainder is spelled out rather than left to the emitter: the
        // quotient it needs in between is a value like any other, and the
        // allocator can find it a register.  The emitter fuses the last two back
        // into one `msub`.
        final quotient = binop("/", a, b);
        final product = binop("*", quotient, b);
        return binop("-", a, product);
      case "+" | "-" | "*":
        return binop(op, a, b);
      case _:
        if (lhs.ty != null && lhs.ty.match(TString)) {
          final order = callRuntime("wol_string_cmp", [a, b]);
          return compare(op, order, constant(Int64.ofInt(0)));
        }
        return compare(op, a, b);
    }
  }

  /** `andalso` and `orelse` are branches, so the result needs a register. */
  function logic(op:String, lhs:Exp, rhs:Exp):Reg {
    final result = reg();
    final rhsBlock = fresh("logic");
    final join = fresh("logicjoin");
    final a = value(lhs);
    put(Move(result, a));
    if (op == "andalso") branch(a, rhsBlock, join) else branch(a, join, rhsBlock);
    cur = rhsBlock;
    put(Move(result, value(rhs)));
    jump(join);
    cur = join;
    return result;
  }

  function callExp(e:Exp, args:Array<Exp>):Null<Reg> {
    final sym = e.callee();
    switch sym.builtin {
      case "not":
        final operand = value(args[0]);
        final one = constant(Int64.ofInt(1));
        return binop("xor", operand, one);

      case "array":
        final n = value(args[0]);
        final init = value(args[1]);
        return callRuntime("wol_array", [n, init]);

      case "length":
        final arr = value(args[0]);
        checkNotNil(arr);
        final r = reg();
        put(Load(r, arr, 0));
        return r;

      case _:
        // The arguments are lowered first, and only then the static link, which
        // is the order the register numbers come out in.
        final lowered = args.map(value);
        if (sym.builtin == null) lowered.unshift(frameAt(sym.depth - 1));
        if (sym.result.match(TUnit)) {
          put(Call(null, sym.label, lowered));
          return null;
        }
        return callRuntime(sym.label, lowered);
    }
  }

  function record(e:Exp, fields:Array<FieldInit>):Reg {
    final r = switch e.ty {
      case TRecord(r): r;
      case _: throw "a record literal is not of a record type";
    };
    final count = r.fields.length < 1 ? 1 : r.fields.length;
    final size = constant(Int64.ofInt(Ir.WORD * count));
    final base = callRuntime("wol_alloc", [size]);
    for (at in 0...fields.length) {
      put(Store(base, Ir.WORD * at, value(fields[at].value)));
    }
    return base;
  }

  /**
   * The address of `a[i]`, without the length word the elements follow.
   *
   * The selector turns this into one `add` with a shifted operand, and the word
   * is the load's displacement, so the two instructions that come out are the two
   * the machine has.
   */
  function elementAddress(array:Exp, index:Exp):Reg {
    final base = value(array);
    final idx = value(index);
    checkNotNil(base);
    checkBounds(base, idx);
    return binop("+", base, binop("shl", idx, constant(Int64.ofInt(3))));
  }

  function assign(target:Exp, v:Exp):Void {
    switch target.def {
      case EVar(_):
        writeVar(target.variable(), value(v));
      case EIndex(array, index):
        final addr = elementAddress(array, index);
        put(Store(addr, Ir.WORD, value(v)));
      case EField(rec, _):
        final base = value(rec);
        checkNotNil(base);
        put(Store(base, Ir.WORD * target.offset, value(v)));
      case _:
        throw "assignment to something that is not a place";
    }
  }

  function ifExp(e:Exp, cond:Exp, then:Exp, els:Null<Exp>):Null<Reg> {
    final result:Null<Reg> = e.ty.match(TUnit) ? null : reg();
    final yes = fresh("then");
    final no = fresh("else");
    final join = fresh("join");
    branch(value(cond), yes, no);

    cur = yes;
    final taken = exp(then);
    if (result != null && taken != null) put(Move(result, taken));
    jump(join);

    cur = no;
    if (els != null) {
      final otherwise = exp(els);
      if (result != null && otherwise != null) put(Move(result, otherwise));
    }
    jump(join);

    cur = join;
    return result;
  }

  function whileExp(cond:Exp, body:Exp):Void {
    final test = fresh("test");
    final bodyBlock = fresh("body");
    final over = fresh("done");
    jump(test);
    cur = test;
    branch(value(cond), bodyBlock, over);
    cur = bodyBlock;
    breaks.unshift(over.label);
    exp(body);
    breaks.shift();
    jump(test);
    cur = over;
  }

  /** `for i = lo to hi` counts up, and stops before overflowing at `hi`. */
  function forExp(sym:VarSym, lo:Exp, hi:Exp, body:Exp):Void {
    final low = value(lo);
    final highValue = value(hi);
    final high = reg();
    put(Move(high, highValue));
    bind(sym, low);
    final bodyBlock = fresh("forbody");
    final step = fresh("forstep");
    final over = fresh("fordone");
    branch(compare("<=", low, high), bodyBlock, over);

    cur = bodyBlock;
    breaks.unshift(over.label);
    exp(body);
    breaks.shift();
    branch(compare("<", readVar(sym), high), step, over);

    cur = step;
    final i = readVar(sym);
    final one = constant(Int64.ofInt(1));
    writeVar(sym, binop("+", i, one));
    jump(bodyBlock);

    cur = over;
  }

  /* -- declarations --------------------------------------------------------- */

  public function decls(list:Array<Decl>):Void {
    for (d in list) decl(d);
  }

  function decl(d:Decl):Void {
    switch d {
      case DType(_, _):
      case DVal(v):
        final r = exp(v.init);
        if (v.sym != null && !v.sym.ty.match(TUnit)) bind(v.sym, r);
      case DFun(_, binds):
        hasChildren = true;
        for (b in binds) lowerFunction(up, b);
    }
  }

  /* -- whole functions ------------------------------------------------------ */

  /**
   * A function nobody nests inside, and that never looks outward, keeps no static
   * link: the slot goes, and every later slot moves down one.
   */
  function dropUnusedStaticLink():Void {
    final slot = fn.linkSlot;
    if (slot < 0 || hasChildren) return;
    for (b in fn.walk()) {
      for (i in b.instrs) switch i {
        case LoadSlot(_, s) if (s == slot): return;
        case _:
      }
    }
    for (b in fn.walk()) {
      final kept = [];
      for (i in b.instrs) switch i {
        case StoreSlot(s, _) if (s == slot): // the link's own store goes
        case StoreSlot(s, src): kept.push(StoreSlot(s > slot ? s - 1 : s, src));
        case LoadSlot(dst, s): kept.push(LoadSlot(dst, s > slot ? s - 1 : s));
        case _: kept.push(i);
      }
      b.instrs = kept;
    }
    fn.nslots -= 1;
    fn.linkSlot = -1;
  }

  public function finish():Void {
    Ir.dropUnreachable(fn);
    dropUnusedStaticLink();
  }

  /**
   * The entry: the static link if there is one, then the parameters.  The ninth
   * and later arguments have no register to arrive in, so they are read out of
   * the caller's frame instead, which is what a negative slot means.
   */
  public function enter(b:FunBind):Void {
    final sym = b.sym;
    if (fn.depth > 0) {
      final link = reg();
      fn.params.push(link);
      put(StoreSlot(fn.linkSlot, link));
    }
    final first = fn.params.length;
    for (offset in 0...sym.params.length) {
      final psym = sym.params[offset];
      final index = first + offset;
      if (index >= Ir.ARGUMENT_REGISTERS) {
        psym.escapes = true;
        psym.slot = -(index - Ir.ARGUMENT_REGISTERS + 1);
      } else {
        final r = reg();
        fn.params.push(r);
        if (psym.escapes) {
          psym.slot = fn.newSlot();
          put(StoreSlot(psym.slot, r));
        } else {
          psym.reg = r;
        }
      }
    }
    final v = exp(b.body);
    terminate(Ret(sym.result.match(TUnit) ? null : v));
    finish();
  }
}

private function lowerFunction(up:Shared, b:FunBind):Void {
  new Lowerer(up, b.sym.label, b.sym.name, b.sym.depth).enter(b);
}
