package wolv;

/* Source positions, and the one error every pass throws. */

class Diag {
  /** A position in the source, counted from one. */
  public static function span(line:Int, col:Int):Span return new Span(line, col);
}

class Span {
  public final line:Int;
  public final col:Int;

  public function new(line:Int, col:Int) {
    this.line = line;
    this.col = col;
  }

  public function toString():String return line + ":" + col;
}

/** Which pass raised an error, so a test can ask for the one it means. */
enum Kind {
  LexKind;
  ParseKind;
  TypeKind;
}

/** A user-facing compile error, carrying where it happened. */
class WolvError {
  public final kind:Kind;
  public final span:Span;
  public final detail:String;

  public function new(kind:Kind, span:Span, detail:String) {
    this.kind = kind;
    this.span = span;
    this.detail = detail;
  }

  public function toString():String return span + ": " + detail;
}

class Errors {
  public static function lex(span:Span, detail:String):WolvError
    return new WolvError(LexKind, span, detail);

  public static function parse(span:Span, detail:String):WolvError
    return new WolvError(ParseKind, span, detail);

  public static function type(span:Span, detail:String):WolvError
    return new WolvError(TypeKind, span, detail);
}
