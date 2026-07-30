% The zebra puzzle: five houses, fifteen constraints, one question.
%
% This is the program that shows what unification and backtracking buy you.
% There is no search written down anywhere -- the constraints are stated as
% partially known houses, unification fills in what it can, and the engine
% does the rest.  A house is
%
%     h(Colour, Nationality, Pet, Drink, Smoke)
%
% and any argument left as a variable is one that clue has nothing to say
% about.

:- initialization(main).

% X is immediately to the right of Y.
right_of(X, Y, Houses) :- adjacent(Y, X, Houses).

% X and Y are neighbours, in either order.
next_to(X, Y, Houses) :- adjacent(X, Y, Houses).
next_to(X, Y, Houses) :- adjacent(Y, X, Houses).

adjacent(X, Y, [X,Y|_]).
adjacent(X, Y, [_|Rest]) :- adjacent(X, Y, Rest).

houses(Houses) :-
    % Five houses; the Norwegian is in the first and milk is drunk in the
    % middle, so those go straight into the shape of the list.
    Houses = [h(_,norwegian,_,_,_), _, h(_,_,_,milk,_), _, _],
    member(h(red,englishman,_,_,_), Houses),
    member(h(_,spaniard,dog,_,_), Houses),
    member(h(green,_,_,coffee,_), Houses),
    member(h(_,ukrainian,_,tea,_), Houses),
    right_of(h(green,_,_,_,_), h(ivory,_,_,_,_), Houses),
    member(h(_,_,snails,_,old_gold), Houses),
    member(h(yellow,_,_,_,kools), Houses),
    next_to(h(_,_,_,_,chesterfields), h(_,_,fox,_,_), Houses),
    next_to(h(_,_,_,_,kools), h(_,_,horse,_,_), Houses),
    member(h(_,_,_,orange_juice,lucky_strike), Houses),
    member(h(_,japanese,_,_,parliaments), Houses),
    next_to(h(_,norwegian,_,_,_), h(blue,_,_,_,_), Houses),
    % The two facts the puzzle never states, and asks about.
    member(h(_,_,zebra,_,_), Houses),
    member(h(_,_,_,water,_), Houses).

report(Houses) :-
    member(h(_,ZebraOwner,zebra,_,_), Houses),
    member(h(_,WaterDrinker,_,water,_), Houses),
    format("the ~w owns the zebra~n", [ZebraOwner]),
    format("the ~w drinks water~n", [WaterDrinker]),
    nl,
    forall(nth1(N, Houses, House),
           ( House = h(Colour, Nation, Pet, Drink, Smoke),
             format("~w. ~w~t~10|~w~t~24|~w~t~34|~w~t~48|~w~n",
                    [N, Colour, Nation, Pet, Drink, Smoke]) )).

main :-
    (   houses(Houses)
    ->  report(Houses),
        % And the answer is unique, which findall/3 can check because a
        % solution that fails on the way out simply is not collected.
        aggregate_all(count, houses(_), Count),
        format("~nsolutions: ~w~n", [Count])
    ;   writeln('no solution')
    ).
