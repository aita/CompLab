/** <module> Random programs whose answer is known before they are compiled.
 *
 *  The other tests say what the compiler should do; these say what the program
 *  should print, which is the only thing a user cares about.  A program is
 *  built at random, worked out here with the language's arithmetic, and then
 *  compiled -- so any disagreement is a bug in the compiler and not in a
 *  comparison between two of its own configurations.
 *
 *  The generator carries its own linear congruential sequence rather than
 *  using `random/1`, because a failing case has to be reachable again from its
 *  seed.
 */

:- module(oracle, [arithmetic/4, imperative/4]).

:- use_module(library(assoc)).
:- use_module(library(lists)).
:- use_module('../src/i64', []).

size(16).
vars(["v0", "v1", "v2", "v3"]).
constants([0, 1, 2, 3, 7, 8, 15, 16, 100, 4095, 4096, 65536, -1, -8, 1099511627776]).
arguments([[0, 0, 0], [1, 2, 3], [-1, 7, -13], [Max, Min, 2]]) :-
    Max is (1 << 63) - 1, Min is -(1 << 63).
orders([=, <>, <, <=, >, >=]).

%   -- the source of chance ---------------------------------------------------

next(S0, N, S) :-
    S is (6364136223846793005 * S0 + 1442695040888963407) mod (1 << 64),
    N is S >> 33.

below(S0, Limit, N, S) :- next(S0, Raw, S), N is Raw mod Limit.
roll(S0, R, S) :- below(S0, 1000, N, S), R is N / 1000.0.
pick(S0, Xs, X, S) :- length(Xs, L), below(S0, L, I, S), nth0(I, Xs, X).
between_(S0, Lo, Hi, N, S) :- Span is Hi - Lo + 1, below(S0, Span, K, S), N is Lo + K.

%   `+` twice as likely as `/`, because a division that turns out to be by zero
%   throws the whole expression away and generating them is not free.
weighted(S0, Choices, Weights, Choice, S) :-
    sum_list(Weights, Total),
    below(S0, Total, Target, S),
    walk_weights(Choices, Weights, Target, 0, Choice).

walk_weights([C|_], [W|_], Target, Seen, C) :- Target < Seen + W, !.
walk_weights([_|Cs], [W|Ws], Target, Seen, C) :-
    Next is Seen + W, walk_weights(Cs, Ws, Target, Next, C).

%   -- the arithmetic half ----------------------------------------------------

literal(V, T) :- V < 0, !, P is -V, format(atom(T), '~~~d', [P]).
literal(V, T) :- format(atom(T), '~d', [V]).

expression(S0, Depth, Node, S) :-
    roll(S0, R, S1),
    (   ( Depth =:= 0 ; R < 0.25 )
    ->  leaf(S1, Node, S)
    ;   roll(S1, R2, S2),
        (   R2 < 0.1
        ->  branch(S2, Depth, Node, S)
        ;   operator(S2, Depth, Node, S)
        )
    ).

leaf(S0, Node, S) :-
    roll(S0, R, S1),
    (   R < 0.5
    ->  pick(S1, ["a", "b", "c"], Name, S), Node = var(Name)
    ;   constants(Cs), pick(S1, Cs, V, S), Node = int(V)
    ).

branch(S0, Depth, if(Op, A, B, T, E), S) :-
    orders(Orders), pick(S0, Orders, Op, S1),
    Inner is Depth - 1,
    expression(S1, Inner, A, S2), expression(S2, Inner, B, S3),
    expression(S3, Inner, T, S4), expression(S4, Inner, E, S).

operator(S0, Depth, bin(Op, A, B), S) :-
    weighted(S0, [+, -, *, /, mod], [4, 3, 3, 1, 1], Op, S1),
    Inner is Depth - 1,
    expression(S1, Inner, A, S2), expression(S2, Inner, B, S).

compares(Op, A, B) :- i64:i64_order(Op, A, B).

evaluate(var(Name), Env, V) :- memberchk(Name-V, Env).
evaluate(int(V), _, V).
evaluate(if(Op, A, B, T, E), Env, V) :-
    evaluate(A, Env, X), evaluate(B, Env, Y),
    ( compares(Op, X, Y) -> evaluate(T, Env, V) ; evaluate(E, Env, V) ).
evaluate(bin(Op, A, B), Env, V) :-
    evaluate(A, Env, X), evaluate(B, Env, Y),
    ( i64:i64_arith(Op, X, Y, V) -> true ; throw(divided_by_zero) ).

show(var(Name), Name).
show(int(V), T) :- literal(V, T).
show(if(Op, A, B, T, E), Text) :-
    show(A, As), show(B, Bs), show(T, Ts), show(E, Es),
    format(atom(Text), '(if ~w ~w ~w then ~w else ~w)', [As, Op, Bs, Ts, Es]).
show(bin(Op, A, B), Text) :-
    show(A, As), show(B, Bs), format(atom(Text), '(~w ~w ~w)', [As, Op, Bs]).

%!  arithmetic(+Seed, +Count, -Source, -Expected) is det.
%
%   Count functions of three arguments, and what they print.

