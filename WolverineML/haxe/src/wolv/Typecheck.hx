package wolv;

import wolv.Ast;
import wolv.Diag;
import wolv.Types;

/* The type checker, which also decides which variables escape.
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
 * pass gives those a frame slot instead. */

/** Types the program in place: every node comes back with its type. */
function check(prog:Program):Void {
  new Checker().program(prog);
}

private final BUILTINS:Array<{name:String, params:Array<Ty>, result:Ty, symbol:String}> = [
  {name: "print", params: [TString], result: TUnit, symbol: "wol_print"},
  {name: "println", params: [TString], result: TUnit, symbol: "wol_println"},
  {name: "printInt", params: [TInt], result: TUnit, symbol: "wol_print_int"},
  {name: "flush", params: [], result: TUnit, symbol: "wol_flush"},
  {name: "getChar", params: [], result: TString, symbol: "wol_getchar"},
  {name: "ord", params: [TString], result: TInt, symbol: "wol_ord"},
  {name: "chr", params: [TInt], result: TString, symbol: "wol_chr"},
  {name: "size", params: [TString], result: TInt, symbol: "wol_size"},
  {name: "substring", params: [TString, TInt, TInt], result: TString, symbol: "wol_substring"},
  {name: "concat", params: [TString, TString], result: TString, symbol: "wol_concat"},
  {name: "intToString", params: [TInt], result: TString, symbol: "wol_int_to_string"},
  {name: "stringToInt", params: [TString], result: TInt, symbol: "wol_string_to_int"},
  {name: "exit", params: [TInt], result: TUnit, symbol: "wol_exit"},
];

/** The three whose types depend on their arguments, so `Checker` types them itself. */
private final SPECIAL = ["array", "length", "not"];

private final ARITHMETIC = ["+", "-", "*", "/", "mod"];
private final ORDERING = ["<", "<=", ">", ">="];
private final EQUALITY = ["=", "<>"];

private class Scope {
  public final tys = new Map<String, Ty>();
  public final vals = new Map<String, Sym>();

  public function new() {}
}

private class Checker {
  /** Innermost first, so a lookup walks outward and stops at the first hit. */
  final scopes:Array<Scope> = [];

  var depth = 0;
  var loops = 0;
  final labels = new Map<String, Int>();

  public function new() {
    final prelude = new Scope();
    for (t in [{n: "int", t: TInt}, {n: "string", t: TString}, {n: "bool", t: TBool},
      {n: "unit", t: TUnit}]) prelude.tys.set(t.n, t.t);
    for (b in BUILTINS) {
      final params = [for (at in 0...b.params.length) new VarSym('a$at', b.params[at], false, 0)];
      prelude.vals.set(b.name, Fun(new FunSym(b.name, b.symbol, params, b.result, 0, b.symbol)));
    }
    for (name in SPECIAL) {
      prelude.vals.set(name, Fun(new FunSym(name, name, [], TUnit, 0, name)));
    }
    scopes.push(prelude);
  }

  public function program(prog:Program):Void {
    push();
    decls(prog.decls);
    pop();
  }

  /* -- scopes -------------------------------------------------------------- */

  function push():Void scopes.unshift(new Scope());

  function pop():Void scopes.shift();

  function bindVal(name:String, sym:Sym):Void scopes[0].vals.set(name, sym);

  function bindType(name:String, ty:Ty):Void scopes[0].tys.set(name, ty);

  function lookupVal(name:String, at:Span):Sym {
    for (s in scopes) {
      final v = s.vals.get(name);
      if (v != null) return v;
    }
    throw Errors.type(at, '`$name` is not bound');
  }

  function lookupType(name:String, at:Span):Ty {
    for (s in scopes) {
      final t = s.tys.get(name);
      if (t != null) return t;
    }
    throw Errors.type(at, '`$name` is not a type');
  }

  /** Two functions of the same name in one program need two labels. */
  function uniqueLabel(name:String):String {
    final n = labels.exists(name) ? labels.get(name) : 0;
    labels.set(name, n + 1);
    return n == 0 ? 'wol_$name' : 'wol_$name.$n';
  }

