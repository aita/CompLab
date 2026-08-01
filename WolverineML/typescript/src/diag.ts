// Source positions, and the one error every pass throws.

export class Span {
  readonly line: number;
  readonly col: number;

  constructor(line: number, col: number) {
    this.line = line;
    this.col = col;
  }

  toString(): string {
    return `${this.line}:${this.col}`;
  }
}

/** Which pass raised an error, so a test can ask for the one it means. */
export type Kind = "lex" | "parse" | "typecheck";

/** A user-facing compile error, carrying where it happened. */
export class WolvError extends Error {
  readonly kind: Kind;
  readonly span: Span;
  readonly detail: string;

  constructor(kind: Kind, span: Span, detail: string) {
    super(`${span}: ${detail}`);
    this.name = "WolvError";
    this.kind = kind;
    this.span = span;
    this.detail = detail;
  }
}

export const lexError = (span: Span, detail: string): WolvError =>
  new WolvError("lex", span, detail);

export const parseError = (span: Span, detail: string): WolvError =>
  new WolvError("parse", span, detail);

export const typeError = (span: Span, detail: string): WolvError =>
  new WolvError("typecheck", span, detail);
