% What the cut does, and what it does not.
%
% The cut is the one construct in Prolog that is not about logic: it is about
% the search.  Everything below is a way of seeing which alternatives it
% throws away.

:- initialization(main).

q(1).
q(2).
q(3).

% A cut discards the alternatives of the clause it is in *and* the goals to its
% left in that clause.  So this yields one solution, not three.
first(X) :- q(X), !.

% Which is not the same as cutting nothing: this yields all three, because the
% cut is inside call/1, and call/1 gives its goal a barrier of its own.
opaque(X) :- q(X), call(!).

% A cut is local to the condition of if-then-else, so this still yields three.
in_condition(X) :- q(X), ( ! -> true ; true ).

% \+ is if-then-else in disguise, so a cut inside it is local too.
double_negation :- \+ ( q(_), !, fail ).

% The cut in the second clause never runs, because reaching it means the first
% clause failed, and the first clause is the one with alternatives.  This is
% the shape every "if" written as two clauses has.
classify(N, negative) :- N < 0, !.
classify(0, zero) :- !.
classify(_, positive).

% Cut turns a generator into a test.  once/1 is this, and says so.
member_once(X, L) :- member(X, L), !.

% A cut in a base case is doing real work: without it, max_ok([3], M) would
% also try the second clause, fail in max_ok([], _), and come back -- harmless
% here, but the same shape one clause later is how a recursion acquires
% duplicate solutions.
max_ok([X], X) :- !.
max_ok([X|Xs], Max) :- max_ok(Xs, Rest), ( X > Rest -> Max = X ; Max = Rest ).

show(Label, Goal) :-
    findall(Goal, Goal, Solutions),
    length(Solutions, N),
    format("~w~t~18|~w solution(s): ~q~n", [Label, N, Solutions]).

main :-
    show('q/1', q(_)),
    show('first/1', first(_)),
    show('opaque/1', opaque(_)),
    show('in_condition/1', in_condition(_)),
    show('member_once/2', member_once(_, [a,b,c])),

    ( double_negation -> writeln('\\+ (q(_), !, fail) succeeds') ; writeln(unexpected) ),

    forall(member(N, [-2, 0, 7]),
           ( classify(N, Class), format("classify(~w) = ~w~n", [N, Class]) )),

    max_ok([3,9,4], Max),
    format("max_ok([3,9,4]) = ~w~n", [Max]),

    % Negation as failure is not negation: it means "not provable".  A goal
    % with unbound variables can fail for lack of information rather than for
    % lack of truth.
    ( \+ q(9) -> writeln('q(9) is not provable') ; true ),
    ( \+ \+ q(1) -> writeln('double negation keeps no bindings') ; true ).
