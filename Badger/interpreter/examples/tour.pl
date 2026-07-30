% A tour of Badger.  Run it with:
%
%     dune exec src/badger.exe examples/tour.pl

:- initialization(main).

% ------------------------------------------------------------------- facts

parent(tom, bob).
parent(tom, liz).
parent(bob, ann).
parent(bob, pat).
parent(pat, jim).

% A rule.  The comma is conjunction; the same variable twice is the same
% variable, which is all "join" means here.
grandparent(X, Z) :- parent(X, Y), parent(Y, Z).

% Recursion, and the reason a Prolog program is read twice: as a set of
% clauses, and as a procedure.
ancestor(X, Z) :- parent(X, Z).
ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).

% ------------------------------------------------------------------- lists

% Terms are the only data structure, and a list is a term: '[|]' spelt '.',
% nested to the right, ending in the atom [].
total([], 0).
total([N|Ns], Sum) :- total(Ns, Rest), Sum is Rest + N.

% One clause per shape of the input is the whole of pattern matching.
describe([], empty).
describe([_], one).
describe([_,_|_], several).

% ------------------------------------------------------------- nondeterminism

% A predicate does not return a value; it succeeds, possibly more than once.
% between/3 succeeds once per integer, and findall/3 collects what came out.
squares(Upto, Squares) :-
    findall(N-Square, (between(1, Upto, N), Square is N * N), Squares).

% ----------------------------------------------------------------------- cut

% Without the cut, min/3 would offer a second, wrong answer on backtracking.
min(A, B, A) :- A =< B, !.
min(_, B, B).

% ------------------------------------------------------------------ grammars

% A DCG rule is a clause with two extra arguments threaded through it: the
% tokens before, and the tokens after.
greeting([Name]) --> [hello], [Name].
greeting([Name]) --> [hi], [Name].

% ----------------------------------------------------------------------- main

main :-
    format("grandchildren of tom:~n"),
    forall(grandparent(tom, C), format("  ~w~n", [C])),

    findall(A, ancestor(tom, A), As),
    format("everyone below tom: ~w~n", [As]),

    total([1,2,3,4], Sum),
    describe([1,2,3], Shape),
    format("total ~w, shape ~w~n", [Sum, Shape]),

    squares(5, Squares),
    format("squares: ~w~n", [Squares]),

    min(3, 7, Min),
    format("min(3,7) = ~w~n", [Min]),

    ( phrase(greeting(G), [hello, badger]) -> format("greeted: ~w~n", [G]) ; true ),

    % Terms are inspectable at run time, which is why a Prolog program can be
    % a Prolog term.
    T = point(1, 2),
    T =.. Parts,
    functor(T, Name, Arity),
    format("~q is ~w/~w, as a list ~q~n", [T, Name, Arity, Parts]),

    % An error is a term, and catching it is unification.
    catch(_ is 1 / 0, error(Formal, _), format("caught: ~q~n", [Formal])),

    % Backtracking undoes bindings.  Asserting is not undone.
    ( member(X, [1,2,3]), X > 5 -> true ; format("nothing over five~n") ),
    format("done~n").
