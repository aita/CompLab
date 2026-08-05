/** <module> Source positions, and the one exception every pass throws.
 *
 *  A compile error is a thrown term.  Prolog has no other sensible way to
 *  leave a deeply nested relation that has just found out the program is
 *  wrong: failing would be indistinguishable from "try the next clause", and
 *  threading an error through every argument would double the width of the
 *  compiler.  So `wolv_error(Kind, Span, Message)` is thrown and `cli` is the
 *  only thing that catches it.
 */

:- module(diag,
          [ span_text/2,          % +Span, -Text
            throw_lex/2,          % +Span, +Message
            throw_parse/2,
            throw_type/2,
            error_text/2          % +Error, -Text
          ]).

%!  span_text(+Span, -Text) is det.
%
%   A position, counted from one, as `line:column`.

span_text(span(Line, Col), Text) :-
    format(atom(Text), '~d:~d', [Line, Col]).

throw_lex(Span, Message) :- throw(wolv_error(lex, Span, Message)).
throw_parse(Span, Message) :- throw(wolv_error(parse, Span, Message)).
throw_type(Span, Message) :- throw(wolv_error(type, Span, Message)).

%!  error_text(+Error, -Text) is det.

error_text(wolv_error(_, Span, Message), Text) :-
    span_text(Span, Where),
    format(atom(Text), '~w: ~w', [Where, Message]).
