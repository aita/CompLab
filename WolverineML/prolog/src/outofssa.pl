/** <module> Leaving SSA before allocation.
 *
 *  A phi is a copy that happens on an edge, so it becomes copies at the end of
 *  each predecessor.  Critical edges are already split, so a predecessor of a
 *  block with phis has nowhere else to go and the copies can simply be
 *  appended.
 *
 *  The copies of one edge happen at once: every argument is read before any
 *  destination is written.  Usually that needs no care, because a phi's
 *  destination is defined nowhere else and so is nobody's argument -- but a
 *  block that is its own predecessor can have two phis that swap, and then the
 *  copies go through temporaries, which is Sreedhar's answer and which
 *  coalescing is expected to remove again.
 */

:- module(outofssa,
          [ destruct/2,           % +Func, -Func
            destruct_module/2     % +Module, -Module
          ]).

:- use_module(library(lists)).
:- use_module(ir).

destruct_module(module(Funcs0, Strings), module(Funcs, Strings)) :-
    maplist(destruct, Funcs0, Funcs).

destruct(F0, F) :-
    ir:walk(F0, Blocks),
    foldl(destruct_block, Blocks, F0, F1),
    ir:recompute_preds(F1, F).

destruct_block(block(_, [], _, _), F, F) :- !.
destruct_block(block(Label, Phis, _, Preds), F0, F) :-
    foldl(copies_for(Phis), Preds, F0, F1),
    ir:get_block(F1, Label, block(L, _, Instrs, P)),
    ir:put_block(F1, block(L, [], Instrs, P), F).

copies_for(Phis, Pred, F0, F) :-
    ir:get_block(F0, Pred, Source),
    (   ir:succs(Source, [_])
    ->  true
    ;   throw(error(critical_edge(Pred), _))
    ),
    findall(D-A, ( member(Phi, Phis), Phi = phi(D, _), ir:phi_arg(Phi, Pred, A) ),
            Moves),
    copy_in_parallel(Pred, Moves, F0, F).

copy_in_parallel(Label, Moves, F0, F) :-
    exclude(same_ends, Moves, Real),
    (   Real == []
    ->  F = F0
    ;   pairs_keys_values(Real, Written, Read),
        (   intersecting(Written, Read)
        ->  through(Written, F0, F1, Temporaries),
            findall(move(T, S),
                    ( nth0(I, Real, _-S), nth0(I, Temporaries, T) ), Into),
            findall(move(D, T),
                    ( nth0(I, Real, D-_), nth0(I, Temporaries, T) ), OutOf),
            append(Into, OutOf, Copies)
        ;   F1 = F0,
            findall(move(D, S), member(D-S, Real), Copies)
        ),
        ir:get_block(F1, Label, Block),
        ir:insert_before_terminator(Block, Copies, Updated),
        ir:put_block(F1, Updated, F)
    ).

same_ends(D-S) :- D == S.

intersecting(A, B) :- member(X, A), memberchk(X, B), !.

through([], F, F, []).
through([_|Rest], F0, F, [T|Ts]) :-
    ir:new_reg(F0, T, F1),
    through(Rest, F1, F, Ts).
