% The list library, and what makes it different from a list library elsewhere:
% every one of these runs in more than one direction.

:- initialization(main).

% numbervars/3 replaces the remaining variables with '$VAR'(N), which is what
% makes them print as A, B, C rather than as internal tags.
named(Term, Named) :- copy_term(Term, Named), numbervars(Named, 0, _).

show(Goal) :-
    named(Goal, Before),
    (   call(Goal)
    ->  named(Goal, After),
        format("~q~t~46|~q~n", [Before, After])
    ;   format("~q~t~46|fails~n", [Before])
    ),
    !.

% predsort/3 takes a three-argument comparison whose first argument is the
% answer, which is why it can also drop elements: reporting = removes one.
by_length(Order, A, B) :-
    length(A, LA),
    length(B, LB),
    compare(Order, LA, LB).

show_all(Template, Goal) :-
    named(Goal, Before),
    findall(Template, Goal, Solutions),
    named(Solutions, Shown),
    format("~q~t~46|~q~n", [Before, Shown]).

main :-
    % append/3 concatenates, splits, and enumerates every split.
    show(append([1,2], [3], _)),
    show(append(_, [3], [1,2,3])),
    show_all(A-B, append(A, B, [1,2])),

    % member/2 is a generator, and memberchk/2 is the same predicate with the
    % alternatives cut away.
    show_all(X, member(X, [a,b,c])),
    show(memberchk(b, [a,b,c])),

    % nth0/3 and nth1/3 index, or search for the index.
    show(nth0(1, [a,b,c], _)),
    show(nth1(_, [a,b,c], c)),

    show(last([a,b,c], _)),
    show(reverse([1,2,3], _)),
    show(length(_, 3)),
    show(numlist(1, 5, _)),

    % select/3 removes one element, and every element in turn.
    show_all(E-R, select(E, [a,b,c], R)),
    show(select(b, [a,b,c], x, _)),

    % A permutation is select/3 applied until the list runs out.
    show_all(P, permutation([1,2,3], P)),

    % Sorting: msort/2 keeps duplicates, sort/2 drops them, keysort/2 is
    % stable and looks only at the keys.
    show(msort([c,a,b,a], _)),
    show(sort([c,a,b,a], _)),
    show(keysort([2-two, 1-one, 2-deux], _)),
    show(predsort(by_length, [[1,2,3],[1],[1,2]], _)),

    % Higher-order: the goal is a term, and call/N fills in its arguments.
    show(maplist(succ, [1,2,3], _)),
    show(include(integer, [a,1,b,2], _)),
    show(exclude(integer, [a,1,b,2], _)),
    show(partition(integer, [a,1,b,2], _, _)),
    show(foldl(plus, [1,2,3,4], 0, _)),

    show(sum_list([1,2,3], _)),
    show(max_list([1,9,3], _)),
    show(min_list([1,9,3], _)),
    show(list_to_set([a,b,a,c,b], _)),
    show(flatten([1,[2,[3,[4]]]], _)),
    show(subtract([1,2,3,4], [2,4], _)),
    show(intersection([1,2,3], [2,3,4], _)),
    show(union([1,2], [2,3], _)),
    show(pairs_keys_values(_, [a,b], [1,2])),

    % findall/3 collects; bagof/3 groups by the variables it was not told to
    % ignore; setof/3 sorts what bagof/3 gathered.
    show_all(Bag, bagof(N, member(N, [3,1,2]), Bag)),
    show_all(Set, setof(N, member(N, [3,1,2,1]), Set)),
    show(aggregate_all(count, member(_, [a,b,c]), _)),
    show(aggregate_all(sum(N2), member(N2, [1,2,3]), _)).
