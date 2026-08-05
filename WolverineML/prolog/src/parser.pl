/** <module> A Pratt parser, as a grammar over the tokens.
 *
 *  Every expression form is either a prefix form (in atom_exp//1) or an infix
 *  one (in exp_rest//3), and the table below is the whole of the precedence.
 *  The prefix forms that end in an expression -- `if`, `while`, `for`, `:=` --
 *  take their tail at binding power 0, so `if c then x := 1 else x := 2` reads
 *  the way it looks.
 *
 *  The lexer is a grammar over characters and this is a grammar over tokens,
 *  which is the same notation twice: `[token(then, _, _)]` is a terminal in
 *  exactly the way `"(*"` is one in the lexer.
 */

:- module(parser,
          [ parse/2,              % +Source, -Decls
            parse_exp/2           % +Source, -Exp
          ]).

:- use_module(diag).
:- use_module(ast).
:- use_module(lexer).

%   Left and right binding powers.
bp(assign, 2, 1).
bp(orelse, 4, 5).
bp(andalso, 6, 7).
bp(eq, 8, 9).   bp(ne, 8, 9).   bp(lt, 8, 9).
bp(le, 8, 9).   bp(gt, 8, 9).   bp(ge, 8, 9).
bp(caret, 10, 11).
bp(plus, 12, 13).  bp(minus, 12, 13).
bp(star, 14, 15).  bp(slash, 14, 15).  bp(mod, 14, 15).

unary_bp(16).

binop(plus, +).    binop(minus, -).   binop(star, *).   binop(slash, /).
binop(mod, mod).   binop(caret, ^).   binop(eq, =).     binop(ne, <>).
binop(lt, <).      binop(le, <=).     binop(gt, >).     binop(ge, >=).

decl_starter(val).  decl_starter(var).  decl_starter(fun).  decl_starter(type).

%!  parse(+Source, -Decls) is det.

parse(Source, Decls) :-
    lexer:lex(Source, Tokens),
    phrase(program(Decls), Tokens, []).

%!  parse_exp(+Source, -Exp) is det.
%
%   Parse a single expression -- the tests use it, the compiler does not.

parse_exp(Source, Exp) :-
    lexer:lex(Source, Tokens),
    phrase(one_exp(Exp), Tokens, []).

one_exp(E) -->
    exp(0, E),
    (   [token(eof, _, _)]
    ->  []
    ;   peek(Cur),
        { lexer:token_description(Cur, What),
          Cur = token(_, _, Span),
          format(atom(M), 'unexpected ~w after the expression', [What]),
          diag:throw_parse(Span, M) }
    ).

%   -- token plumbing ---------------------------------------------------------

peek(T), [T] --> [T].

take(Kind, token(Kind, Text, Span)) --> [token(Kind, Text, Span)].

expect(Kind, T) -->
    (   take(Kind, T0)
    ->  { T = T0 }
    ;   peek(Cur),
        { lexer:kind_text(Kind, Wanted),
          lexer:token_description(Cur, Found),
          Cur = token(_, _, Span),
          format(atom(M), 'expected `~w`, found ~w', [Wanted, Found]),
          diag:throw_parse(Span, M) }
    ).

expect_ident(T) -->
    (   take(ident, T0)
    ->  { T = T0 }
    ;   peek(Cur),
        { lexer:token_description(Cur, Found),
          Cur = token(_, _, Span),
          format(atom(M), 'expected a name, found ~w', [Found]),
          diag:throw_parse(Span, M) }
    ).

at(Kind) --> peek(token(Kind, _, _)).

%   -- programs and declarations ----------------------------------------------

program(Decls) -->
    (   at(eof)
    ->  { Decls = [] }, [token(eof, _, _)]
    ;   decl(D), program(Rest), { Decls = [D|Rest] }
    ).

decl(D) -->
    peek(token(Kind, _, Span)),
    (   { Kind == type } -> type_decl(D)
    ;   { Kind == val ; Kind == var } -> val_decl(D)
    ;   { Kind == fun } -> fun_decl(D)
    ;   { lexer:token_description(token(Kind, _, Span), Found),
          format(atom(M),
                 'expected a declaration (`val`, `var`, `fun`, `type`), found ~w',
                 [Found]),
          diag:throw_parse(Span, M) }
    ).

