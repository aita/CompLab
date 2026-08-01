package wolv;

/* Semantic types, and the symbols that carry them.
 *
 * Types are monomorphic.  Records are nominal — two record types with the same
 * fields are different types — and everything else is structural, which for this
 * language means arrays compare by their element type.
 *
 * The enum is `Ty` and not `Type`, because Haxe's standard library already has a
 * `Type`.  Nominal records are why `TRecord` carries a class and not the fields
 * themselves: the class is the identity, and `same` compares it by reference. */

enum Ty {
  TInt;
  TString;
  TBool;
  TUnit;

  /** The type of `nil` before it is known which record it stands for. */
  TNil;

  TRecord(of:Record);
  TArray(elem:Ty);
}

/** Type equality: nominal for records, structural for arrays. */
function same(a:Ty, b:Ty):Bool {
  return switch [a, b] {
    case [TRecord(x), TRecord(y)]: x == y;
    case [TArray(x), TArray(y)]: same(x, y);
    case [TInt, TInt] | [TString, TString] | [TBool, TBool]
       | [TUnit, TUnit] | [TNil, TNil]: true;
    case _: false;
  }
}

/** Equality, but `nil` stands in for any record. */
function compatible(a:Ty, b:Ty):Bool {
  return switch [a, b] {
    case [TNil, TRecord(_)] | [TNil, TNil] | [TRecord(_), TNil]: true;
    case _: same(a, b);
  }
}

function show(t:Ty):String {
  return switch t {
    case TInt: "int";
    case TString: "string";
    case TBool: "bool";
    case TUnit: "unit";
    case TNil: "nil";
    case TRecord(of): of.name;
    case TArray(elem): show(elem) + " array";
  }
}

/**
 * The body of a record type.
 *
 * Mutable, and built empty first, because a record may name itself: `type list =
 * {head: int, tail: list}` needs `list` to exist before its fields can be typed.
 */
class Record {
  public final name:String;
  public final fields:Array<{name:String, ty:Ty}> = [];

  public function new(name:String) {
    this.name = name;
  }

  public function index(field:String):Int {
    for (at in 0...fields.length) if (fields[at].name == field) return at;
    return -1;
  }

  public function fieldType(field:String):Null<Ty> {
    final at = index(field);
    return at < 0 ? null : fields[at].ty;
  }
}

/* -- symbols ---------------------------------------------------------------- */

/**
 * What a name can be bound to.
 *
 * A variable and a function are different enough that an enum here would only be
 * unwrapped again at every use, so this is the one place a plain union of two
 * classes reads better than a constructor apiece.
 */
enum Sym {
  Var(v:VarSym);
  Fun(f:FunSym);
}

/**
 * One binding occurrence of a variable.
 *
 * `depth` is the static nesting depth of the function that binds it.  A variable
 * read from a deeper function escapes, and then it lives in a frame slot instead
 * of a register — which is what `escapes` and `slot` are filled in with.
 */
class VarSym {
  public final name:String;
  public final ty:Ty;
  public final mutable:Bool;
  public final depth:Int;
  public var escapes:Bool = false;
  public var slot:Int = -1;
  public var reg:Int = -1;

  public function new(name:String, ty:Ty, mutable:Bool, depth:Int) {
    this.name = name;
    this.ty = ty;
    this.mutable = mutable;
    this.depth = depth;
  }

  public function toString():String return name;
}

/** A function.  Functions are not values, so there is no function type. */
class FunSym {
  public final name:String;
  public final label:String;
  public final params:Array<VarSym>;
  public final result:Ty;
  public final depth:Int;

  /** null unless it is one of the prelude's. */
  public final builtin:Null<String>;

  public function new(name:String, label:String, params:Array<VarSym>, result:Ty, depth:Int,
      ?builtin:String) {
    this.name = name;
    this.label = label;
    this.params = params;
    this.result = result;
    this.depth = depth;
    this.builtin = builtin;
  }

  public function toString():String return name;
}
