/** <module> Liveness on SSA.
 *
 *  The only subtlety is the phi.  A phi does not read its arguments where it
 *  stands; it reads them on the edges, so an argument is live at the end of
 *  the predecessor it is paired with and not anywhere inside the block that
 *  holds the phi.  Getting that wrong is what makes phi-related values
 *  interfere when they should not.
 *
 *  A set of registers is an ordset -- a sorted list without duplicates -- so
 *  union and difference are merges and `==` is set equality.  Nothing here
 *  needs a hash table, and nothing here has an order that has to be justified.
 */

:- module(liveness,
          [ analyse/2,            % +Func, -Liveness
            live_in/3,            % +Liveness, +Label, -Set
            live_out/3,           % +Liveness, +Label, -Set
            across_calls/3,       % +Func, +Liveness, -Set
            pressure/3            % +Func, +Liveness, -Most
          ]).

:- use_module(library(assoc)).
:- use_module(library(ordsets)).
:- use_module(ir).

live_in(live(Ins, _), Label, Set) :- get_assoc(Label, Ins, Set).
live_out(live(_, Outs), Label, Set) :- get_assoc(Label, Outs, Set).

analyse(F, Live) :-
    ir:walk(F, Blocks),
    empty_assoc(E0),
    foldl(block_use_kill, Blocks, E0-E0, Upward-Killed),
    ir:block_labels(F, Labels),
    foldl(empty_set, Labels, E0, Empty),
    ir:rpo(F, Rpo), reverse(Rpo, Backwards),
    fixpoint(Backwards, F, Upward, Killed, live(Empty, Empty), Live).

empty_set(Label, A0, A) :- put_assoc(Label, A0, [], A).

block_use_kill(block(Label, Phis, Instrs, _), U0-K0, U-K) :-
    findall(D, member(phi(D, _), Phis), PhiDefs),
    list_to_ord_set(PhiDefs, Kill0),
    foldl(instr_use_kill, Instrs, []-Kill0, Use-Kill),
    put_assoc(Label, U0, Use, U),
    put_assoc(Label, K0, Kill, K).

instr_use_kill(I, Use0-Kill0, Use-Kill) :-
    ir:uses(I, Regs),
    list_to_ord_set(Regs, Read),
    ord_subtract(Read, Kill0, Fresh),
    ord_union(Use0, Fresh, Use),
    ( ir:defs(I, D) -> ord_add_element(Kill0, D, Kill) ; Kill = Kill0 ).

fixpoint(Order, F, Upward, Killed, Live0, Live) :-
    foldl(live_step(F, Upward, Killed), Order, Live0-false, Live1-Changed),
    (   Changed == true
    ->  fixpoint(Order, F, Upward, Killed, Live1, Live)
    ;   Live = Live1
    ).

live_step(F, Upward, Killed, Label, live(Ins0, Outs0)-Changed0, live(Ins, Outs)-Changed) :-
    ir:get_block(F, Label, B),
    ir:succs(B, Succs),
    foldl(out_from(F, Ins0, Label), Succs, [], Out),
    get_assoc(Label, Upward, Use),
    get_assoc(Label, Killed, Kill),
    ord_subtract(Out, Kill, Survives),
    ord_union(Use, Survives, NewIn),
    get_assoc(Label, Outs0, OldOut),
    get_assoc(Label, Ins0, OldIn),
    (   OldOut == Out, OldIn == NewIn
    ->  Ins = Ins0, Outs = Outs0, Changed = Changed0
    ;   put_assoc(Label, Ins0, NewIn, Ins),
        put_assoc(Label, Outs0, Out, Outs),
        Changed = true
    ).

out_from(F, Ins, Label, Succ, Out0, Out) :-
    get_assoc(Succ, Ins, Entering),
    ord_union(Out0, Entering, Out1),
    ir:get_block(F, Succ, block(_, Phis, _, _)),
    foldl(phi_argument(Label), Phis, Out1, Out).

phi_argument(Label, Phi, Out0, Out) :-
    ( ir:phi_arg(Phi, Label, Arg) -> ord_add_element(Out0, Arg, Out) ; Out = Out0 ).

%!  across_calls(+Func, +Liveness, -Set) is det.
%
%   Values that are live across a call, and so cannot sit in a scratch register.

across_calls(F, Live, Set) :-
    ir:walk(F, Blocks),
    foldl(across_block(Live), Blocks, [], Set).

across_block(Live, block(Label, _, Instrs, _), Set0, Set) :-
    live_out(Live, Label, After),
    reverse(Instrs, Backwards),
    foldl(across_instr, Backwards, After-Set0, _-Set).

across_instr(I, After0-Set0, After-Set) :-
    ( ir:defs(I, D) -> ord_del_element(After0, D, After1) ; After1 = After0 ),
    ( I = call(_, _, _) -> ord_union(Set0, After1, Set) ; Set = Set0 ),
    ir:uses(I, Regs), list_to_ord_set(Regs, Read),
    ord_union(After1, Read, After).

%!  pressure(+Func, +Liveness, -Most) is det.
%
%   The most values live at any one point -- the registers the function wants.

pressure(F, Live, Most) :-
    ir:walk(F, Blocks),
    foldl(pressure_block(Live), Blocks, 0, Most).

pressure_block(Live, block(Label, Phis, Instrs, _), Most0, Most) :-
    live_out(Live, Label, After),
    length(After, N), Most1 is max(Most0, N),
    reverse(Instrs, Backwards),
    foldl(pressure_instr, Backwards, After-Most1, _-Most2),
    live_in(Live, Label, Entering),
    findall(D, member(phi(D, _), Phis), Defs),
    list_to_ord_set(Defs, PhiSet),
    ord_union(Entering, PhiSet, Top),
    length(Top, M), Most is max(Most2, M).

pressure_instr(I, After0-Most0, After-Most) :-
    ( ir:defs(I, D) -> ord_del_element(After0, D, After1) ; After1 = After0 ),
    ir:uses(I, Regs), list_to_ord_set(Regs, Read),
    ord_union(After1, Read, After),
    length(After, N), Most is max(Most0, N).