type_decl(type_decl(Binds, Span)) -->
    expect(type, token(_, _, Span)),
    type_bind(B), and_more(type_bind, Rest),
    { Binds = [B|Rest] }.

and_more(What, [B|Rest]) -->
    take(and, _), !, call(What, B), and_more(What, Rest).
and_more(_, []) --> [].

type_bind(type_bind(Name, Ty, Span)) -->
    expect_ident(token(_, Name, Span)), expect(eq, _), ty(Ty).

val_decl(val_decl(Name, Ty, Init, Mutable, Span, _Sym)) -->
    peek(token(Kind, _, Span)), [_],
    { ( Kind == var -> Mutable = true ; Mutable = false ) },
    (   take(lparen, _)
    ->  expect(rparen, _), { Name = none }
    ;   expect_ident(token(_, Name, _))
    ),
    (   take(colon, _) -> ty(Ty) ; { Ty = none } ),
    expect(eq, _),
    exp(0, Init).

fun_decl(fun_decl(Binds, Span)) -->
    expect(fun, token(_, _, Span)),
    fun_bind(B), and_more(fun_bind, Rest),
    { Binds = [B|Rest] }.

fun_bind(fun_bind(Name, Params, Result, Body, Span, _Sym)) -->
    expect_ident(token(_, Name, Span)),
    expect(lparen, _),
    (   take(rparen, _) -> { Params = [] }
    ;   params(Params), expect(rparen, _)
    ),
    (   take(colon, _) -> ty(Result) ; { Result = none } ),
    expect(eq, _),
    exp(0, Body).

params([param(Name, Ty, Span, _Sym)|Rest]) -->
    expect_ident(token(_, Name, Span)), expect(colon, _), ty(Ty),
    ( take(comma, _) -> params(Rest) ; { Rest = [] } ).

%   -- types ------------------------------------------------------------------

ty(Ty) -->
    peek(token(_, _, Span)),
    (   take(lbrace, _)
    ->  (   take(rbrace, _) -> { Fields = [] }
        ;   ty_fields(Fields), expect(rbrace, _)
        ),
        { Base = ty_record(Fields, Span) }
    ;   take(lparen, _)
    ->  ty(Base), expect(rparen, _)
    ;   expect_ident(token(_, Name, _)), { Base = ty_name(Name, Span) }
    ),
    array_suffix(Base, Span, Ty).

ty_fields([ty_field(Name, Ty, Span)|Rest]) -->
    expect_ident(token(_, Name, Span)), expect(colon, _), ty(Ty),
    ( take(comma, _) -> ty_fields(Rest) ; { Rest = [] } ).

array_suffix(Base, Span, Ty) -->
    (   peek(token(ident, "array", _))
    ->  [_], array_suffix(ty_array(Base, Span), Span, Ty)
    ;   { Ty = Base }
    ).

%   -- expressions ------------------------------------------------------------

exp(MinBp, E) --> atom_exp(Left), exp_rest(MinBp, Left, E).

exp_rest(MinBp, Left, E) -->
    peek(token(Kind, Text, Span)),
    { bp(Kind, Lbp, Rbp), Lbp >= MinBp },
    !,
    [_],
    (   { Kind == assign }
    ->  { check_lvalue(Left) },
        exp(Rbp, Rhs),
        { Next = exp(assign_exp(Left, Rhs), Span, _) }
    ;   { Kind == andalso ; Kind == orelse }
    ->  exp(Rbp, Rhs),
        { atom_string(Op, Text), Next = exp(logic_exp(Op, Left, Rhs), Span, _) }
    ;   exp(Rbp, Rhs),
        { binop(Kind, Op), Next = exp(bin_exp(Op, Left, Rhs), Span, _) }
    ),
    exp_rest(MinBp, Next, E).
exp_rest(_, E, E) --> [].

check_lvalue(E) :-
    (   ast:place(E)
    ->  true
    ;   ast:exp_span(E, Span),
        diag:throw_parse(Span, "the left of `:=` is not assignable")
    ).

