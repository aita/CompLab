:- begin_tests(parser).

:- use_module('../src/parser', []).
:- use_module('../src/ast', []).

%   A parenthesised sketch of the tree, so precedence is easy to assert.
shape(Exp, Text) :- ast:exp_node(Exp, Node), sketch(Node, Text).

shapes(Exps, Text) :-
    maplist(shape, Exps, Parts),
    atomic_list_concat(Parts, ' ', Text).

sketch(int_lit(V), T) :- format(atom(T), '~d', [V]).
sketch(str_lit(V), T) :- format(atom(T), '"~w"', [V]).
sketch(bool_lit(V), V).
sketch(nil_lit, nil).
sketch(unit_lit, '()').
sketch(var_ref(Name, _), T) :- atom_string(T, Name).
sketch(break_exp, break).
sketch(neg_exp(E), T) :- shape(E, S), format(atom(T), '(~~ ~w)', [S]).
sketch(bin_exp(Op, L, R), T) :-
    shape(L, A), shape(R, B), format(atom(T), '(~w ~w ~w)', [Op, A, B]).
sketch(logic_exp(Op, L, R), T) :-
    shape(L, A), shape(R, B), format(atom(T), '(~w ~w ~w)', [Op, A, B]).
sketch(assign_exp(Target, Value), T) :-
    shape(Target, A), shape(Value, B), format(atom(T), '(:= ~w ~w)', [A, B]).
sketch(if_exp(C, Then, none), T) :- !,
    shape(C, A), shape(Then, B), format(atom(T), '(if ~w ~w)', [A, B]).
sketch(if_exp(C, Then, Else), T) :-
    shape(C, A), shape(Then, B), shape(Else, E),
    format(atom(T), '(if ~w ~w ~w)', [A, B, E]).
sketch(while_exp(C, Body), T) :-
    shape(C, A), shape(Body, B), format(atom(T), '(while ~w ~w)', [A, B]).
sketch(for_exp(Name, Lo, Hi, Body, _), T) :-
    shape(Lo, A), shape(Hi, B), shape(Body, C),
    format(atom(T), '(for ~w ~w ~w ~w)', [Name, A, B, C]).
sketch(seq_exp(Items), T) :- shapes(Items, S), format(atom(T), '(seq ~w)', [S]).
sketch(call_exp(Name, Args, _), T) :-
    shapes(Args, S), format(atom(T), '(~w ~w)', [Name, S]).
sketch(index_exp(A, I), T) :-
    shape(A, X), shape(I, Y), format(atom(T), '(index ~w ~w)', [X, Y]).
sketch(field_exp(R, Name, _), T) :-
    shape(R, X), format(atom(T), '(field ~w ~w)', [X, Name]).
sketch(record_lit(Name, Fields, _), T) :-
    findall(P, ( member(field_init(F, V, _), Fields), shape(V, S),
                 format(atom(P), '~w=~w', [F, S]) ), Parts),
    atomic_list_concat(Parts, ' ', Written),
    format(atom(T), '(record ~w ~w)', [Name, Written]).
sketch(let_exp(Decls, Body), T) :-
    length(Decls, N), shape(Body, B), format(atom(T), '(let ~d ~w)', [N, B]).

sketch_of(Source, Text) :- parser:parse_exp(Source, Exp), shape(Exp, Text).

parse_error(Source, Message) :-
    catch(parser:parse_exp(Source, _), wolv_error(parse, _, M), true),
    sub_string(M, _, _, _, Message).

test('arithmetic precedence') :-
    sketch_of("1 + 2 * 3", '(+ 1 (* 2 3))'),
    sketch_of("1 * 2 + 3", '(+ (* 1 2) 3)'),
    sketch_of("1 - 2 - 3", '(- (- 1 2) 3)'),
    sketch_of("1 + 2 = 3", '(= (+ 1 2) 3)').

test('logic binds looser than comparison') :-
    sketch_of("a < b andalso c > d", '(andalso (< a b) (> c d))'),
    sketch_of("a orelse b andalso c", '(orelse a (andalso b c))').

test('assignment is right-associative and loosest') :-
    sketch_of("x := y + 1", '(:= x (+ y 1))').

test('a branch swallows what follows it') :-
    sketch_of("if c then x := 1 else x := 2", '(if c (:= x 1) (:= x 2))'),
    sketch_of("if c then a else b + 1", '(if c a (+ b 1))').

test('postfix chains') :-
    sketch_of("a[i].f[j]", '(index (field (index a i) f) j)'),
    sketch_of("f(1, 2).g", '(field (f 1 2) g)').

test('sequences and unit') :-
    sketch_of("()", '()'),
    sketch_of("(a; b; c)", '(seq a b c)'),
    sketch_of("(a)", a).

test('negation is a tilde') :-
    sketch_of("~x + 1", '(+ (~ x) 1)'),
    parse_error("-x", "negation is written").

test('a record literal is not a call') :-
    sketch_of("point { x = 1, y = 2 }", '(record point x=1 y=2)'),
    sketch_of("point (1, 2)", '(point 1 2)').

test('let with declarations') :-
    sketch_of("let val x = 1 var y = 2 in x + y end", '(let 2 (+ x y))').

test('a program is declarations') :-
    parser:parse("type t = int\nval x = 1\nfun f (a : int) : int = a\n",
                 [type_decl(_, _), val_decl(_, _, _, _, _, _), fun_decl(_, _)]).

test('mutual recursion is one declaration') :-
    parser:parse("fun f () : int = g ()\nand g () : int = 1\n", [fun_decl(Binds, _)]),
    findall(Name, member(fun_bind(Name, _, _, _, _, _), Binds), ["f", "g"]).

test('only a place can be assigned') :-
    parse_error("1 + 2 := 3", "not assignable").

test('errors name what was expected') :-
    parse_error("if a do b", "expected `then`").

:- end_tests(parser).
