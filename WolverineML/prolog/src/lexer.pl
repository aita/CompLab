/** <module> Tokens, and the scanner that produces them, as a grammar.
 *
 *  A definite clause grammar is what Prolog has instead of a hand-written
 *  scanner loop, and it is the same scanner: one pass, no regular expressions,
 *  longest punctuation first, nested comments.  What the DCG carries besides
 *  the characters is the position, threaded through as two extra arguments, so
 *  a token knows where it came from without anything being mutated.
 *
 *  A token is `token(Kind, Text, Span)`.  The kind is an atom, so there is no
 *  enumeration type to declare: the three tables below say how each kind is
 *  written in a dump, what an error message calls it, and which of them are
 *  words rather than identifiers.
 */

:- module(lexer,
          [ lex/2,                % +Source, -Tokens
            kind_name/2,          % ?Kind, ?DumpName
            kind_text/2,          % ?Kind, ?Written
            token_description/2,  % +Token, -Text
            utf8_codes/2          % +Code, -Bytes
          ]).

:- use_module(diag).

%   Each kind, the name a dump gives it, and what an error message calls it.
kind(int,      'INT',      "an integer").
kind(string,   'STRING',   "a string").
kind(ident,    'IDENT',    "an identifier").
kind(eof,      'EOF',      "end of input").
kind(and,      'AND',      "and").
kind(andalso,  'ANDALSO',  "andalso").
kind(break,    'BREAK',    "break").
kind(do,       'DO',       "do").
kind(else,     'ELSE',     "else").
kind(end,      'END',      "end").
kind(false,    'FALSE',    "false").
kind(for,      'FOR',      "for").
kind(fun,      'FUN',      "fun").
kind(if,       'IF',       "if").
kind(in,       'IN',       "in").
kind(let,      'LET',      "let").
kind(mod,      'MOD',      "mod").
kind(nil,      'NIL',      "nil").
kind(orelse,   'ORELSE',   "orelse").
kind(then,     'THEN',     "then").
kind(to,       'TO',       "to").
kind(true,     'TRUE',     "true").
kind(type,     'TYPE',     "type").
kind(val,      'VAL',      "val").
kind(var,      'VAR',      "var").
kind(while,    'WHILE',    "while").
kind(lparen,   'LPAREN',   "(").
kind(rparen,   'RPAREN',   ")").
kind(lbrack,   'LBRACK',   "[").
kind(rbrack,   'RBRACK',   "]").
kind(lbrace,   'LBRACE',   "{").
kind(rbrace,   'RBRACE',   "}").
kind(comma,    'COMMA',    ",").
kind(colon,    'COLON',    ":").
kind(semi,     'SEMI',     ";").
kind(dot,      'DOT',      ".").
kind(assign,   'ASSIGN',   ":=").
kind(eq,       'EQ',       "=").
kind(ne,       'NE',       "<>").
kind(le,       'LE',       "<=").
kind(lt,       'LT',       "<").
kind(ge,       'GE',       ">=").
kind(gt,       'GT',       ">").
kind(plus,     'PLUS',     "+").
kind(minus,    'MINUS',    "-").
kind(star,     'STAR',     "*").
kind(slash,    'SLASH',    "/").
kind(caret,    'CARET',    "^").
kind(tilde,    'TILDE',    "~").

kind_name(Kind, Name) :- kind(Kind, Name, _).
kind_text(Kind, Text) :- kind(Kind, _, Text).

%   The words that are not identifiers.
keyword("and", and).        keyword("andalso", andalso).
keyword("break", break).    keyword("do", do).
keyword("else", else).      keyword("end", end).
keyword("false", false).    keyword("for", for).
keyword("fun", fun).        keyword("if", if).
keyword("in", in).          keyword("let", let).
keyword("mod", mod).        keyword("nil", nil).
keyword("orelse", orelse).  keyword("then", then).
keyword("to", to).          keyword("true", true).
keyword("type", type).      keyword("val", val).
keyword("var", var).        keyword("while", while).