atom_exp(E) -->
    peek(token(Kind, Text, Span)),
    (   { Kind == int }
    ->  [_], { number_string(Value, Text) },
        postfix(exp(int_lit(Value), Span, _), E)
    ;   { Kind == string }
    ->  [_], postfix(exp(str_lit(Text), Span, _), E)
    ;   { Kind == true ; Kind == false }
    ->  [_], { ( Kind == true -> V = true ; V = false ) },
        { E = exp(bool_lit(V), Span, _) }
    ;   { Kind == nil }    -> [_], { E = exp(nil_lit, Span, _) }
    ;   { Kind == break }  -> [_], { E = exp(break_exp, Span, _) }
    ;   { Kind == tilde }
    ->  [_], { unary_bp(Bp) }, exp(Bp, Operand),
        { E = exp(neg_exp(Operand), Span, _) }
    ;   { Kind == minus }
    ->  { diag:throw_parse(Span, "negation is written `~`, not `-`") }
    ;   { Kind == lparen } -> parens(Base), postfix(Base, E)
    ;   { Kind == ident }  -> named(Base), postfix(Base, E)
    ;   { Kind == if }     -> if_exp(E)
    ;   { Kind == while }  -> while_exp(E)
    ;   { Kind == for }    -> for_exp(E)
    ;   { Kind == let }    -> let_exp(E)
    ;   { lexer:token_description(token(Kind, Text, Span), Found),
          format(atom(M), 'expected an expression, found ~w', [Found]),
          diag:throw_parse(Span, M) }
    ).

parens(E) -->
    expect(lparen, token(_, _, Span)),
    (   take(rparen, _)
    ->  { E = exp(unit_lit, Span, _) }
    ;   sequence(rparen, Items), expect(rparen, _),
        { Items = [One] -> E = One ; E = exp(seq_exp(Items), Span, _) }
    ).

sequence(End, [E|Rest]) -->
    exp(0, E),
    (   take(semi, _)
    ->  ( at(End) -> { Rest = [] } ; sequence(End, Rest) )
    ;   { Rest = [] }
    ).

named(E) -->
    expect_ident(token(_, Name, Span)),
    (   take(lparen, _)
    ->  (   take(rparen, _) -> { Args = [] }
        ;   arguments(Args), expect(rparen, _)
        ),
        { E = exp(call_exp(Name, Args, _), Span, _) }
    ;   take(lbrace, _)
    ->  (   take(rbrace, _) -> { Fields = [] }
        ;   inits(Fields), expect(rbrace, _)
        ),
        { E = exp(record_lit(Name, Fields, _), Span, _) }
    ;   { E = exp(var_ref(Name, _), Span, _) }
    ).

arguments([A|Rest]) -->
    exp(0, A), ( take(comma, _) -> arguments(Rest) ; { Rest = [] } ).

inits([field_init(Name, Value, Span)|Rest]) -->
    expect_ident(token(_, Name, Span)), expect(eq, _), exp(0, Value),
    ( take(comma, _) -> inits(Rest) ; { Rest = [] } ).

postfix(Base, E) -->
    (   peek(token(lbrack, _, Span))
    ->  [_], exp(0, Index), expect(rbrack, _),
        postfix(exp(index_exp(Base, Index), Span, _), E)
    ;   peek(token(dot, _, Span))
    ->  [_], expect_ident(token(_, Name, _)),
        postfix(exp(field_exp(Base, Name, _), Span, _), E)
    ;   { E = Base }
    ).

if_exp(exp(if_exp(Test, Then, Else), Span, _)) -->
    expect(if, token(_, _, Span)), exp(0, Test),
    expect(then, _), exp(0, Then),
    ( take(else, _) -> exp(0, Else) ; { Else = none } ).

while_exp(exp(while_exp(Test, Body), Span, _)) -->
    expect(while, token(_, _, Span)), exp(0, Test),
    expect(do, _), exp(0, Body).

for_exp(exp(for_exp(Name, Lo, Hi, Body, _Sym), Span, _)) -->
    expect(for, token(_, _, Span)), expect_ident(token(_, Name, _)),
    expect(eq, _), exp(0, Lo),
    expect(to, _), exp(0, Hi),
    expect(do, _), exp(0, Body).

let_exp(exp(let_exp(Decls, Body), Span, _)) -->
    expect(let, token(_, _, Span)),
    let_decls(Decls),
    expect(in, _),
    (   at(end)
    ->  { Body = exp(unit_lit, Span, _) }
    ;   sequence(end, Items),
        { Items = [One] -> Body = One ; Body = exp(seq_exp(Items), Span, _) }
    ),
    expect(end, _).

let_decls([D|Rest]) -->
    peek(token(Kind, _, _)), { decl_starter(Kind) }, !,
    decl(D), let_decls(Rest).
let_decls([]) --> [].