  function unify(want:Ty, got:Ty, at:Span, where:String):Void {
    if (!Types.compatible(want, got)) {
      throw Errors.type(at, 'expected `${Types.show(want)}`, found `${Types.show(got)}` $where');
    }
  }

  /* -- types as they are written -------------------------------------------- */

  function resolve(t:TyExp):Ty {
    return switch t {
      case TyNamed(span, name): lookupType(name, span);
      case TyArrayOf(_, elem): TArray(resolve(elem));
      case TyRecordOf(span, _):
        throw Errors.type(span, "a record type has to be given a name by `type`");
    }
  }

  /* -- declarations --------------------------------------------------------- */

  function decls(list:Array<Decl>):Void {
    for (d in list) decl(d);
  }

  function decl(d:Decl):Void {
    switch d {
      case DType(_, binds): typeDecl(binds);
      case DVal(bind): valDecl(bind);
      case DFun(_, binds): funDecl(binds);
    }
  }

  /**
   * Records are bound before any field is resolved, so a group of `type`s may
   * name each other and itself.
   */
  function typeDecl(binds:Array<TypeBind>):Void {
    final records = [];
    for (b in binds) {
      switch b.ty {
        case TyRecordOf(_, fields):
          final r = new Record(b.name);
          bindType(b.name, TRecord(r));
          records.push({record: r, fields: fields});
        case _:
      }
    }
    for (b in binds) {
      switch b.ty {
        case TyRecordOf(_, _):
        case _: bindType(b.name, resolve(b.ty));
      }
    }
    for (r in records) {
      final seen = new Map<String, Bool>();
      for (f in r.fields) {
        if (seen.exists(f.name)) throw Errors.type(f.span, 'duplicate field `${f.name}`');
        seen.set(f.name, true);
        r.record.fields.push({name: f.name, ty: resolve(f.ty)});
      }
    }
  }

  function valDecl(d:ValBind):Void {
    var got = exp(d.init);
    if (d.ty != null) {
      final want = resolve(d.ty);
      unify(want, got, d.init.span, "in this binding");
      got = want;
    }
    if (d.name == null) {
      unify(TUnit, got, d.init.span, "in `val () =`");
      return;
    }
    if (got.match(TNil)) {
      throw Errors.type(d.span, '`${d.name}` needs a type annotation to hold `nil`');
    }
    final sym = new VarSym(d.name, got, d.mutable, depth);
    d.sym = sym;
    bindVal(d.name, Var(sym));
  }

  /** Every signature in the group is bound before any body is typed. */
  function funDecl(binds:Array<FunBind>):Void {
    for (b in binds) {
      final seen = new Map<String, Bool>();
      final params = [];
      for (p in b.params) {
        if (seen.exists(p.name)) throw Errors.type(p.span, 'duplicate parameter `${p.name}`');
        seen.set(p.name, true);
        final sym = new VarSym(p.name, resolve(p.ty), false, depth + 1);
        p.sym = sym;
        params.push(sym);
      }
      final result = b.result == null ? TUnit : resolve(b.result);
      b.sym = new FunSym(b.name, uniqueLabel(b.name), params, result, depth + 1);
      bindVal(b.name, Fun(b.sym));
    }
    for (b in binds) {
      final signature = b.sym;
      depth += 1;
      final outer = loops;
      loops = 0;
      push();
      for (p in b.params) bindVal(p.name, Var(p.sym));
      final got = exp(b.body);
      unify(signature.result, got, b.body.span, 'in the body of `${b.name}`');
      pop();
      loops = outer;
      depth -= 1;
    }
  }

  /* -- expressions ---------------------------------------------------------- */

  function exp(e:Exp):Ty {
    final ty = infer(e);
    e.ty = ty;
    return ty;
  }

