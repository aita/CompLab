// Tokens, and the hand-written scanner that produces them.

import { Span, lexError } from "./diag.ts";

/** A token kind.  The value is what an error message calls it. */
export const TEXT = {
  INT: "an integer",
  STRING: "a string",
  IDENT: "an identifier",
  EOF: "end of input",

  AND: "and",
  ANDALSO: "andalso",
  BREAK: "break",
  DO: "do",
  ELSE: "else",
  END: "end",
  FALSE: "false",
  FOR: "for",
  FUN: "fun",
  IF: "if",
  IN: "in",
  LET: "let",
  MOD: "mod",
  NIL: "nil",
  ORELSE: "orelse",
  THEN: "then",
  TO: "to",
  TRUE: "true",
  TYPE: "type",
  VAL: "val",
  VAR: "var",
  WHILE: "while",

  LPAREN: "(",
  RPAREN: ")",
  LBRACK: "[",
  RBRACK: "]",
  LBRACE: "{",
  RBRACE: "}",
  COMMA: ",",
  COLON: ":",
  SEMI: ";",
  DOT: ".",
  ASSIGN: ":=",
  EQ: "=",
  NE: "<>",
  LE: "<=",
  LT: "<",
  GE: ">=",
  GT: ">",
  PLUS: "+",
  MINUS: "-",
  STAR: "*",
  SLASH: "/",
  CARET: "^",
  TILDE: "~",
} as const;

/** The kind is its own name, which is what a token dump prints. */
export type Tok = keyof typeof TEXT;

const isLetter = (ch: string): boolean => /\p{L}/u.test(ch);
const isDigit = (ch: string): boolean => /\p{Nd}/u.test(ch);

const KEYWORDS = new Map<string, Tok>(
  (Object.keys(TEXT) as Tok[])
    .filter((kind) => [...TEXT[kind]].every(isLetter))
    .map((kind) => [TEXT[kind], kind]),
);

// Longest first, so that `:=` beats `:` and `<=` beats `<`.
const PUNCTUATION: Tok[] = (Object.keys(TEXT) as Tok[])
  .filter((kind) => !isLetter(TEXT[kind][0]!))
  .sort((a, b) => TEXT[b].length - TEXT[a].length);

const ESCAPES = new Map<string, string>([
  ["n", "\n"],
  ["t", "\t"],
  ["r", "\r"],
  ['"', '"'],
  ["\\", "\\"],
]);

export class Token {
  readonly kind: Tok;
  readonly text: string;
  readonly span: Span;

  constructor(kind: Tok, text: string, span: Span) {
    this.kind = kind;
    this.text = text;
    this.span = span;
  }

  toString(): string {
    if (this.kind === "EOF") return "end of input";
    if (this.kind === "STRING") return `"${this.text}"`;
    return `\`${this.text}\``;
  }
}

/**
 * The scanner reads code points and not UTF-16 units, so a character outside the
 * basic plane is one character everywhere it matters: it is one column, it is a
 * letter if Unicode says it is, and inside a string literal it contributes the
 * UTF-8 bytes of the whole of itself.
 */
class Scanner {
  private readonly src: string;
  private pos = 0;
  private line = 1;
  private col = 1;

  constructor(src: string) {
    this.src = src;
  }

  tokens(): Token[] {
    const out: Token[] = [];
    for (;;) {
      const tok = this.next();
      out.push(tok);
      if (tok.kind === "EOF") return out;
    }
  }

  // -- reading code points ------------------------------------------------

  private get done(): boolean {
    return this.pos >= this.src.length;
  }

  /** The code point under the cursor, as a string of one character. */
  private here(): string {
    return String.fromCodePoint(this.src.codePointAt(this.pos)!);
  }

  /** Move on by `units` UTF-16 units, counting columns in code points. */
  private advance(units: number): void {
    for (let i = 0; i < units; i++) {
      const ch = this.src[this.pos]!;
      if (ch === "\n") {
        this.line += 1;
        this.col = 1;
      } else if (!(ch >= "\uDC00" && ch <= "\uDFFF")) {
        // A trailing surrogate is the second half of a character already counted.
        this.col += 1;
      }
      this.pos += 1;
    }
  }

