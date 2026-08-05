/** <module> The register allocator, and the verifier it answers to.
 *
 *  The Python tree has two of these -- one that colours the SSA program itself
 *  in dominance order and one that leaves SSA first -- so that the two can be
 *  measured against each other.  This tree keeps the second: leave SSA, build
 *  the interference graph, and colour it with Chaitin's algorithm and George
 *  and Appel's iterated coalescing.
 */

:- module(allocator,
          [ allocate_module/3,    % +Module, +Machine, -Module
            verify/1              % +Func
          ]).

:- use_module(library(assoc)).
:- use_module(library(lists)).
:- use_module(library(ordsets)).
:- use_module(graph).
:- use_module(ir).
:- use_module(liveness).

allocate_module(module(Funcs0, Strings), Machine, module(Funcs, Strings)) :-
    maplist(colour_func(Machine), Funcs0, Funcs).

colour_func(Machine, F0, F) :- graph:allocate(F0, Machine, F).

%!  verify(+Func) is det.
%
%   No two values that hold different things at once may share a colour.
%
%   The check is made where the interference graph joins values -- at each
%   definition, and at the top of a block for the phis and the parameters,
%   which define several at once.  Looking at a whole live set instead would be
%   wrong, not merely slower: both ends of a copy are live after it and hold
%   the same value, so they may share a register, and that is the entire point
%   of coalescing.  A verifier that rejected it would reject every program the
%   coalescer had done its job on.
%
%   Every value that interferes with another is caught this way, because the
%   later of the two definitions that put the values there happens while the
%   other is live.

verify(F) :-
    liveness:analyse(F, Live),
    ir:func_colours(F, Colours),
    ir:walk(F, Blocks),
    forall(member(B, Blocks), verify_block(F, Colours, Live, B)).

verify_block(F, Colours, Live, block(Label, Phis, Instrs, _)) :-
    liveness:live_out(Live, Label, Out),
    reverse(Instrs, Backwards),
    foldl(verify_instr(F, Colours, Label), Backwards, Out, _),
    liveness:live_in(Live, Label, In),
    foldl(verify_phi(F, Colours, Label), Phis, In, Entering),
    ir:func_entry(F, Entry),
    (   Label == Entry
    ->  ir:func_params(F, Params),
        foldl(verify_param(F, Colours, Label), Params, Entering, _)
    ;   true
    ).

%   Both ends of a copy hold the same value, so the source stops being a
%   separate thing here.  What the definition writes is checked against
%   everything else live and then leaves the set again -- it was not live
%   before the instruction that wrote it.
verify_instr(F, Colours, Label, I, Alive0, Alive) :-
    ( I = move(_, Src) -> ord_del_element(Alive0, Src, Alive1) ; Alive1 = Alive0 ),
    ir:uses(I, Regs),
    forall(member(R, Regs), coloured(Colours, R)),
    (   ir:defs(I, D)
    ->  coloured(Colours, D),
        ord_add_element(Alive1, D, WithDef),
        no_clash(F, WithDef, D, Label),
        ord_del_element(WithDef, D, Alive2)
    ;   Alive2 = Alive1
    ),
    list_to_ord_set(Regs, Read),
    ord_union(Alive2, Read, Alive).

verify_phi(F, Colours, Label, phi(D, _), Entering0, Entering) :-
    coloured(Colours, D),
    ord_add_element(Entering0, D, Entering),
    no_clash(F, Entering, D, Label).

verify_param(F, Colours, Label, P, Entering0, Entering) :-
    coloured(Colours, P),
    ord_add_element(Entering0, P, Entering),
    no_clash(F, Entering, P, Label).

coloured(Colours, R) :-
    ( get_assoc(R, Colours, _) -> true ; throw(error(no_colour(R), _)) ).

%   Nothing else live here may hold the colour Written was just given.
no_clash(F, Alive, Written, Where) :-
    ir:func_colours(F, Colours),
    (   get_assoc(Written, Colours, Colour)
    ->  forall(( member(Other, Alive), Other \== Written,
                 get_assoc(Other, Colours, Colour) ),
               throw(error(at_once(Colour, Written, Other, Where), _)))
    ;   true
    ).
