/** <module> Spilling.
 *
 *  A spilled value gets a frame slot, a store after every definition of it and
 *  a reload in front of every use.  The reloads are new registers, live from
 *  the load to the instruction under it and nowhere else, which is what makes
 *  the pressure come down.  Nothing here assumes SSA: a value written twice
 *  gets two stores, and a phi argument is reloaded at the end of the
 *  predecessor it comes from.
 */

:- module(spill,
          [ loop_depth/2,         % +Func, -Assoc
            costs/2,              % +Func, -Assoc
            spill/4               % +Func, +Victim, -Func, -Reloads
          ]).

:- use_module(library(assoc)).
:- use_module(library(lists)).
:- use_module(library(ordsets)).
:- use_module(ir).
:- use_module(ssa).

%!  loop_depth(+Func, -Depth) is det.
%
%   How deeply each block is nested in loops, for weighing what a use costs.
%   A back edge is an edge into a block that dominates its source; everything
%   that can reach the source without leaving the dominated region is in that
%   loop.

loop_depth(F, Depth) :-
    ssa:dominance(F, Dom),
    ir:block_labels(F, Labels),
    empty_assoc(E),
    foldl(zero, Labels, E, Zeroed),
    ir:walk(F, Blocks),
    findall(Succ-Label,
            ( member(B, Blocks), B = block(Label, _, _, _),
              ir:succs(B, Succs), member(Succ, Succs),
              ssa:dominates(Dom, Succ, Label) ),
            BackEdges),
    foldl(one_loop(F), BackEdges, Zeroed, Depth).

zero(Label, A0, A) :- put_assoc(Label, A0, 0, A).

one_loop(F, Head-Tail, A0, A) :-
    body_of(F, [Tail], [Head], Body),
    foldl(deeper, Body, A0, A).

body_of(_, [], Body, Body).
body_of(F, [L|Ls], Body0, Body) :-
    (   memberchk(L, Body0)
    ->  body_of(F, Ls, Body0, Body)
    ;   ir:get_block(F, L, block(_, _, _, Preds)),
        append(Preds, Ls, Next),
        body_of(F, Next, [L|Body0], Body)
    ).

deeper(Label, A0, A) :- get_assoc(Label, A0, N), M is N + 1, put_assoc(Label, A0, M, A).

%!  costs(+Func, -Weight) is det.
%
%   What spilling a value would cost: its reads and writes, weighed by loops.

costs(F, Weight) :-
    loop_depth(F, Depth),
    ir:walk(F, Blocks),
    empty_assoc(E),
    foldl(block_cost(Depth), Blocks, E, Weight).

scale(Depth, Label, Scale) :-
    get_assoc(Label, Depth, N),
    Capped is min(N, 4),
    Scale is float(10 ** Capped).

block_cost(Depth, block(Label, Phis, Instrs, _), A0, A) :-
    scale(Depth, Label, Scale),
    foldl(phi_cost(Depth, Scale), Phis, A0, A1),
    foldl(instr_cost(Scale), Instrs, A1, A).

phi_cost(Depth, Scale, Phi, A0, A) :-
    Phi = phi(D, Args),
    foldl(arg_cost(Depth), Args, A0, A1),
    bump(D, Scale, A1, A).

arg_cost(Depth, Pred-Arg, A0, A) :-
    scale(Depth, Pred, Scale),
    bump(Arg, Scale, A0, A).

instr_cost(Scale, I, A0, A) :-
    ir:uses(I, Regs),
    foldl(bump_by(Scale), Regs, A0, A1),
    ( ir:defs(I, D) -> bump(D, Scale, A1, A) ; A = A1 ).

bump_by(Scale, R, A0, A) :- bump(R, Scale, A0, A).

bump(R, By, A0, A) :-
    ( get_assoc(R, A0, W) -> true ; W = 0.0 ),
    W1 is W + By,
    put_assoc(R, A0, W1, A).

%!  spill(+Func, +Victim, -Func, -Reloads) is det.
%
%   Give Victim a frame slot, and answer with the reloads that replaced it.

spill(F0, Victim, F, Reloads) :-
    ir:new_slot(F0, Slot, F1),
    ir:func_spill_slots(F1, S0), put_assoc(Victim, S0, Slot, S),
    ir:set_spill_slots_of_func(S, F1, F2),
    ir:func_params(F2, Params),
    ( memberchk(Victim, Params) -> IsParam = true ; IsParam = false ),
    ir:walk(F2, Blocks),
    foldl(spill_block(Victim, Slot, IsParam), Blocks, F2-[], F3-Made),
    ir:walk(F3, Blocks1),
    foldl(spill_phis(Victim, Slot), Blocks1, F3-Made, F-Reloads0),
    list_to_ord_set(Reloads0, Reloads).

spill_block(Victim, Slot, IsParam, block(Label, _, _, _), F0-Made0, F-Made) :-
    ir:get_block(F0, Label, block(_, Phis, Instrs0, Preds)),
    ir:func_entry(F0, Entry),
    (   member(phi(Victim, _), Phis)
    ->  Instrs1 = [store_slot(Slot, Victim)|Instrs0]
    ;   Instrs1 = Instrs0
    ),
    (   IsParam == true, Label == Entry
    ->  Instrs2 = [store_slot(Slot, Victim)|Instrs1]
    ;   Instrs2 = Instrs1
    ),
    foldl(spill_instr(Victim, Slot), Instrs2, F0-[]-Made0, F1-Reversed-Made),
    reverse(Reversed, Instrs),
    ir:put_block(F1, block(Label, Phis, Instrs, Preds), F).

spill_instr(Victim, Slot, I0, F0-Acc0-Made0, F-Acc-Made) :-
    ir:uses(I0, Regs),
    (   memberchk(Victim, Regs), I0 \= store_slot(Slot, _)
    ->  ir:new_reg(F0, Fresh, F),
        ir:map_uses(I0, spill:instead_of(Victim, Fresh), I),
        Acc1 = [I, load_slot(Fresh, Slot)|Acc0],
        Made = [Fresh|Made0]
    ;   F = F0, I = I0, Acc1 = [I|Acc0], Made = Made0
    ),
    (   ir:defs(I, Victim)
    ->  Acc = [store_slot(Slot, Victim)|Acc1]
    ;   Acc = Acc1
    ).

instead_of(Victim, Fresh, R, Out) :- ( R == Victim -> Out = Fresh ; Out = R ).

spill_phis(Victim, Slot, block(Label, _, _, _), F0-Made0, F-Made) :-
    ir:get_block(F0, Label, block(_, Phis0, Instrs, Preds)),
    foldl(spill_phi(Victim, Slot), Phis0, F0-[]-Made0, F1-Reversed-Made),
    reverse(Reversed, Phis),
    ir:put_block(F1, block(Label, Phis, Instrs, Preds), F).

spill_phi(Victim, Slot, Phi0, F0-Acc-Made0, F-[Phi|Acc]-Made) :-
    Phi0 = phi(_, Args),
    findall(Pred, member(Pred-Victim, Args), Preds),
    foldl(reload_edge(Slot), Preds, F0-Phi0-Made0, F-Phi-Made).

reload_edge(Slot, Pred, F0-Phi0-Made0, F-Phi-[Fresh|Made0]) :-
    ir:new_reg(F0, Fresh, F1),
    ir:get_block(F1, Pred, Source),
    ir:insert_before_terminator(Source, [load_slot(Fresh, Slot)], Updated),
    ir:put_block(F1, Updated, F),
    ir:set_phi_arg(Phi0, Pred, Fresh, Phi).