%   Longest first, so that `:=` beats `:` and `<=` beats `<`.
punct(":=", assign).  punct("<>", ne).   punct("<=", le).   punct(">=", ge).
punct("(", lparen).   punct(")", rparen). punct("[", lbrack). punct("]", rbrack).
punct("{", lbrace).   punct("}", rbrace). punct(",", comma). punct(":", colon).
punct(";", semi).     punct(".", dot).   punct("=", eq).    punct("<", lt).
punct(">", gt).       punct("+", plus).  punct("-", minus). punct("*", star).
punct("/", slash).    punct("^", caret). punct("~", tilde).

escape(0'n, 0'\n).  escape(0't, 0'\t).  escape(0'r, 0'\r).
escape(0'", 0'").   escape(0'\\, 0'\\).

%!  token_description(+Token, -Text) is det.
%
%   The token as an error message names it.

token_description(token(eof, _, _), "end of input") :- !.
token_description(token(string, Text, _), Written) :- !,
    format(atom(Written), '"~w"', [Text]).
token_description(token(_, Text, _), Written) :-
    format(atom(Written), '`~w`', [Text]).

%!  lex(+Source, -Tokens) is det.

lex(Source, Tokens) :-
    string_codes(Source, Codes),
    phrase(all_tokens(span(1, 1), Tokens), Codes, []).

%   The grammar carries the position and the tokens it has made; `phrase/4`
%   would only give one of them, so the tokens come out as an argument.
all_tokens(P0, [T|Ts]) -->
    next_token(P0, T, P),
    (   { T = token(eof, _, _) }
    ->  { Ts = [] }
    ;   all_tokens(P, Ts)
    ).

next_token(P0, Token, P) -->
    trivia(P0, P1),
    (   at_end
    ->  { Token = token(eof, "", P1), P = P1 }
    ;   peek(C),
        (   { digit_code(C) }        -> number_token(P1, Token, P)
        ;   { start_code(C) }        -> word_token(P1, Token, P)
        ;   { C =:= 0'" }            -> string_token(P1, Token, P)
        ;   punct_token(P1, Token, P)
        )
    ).

%   -- what a DCG needs that is not a terminal --------------------------------

at_end([], []).
peek(C, [C|Rest], [C|Rest]).

advance(C, span(Line, _), span(Next, 1)) :- C =:= 0'\n, !, Next is Line + 1.
advance(_, span(Line, Col), span(Line, Next)) :- Next is Col + 1.

advance_codes([], P, P).
advance_codes([C|Cs], P0, P) :- advance(C, P0, P1), advance_codes(Cs, P1, P).

advance_text(Text, P0, P) :- string_codes(Text, Cs), advance_codes(Cs, P0, P).

digit_code(C) :- C >= 0'0, C =< 0'9.
letter_code(C) :- C >= 0'a, C =< 0'z, !.
letter_code(C) :- C >= 0'A, C =< 0'Z, !.
letter_code(C) :- C > 127, code_type(C, alpha).
start_code(C) :- letter_code(C), !.
start_code(0'_).
word_code(C) :- letter_code(C), !.
word_code(C) :- digit_code(C), !.
word_code(0'_).
word_code(0'\').
space_code(C) :- memberchk(C, [0' , 0'\t, 0'\r, 0'\n]).

%   -- whitespace and comments ------------------------------------------------

trivia(P0, P) -->
    (   [C], { space_code(C) }
    ->  { advance(C, P0, P1) }, trivia(P1, P)
    ;   "(*"
    ->  { advance_text("(*", P0, P1) },
        comment(1, P0, P1, P2),
        trivia(P2, P)
    ;   { P = P0 }
    ).

comment(0, _, P, P) --> !, [].
comment(Depth, Start, P0, P) -->
    (   at_end
    ->  { diag:throw_lex(Start, "unterminated comment") }
    ;   "(*"
    ->  { advance_text("(*", P0, P1), Deeper is Depth + 1 },
        comment(Deeper, Start, P1, P)
    ;   "*)"
    ->  { advance_text("*)", P0, P1), Shallower is Depth - 1 },
        comment(Shallower, Start, P1, P)
    ;   [C], { advance(C, P0, P1) },
        comment(Depth, Start, P1, P)
    ).

%   -- numbers and words ------------------------------------------------------

number_token(P0, token(int, Text, P0), P) -->
    run(digit_code, Ds),
    { advance_codes(Ds, P0, P1), string_codes(Text, Ds) },
    (   peek(C), { start_code(C) }
    ->  { char_code(Ch, C),
          format(atom(Message), '`~w~w` is not a number', [Text, Ch]),
          diag:throw_lex(P0, Message) }
    ;   { P = P1 }
    ).

word_token(P0, token(Kind, Text, P0), P) -->
    run(word_code, Cs),
    { advance_codes(Cs, P0, P), string_codes(Text, Cs),
      ( keyword(Text, K) -> Kind = K ; Kind = ident ) }.

run(Test, [C|Cs]) --> [C], { call(Test, C) }, !, run(Test, Cs).
run(_, []) --> [].

punct_token(P0, token(Kind, Text, P0), P) -->
    { punct(Text, Kind), string_codes(Text, Cs) },
    Cs, !,
    { advance_codes(Cs, P0, P) }.
punct_token(P0, _, _) -->
    peek(C),
    { char_code(Ch, C),
      format(atom(Message), 'stray character `~w`', [Ch]),
      diag:throw_lex(P0, Message) }.

%   -- strings, which are sequences of bytes ----------------------------------
%
%   `size`, `ord` and `substring` count bytes at run time, so a literal is read
%   as bytes here too: source text contributes its UTF-8 encoding, and `\ddd`
%   names one byte.  Each byte becomes one character of the token's text, which
%   is what emit:escape writes back out.

string_token(P0, token(string, Text, P0), P) -->
    [0'"], { advance(0'", P0, P1) },
    string_body(P0, P1, Cs, P),
    { string_codes(Text, Cs) }.

string_body(Start, P0, Cs, P) -->
    (   at_end
    ->  { diag:throw_lex(Start, "unterminated string") }
    ;   [0'"]
    ->  { advance(0'", P0, P), Cs = [] }
    ;   peek(C), { C =:= 0'\n }
    ->  { diag:throw_lex(P0, "a string may not span lines") }
    ;   [0'\\]
    ->  { advance(0'\\, P0, P1) },
        escaped(P1, Byte, P2),
        string_body(Start, P2, Rest, P),
        { Cs = [Byte|Rest] }
    ;   [C],
        { advance(C, P0, P1),
          ( C < 128 -> Bytes = [C] ; utf8_codes(C, Bytes) ) },
        string_body(Start, P1, Rest, P),
        { append(Bytes, Rest, Cs) }
    ).

escaped(P0, Byte, P) -->
    (   at_end
    ->  { diag:throw_lex(P0, "unterminated escape") }
    ;   peek(C), { digit_code(C) }
    ->  numeric_escape(P0, Byte, P)
    ;   [C], { escape(C, Byte) }
    ->  { advance(C, P0, P) }
    ;   peek(C),
        { char_code(Ch, C),
          format(atom(Message), 'unknown escape `\\~w`', [Ch]),
          diag:throw_lex(P0, Message) }
    ).

numeric_escape(P0, Byte, P) -->
    (   [A, B, C],
        { digit_code(A), digit_code(B), digit_code(C),
          number_codes(Byte, [A, B, C]), Byte < 256 }
    ->  { advance_codes([A, B, C], P0, P) }
    ;   { diag:throw_lex(P0, "a numeric escape is three digits, `\\065`") }
    ).

%!  utf8_codes(+Code, -Bytes) is det.
%
%   The UTF-8 of one character, which is what a literal contributes.

utf8_codes(C, [C]) :- C < 0x80, !.
utf8_codes(C, [B0, B1]) :- C < 0x800, !,
    B0 is 0xC0 \/ (C >> 6), B1 is 0x80 \/ (C /\ 0x3F).
utf8_codes(C, [B0, B1, B2]) :- C < 0x10000, !,
    B0 is 0xE0 \/ (C >> 12),
    B1 is 0x80 \/ ((C >> 6) /\ 0x3F),
    B2 is 0x80 \/ (C /\ 0x3F).
utf8_codes(C, [B0, B1, B2, B3]) :-
    B0 is 0xF0 \/ (C >> 18),
    B1 is 0x80 \/ ((C >> 12) /\ 0x3F),
    B2 is 0x80 \/ ((C >> 6) /\ 0x3F),
    B3 is 0x80 \/ (C /\ 0x3F).
