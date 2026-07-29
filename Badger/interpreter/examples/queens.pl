% N queens, twice, to show what the ordering of goals costs.
%
% Both programs search the same space.  The difference is when they check: one
% lays out a whole permutation and then tests it, the other tests each queen as
% it is placed and so never builds a board it will have to throw away.  On an
% 8x8 board that is the difference between tens of thousands of failed tests
% and a few thousand.

:- initialization(main).

% ------------------------------------------------- generate, and then test

slow_queens(N, Queens) :-
    numlist(1, N, Columns),
    permutation(Columns, Queens),
    safe(Queens).

safe([]).
safe([Q|Qs]) :- no_diagonal(Q, Qs, 1), safe(Qs).

no_diagonal(_, [], _).
no_diagonal(Q, [P|Ps], Distance) :-
    Q - P =\= Distance,
    P - Q =\= Distance,
    Next is Distance + 1,
    no_diagonal(Q, Ps, Next).

% -------------------------------------------------- test while generating

% Placing a queen and checking it against the queens already placed means a
% partial board is abandoned as soon as it is hopeless.  The predicate is the
% same length; only the order of the goals changed.
queens(N, Queens) :-
    numlist(1, N, Columns),
    place(Columns, [], Queens).

place([], Placed, Placed).
place(Unplaced, Placed, Queens) :-
    select(Q, Unplaced, Rest),
    no_diagonal(Q, Placed, 1),
    place(Rest, [Q|Placed], Queens).

% ------------------------------------------------------------------- output

board(Queens) :-
    length(Queens, N),
    forall(member(Q, Queens),
           ( forall(between(1, N, C),
                    ( C =:= Q -> write('Q ') ; write('. ') )),
             nl )).

main :-
    queens(8, First),
    format("8 queens: ~w~n~n", [First]),
    board(First),

    aggregate_all(count, queens(6, _), Six),
    format("~nsolutions on a 6x6 board: ~w~n", [Six]),

    % The two programs agree, which is the only thing worth checking about an
    % optimisation.
    findall(Q, queens(6, Q), Fast),
    findall(Q, slow_queens(6, Q), Slow),
    msort(Fast, Sorted),
    msort(Slow, Sorted),
    format("both programs found the same ~w boards~n", [Six]).
