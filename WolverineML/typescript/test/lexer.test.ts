import { test } from "node:test";
import assert from "node:assert/strict";

import { WolvError } from "../src/diag.ts";
import { lex, type Tok } from "../src/lexer.ts";

const kinds = (source: string): Tok[] => lex(source).map((t) => t.kind);

const refuses = (source: string, want: string): void => {
  assert.throws(() => lex(source), (e: unknown) => {
    assert.ok(e instanceof WolvError);
    assert.ok(e.detail.includes(want), `${e.detail} should mention ${want}`);
    return true;
  });
};

const utf8 = (text: string): string =>
  [...new TextEncoder().encode(text)].map((b) => String.fromCharCode(b)).join("");

test("keywords are not identifiers", () => {
  assert.deepEqual(kinds("let val"), ["LET", "VAL", "EOF"]);
  assert.deepEqual(kinds("letter"), ["IDENT", "EOF"]);
});

test("longest punctuation wins", () => {
  assert.deepEqual(kinds(":= : <= < <> >="), ["ASSIGN", "COLON", "LE", "LT", "NE", "GE", "EOF"]);
});

test("comments nest", () => {
  assert.deepEqual(kinds("(* a (* b *) c *) 1"), ["INT", "EOF"]);
});

test("an unterminated comment is caught", () => refuses("(* forever", "unterminated comment"));

test("string escapes", () => {
  assert.equal(lex(String.raw`"a\nb\t\"\\\065"`)[0]!.text, 'a\nb\t"\\A');
});

test("a string is bytes", () => {
  assert.equal(lex('"日"')[0]!.text, utf8("日"));
  assert.equal(lex(String.raw`"\230\151\165"`)[0]!.text, utf8("日"));
  assert.equal(lex('"日本語"')[0]!.text.length, 9);
});

test("a character outside the basic plane is four bytes and one column", () => {
  const emoji = "\u{1F600}";
  assert.equal(lex(`"${emoji}"`)[0]!.text.length, 4);
  assert.equal(lex(`"${emoji}"`)[0]!.text, utf8(emoji));
  // The pair is one character, so a column counts it once.
  assert.equal(String(lex(`(*${emoji}*) x`)[0]!.span), "1:7");
});

test("a name may be written in any script", () => {
  assert.deepEqual(kinds("名前"), ["IDENT", "EOF"]);
});

test("a numeric escape is three digits", () => refuses(String.raw`"\65"`, "three digits"));

test("a string may not span lines", () => refuses('"one\ntwo"', "may not span lines"));

test("spans count from one", () => {
  const toks = lex("val\n  x");
  assert.equal(String(toks[0]!.span), "1:1");
  assert.equal(String(toks[1]!.span), "2:3");
});

test("a number may not run into a name", () => refuses("12ab", "is not a number"));

test("a stray character is caught", () => refuses("a ? b", "stray character"));
