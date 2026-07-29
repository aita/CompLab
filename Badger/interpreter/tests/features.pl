% One line of output per thing that is supposed to work.  The output is the
% test: it is diffed against features.expected.

:- initialization(main).

check(Label, Goal) :-
    (   catch(Goal, Ball, (Thrown = Ball, fail))
    ->  format("ok    ~w~n", [Label])
    ;   ( nonvar(Thrown) -> format("THREW ~w: ~q~n", [Label, Thrown])
        ; format("FAIL  ~w~n", [Label]) )
    ).

shows(Label, Term) :-
    format("~w~t~28|~q~n", [Label, Term]).

% ------------------------------------------------------------- unification

unification :-
    check(bind, X = f(1)),
    check(both_ways, (f(A, b) = f(a, B), A == a, B == b)),
    check(shared, (f(C, C) = f(1, D), D == 1)),
    check(no_match, \+ f(1) = f(2)),
    check(arity, \+ f(1) = f(1, 2)),
    check(int_is_not_float, \+ 1 = 1.0),
    check(cyclic_without_check, E = f(E)),
    check(occurs_check, \+ unify_with_occurs_check(F, f(F))),
    check(not_unifiable, \+ 1 \= 1),
    check(undone_on_failure, (\+ (G = 1, fail), var(G))),
    ignore((X, A, B, C, D, E, F, G) = ignored).

% ------------------------------------------------------------- type tests

types :-
    check(var, var(_)),
    check(nonvar, nonvar(a)),
    check(atom, (atom(a), atom([]), \+ atom("x"), \+ atom(1))),
    check(number, (number(1), number(1.5), \+ number(a))),
    check(integer, (integer(1), \+ integer(1.0))),
    check(float, (float(1.0), \+ float(1))),
    check(atomic, (atomic(a), atomic(1), \+ atomic(f(x)), \+ atomic(_))),
    check(compound, (compound(f(x)), compound([a]), \+ compound([]))),
    check(callable, (callable(a), callable(f(x)), \+ callable(1))),
    check(is_list, (is_list([1,2]), \+ is_list([1|_]), \+ is_list(a))),
    check(ground, (ground(f(1)), \+ ground(f(_)))).

% -------------------------------------------------- order and comparison

order :-
    check(identical, (a == a, \+ a == b)),
    check(var_first, _ @< 0),
    check(number_before_atom, 1 @< a),
    check(atom_before_compound, a @< f(x)),
    check(arity_first, f(x) @< g(x, y)),
    check(float_before_int, 1.0 @< 1),
    check(compare, (compare(<, 1, 2), compare(=, a, a), compare(>, b, a))),
    check(variant, f(_, _) =@= f(_, _)),
    check(not_variant, f(A, A) \=@= f(_, _)),
    msort([b, 1, a, f(x), 1.0], Sorted),
    shows(standard_order, Sorted).

% ------------------------------------------------------------- arithmetic

