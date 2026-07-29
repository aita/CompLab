(* The library, in Prolog.

   Everything here could have been written in OCaml and is not, because list
   predicates are shorter and clearer as clauses -- and because a library
   written in the language is the best evidence that the language works.  It is
   consulted at startup like any other file. *)

let source =
  {prolog|
% ---------------------------------------------------------------- control

not(Goal) :- \+ Goal.

% ------------------------------------------------------------------ lists

append([], List, List).
append([H|T], List, [H|Rest]) :- append(T, List, Rest).

member(X, [X|_]).
member(X, [_|T]) :- member(X, T).

memberchk(X, [Y|T]) :- ( X = Y -> true ; memberchk(X, T) ).

'$memberchk_eq'(X, [Y|T]) :- ( X == Y -> true ; '$memberchk_eq'(X, T) ).

reverse(List, Reversed) :- '$reverse'(List, [], Reversed).
'$reverse'([], Acc, Acc).
'$reverse'([H|T], Acc, Reversed) :- '$reverse'(T, [H|Acc], Reversed).

last([H|T], Last) :- '$last'(T, H, Last).
'$last'([], Last, Last).
'$last'([H|T], _, Last) :- '$last'(T, H, Last).

nth0(Index, List, Elem) :-
    (   integer(Index)
    ->  Index >= 0, '$nth_fixed'(Index, List, Elem)
    ;   '$nth_search'(List, Elem, 0, Index)
    ).
nth1(Index, List, Elem) :-
    (   integer(Index)
    ->  Index >= 1, Before is Index - 1, '$nth_fixed'(Before, List, Elem)
    ;   '$nth_search'(List, Elem, 1, Index)
    ).
'$nth_fixed'(0, [Elem|_], Elem) :- !.
'$nth_fixed'(N, [_|T], Elem) :- N1 is N - 1, '$nth_fixed'(N1, T, Elem).
'$nth_search'([Elem|_], Elem, Index, Index).
'$nth_search'([_|T], Elem, Sofar, Index) :- Next is Sofar + 1, '$nth_search'(T, Elem, Next, Index).

select(X, [X|T], T).
select(X, [H|T], [H|Rest]) :- select(X, T, Rest).

select(X, [X|T], Y, [Y|T]).
select(X, [H|T], Y, [H|Rest]) :- select(X, T, Y, Rest).

selectchk(X, List, Rest) :- select(X, List, Rest), !.

exclude(_, [], []).
exclude(P, [H|T], Rest) :-
    ( call(P, H) -> Rest = Rest1 ; Rest = [H|Rest1] ),
    exclude(P, T, Rest1).

include(_, [], []).
include(P, [H|T], Rest) :-
    ( call(P, H) -> Rest = [H|Rest1] ; Rest = Rest1 ),
    include(P, T, Rest1).

partition(_, [], [], []).
partition(P, [H|T], Included, Excluded) :-
    (   call(P, H)
    ->  Included = [H|Included1], Excluded = Excluded1
    ;   Included = Included1, Excluded = [H|Excluded1]
    ),
    partition(P, T, Included1, Excluded1).

subtract([], _, []).
subtract([H|T], Remove, Rest) :-
    ( memberchk(H, Remove) -> Rest = Rest1 ; Rest = [H|Rest1] ),
    subtract(T, Remove, Rest1).

intersection([], _, []).
intersection([H|T], Other, Rest) :-
    ( memberchk(H, Other) -> Rest = [H|Rest1] ; Rest = Rest1 ),
    intersection(T, Other, Rest1).

union([], List, List).
union([H|T], Other, Rest) :-
    ( memberchk(H, Other) -> Rest = Rest1 ; Rest = [H|Rest1] ),
    union(T, Other, Rest1).

delete([], _, []).
delete([H|T], X, Rest) :-
    ( H \= X -> Rest = [H|Rest1] ; Rest = Rest1 ),
    delete(T, X, Rest1).

permutation([], []).
permutation(List, [X|Perm]) :- select(X, List, Rest), permutation(Rest, Perm).

list_to_set(List, Set) :- '$to_set'(List, [], Set).
'$to_set'([], _, []).
'$to_set'([H|T], Seen, Set) :-
    ( '$memberchk_eq'(H, Seen) -> Set = Set1 ; Set = [H|Set1] ),
    '$to_set'(T, [H|Seen], Set1).

flatten(List, Flat) :- '$flatten'(List, [], Flat).
'$flatten'(Var, Tail, [Var|Tail]) :- var(Var), !.
'$flatten'([], Tail, Tail) :- !.
'$flatten'([H|T], Tail, Flat) :- !, '$flatten'(T, Tail, Flat1), '$flatten'(H, Flat1, Flat).
'$flatten'(Atomic, Tail, [Atomic|Tail]).

numlist(Low, High, [Low|Rest]) :-
    Low =< High,
    ( Low =:= High -> Rest = [] ; Next is Low + 1, numlist(Next, High, Rest) ).

sum_list([], 0).
sum_list([X|Xs], Sum) :- sum_list(Xs, Rest), Sum is Rest + X.
sumlist(List, Sum) :- sum_list(List, Sum).

max_list([X|Xs], Max) :- '$max_list'(Xs, X, Max).
'$max_list'([], Max, Max).
'$max_list'([X|Xs], Sofar, Max) :- ( X > Sofar -> '$max_list'(Xs, X, Max) ; '$max_list'(Xs, Sofar, Max) ).

min_list([X|Xs], Min) :- '$min_list'(Xs, X, Min).
'$min_list'([], Min, Min).
'$min_list'([X|Xs], Sofar, Min) :- ( X < Sofar -> '$min_list'(Xs, X, Min) ; '$min_list'(Xs, Sofar, Min) ).

max_member(Max, List) :- msort(List, Sorted), last(Sorted, Max).
min_member(Min, List) :- msort(List, [Min|_]).

maplist(_, []).
maplist(P, [X|Xs]) :- call(P, X), maplist(P, Xs).
maplist(_, [], []).
maplist(P, [X|Xs], [Y|Ys]) :- call(P, X, Y), maplist(P, Xs, Ys).
maplist(_, [], [], []).
maplist(P, [X|Xs], [Y|Ys], [Z|Zs]) :- call(P, X, Y, Z), maplist(P, Xs, Ys, Zs).
maplist(_, [], [], [], []).
maplist(P, [X|Xs], [Y|Ys], [Z|Zs], [W|Ws]) :- call(P, X, Y, Z, W), maplist(P, Xs, Ys, Zs, Ws).

foldl(Goal, List, V0, V) :- '$foldl'(List, Goal, V0, V).
'$foldl'([], _, V, V).
'$foldl'([X|Xs], Goal, V0, V) :- call(Goal, X, V0, V1), '$foldl'(Xs, Goal, V1, V).

foldl(Goal, List1, List2, V0, V) :- '$foldl2'(List1, List2, Goal, V0, V).
'$foldl2'([], [], _, V, V).
'$foldl2'([X|Xs], [Y|Ys], Goal, V0, V) :- call(Goal, X, Y, V0, V1), '$foldl2'(Xs, Ys, Goal, V1, V).

pairs_keys_values([], [], []).
pairs_keys_values([K-V|Pairs], [K|Ks], [V|Vs]) :- pairs_keys_values(Pairs, Ks, Vs).
pairs_keys(Pairs, Keys) :- pairs_keys_values(Pairs, Keys, _).
pairs_values(Pairs, Values) :- pairs_keys_values(Pairs, _, Values).

% Insertion sort, because the comparison is a goal and not a function: it may
% bind, fail or throw, and it decides on = that one of the two goes away.
predsort(_, [], []) :- !.
predsort(P, [H|T], Sorted) :- predsort(P, T, Rest), '$pred_insert'(P, H, Rest, Sorted).
'$pred_insert'(_, X, [], [X]) :- !.
'$pred_insert'(P, X, [Y|Ys], Sorted) :-
    call(P, Order, X, Y),
    (   Order = (<)
    ->  Sorted = [X,Y|Ys]
    ;   Order = (=)
    ->  Sorted = [Y|Ys]
    ;   Sorted = [Y|Rest], '$pred_insert'(P, X, Ys, Rest)
    ).

% ---------------------------------------------------------- all solutions

% bagof/3 differs from findall/3 in the variables of the goal that appear
% neither in the template nor under a ^: those are not collected over but
% *reported*, one group of solutions per binding of them.  So: find the free
% variables, collect Witness-Template pairs, sort by witness, and hand back one
% group at a time.
bagof(Template, Goal, Bag) :-
    '$strip_carets'(Goal, Plain, Existential),
    term_variables(Template-Existential, Quantified),
    term_variables(Plain, All),
    '$free_vars'(All, Quantified, Free),
    (   Free == []
    ->  findall(Template, Plain, Bag), Bag \== []
    ;   Witness =.. [w|Free],
        findall(Witness-Template, Plain, Pairs),
        Pairs \== [],
        keysort(Pairs, Sorted),
        '$group_pairs'(Sorted, Groups),
        member(Witness-Bag, Groups)
    ).

setof(Template, Goal, Set) :- bagof(Template, Goal, Bag), sort(Bag, Set).

'$free_vars'([], _, []).
'$free_vars'([V|Vs], Quantified, Free) :-
    ( '$memberchk_eq'(V, Quantified) -> Free = Free1 ; Free = [V|Free1] ),
    '$free_vars'(Vs, Quantified, Free1).

'$group_pairs'([], []).
'$group_pairs'([K-V|Rest], [K-[V|Vs]|Groups]) :-
    '$same_witness'(K, Rest, Vs, Tail),
    '$group_pairs'(Tail, Groups).
'$same_witness'(K, [K1-V|Rest], [V|Vs], Tail) :- K =@= K1, !, '$same_witness'(K, Rest, Vs, Tail).
'$same_witness'(_, Rest, [], Rest).

aggregate_all(count, Goal, Count) :- findall(x, Goal, Xs), length(Xs, Count).
aggregate_all(count(T), Goal, Count) :- findall(T, Goal, Xs), length(Xs, Count).
aggregate_all(sum(E), Goal, Sum) :- findall(E, Goal, Xs), sum_list(Xs, Sum).
aggregate_all(max(E), Goal, Max) :- findall(E, Goal, Xs), Xs \== [], max_list(Xs, Max).
aggregate_all(min(E), Goal, Min) :- findall(E, Goal, Xs), Xs \== [], min_list(Xs, Min).
aggregate_all(bag(T), Goal, Bag) :- findall(T, Goal, Bag).
aggregate_all(set(T), Goal, Set) :- findall(T, Goal, Xs), sort(Xs, Set).

% -------------------------------------------------------------------- DCG

phrase(Body, List) :- phrase(Body, List, []).
phrase(Body, List, Rest) :- '$dcg_body'(Body, List, Rest, Goal), call(Goal).

% ----------------------------------------------------------------- output

writeln(X) :- write(X), nl.
|prolog}
