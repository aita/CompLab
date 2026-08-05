:- begin_tests(lexer).

:- use_module('../src/lexer', []).

kinds(Source, Kinds) :-
    lexer:lex(Source, Tokens),
    findall(K, member(token(K, _, _), Tokens), Kinds).

texts(Source, Texts) :-
    lexer:lex(Source, Tokens),
    findall(T, member(token(_, T, _), Tokens), Texts).

lex_error(Source, Message) :-
    catch(lexer:lex(Source, _), wolv_error(lex, _, M), true),
    sub_string(M, _, _, _, Message).

test('keywords are not identifiers') :-
    kinds("let val", [let, val, eof]),
    kinds("letter", [ident, eof]).

test('the longest punctuation wins') :-
    kinds(":= : <= < <> >=", [assign, colon, le, lt, ne, ge, eof]).

test('comments nest') :-
    kinds("(* a (* b *) c *) 1", [int, eof]).

test('an unterminated comment is an error') :-
    lex_error("(* forever", "unterminated comment").

test('string escapes') :-
    texts("\"a\\nb\\t\\\"\\\\\\065\"", [Text|_]),
    Text == "a\nb\t\"\\A".

test('a string is bytes') :-
    %   Source text contributes its UTF-8; `\ddd` names one byte of it.
    texts("\"日\"", [Direct|_]),
    texts("\"\\230\\151\\165\"", [Escaped|_]),
    Direct == Escaped,
    texts("\"日本語\"", [Three|_]),
    string_length(Three, 9).

test('a numeric escape is three digits') :-
    lex_error("\"\\65\"", "three digits").

test('a string may not span lines') :-
    lex_error("\"one\ntwo\"", "may not span lines").

test('spans count from one') :-
    lexer:lex("val\n  x", [token(_, _, span(1, 1)), token(_, _, span(2, 3))|_]).

test('a number may not run into a name') :-
    lex_error("12ab", "is not a number").

test('a stray character is an error') :-
    lex_error("a ? b", "stray character").

:- end_tests(lexer).