arithmetic(Seed, Count, Source, Expected) :-
    build_functions(Seed, 0, Count, [], Definitions, [], Calls, [], Values),
    reverse(Definitions, Ds), reverse(Calls, Cs), reverse(Values, Vs),
    append(Ds, Cs, Lines),
    atomic_list_concat(Lines, '\n', Body), format(string(Source), '~w\n', [Body]),
    atomic_list_concat(Vs, '\n', Want), format(string(Expected), '~w\n', [Want]).

build_functions(_, Made, Made, Ds, Ds, Cs, Cs, Vs, Vs) :- !.
build_functions(S0, Made, Count, Ds0, Ds, Cs0, Cs, Vs0, Vs) :-
    between_(S0, 1, 5, Depth, S1),
    expression(S1, Depth, Tree, S2),
    arguments(Arguments),
    (   catch(findall(V, ( member(Args, Arguments),
                           pairs_with(Args, Env),
                           evaluate(Tree, Env, V) ), Answers),
              divided_by_zero, fail)
    ->  show(Tree, Written),
        format(atom(Definition),
               'fun f~d (a : int, b : int, c : int) : int = ~w', [Made, Written]),
        findall(Call, ( member(Args, Arguments), maplist(literal, Args, Ls),
                        atomic_list_concat(Ls, ', ', Written2),
                        format(atom(Call),
                               'val () = (printInt (f~d (~w)); print ("\\n"))',
                               [Made, Written2]) ), NewCalls),
        reverse(NewCalls, Reversed),
        append(Reversed, Cs0, Cs1),
        reverse(Answers, ReversedAnswers),
        append(ReversedAnswers, Vs0, Vs1),
        Next is Made + 1,
        build_functions(S2, Next, Count, [Definition|Ds0], Ds, Cs1, Cs, Vs1, Vs)
    ;   build_functions(S2, Made, Count, Ds0, Ds, Cs0, Cs, Vs0, Vs)
    ).

pairs_with([A, B, C], ["a"-A, "b"-B, "c"-C]).

%   -- the imperative half ----------------------------------------------------

place(S0, Scope, Node, S) :-
    roll(S0, R, S1),
    (   R < 0.35 -> pick(S1, Scope, Name, S), Node = var(Name)
    ;   R < 0.5 -> constants(Cs), pick(S1, Cs, V, S), Node = int(V)
    ;   R < 0.65 -> place(S1, Scope, Inner, S), Node = get(Inner)
    ;   pick(S1, [+, -, *], Op, S2),
        place(S2, Scope, A, S3), place(S3, Scope, B, S),
        Node = bin(Op, A, B)
    ).

statement(S0, Depth, Scope, Fresh0, Node, S, Fresh) :-
    roll(S0, R, S1),
    (   Depth > 0, R < 0.2
    ->  orders(Orders), pick(S1, Orders, Op, S2),
        place(S2, Scope, A, S3), place(S3, Scope, B, S4),
        Inner is Depth - 1,
        statement(S4, Inner, Scope, Fresh0, T, S5, Fresh1),
        statement(S5, Inner, Scope, Fresh1, E, S, Fresh),
        Node = if(Op, A, B, T, E)
    ;   Depth > 0, R < 0.45
    ->  Fresh1 is Fresh0 + 1,
        format(string(Name), 'i~d', [Fresh1]),
        between_(S1, 0, 2, Lo, S2), between_(S2, 2, 5, Hi, S3),
        Inner is Depth - 1,
        append(Scope, [Name], Deeper),
        statement(S3, Inner, Deeper, Fresh1, Body, S, Fresh),
        Node = for(Name, Lo, Hi, Body)
    ;   Depth > 0, R < 0.55
    ->  Inner is Depth - 1,
        statement(S1, Inner, Scope, Fresh0, A, S2, Fresh1),
        statement(S2, Inner, Scope, Fresh1, B, S, Fresh),
        Node = seq([A, B])
    ;   R < 0.8
    ->  vars(Vs), pick(S1, Vs, Name, S2), place(S2, Scope, V, S),
        Fresh = Fresh0, Node = set(Name, V)
    ;   place(S1, Scope, A, S2), place(S2, Scope, B, S),
        Fresh = Fresh0, Node = put(A, B)
    ).

%   `index` in the generated program: the remainder, made positive.
cell(Value, Cell) :-
    size(N), i64:i64_arith(/, Value, N, Q), R is Value - Q * N,
    Cell is (R + N) mod N.

run_place(var(Name), Env, _, V) :- get_assoc(Name, Env, V).
run_place(int(V), _, _, V).
run_place(get(Inner), Env, Array, V) :-
    run_place(Inner, Env, Array, Raw), cell(Raw, Cell), nth0(Cell, Array, V).
run_place(bin(Op, A, B), Env, Array, V) :-
    run_place(A, Env, Array, X), run_place(B, Env, Array, Y),
    i64:i64_arith(Op, X, Y, V).

%   The environment and the array are both threaded, because a `for` binds a
%   variable the loop above it does not have.
run(set(Name, V), Env0, Array, Env, Array) :-
    run_place(V, Env0, Array, Value), put_assoc(Name, Env0, Value, Env).