  /** Move on by one code point. */
  private step(): void {
    this.advance(this.here().length);
  }

  private at(): Span {
    return new Span(this.line, this.col);
  }

  // -- the scanner --------------------------------------------------------

  private next(): Token {
    this.skipTrivia();
    const start = this.at();
    if (this.done) return new Token("EOF", "", start);

    const ch = this.here();
    if (isDigit(ch)) return this.number(start);
    if (isLetter(ch) || ch === "_") return this.word(start);
    if (ch === '"') return this.string(start);
    for (const kind of PUNCTUATION) {
      if (this.src.startsWith(TEXT[kind], this.pos)) {
        this.advance(TEXT[kind].length);
        return new Token(kind, TEXT[kind], start);
      }
    }
    throw lexError(start, `stray character \`${ch}\``);
  }

  private number(start: Span): Token {
    const from = this.pos;
    while (!this.done && isDigit(this.here())) this.step();
    const body = this.src.slice(from, this.pos);
    if (!this.done && (isLetter(this.here()) || this.here() === "_")) {
      throw lexError(start, `\`${body}${this.here()}\` is not a number`);
    }
    return new Token("INT", body, start);
  }

  private word(start: Span): Token {
    const from = this.pos;
    while (!this.done) {
      const ch = this.here();
      if (!isLetter(ch) && !isDigit(ch) && ch !== "_" && ch !== "'") break;
      this.step();
    }
    const body = this.src.slice(from, this.pos);
    return new Token(KEYWORDS.get(body) ?? "IDENT", body, start);
  }

  /**
   * Scan a string literal, which is a sequence of bytes.
   *
   * `size`, `ord` and `substring` count bytes at run time, so a literal is read
   * as bytes here too: source text contributes its UTF-8 encoding, and `\ddd`
   * names one byte.  Each byte is kept as one character of the string, which is
   * what `emit.escape` writes back out.
   */
  private string(start: Span): Token {
    this.step();
    const parts: string[] = [];
    for (;;) {
      if (this.done) throw lexError(start, "unterminated string");
      const ch = this.here();
      if (ch === '"') {
        this.step();
        return new Token("STRING", parts.join(""), start);
      }
      if (ch === "\n") throw lexError(this.at(), "a string may not span lines");
      if (ch === "\\") {
        this.step();
        parts.push(this.escape());
        continue;
      }
      if (ch.codePointAt(0)! < 0x80) {
        this.step();
        parts.push(ch);
        continue;
      }
      // One code point, surrogate pair and all, as its UTF-8 bytes.
      this.step();
      for (const byte of new TextEncoder().encode(ch)) {
        parts.push(String.fromCharCode(byte));
      }
    }
  }

  private escape(): string {
    if (this.done) throw lexError(this.at(), "unterminated escape");
    const ch = this.here();
    if (isDigit(ch)) {
      const digits = this.src.slice(this.pos, this.pos + 3);
      if (digits.length === 3 && /^[0-9]{3}$/.test(digits) && Number(digits) < 256) {
        this.advance(3);
        return String.fromCharCode(Number(digits));
      }
      throw lexError(this.at(), "a numeric escape is three digits, `\\065`");
    }
    const got = ESCAPES.get(ch);
    if (got === undefined) throw lexError(this.at(), `unknown escape \`\\${ch}\``);
    this.step();
    return got;
  }

  private skipTrivia(): void {
    while (!this.done) {
      const ch = this.src[this.pos]!;
      if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") this.advance(1);
      else if (this.src.startsWith("(*", this.pos)) this.comment();
      else return;
    }
  }

  private comment(): void {
    const start = this.at();
    let depth = 0;
    while (!this.done) {
      if (this.src.startsWith("(*", this.pos)) {
        depth += 1;
        this.advance(2);
      } else if (this.src.startsWith("*)", this.pos)) {
        depth -= 1;
        this.advance(2);
        if (depth === 0) return;
      } else {
        this.step();
      }
    }
    throw lexError(start, "unterminated comment");
  }
}

export const lex = (source: string): Token[] => new Scanner(source).tokens();
