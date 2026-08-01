package wolv;

import haxe.Int64;
import wolv.Ast;
import wolv.Diag;
import wolv.Lexer;

/* A Pratt parser.
 *
 * Every expression form is either a prefix form (nud, in `atom`) or an infix one
 * (led, in `exp`), and the table below is the whole of the precedence.  The prefix
 * forms that end in an expression — `if`, `while`, `for`, `:=` — take their tail
 * at binding power 0, so `if c then x := 1 else x := 2` reads the way it looks. */

class Parser {
  /** The left binding power, and the power the right side is read at. */
  public static function bindingPower(kind:Tok):Null<Array<Int>> {
    return switch (kind) {
      case ASSIGN: [2, 1]; // right associative
      case ORELSE: [4, 5];
      case ANDALSO: [6, 7];
      case EQ | NE | LT | LE | GT | GE: [8, 9];
      case CARET: [10, 11];
      case PLUS | MINUS: [12, 13];
      case STAR | SLASH | MOD: [14, 15];
      case _: null;
    };
  }

  public static final unaryBP = 16;

  public static function binop(kind:Tok):String {
    return switch (kind) {
      case PLUS: "+"; case MINUS: "-"; case STAR: "*"; case SLASH: "/";
      case MOD: "mod"; case CARET: "^"; case EQ: "="; case NE: "<>";
      case LT: "<"; case LE: "<="; case GT: ">"; case GE: ">=";
      case _: throw "no such operator";
    };
  }

  public static function parse(source:String):Program {
    return new Parse(Lexer.lex(source)).program();
  }

  /** Reads a single expression — the tests use it, the compiler does not. */
  public static function parseExp(source:String):Exp {
    var p = new Parse(Lexer.lex(source));
    var e = p.exp(0);
    if (!p.at(EOF)) {
      throw Errors.parse(p.cur().span, "unexpected " + p.cur() + " after the expression");
    }
    return e;
  }
}

class Parse {
  final toks:Array<Token>;
  var pos:Int = 0;

  public function new(toks:Array<Token>) { this.toks = toks; }

  // -- token plumbing -----------------------------------------------------

  public inline function cur():Token return toks[pos];

  public inline function at(kind:Tok):Bool return cur().kind == kind;

  function take(kind:Tok):Null<Token> {
    if (cur().kind != kind) return null;
    var t = cur();
    pos += 1;
    return t;
  }

  inline function took(kind:Tok):Bool return take(kind) != null;

  function expect(kind:Tok):Token {
    var t = take(kind);
    if (t == null) {
      throw Errors.parse(cur().span, "expected `" + Lexer.text(kind) + "`, found " + cur());
    }
    return t;
  }

  function expectIdent():Token {
    var t = take(IDENT);
    if (t == null) throw Errors.parse(cur().span, "expected a name, found " + cur());
    return t;
  }

  // -- programs and declarations ------------------------------------------

  public function program():Program {
    var decls = [];
    while (!at(EOF)) decls.push(decl());
    return new Program(decls);
  }

  function decl():Decl {
    return switch (cur().kind) {
      case TYPE: typeDecl();
      case VAL | VAR: valDecl();
      case FUN: funDecl();
      case _: throw Errors.parse(cur().span,
        "expected a declaration (`val`, `var`, `fun`, `type`), found " + cur());
    };
  }

  function typeDecl():Decl {
    var span = expect(TYPE).span;
    var binds = [typeBind()];
    while (took(AND)) binds.push(typeBind());
    return DType(span, binds);
  }

  function typeBind():TypeBind {
    var name = expectIdent();
    expect(EQ);
    return new TypeBind(name.text, ty(), name.span);
  }

  function valDecl():Decl {
    var mutable = cur().kind == VAR;
    var span = cur().span;
    pos += 1;
    var name:Null<String> = null;
    if (took(LPAREN)) expect(RPAREN);
    else name = expectIdent().text;
    var written:Null<TyExp> = took(COLON) ? ty() : null;
    expect(EQ);
    return DVal(new ValBind(span, name, written, exp(0), mutable));
  }

  function funDecl():Decl {
    var span = expect(FUN).span;
    var binds = [funBind()];
    while (took(AND)) binds.push(funBind());
    return DFun(span, binds);
  }

  function funBind():FunBind {
    var name = expectIdent();
    expect(LPAREN);
    var params = [];
    if (!took(RPAREN)) {
      while (true) {
        var pname = expectIdent();
        expect(COLON);
        params.push(new Param(pname.text, ty(), pname.span));
        if (!took(COMMA)) break;
      }
      expect(RPAREN);
    }
    var result:Null<TyExp> = took(COLON) ? ty() : null;
    expect(EQ);
    return new FunBind(name.text, params, result, exp(0), name.span);
  }

  // -- types --------------------------------------------------------------

  function ty():TyExp {
    var span = cur().span;
    var base:TyExp;
    if (took(LBRACE)) {
      var fields = [];
      if (!took(RBRACE)) {
        while (true) {
          var fname = expectIdent();
          expect(COLON);
          fields.push(new TyField(fname.text, ty(), fname.span));
          if (!took(COMMA)) break;
        }
        expect(RBRACE);
      }
      base = TyRecordOf(span, fields);
    } else if (took(LPAREN)) {
      base = ty();
      expect(RPAREN);
    } else {
      base = TyNamed(span, expectIdent().text);
    }
    while (cur().kind == IDENT && cur().text == "array") {
      pos += 1;
      base = TyArrayOf(span, base);
    }
    return base;
  }

  // -- expressions --------------------------------------------------------

