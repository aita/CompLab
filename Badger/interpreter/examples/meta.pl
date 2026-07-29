% A Prolog interpreter, in Prolog.
%
% clause/2 hands a program its own clauses, so an interpreter for Prolog is a
% few lines of Prolog.  That is worth knowing for its own sake, and it is also
% the shortest way to see what the real engine is doing: change solve/1 a
% little and it prints a proof, or counts inferences, or stops at a depth.
%
% One thing it cannot do is the cut, and the reason is exactly the reason the
% cut needs special treatment in the real engine: a cut has to reach the frame
% of the predicate that contains it, and an interpreted cut only knows about
% the interpreter's own frames.  solve/1 says so rather than pretending.

:- initialization(main).

% -------------------------------------------------------- the vanilla version

solve(true) :- !.
solve((A, B)) :- !, solve(A), solve(B).
solve((A -> B ; C)) :- !, ( solve(A) -> solve(B) ; solve(C) ).
solve((A ; B)) :- !, ( solve(A) ; solve(B) ).
solve((A -> B)) :- !, ( solve(A) -> solve(B) ).
solve(\+ A) :- !, \+ solve(A).
solve(!) :- !, throw(cut_not_supported).
solve(Goal) :- predicate_property(Goal, built_in), !, call(Goal).
solve(Goal) :- clause(Goal, Body), solve(Body).

% ----------------------------------------------------- with a proof to show

prove(true, true) :- !.
prove((A, B), (PA, PB)) :- !, prove(A, PA), prove(B, PB).
prove(\+ A, \+ A) :- !, \+ solve(A).
prove(Goal, fact(Goal)) :- predicate_property(Goal, built_in), !, call(Goal).
prove(Goal, proof(Goal, Sub)) :- clause(Goal, Body), prove(Body, Sub).

% ------------------------------------------------ with a depth limit, so that
%                                                  a loop is reported, not run

solve(_, Depth) :- Depth < 0, !, fail.
solve(true, _) :- !.
solve((A, B), D) :- !, solve(A, D), solve(B, D).
solve((A ; B), D) :- !, ( solve(A, D) ; solve(B, D) ).
solve(\+ A, D) :- !, \+ solve(A, D).
solve(Goal, _) :- predicate_property(Goal, built_in), !, call(Goal).
solve(Goal, D) :- D1 is D - 1, clause(Goal, Body), solve(Body, D1).

% -------------------------------------------------------- a program to run

parent(tom, bob).
parent(bob, ann).
parent(ann, jim).

ancestor(X, Y) :- parent(X, Y).
ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).

% Left recursion: true in logic, a loop as a procedure.  The depth-limited
% interpreter is how you find out which of the two you wrote.
loops(X) :- loops(X).

sum([], 0).
sum([N|Ns], Total) :- sum(Ns, Rest), Total is Rest + N.

% ------------------------------------------------------------------- driving

indent(0) :- !.
indent(N) :- write('  '), N1 is N - 1, indent(N1).

show_proof(fact(Goal), Depth) :-
    indent(Depth), format("~q~n", [Goal]).
show_proof(proof(Goal, Sub), Depth) :-
    indent(Depth), format("~q~n", [Goal]),
    D1 is Depth + 1,
    show_proof(Sub, D1).
show_proof((A, B), Depth) :-
    show_proof(A, Depth),
    show_proof(B, Depth).
show_proof(true, _).
show_proof(\+ A, Depth) :-
    indent(Depth), format("\\+ ~q~n", [A]).

main :-
    findall(X-Y, solve(ancestor(X, Y)), Pairs),
    format("interpreted ancestor/2: ~q~n~n", [Pairs]),

    solve(sum([1,2,3], Total)),
    format("interpreted sum/2: ~w~n~n", [Total]),

    prove(ancestor(tom, jim), Proof),
    writeln('a proof of ancestor(tom, jim):'),
    show_proof(Proof, 1),
    nl,

    (   solve(loops(_), 20)
    ->  writeln(unexpected)
    ;   writeln('loops/1 found no proof within depth 20')
    ),

    catch(solve((parent(tom, _), !)), Ball, true),
    format("interpreting a cut: ~q~n", [Ball]),

    % The real engine counts what it does, and the interpreted run costs a
    % multiple of it -- one clause lookup per interpreted clause lookup, plus
    % solve/1's own clauses on top.
    statistics(inferences, Before),
    findall(_, solve(ancestor(_, _)), _),
    statistics(inferences, After),
    Cost is After - Before,
    format("inferences spent interpreting ancestor/2: ~w~n", [Cost]).