arithmetic :-
    check(plus, 3 =:= 1 + 2),
    check(int_division_exact, 2 =:= 4 / 2),
    check(int_division_inexact, 2.5 =:= 5 / 2),
    check(truncating, (-2 =:= -7 // 3)),
    check(flooring, (-3 =:= -7 div 3)),
    check(mod_takes_divisor_sign, 2 =:= -7 mod 3),
    check(rem_takes_dividend_sign, -1 =:= -7 rem 3),
    check(int_power, 8 =:= 2 ^ 3),
    check(float_power, 8.0 =:= 2 ** 3),
    check(bit_and, 4 =:= 12 /\ 6),
    check(shift, 8 =:= 1 << 3),
    check(min_max, (1 =:= min(1, 2), 2 =:= max(1, 2))),
    check(abs_sign, (3 =:= abs(-3), -1 =:= sign(-9))),
    check(gcd, 6 =:= gcd(12, 18)),
    check(sqrt, 3.0 =:= sqrt(9)),
    check(rounding, (2 =:= round(1.5), 1 =:= truncate(1.9), 2 =:= ceiling(1.1), 1 =:= floor(1.9))),
    check(pi, 3 =:= truncate(pi)),
    check(char_code_arith, 0'a =:= 97),
    check(one_element_list, 97 =:= "a"),
    check(comparison_ops, (1 < 2, 2 =< 2, 3 > 2, 2 >= 2, 1 =\= 2)),
    check(succ_forward, (succ(3, S), S == 4)),
    check(succ_backward, (succ(P, 4), P == 3)),
    check(succ_zero, \+ succ(_, 0)),
    check(plus3, (plus(1, 2, T), T == 3, plus(1, U, 3), U == 2)),
    check(zero_divisor, catch(_ is 1 // 0, error(evaluation_error(zero_divisor), _), true)),
    check(not_evaluable, catch(_ is foo, error(type_error(evaluable, foo/0), _), true)),
    check(unbound, catch(_ is _ + 1, error(instantiation_error, _), true)).

% ------------------------------------------------------- term inspection

inspection :-
    check(functor_read, (functor(f(a, b), N, A), N == f, A == 2)),
    check(functor_atomic, (functor(hello, N2, A2), N2 == hello, A2 == 0)),
    check(functor_build, (functor(T, point, 2), T = point(_, _))),
    check(arg_index, (arg(2, f(a, b, c), X), X == b)),
    check(arg_enumerate, (findall(I-V, arg(I, f(a, b), V), L), L == [1-a, 2-b])),
    check(univ_read, (f(a, b) =.. L2, L2 == [f, a, b])),
    check(univ_build, (T2 =.. [g, 1, 2], T2 == g(1, 2))),
    check(univ_atomic, (7 =.. L3, L3 == [7])),
    check(copy_term, (copy_term(f(A3, A3, b), C), C = f(P, Q, b), P == Q, A3 \== P)),
    check(term_variables, (term_variables(f(V1, g(V2), V1), Vs), Vs == [V1, V2])),
    check(numbervars, (T3 = f(_, _), numbervars(T3, 0, End), End == 2,
                       with_output_to_atom(write(T3), Written), Written == 'f(A,B)')).

% There is no with_output_to/2, so format/3 to an atom stands in for it.
with_output_to_atom(write(Term), Atom) :- format(atom(Atom), "~w", [Term]).

% ------------------------------------------------------------------- atoms

atoms :-
    check(atom_length, (atom_length(hello, 5), atom_length('', 0))),
    check(atom_chars, (atom_chars(abc, Cs), Cs == [a, b, c])),
    check(atom_chars_build, (atom_chars(A, [x, y]), A == xy)),
    check(atom_codes, (atom_codes(ab, Ks), Ks == [0'a, 0'b])),
    check(char_code, (char_code(a, C), C == 0'a, char_code(D, 0'b), D == b)),
    check(atom_number, (atom_number('42', N), N == 42, atom_number(A2, 7), A2 == '7')),
    check(atom_number_fails, \+ atom_number(hello, _)),
    check(number_codes, (number_codes(12, Ns), atom_codes(A3, Ns), A3 == '12')),
    check(atom_concat, (atom_concat(foo, bar, F), F == foobar)),
    check(atom_concat_split, (findall(X-Y, atom_concat(X, Y, ab), L),
                              L == [''-ab, a-b, ab-''])),
    check(sub_atom_find, (sub_atom(hello, B, 2, A4, ll), B == 2, A4 == 1)),
    check(sub_atom_count, (findall(S, sub_atom(abc, _, _, _, S), L2), length(L2, 10))),
    check(case, (upcase_atom(aB, U), U == 'AB', downcase_atom(aB, Dn), Dn == ab)),
    check(atomic_list_concat, (atomic_list_concat([a, 1, b], R), R == a1b)),
    check(atomic_list_concat_sep, (atomic_list_concat([a, b], '-', R2), R2 == 'a-b')),
    check(atomic_list_concat_split, (atomic_list_concat(P, '-', 'a-b-c'), P == [a, b, c])),
    check(term_to_atom_write, (term_to_atom(f(_, 'a b'), T), atom(T))),
    check(term_to_atom_read, (term_to_atom(T2, 'f(1,2)'), T2 == f(1, 2))),
    check(atom_to_term, (atom_to_term('foo(X, Y)', T3, Bs), T3 = foo(_, _),
                         Bs = ['X' = _, 'Y' = _])),
    check(code_type, (code_type(0'7, digit(W)), W == 7, code_type(0' , space))),
    check(char_type, (char_type(a, alpha), char_type('A', upper(Lower)), Lower == a)).

% ------------------------------------------------------------------ control

control :-
    check(true, true),
    check(fail, \+ fail),
    check(conjunction, (true, true)),
    check(disjunction, (fail ; true)),
    check(if_then_else_then, (1 < 2 -> true ; fail)),
    check(if_then_else_else, (1 > 2 -> fail ; true)),
    check(if_then_no_else, \+ (1 > 2 -> true)),
    check(soft_cut, (findall(X, (member(X, [1, 2]) *-> true ; X = none), L), L == [1, 2])),
    check(soft_cut_else, (findall(X, (fail *-> true ; X = none), L2), L2 == [none])),
    check(once, (findall(X, once(member(X, [1, 2])), L3), L3 == [1])),
    check(ignore_failure, (ignore(fail), ignore(true))),
    check(forall, forall(member(X2, [1, 2, 3]), X2 > 0)),
    check(forall_counterexample, \+ forall(member(X3, [1, -1]), X3 > 0)),
    check(negation_keeps_nothing, (\+ \+ Y = 1, var(Y))),
    check(call_extra_args, (call(plus, 1, 2, Z), Z == 3)),
    check(call_conjunction, call((true, true))),
    check(not_callable, catch(call(1), error(type_error(callable, 1), _), true)),
    check(unbound_goal, catch(call(_), error(instantiation_error, _), true)),
    check(between_check, between(1, 10, 5)),
    check(between_enumerate, (findall(X4, between(1, 4, X4), L4), L4 == [1, 2, 3, 4])),
    check(repeat_with_cut, (repeat, !)),
    check(length_measure, (length([a, b], 2))),
    check(length_generate, (length(L5, 2), L5 = [_, _])).

cuts :-
    check(cut_commits, (findall(X, cut_first(X), L), L == [1])),
    check(cut_is_local_to_call, (findall(X2, cut_in_call(X2), L2), L2 == [1, 2, 3])),
    check(cut_is_local_to_condition,
          (findall(X3, (q(X3), (! -> true ; true)), L3), L3 == [1, 2, 3])),
    check(cut_in_a_disjunction_is_not,
          (findall(X5, (q(X5), (! ; true)), L5), L5 == [1])),
    check(cut_is_local_to_negation, \+ (q(_), !, fail)),
    check(cut_is_local_to_findall, (findall(X4, (q(X4), !), L4), L4 == [1])).

q(1).
q(2).
q(3).
cut_first(X) :- q(X), !.
cut_in_call(X) :- q(X), call(!).

% --------------------------------------------------------- all solutions

solutions :-
    check(findall, (findall(X, q(X), L), L == [1, 2, 3])),
    check(findall_empty, (findall(_, fail, L2), L2 == [])),
    check(findall_tail, (findall(X2, q(X2), L3, [done]), L3 == [1, 2, 3, done])),
    check(bagof, (bagof(X3, q(X3), L4), L4 == [1, 2, 3])),
    check(bagof_fails_when_empty, \+ bagof(_, fail, _)),
    check(bagof_groups_free_variables,
          (findall(K-Bag, bagof(V, pair(K, V), Bag), L5),
           L5 == [a-[1, 3], b-[2]])),
    check(bagof_caret, (bagof(V2, K2^pair(K2, V2), L6), L6 == [1, 2, 3])),
    check(setof_sorts_and_dedupes, (setof(X4, member(X4, [c, a, b, a]), L7), L7 == [a, b, c])),
    check(aggregate_count, (aggregate_all(count, q(_), C), C == 3)),
    check(aggregate_sum, (aggregate_all(sum(X5), q(X5), S), S == 6)),
    check(aggregate_max_min, (aggregate_all(max(X6), q(X6), Mx), Mx == 3,
                              aggregate_all(min(X7), q(X7), Mn), Mn == 1)),
    check(aggregate_set, (aggregate_all(set(X8), member(X8, [b, a, b]), St), St == [a, b])).

pair(a, 1).
pair(b, 2).
pair(a, 3).

% ------------------------------------------------------------- the database

:- dynamic counter/1.
:- dynamic fact/1.

database :-
    check(assertz_then_call, (assertz(fact(1)), fact(1))),
    check(asserta_order, (assertz(fact(2)), asserta(fact(0)),
                          findall(X, fact(X), L), L == [0, 1, 2])),
    check(retract_one, (retract(fact(1)), findall(X2, fact(X2), L2), L2 == [0, 2])),
    check(retract_fails, \+ retract(fact(99))),
    check(retractall, (retractall(fact(_)), \+ fact(_))),
    check(retractall_declares, (retractall(never_seen(_)), \+ never_seen(_))),
    check(clause, (assertz((rule(X3) :- X3 > 0)), clause(rule(_), Body), Body = (_ > 0))),
    check(logical_update_view,
          (assertz(counter(1)), assertz(counter(2)),
           findall(X4, (counter(X4), assertz(counter(99))), L3),
           L3 == [1, 2])),
    check(current_predicate, current_predicate(counter/1)),
    check(current_predicate_enumerates,
          (findall(A, current_predicate(fact/A), L4), L4 == [1])),
    check(predicate_property_builtin, predicate_property(atom(_), built_in)),
    check(predicate_property_dynamic, predicate_property(counter(_), dynamic)),
    check(cannot_assert_over_builtin,
          catch(assertz(atom(x)), error(permission_error(modify, static_procedure, atom/1), _), true)),
    check(cannot_retract_builtin,
          catch(retract(atom(_)), error(permission_error(access, private_procedure, atom/1), _), true)),
    check(unknown_procedure,
          catch(no_such_predicate, error(existence_error(procedure, no_such_predicate/0), _), true)),
    check(unknown_can_fail_instead,
          ( set_prolog_flag(unknown, fail),
            \+ still_no_such_predicate,
            set_prolog_flag(unknown, error) )),
    retractall(counter(_)).

% -------------------------------------------------------------- exceptions

exceptions :-
    check(throw_catch, catch(throw(ball), ball, true)),
    check(catch_rethrows_unmatched,
          catch(catch(throw(a), b, true), a, true)),
    check(recovery_runs, (catch(throw(x), x, R = recovered), R == recovered)),
    check(catch_is_transparent_to_solutions,
          (findall(X, catch(q(X), _, fail), L), L == [1, 2, 3])),
    check(catch_does_not_catch_its_continuation,
          catch(( catch(true, inner, R2 = wrong), throw(outer) ), Ball, Ball == outer)),
    check(ball_survives_backtracking,
          catch(( member(_, [1, 2]), throw(boom) ), B, B == boom)),
    check(error_context, catch(atom_length(1.0, _), error(_, _), true)),
    check(unbound_ball, catch(throw(_), error(instantiation_error, _), true)),
    ignore(R2 = unused).

% ---------------------------------------------------------- read and write

% A directive runs while the file is being read, so this changes the syntax of
% everything below it -- including the clause for syntax/0.
:- op(700, xfx, ===).

syntax :-
    check(operators_read, ('-'(1, 2) == 1 - 2)),
    check(left_associative, (1 - 2 - 3 == (1 - 2) - 3)),
    check(right_associative, (1 ^ 2 ^ 3 == 1 ^ (2 ^ 3))),
    check(precedence, (1 + 2 * 3 == 1 + (2 * 3))),
    check(negative_literal, (X = -1, integer(X))),
    check(prefix_minus_is_not_a_literal, (Y = - 1, Y == -(1), \+ integer(Y))),
    check(list_cons, ([a, b] == '.'(a, '.'(b, [])))),
    check(partial_list, ([a|T] = [a, b], T == [b])),
    check(curly, ({a, b} == {}(','(a, b)))),
    check(quoted_atom, ('hello world' == 'hello world')),
    check(quoted_operator, (X2 = ',', atom(X2), atom_length(X2, 1))),
    check(escape, (atom_codes('\n', [10]))),
    check(char_code_syntax, (0'a == 97, 0'\n == 10, 0''' == 39)),
    check(double_quotes_are_codes, ("ab" == [0'a, 0'b])),
    check(operator_from_a_directive, (T2 = (a === b), T2 =.. ['===', a, b])),
    check(operator_at_runtime,
          ( op(200, xfy, '<=>'), term_to_atom(T3, 'a <=> b'), T3 =.. ['<=>', a, b] )),
    check(current_op, (current_op(P, yfx, +), P == 500)).

writing :-
    round_trip('f(a,b)'),
    round_trip('1+2*3'),
    round_trip('(1+2)*3'),
    round_trip('1-2-3'),
    round_trip('1-(2-3)'),
    round_trip('- 1'),
    round_trip('1- -1'),
    round_trip('- (1,2)'),
    round_trip('[a,b|c]'),
    round_trip('{a,b}'),
    round_trip('\'hello world\''),
    round_trip('\'don\\\'t\''),
    round_trip('f(-,+)'),
    round_trip('a:-b,c'),
    round_trip('- - 1'),
    round_trip('\'[]\'(x)'),
    round_trip('1.0'),
    round_trip('-1.5e10'),
    round_trip('f(\'A\',_)').

% Reading a term, writing it, and reading it back must give the same term.
% That is the property the writer exists to have.  What is shown is the same
% text with the variables numbered, so that the output does not depend on how
% many variables happened to be allocated before it.
round_trip(Atom) :-
    term_to_atom(Term, Atom),
    format(atom(Printed), "~q", [Term]),
    term_to_atom(Again, Printed),
    copy_term(Term, Shown),
    numbervars(Shown, 0, _),
    format(atom(Display), "~q", [Shown]),
    (   Term =@= Again
    ->  format("ok    ~w~t~28|~w~n", [Atom, Display])
    ;   format("BAD   ~w~t~28|~w~n", [Atom, Display])
    ).

formatting :-
    format(atom(A), "~w ~q ~a", ['a b', 'a b', 'a b']), shows(w_q_a, A),
    format(atom(B), "~d ~2d ~D", [42, 1234, 1234567]), shows(d_2d_D, B),
    format(atom(C), "~2f ~e ~g", [3.14159, 1.5, 0.5]), shows(f_e_g, C),
    format(atom(D), "~s and ~c~c", ["abc", 0'h, 0'i]), shows(s_c, D),
    format(atom(E), "[~w~t~10||]", [left]), shows(column, E),
    format(atom(F), "~8|x", []), shows(column_stop, F),
    format(atom(G), "~a~t~*c~a", [a, 3, 0'., b]), shows(star, G),
    format(atom(H), "100~~", []), shows(tilde, H),
    format(atom(I), "~16r", [255]), shows(radix, I).

% -------------------------------------------------------------------- DCG

greeting(Name) --> [hello], [Name].
greeting(Name) --> "hi ", word(Codes), { atom_codes(Name, Codes) }.
word([C|Cs]) --> [C], { code_type(C, alpha) }, !, word(Cs).
word([]) --> [].

grammar :-
    check(phrase_tokens, (phrase(greeting(N), [hello, badger]), N == badger)),
    check(phrase_codes, (phrase(greeting(N2), "hi badger"), N2 == badger)),
    check(phrase_rest, (phrase(word(W), "ab cd", Rest), atom_codes(A, W), A == ab,
                        Rest == [0' , 0'c, 0'd])),
    check(phrase_body, phrase(([a], [b]), [a, b])),
    check(phrase_braces, phrase(({1 < 2}), [], [])),
    check(phrase_generates, (findall(L, (length(L, 2), phrase(([a], [_]), L)), Ls),
                             length(Ls, 1))).

% ------------------------------------------------------------------- sorting

sorting :-
    check(msort_keeps_duplicates, (msort([b, a, b], L), L == [a, b, b])),
    check(sort_drops_duplicates, (sort([b, a, b], L2), L2 == [a, b])),
    check(keysort_is_stable, (keysort([1-a, 0-b, 1-c], L3), L3 == [0-b, 1-a, 1-c])),
    check(predsort, (predsort(reverse_order, [1, 3, 2], L4), L4 == [3, 2, 1])),
    check(predsort_drops_equal, (predsort(by_parity, [1, 3, 2], L5), length(L5, 2))).

reverse_order(Order, A, B) :- compare(Inverse, A, B), invert(Inverse, Order).
invert(<, >).
invert(>, <).
invert(=, =).
by_parity(Order, A, B) :- PA is A mod 2, PB is B mod 2, compare(Order, PA, PB).

% --------------------------------------------------------------------- main

main :-
    unification, nl,
    types, nl,
    order, nl,
    arithmetic, nl,
    inspection, nl,
    atoms, nl,
    control, nl,
    cuts, nl,
    solutions, nl,
    database, nl,
    exceptions, nl,
    syntax, nl,
    writing, nl,
    formatting, nl,
    grammar, nl,
    sorting.