  function infer(e:Exp):Ty {
    return switch e.def {
      case EInt(_): TInt;
      case EStr(_): TString;
      case EBool(_): TBool;
      case ENil: TNil;
      case EUnit: TUnit;
      case EVar(name): variable(e, name);
      case ECall(name, args): callExp(e, name, args);
      case ERecord(tyname, fields): recordLit(e, tyname, fields);
      case EIndex(array, index): indexExp(e, array, index);
      case EField(record, name): fieldExp(e, record, name);

      case ENeg(operand):
        unify(TInt, exp(operand), e.span, "in a negation");
        TInt;

      case EBin(op, lhs, rhs): binop(e, op, lhs, rhs);

      case ELogic(op, lhs, rhs):
        unify(TBool, exp(lhs), lhs.span, 'on the left of `$op`');
        unify(TBool, exp(rhs), rhs.span, 'on the right of `$op`');
        TBool;

      case EAssign(target, value): assign(e, target, value);
      case EIf(cond, then, els): ifExp(e, cond, then, els);

      case EWhile(cond, body):
        unify(TBool, exp(cond), cond.span, "as a `while` condition");
        loops += 1;
        unify(TUnit, exp(body), body.span, "in a `while` body");
        loops -= 1;
        TUnit;

      case EFor(name, lo, hi, body): forExp(e, name, lo, hi, body);

      case EBreak:
        if (loops == 0) throw Errors.type(e.span, "`break` is outside any loop");
        TUnit;

      case ESeq(items):
        var ty = TUnit;
        for (item in items) ty = exp(item);
        ty;

      case ELet(ds, body):
        push();
        decls(ds);
        final ty = exp(body);
        pop();
        ty;
    }
  }

  function variable(e:Exp, name:String):Ty {
    return switch lookupVal(name, e.span) {
      case Fun(_):
        throw Errors.type(e.span, '`$name` is a function, and functions are not values');
      case Var(sym):
        // Read from deeper than it was bound: it cannot live in a register.
        if (sym.depth < depth) sym.escapes = true;
        e.sym = Var(sym);
        sym.ty;
    }
  }

  function arity(e:Exp, callee:String, args:Array<Exp>, want:Int):Void {
    if (args.length != want) {
      final plural = want == 1 ? "" : "s";
      throw Errors.type(e.span, '`$callee` takes $want argument$plural, given ${args.length}');
    }
  }

  function callExp(e:Exp, callee:String, args:Array<Exp>):Ty {
    final f = switch lookupVal(callee, e.span) {
      case Var(_): throw Errors.type(e.span, '`$callee` is a variable, not a function');
      case Fun(f): f;
    };
    e.sym = Fun(f);
    return switch f.builtin {
      case "array":
        arity(e, callee, args, 2);
        unify(TInt, exp(args[0]), args[0].span, "as an array length");
        final elem = exp(args[1]);
        if (elem.match(TNil)) {
          throw Errors.type(args[1].span, "`array` cannot tell which record `nil` stands for");
        }
        TArray(elem);

      case "length":
        arity(e, callee, args, 1);
        switch exp(args[0]) {
          case TArray(_):
          case got:
            throw Errors.type(args[0].span, '`length` wants an array, found `${Types.show(got)}`');
        }
        TInt;

      case "not":
        arity(e, callee, args, 1);
        unify(TBool, exp(args[0]), e.span, "in a call to `not`");
        TBool;

      case _:
        arity(e, callee, args, f.params.length);
        for (at in 0...args.length) {
          unify(f.params[at].ty, exp(args[at]), args[at].span, 'in a call to `$callee`');
        }
        f.result;
    }
  }

  /** The initialisers are put into declaration order, which is what lowering wants. */
  function recordLit(e:Exp, tyname:String, fields:Array<FieldInit>):Ty {
    final record = switch lookupType(tyname, e.span) {
      case TRecord(r): r;
      case _: throw Errors.type(e.span, '`$tyname` is not a record type');
    };
    final seen = new Map<String, FieldInit>();
    for (f in fields) {
      if (seen.exists(f.name)) throw Errors.type(f.span, 'field `${f.name}` is given twice');
      if (record.index(f.name) < 0) {
        throw Errors.type(f.span, '`${record.name}` has no field `${f.name}`');
      }
      seen.set(f.name, f);
    }
    final ordered = [];
    for (want in record.fields) {
      final init = seen.get(want.name);
      if (init == null) throw Errors.type(e.span, 'field `${want.name}` is missing');
      unify(want.ty, exp(init.value), init.span, 'in field `${want.name}`');
      ordered.push(init);
    }
    // The enum holds the array, so it is refilled rather than replaced.
    fields.splice(0, fields.length);
    for (f in ordered) fields.push(f);
    return TRecord(record);
  }

