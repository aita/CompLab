package wolv;

import wolv.Diag;

/* Tokens, and the hand-written scanner that produces them. */

/** A token kind.  Its own name is what a token dump prints. */
enum Tok {
  INT; STRING; IDENT; EOF;
  AND; ANDALSO; BREAK; DO; ELSE; END; FALSE; FOR; FUN; IF; IN; LET; MOD;
  NIL; ORELSE; THEN; TO; TRUE; TYPE; VAL; VAR; WHILE;
  LPAREN; RPAREN; LBRACK; RBRACK; LBRACE; RBRACE; COMMA; COLON; SEMI; DOT;
  ASSIGN; EQ; NE; LE; LT; GE; GT; PLUS; MINUS; STAR; SLASH; CARET; TILDE;
}

/** One token, and where it started. */
class Token {
  public final kind:Tok;
  public final text:String;
  public final span:Span;

  public function new(kind:Tok, text:String, span:Span) {
    this.kind = kind;
    this.text = text;
    this.span = span;
  }

  public function toString():String {
    return switch (kind) {
      case EOF: "end of input";
      case STRING: '"' + text + '"';
      case _: "`" + text + "`";
    };
  }
}

/** What an error message calls each kind. */
function text(kind:Tok):String {
  return switch (kind) {
    case INT: "an integer";
    case STRING: "a string";
    case IDENT: "an identifier";
    case EOF: "end of input";
    case AND: "and"; case ANDALSO: "andalso"; case BREAK: "break";
    case DO: "do"; case ELSE: "else"; case END: "end"; case FALSE: "false";
    case FOR: "for"; case FUN: "fun"; case IF: "if"; case IN: "in";
    case LET: "let"; case MOD: "mod"; case NIL: "nil"; case ORELSE: "orelse";
    case THEN: "then"; case TO: "to"; case TRUE: "true"; case TYPE: "type";
    case VAL: "val"; case VAR: "var"; case WHILE: "while";
    case LPAREN: "("; case RPAREN: ")"; case LBRACK: "["; case RBRACK: "]";
    case LBRACE: "{"; case RBRACE: "}"; case COMMA: ","; case COLON: ":";
    case SEMI: ";"; case DOT: "."; case ASSIGN: ":="; case EQ: "=";
    case NE: "<>"; case LE: "<="; case LT: "<"; case GE: ">="; case GT: ">";
    case PLUS: "+"; case MINUS: "-"; case STAR: "*"; case SLASH: "/";
    case CARET: "^"; case TILDE: "~";
  };
}

final keywords:Array<Tok> = [
    AND, ANDALSO, BREAK, DO, ELSE, END, FALSE, FOR, FUN, IF, IN, LET, MOD,
    NIL, ORELSE, THEN, TO, TRUE, TYPE, VAL, VAR, WHILE,
  ];

/** Longest first, so that `:=` beats `:` and `<=` beats `<`. */
final punctuation:Array<Tok> = [
    ASSIGN, NE, LE, GE,
    LPAREN, RPAREN, LBRACK, RBRACK, LBRACE, RBRACE, COMMA, COLON, SEMI, DOT,
    EQ, LT, GT, PLUS, MINUS, STAR, SLASH, CARET, TILDE,
  ];

/** Turns source text into tokens, in one pass, no regexes. */
function lex(source:String):Array<Token> {
  return new Scanner(source).tokens();
}

/**
 * What a token dump calls a kind, which is the constructor's own name — so the
 * enum above is the table, and there is no second one to keep in step.
 */
function name(kind:Tok):String {
  return Std.string(kind);
}

function dump(tokens:Array<Token>):String {
  return tokens.map(t -> '${t.span}\t${name(t.kind)}\t${Ir.asText(t.text)}').join("\n");
}

/**
 * The scanner reads code points and not bytes, so a character outside the basic
 * plane is one character everywhere it matters: it is one column, it is a letter
 * if it is one, and inside a string literal it contributes the UTF-8 bytes of the
 * whole of itself.
 *
 * A Haxe string on this target is already a sequence of bytes, so the scanner
 * decodes UTF-8 itself.  What it calls a letter is ASCII plus everything above
 * ASCII: Haxe's standard library has no Unicode character database, and this is
 * the one place where the port approximates rather than matching Python exactly.
 */
class Scanner {
  final src:String;
  var pos:Int = 0;
  var line:Int = 1;
  var col:Int = 1;

  public function new(src:String) { this.src = src; }

  public function tokens():Array<Token> {
    var out = [];
    while (true) {
      var tok = next();
      out.push(tok);
      if (tok.kind == EOF) return out;
    }
  }

  // -- reading code points ------------------------------------------------

  inline function done():Bool return pos >= src.length;

  /** The code point under the cursor, and how many bytes it took. */
  function here():{code:Int, width:Int} {
    var b0 = src.charCodeAt(pos);
    if (b0 < 0x80) return {code: b0, width: 1};
    if (b0 < 0xE0) {
      return {code: ((b0 & 0x1F) << 6) | (src.charCodeAt(pos + 1) & 0x3F), width: 2};
    }
    if (b0 < 0xF0) {
      return {
        code: ((b0 & 0x0F) << 12) | ((src.charCodeAt(pos + 1) & 0x3F) << 6)
          | (src.charCodeAt(pos + 2) & 0x3F),
        width: 3,
      };
    }
    return {
      code: ((b0 & 0x07) << 18) | ((src.charCodeAt(pos + 1) & 0x3F) << 12)
        | ((src.charCodeAt(pos + 2) & 0x3F) << 6) | (src.charCodeAt(pos + 3) & 0x3F),
      width: 4,
    };
  }