run(put(Where, What), Env, Array0, Env, Array) :-
    run_place(Where, Env, Array0, Raw), cell(Raw, Cell),
    run_place(What, Env, Array0, Value),
    nth0(Cell, Array0, _, Rest), nth0(Cell, Array, Value, Rest).
run(seq([A, B]), Env0, Array0, Env, Array) :-
    run(A, Env0, Array0, Env1, Array1), run(B, Env1, Array1, Env, Array).
run(if(Op, A, B, T, E), Env0, Array0, Env, Array) :-
    run_place(A, Env0, Array0, X), run_place(B, Env0, Array0, Y),
    ( compares(Op, X, Y) -> run(T, Env0, Array0, Env, Array)
    ; run(E, Env0, Array0, Env, Array) ).
run(for(Name, Lo, Hi, Body), Env0, Array0, Env, Array) :-
    numlist(Lo, Hi, Steps),
    foldl(one_step(Name, Body), Steps, Env0-Array0, Env-Array).

one_step(Name, Body, I, Env0-Array0, Env-Array) :-
    put_assoc(Name, Env0, I, Inner),
    run(Body, Inner, Array0, Env, Array).

show_place(get(Inner), T) :- !,
    show_place(Inner, S), format(atom(T), 'xs[index (~w)]', [S]).
show_place(bin(Op, A, B), T) :- !,
    show_place(A, X), show_place(B, Y), format(atom(T), '(~w ~w ~w)', [X, Op, Y]).
show_place(Node, T) :- show(Node, T).

show_statement(set(Name, V), Indent, T) :-
    show_place(V, S), format(atom(T), '~w~w := ~w', [Indent, Name, S]).
show_statement(put(Where, What), Indent, T) :-
    show_place(Where, A), show_place(What, B),
    format(atom(T), '~wxs[index (~w)] := ~w', [Indent, A, B]).
show_statement(seq(Items), Indent, T) :-
    atom_concat(Indent, '  ', Deeper),
    findall(S, ( member(I, Items), show_statement(I, Deeper, S) ), Parts),
    atomic_list_concat(Parts, ';\n', Body),
    format(atom(T), '~w(\n~w\n~w)', [Indent, Body, Indent]).
show_statement(if(Op, A, B, Then, Else), Indent, T) :-
    atom_concat(Indent, '  ', Deeper),
    show_place(A, X), show_place(B, Y),
    show_statement(Then, Deeper, Ts), show_statement(Else, Deeper, Es),
    format(atom(T), '~wif ~w ~w ~w then\n~w\n~welse\n~w',
           [Indent, X, Op, Y, Ts, Indent, Es]).
show_statement(for(Name, Lo, Hi, Body), Indent, T) :-
    atom_concat(Indent, '  ', Deeper),
    show_statement(Body, Deeper, Bs),
    format(atom(T), '~wfor ~w = ~d to ~d do\n~w', [Indent, Name, Lo, Hi, Bs]).

preamble("val xs = array (16, 0)
fun index (n : int) : int =
  let val r = n - n / 16 * 16 in
    if r < 0 then r + 16 else r
  end
").

%!  imperative(+Seed, +Count, -Source, -Expected) is det.
%
%   A program of assignments, loops and branches over an array.

imperative(Seed, Count, Source, Expected) :-
    build_statements(Seed, Count, Body),
    size(N), length(Array0, N), maplist(=(0), Array0),
    vars(Vars),
    findall(V-0, member(V, Vars), Zeros), list_to_assoc(Zeros, Env0),
    foldl(run_one, Body, Env0-Array0, Env-Array),
    findall(T, ( member(V, Vars), get_assoc(V, Env, X), format(atom(T), '~d', [X]) ),
            Finals),
    findall(T, ( member(X, Array), format(atom(T), '~d', [X]) ), Cells),
    append(Finals, Cells, Wanted),
    atomic_list_concat(Wanted, '\n', Want),
    format(string(Expected), '~w\n', [Want]),
    preamble(Preamble),
    findall(D, ( member(V, Vars), format(atom(D), 'var ~w = 0', [V]) ), Declarations),
    findall(S, ( member(I, Body), show_statement(I, '  ', S) ), Statements),
    atomic_list_concat(Statements, ';\n', Block),
    findall(P, ( member(V, Vars),
                 format(atom(P), 'val () = (printInt (~w); print ("\\n"))', [V]) ),
            Prints),
    append([[Preamble], Declarations, ['val () = (', Block, ')'], Prints,
            ['val () = for k = 0 to 15 do (printInt (xs[k]); print ("\\n"))']],
           Lines),
    atomic_list_concat(Lines, '\n', Text),
    format(string(Source), '~w\n', [Text]).

run_one(Node, Env0-Array0, Env-Array) :- run(Node, Env0, Array0, Env, Array).

build_statements(Seed, Count, Body) :- statements(Seed, Count, Body).

statements(_, 0, []) :- !.
statements(S0, Count, [Node|Rest]) :-
    vars(Vars),
    statement(S0, 3, Vars, 0, Node, S, _),
    Next is Count - 1,
    statements(S, Next, Rest).

:- use_module(library(pairs)).