  function indexExp(e:Exp, array:Exp, index:Exp):Ty {
    return switch exp(array) {
      case TArray(elem):
        unify(TInt, exp(index), index.span, "as an array index");
        elem;
      case got: throw Errors.type(e.span, '`${Types.show(got)}` is not an array');
    }
  }

  function fieldExp(e:Exp, record:Exp, select:String):Ty {
    return switch exp(record) {
      case TRecord(r):
        final ty = r.fieldType(select);
        if (ty == null) throw Errors.type(e.span, '`${r.name}` has no field `$select`');
        e.offset = r.index(select);
        ty;
      case got: throw Errors.type(e.span, '`${Types.show(got)}` is not a record');
    }
  }

  function binop(e:Exp, op:String, lhs:Exp, rhs:Exp):Ty {
    final l = exp(lhs);
    final r = exp(rhs);
    if (ARITHMETIC.contains(op)) {
      unify(TInt, l, lhs.span, 'on the left of `$op`');
      unify(TInt, r, rhs.span, 'on the right of `$op`');
      return TInt;
    }
    if (op == "^") {
      unify(TString, l, lhs.span, "on the left of `^`");
      unify(TString, r, rhs.span, "on the right of `^`");
      return TString;
    }
    if (ORDERING.contains(op)) {
      return switch l {
        case TInt | TString:
          unify(l, r, rhs.span, 'on the right of `$op`');
          TBool;
        case _:
          throw Errors.type(e.span, '`$op` compares int or string, not `${Types.show(l)}`');
      }
    }
    if (EQUALITY.contains(op)) {
      if (l.match(TUnit) || r.match(TUnit)) {
        throw Errors.type(e.span, '`$op` cannot compare `unit`');
      }
      if (!Types.compatible(l, r)) {
        throw Errors.type(e.span,
          '`$op` compares `${Types.show(l)}` with `${Types.show(r)}`');
      }
      return TBool;
    }
    throw Errors.type(e.span, 'unknown operator `$op`');
  }

  function assign(e:Exp, target:Exp, value:Exp):Ty {
    final ty = exp(target);
    switch target.def {
      case EVar(_):
        final sym = target.variable();
        if (!sym.mutable) {
          throw Errors.type(e.span, '`${sym.name}` is a `val`, so it cannot be assigned');
        }
      case _:
    }
    unify(ty, exp(value), value.span, "in an assignment");
    return TUnit;
  }

  function ifExp(e:Exp, cond:Exp, then:Exp, els:Null<Exp>):Ty {
    unify(TBool, exp(cond), cond.span, "as an `if` condition");
    final t = exp(then);
    if (els == null) {
      unify(TUnit, t, then.span, "in an `if` with no `else`");
      return TUnit;
    }
    final other = exp(els);
    if (!Types.compatible(t, other)) {
      throw Errors.type(e.span,
        'the branches differ: `${Types.show(t)}` and `${Types.show(other)}`');
    }
    return t.match(TNil) ? other : t;
  }

  function forExp(e:Exp, name:String, lo:Exp, hi:Exp, body:Exp):Ty {
    unify(TInt, exp(lo), lo.span, "as a `for` bound");
    unify(TInt, exp(hi), hi.span, "as a `for` bound");
    final sym = new VarSym(name, TInt, false, depth);
    e.sym = Var(sym);
    push();
    bindVal(name, Var(sym));
    loops += 1;
    unify(TUnit, exp(body), body.span, "in a `for` body");
    loops -= 1;
    pop();
    return TUnit;
  }
}
