package wolv;

import wolv.Diag;
import wolv.Types;

/* The syntax tree.
 *
 * Shaped the way Haxe shapes its own: a node is a record of where it was written
 * and what the checker learned about it, carrying an `enum` that says what it is.
 * Everything that walks the tree does it with one `switch` over that enum, and
 * the compiler is the one that insists no case was forgotten.
 *
 * The alternative — a class per node — cannot be switched over in Haxe at all,
 * only asked `Std.isOfType` in a chain, which is what a tree walk should never
 * have to be.
 *
 * The checker's findings live on the node and not in the enum because the enum is
 * immutable: `ty` on every expression, `sym` on the three that name something,
 * `offset` on a field access once its record type is known. */

/* -- types as they are written ---------------------------------------------- */

enum TyExp {
  TyNamed(span:Span, name:String);
  TyArrayOf(span:Span, elem:TyExp);
  TyRecordOf(span:Span, fields:Array<TyField>);
}

function tySpan(t:TyExp):Span {
  return switch t {
    case TyNamed(span, _) | TyArrayOf(span, _) | TyRecordOf(span, _): span;
  }
}

class TyField {
  public final name:String;
  public final ty:TyExp;
  public final span:Span;

  public function new(name:String, ty:TyExp, span:Span) {
    this.name = name;
    this.ty = ty;
    this.span = span;
  }
}

/* -- expressions ------------------------------------------------------------ */

/** What every expression carries: where it was written, what it is, what it is of. */
class Exp {
  public final span:Span;
  public final def:ExpDef;

  /** Filled in by the checker, and read by everything after it. */
  public var ty:Null<Ty> = null;

  /** What `EVar`, `ECall` and `EFor` name.  Null until the checker resolves it. */
  public var sym:Null<Sym> = null;

  /** Which word of the record `EField` reads.  -1 until the checker knows. */
  public var offset:Int = -1;

  public function new(span:Span, def:ExpDef) {
    this.span = span;
    this.def = def;
  }

  /** The variable this names, for the three nodes that name one. */
  public function variable():VarSym {
    return switch sym {
      case Var(v): v;
      case _: throw "not a variable";
    }
  }

  /** The function this calls. */
  public function callee():FunSym {
    return switch sym {
      case Fun(f): f;
      case _: throw "not a function";
    }
  }
}

enum ExpDef {
  EInt(value:haxe.Int64);
  EStr(value:String);
  EBool(value:Bool);
  ENil;
  EUnit;

  EVar(name:String);
  ECall(name:String, args:Array<Exp>);

  /** `fields` is rewritten in place by the checker, into declaration order. */
  ERecord(tyname:String, fields:Array<FieldInit>);

  EIndex(array:Exp, index:Exp);
  EField(record:Exp, name:String);
  ENeg(operand:Exp);
  EBin(op:String, lhs:Exp, rhs:Exp);

  /** `andalso` and `orelse`, which are control flow and not operators. */
  ELogic(op:String, lhs:Exp, rhs:Exp);

  EAssign(target:Exp, value:Exp);
  EIf(cond:Exp, then:Exp, els:Null<Exp>);
  EWhile(cond:Exp, body:Exp);
  EFor(name:String, lo:Exp, hi:Exp, body:Exp);
  EBreak;
  ESeq(items:Array<Exp>);
  ELet(decls:Array<Decl>, body:Exp);
}

class FieldInit {
  public final name:String;
  public final value:Exp;
  public final span:Span;

  public function new(name:String, value:Exp, span:Span) {
    this.name = name;
    this.value = value;
    this.span = span;
  }
}

/* -- declarations ----------------------------------------------------------- */

enum Decl {
  DType(span:Span, binds:Array<TypeBind>);
  DVal(bind:ValBind);
  DFun(span:Span, binds:Array<FunBind>);
}

function declSpan(d:Decl):Span {
  return switch d {
    case DType(span, _) | DFun(span, _): span;
    case DVal(bind): bind.span;
  }
}

class TypeBind {
  public final name:String;
  public final ty:TyExp;
  public final span:Span;

  public function new(name:String, ty:TyExp, span:Span) {
    this.name = name;
    this.ty = ty;
    this.span = span;
  }
}

class ValBind {
  /** null for `val () =`. */
  public final name:Null<String>;

  public final ty:Null<TyExp>;
  public final init:Exp;
  public final mutable:Bool;
  public final span:Span;
  public var sym:Null<VarSym> = null;

  public function new(span:Span, name:Null<String>, ty:Null<TyExp>, init:Exp, mutable:Bool) {
    this.span = span;
    this.name = name;
    this.ty = ty;
    this.init = init;
    this.mutable = mutable;
  }
}

class Param {
  public final name:String;
  public final ty:TyExp;
  public final span:Span;
  public var sym:Null<VarSym> = null;

  public function new(name:String, ty:TyExp, span:Span) {
    this.name = name;
    this.ty = ty;
    this.span = span;
  }
}

class FunBind {
  public final name:String;
  public final params:Array<Param>;
  public final result:Null<TyExp>;
  public final body:Exp;
  public final span:Span;
  public var sym:Null<FunSym> = null;

  public function new(name:String, params:Array<Param>, result:Null<TyExp>, body:Exp, span:Span) {
    this.name = name;
    this.params = params;
    this.result = result;
    this.body = body;
    this.span = span;
  }
}

class Program {
  public final decls:Array<Decl>;

  public function new(decls:Array<Decl>) {
    this.decls = decls;
  }
}
