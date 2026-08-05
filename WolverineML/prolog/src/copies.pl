/** <module> Doing several copies at once, one at a time.
 *
 *  A phi is a copy that happens on an edge, and all the phis of a block happen
 *  together: every argument is read before any destination is written.  Once
 *  the allocator has given both ends real registers that is a permutation, and
 *  putting a permutation into a sequence of instructions is this module.
 *
 *  Copies whose destination nobody else has still to read can go first.  When
 *  only cycles are left, something has to be got out of the way, and there are
 *  two ways to do it: a register the function never used can hold a value for
 *  one step, and if there is no such register the two ends of the cycle swap.
 *  A swap is three `eor`s and needs nothing to borrow, which is why no
 *  register is reserved for this anywhere in the compiler.
 *
 *  The pending copies are an association list and not an assoc, because which
 *  one goes first is visible in the assembly and the order they were given in
 *  is the order they are done in.
 */

:- module(copies, [sequentialize/3]).   % +Moves, +Borrowed, -Steps

:- use_module(library(lists)).
:- use_module(library(pairs)).

%!  sequentialize(+Moves, +Borrowed, -Steps) is det.
%
%   Moves are Destination-Source pairs; Borrowed is a register free to clobber
%   or `none`.  Steps are `mov(Dst, Src)` and `swap(A, B)`.

sequentialize(Moves, Borrowed, Steps) :-
    exclude(same_ends, Moves, Real),
    pairs_keys(Real, Written),
    sort(Written, Unique),
    same_length(Written, Unique),
    untangle(Real, Borrowed, [], Reversed),
    reverse(Reversed, Steps).

same_ends(D-S) :- D == S.

untangle([], _, Done, Done) :- !.
untangle(Pending, Borrowed, Done0, Done) :-
    pairs_values(Pending, Sources),
    include(free_now(Sources), Pending, Ready),
    (   Ready = [_|_]
    ->  foldl(do_move, Ready, Done0, Done1),
        subtract_pairs(Pending, Ready, Rest),
        untangle(Rest, Borrowed, Done1, Done)
    ;   Pending = [Stuck-_|_],
        (   Borrowed \== none
        ->  moved(Pending, Stuck, Borrowed, Rest),
            untangle(Rest, Borrowed, [mov(Borrowed, Stuck)|Done0], Done)
        ;   %   Swapping satisfies `Stuck` outright and leaves its old value
            %   where the other end was, so everything still to read it reads
            %   there instead.
            memberchk(Stuck-Other, Pending),
            selectchk(Stuck-Other, Pending, Without),
            moved(Without, Stuck, Other, Rest),
            untangle(Rest, Borrowed, [swap(Stuck, Other)|Done0], Done)
        )
    ).

free_now(Sources, Dst-_) :- \+ memberchk(Dst, Sources).

do_move(Dst-Src, Done, [mov(Dst, Src)|Done]).

subtract_pairs(Pending, Ready, Rest) :-
    pairs_keys(Ready, Done),
    exclude(among(Done), Pending, Rest).

among(Done, Dst-_) :- memberchk(Dst, Done).

%!  moved(+Pending, +Was, +Now, -Rewritten) is det.
%
%   The value that was in Was is in Now; whoever wanted it looks there.

moved([], _, _, []).
moved([Dst-Src|Rest0], Was, Now, Rest) :-
    (   Src == Was
    ->  (   Dst == Now
        ->  moved(Rest0, Was, Now, Rest)      % the swap already put it there
        ;   Rest = [Dst-Now|More], moved(Rest0, Was, Now, More)
        )
    ;   Rest = [Dst-Src|More], moved(Rest0, Was, Now, More)
    ).