  public function exp(minBp:Int):Exp {
    var left = atom();
    while (true) {
      var bp = Parser.bindingPower(cur().kind);
      if (bp == null || bp[0] < minBp) return left;
      var t = cur();
      pos += 1;
      left = switch (t.kind) {
        case ASSIGN:
          checkLvalue(left);
          new Exp(t.span, EAssign(left, exp(bp[1])));
        case ANDALSO | ORELSE:
          new Exp(t.span, ELogic(t.text, left, exp(bp[1])));
        case _:
          new Exp(t.span, EBin(Parser.binop(t.kind), left, exp(bp[1])));
      };
    }
  }

  function checkLvalue(e:Exp):Void {
    switch e.def {
      case EVar(_) | EIndex(_, _) | EField(_, _): // assignable
      case _: throw Errors.parse(e.span, "the left of `:=` is not assignable");
    }
  }

  function atom():Exp {
    var t = cur();
    var span = t.span;
    switch (t.kind) {
      case INT:
        pos += 1;
        return postfix(new Exp(span, EInt(integer(t))));
      case STRING:
        pos += 1;
        return postfix(new Exp(span, EStr(t.text)));
      case TRUE | FALSE:
        pos += 1;
        return new Exp(span, EBool(t.kind == TRUE));
      case NIL:
        pos += 1;
        return new Exp(span, ENil);
      case BREAK:
        pos += 1;
        return new Exp(span, EBreak);
      case TILDE:
        pos += 1;
        return new Exp(span, ENeg(exp(Parser.unaryBP)));
      case MINUS:
        throw Errors.parse(span, "negation is written `~`, not `-`");
      case LPAREN: return postfix(parens());
      case IDENT: return postfix(named());
      case IF: return ifExp();
      case WHILE: return whileExp();
      case FOR: return forExp();
      case LET: return letExp();
      case _: throw Errors.parse(span, "expected an expression, found " + cur());
    }
  }

  /** Integers are 64 bits and wrap, so the largest is `~9223372036854775808`. */
  function integer(t:Token):Int64 {
    var digits = t.text;
    var trimmed = digits;
    while (trimmed.length > 1 && trimmed.charAt(0) == "0") trimmed = trimmed.substr(1);
    var bound = "18446744073709551615";
    if (trimmed.length > bound.length || (trimmed.length == bound.length && trimmed > bound)) {
      throw Errors.parse(t.span, "`" + digits + "` does not fit in 64 bits");
    }
    var value = Int64.ofInt(0);
    var ten = Int64.ofInt(10);
    for (i in 0...digits.length) {
      value = value * ten + Int64.ofInt(digits.charCodeAt(i) - "0".code);
    }
    return value;
  }

  function parens():Exp {
    var span = expect(LPAREN).span;
    if (took(RPAREN)) return new Exp(span, EUnit);
    var items = sequence(RPAREN);
    expect(RPAREN);
    return items.length == 1 ? items[0] : new Exp(span, ESeq(items));
  }

  function sequence(end:Tok):Array<Exp> {
    var items = [exp(0)];
    while (took(SEMI)) {
      if (at(end)) break;
      items.push(exp(0));
    }
    return items;
  }

  function named():Exp {
    var t = expectIdent();
    switch (cur().kind) {
      case LPAREN:
        pos += 1;
        var args = [];
        if (!took(RPAREN)) {
          while (true) {
            args.push(exp(0));
            if (!took(COMMA)) break;
          }
          expect(RPAREN);
        }
        return new Exp(t.span, ECall(t.text, args));
      case LBRACE:
        pos += 1;
        var fields = [];
        if (!took(RBRACE)) {
          while (true) {
            var fname = expectIdent();
            expect(EQ);
            fields.push(new FieldInit(fname.text, exp(0), fname.span));
            if (!took(COMMA)) break;
          }
          expect(RBRACE);
        }
        return new Exp(t.span, ERecord(t.text, fields));
      case _:
        return new Exp(t.span, EVar(t.text));
    }
  }

  function postfix(start:Exp):Exp {
    var base = start;
    while (true) {
      switch (cur().kind) {
        case LBRACK:
          var span = cur().span;
          pos += 1;
          var index = exp(0);
          expect(RBRACK);
          base = new Exp(span, EIndex(base, index));
        case DOT:
          var span = cur().span;
          pos += 1;
          base = new Exp(span, EField(base, expectIdent().text));
        case _:
          return base;
      }
    }
  }

  function ifExp():Exp {
    var span = expect(IF).span;
    var cond = exp(0);
    expect(THEN);
    var then = exp(0);
    var els:Null<Exp> = took(ELSE) ? exp(0) : null;
    return new Exp(span, EIf(cond, then, els));
  }

  function whileExp():Exp {
    var span = expect(WHILE).span;
    var cond = exp(0);
    expect(DO);
    return new Exp(span, EWhile(cond, exp(0)));
  }

  function forExp():Exp {
    var span = expect(FOR).span;
    var name = expectIdent();
    expect(EQ);
    var lo = exp(0);
    expect(TO);
    var hi = exp(0);
    expect(DO);
    return new Exp(span, EFor(name.text, lo, hi, exp(0)));
  }

  function letExp():Exp {
    var span = expect(LET).span;
    var decls = [];
    while (switch (cur().kind) { case VAL | VAR | FUN | TYPE: true; case _: false; }) {
      decls.push(decl());
    }
    expect(IN);
    var body:Exp;
    if (at(END)) {
      body = new Exp(span, EUnit);
    } else {
      var items = sequence(END);
      body = items.length == 1 ? items[0] : new Exp(span, ESeq(items));
    }
    expect(END);
    return new Exp(span, ELet(decls, body));
  }
}