  /** Move on by one code point, counting one column for it. */
  function step():Void {
    if (src.charCodeAt(pos) == "\n".code) {
      line += 1;
      col = 1;
      pos += 1;
      return;
    }
    col += 1;
    pos += here().width;
  }

  /** Move on by `n` bytes of ASCII, which is what punctuation is made of. */
  function advance(n:Int):Void for (_ in 0...n) step();

  inline function at():Span return new Span(line, col);

  static inline function isDigit(code:Int):Bool
    return code >= "0".code && code <= "9".code;

  static inline function isLetter(code:Int):Bool
    return (code >= "a".code && code <= "z".code)
      || (code >= "A".code && code <= "Z".code)
      || code >= 0x80;

  function startsWith(prefix:String):Bool
    return pos + prefix.length <= src.length && src.substr(pos, prefix.length) == prefix;

  function utf8(code:Int):String {
    var out = new StringBuf();
    if (code < 0x80) out.addChar(code);
    else if (code < 0x800) {
      out.addChar(0xC0 | (code >> 6));
      out.addChar(0x80 | (code & 0x3F));
    } else if (code < 0x10000) {
      out.addChar(0xE0 | (code >> 12));
      out.addChar(0x80 | ((code >> 6) & 0x3F));
      out.addChar(0x80 | (code & 0x3F));
    } else {
      out.addChar(0xF0 | (code >> 18));
      out.addChar(0x80 | ((code >> 12) & 0x3F));
      out.addChar(0x80 | ((code >> 6) & 0x3F));
      out.addChar(0x80 | (code & 0x3F));
    }
    return out.toString();
  }

  // -- the scanner --------------------------------------------------------

  function next():Token {
    skipTrivia();
    var start = at();
    if (done()) return new Token(EOF, "", start);

    var ch = here().code;
    if (isDigit(ch)) return number(start);
    if (isLetter(ch) || ch == "_".code) return word(start);
    if (ch == '"'.code) return string(start);
    for (kind in Lexer.punctuation) {
      var body = Lexer.text(kind);
      if (startsWith(body)) {
        advance(body.length);
        return new Token(kind, body, start);
      }
    }
    throw Errors.lex(start, "stray character `" + utf8(ch) + "`");
  }

  function number(start:Span):Token {
    var from = pos;
    while (!done() && isDigit(here().code)) step();
    var body = src.substr(from, pos - from);
    if (!done()) {
      var ch = here().code;
      if (isLetter(ch) || ch == "_".code) {
        throw Errors.lex(start, "`" + body + utf8(ch) + "` is not a number");
      }
    }
    return new Token(INT, body, start);
  }

  function word(start:Span):Token {
    var from = pos;
    while (!done()) {
      var ch = here().code;
      if (!isLetter(ch) && !isDigit(ch) && ch != "_".code && ch != "'".code) break;
      step();
    }
    var body = src.substr(from, pos - from);
    for (kind in Lexer.keywords) if (Lexer.text(kind) == body) {
      return new Token(kind, body, start);
    }
    return new Token(IDENT, body, start);
  }

  /**
   * Scan a string literal, which is a sequence of bytes.
   *
   * `size`, `ord` and `substring` count bytes at run time, so a literal is read
   * as bytes here too: source text contributes its UTF-8 encoding, and `\ddd`
   * names one byte.  A string on this target is already bytes, which is what
   * `Emit.escape` writes back out.
   */
  function string(start:Span):Token {
    step();
    var out = new StringBuf();
    while (true) {
      if (done()) throw Errors.lex(start, "unterminated string");
      var got = here();
      if (got.code == '"'.code) {
        step();
        return new Token(STRING, out.toString(), start);
      }
      if (got.code == "\n".code) throw Errors.lex(at(), "a string may not span lines");
      if (got.code == "\\".code) {
        step();
        out.addChar(escape());
        continue;
      }
      // One code point, as the UTF-8 bytes it already is.
      out.add(src.substr(pos, got.width));
      step();
    }
  }

  function escape():Int {
    if (done()) throw Errors.lex(at(), "unterminated escape");
    var ch = here().code;
    if (isDigit(ch)) {
      var value = 0;
      var ok = true;
      for (i in 0...3) {
        if (pos + i >= src.length) { ok = false; break; }
        var digit = src.charCodeAt(pos + i) - "0".code;
        if (digit < 0 || digit > 9) { ok = false; break; }
        value = value * 10 + digit;
      }
      if (ok && value < 256) {
        advance(3);
        return value;
      }
      throw Errors.lex(at(), "a numeric escape is three digits, `\\065`");
    }
    var got = switch (ch) {
      case "n".code: "\n".code;
      case "t".code: "\t".code;
      case "r".code: "\r".code;
      case c if (c == '"'.code || c == "\\".code): c;
      case _: -1;
    };
    if (got < 0) throw Errors.lex(at(), "unknown escape `\\" + utf8(ch) + "`");
    step();
    return got;
  }

  function skipTrivia():Void {
    while (!done()) {
      var ch = src.charCodeAt(pos);
      if (ch == " ".code || ch == "\t".code || ch == "\r".code || ch == "\n".code) {
        step();
      } else if (startsWith("(*")) {
        comment();
      } else {
        return;
      }
    }
  }

  function comment():Void {
    var start = at();
    var depth = 0;
    while (!done()) {
      if (startsWith("(*")) {
        depth += 1;
        advance(2);
      } else if (startsWith("*)")) {
        depth -= 1;
        advance(2);
        if (depth == 0) return;
      } else {
        step();
      }
    }
    throw Errors.lex(start, "unterminated comment");
  }
}
