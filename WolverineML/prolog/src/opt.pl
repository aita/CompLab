/** <module> Optimisation on SSA.
 *
 *  Five small passes run to a fixed point.  Each is cheap because SSA makes it
 *  cheap: a register has one definition, so constant folding and copy
 *  propagation are a lookup rather than a dataflow problem, and a phi whose
 *  arguments all agree is a copy that was never needed.
 *
 *      fold constants   ->  arithmetic on known values
 *      propagate copies ->  `move`, and phis that turned into one
 *      simplify phis    ->  a phi with one distinct argument is that argument
 *      fold branches    ->  a branch on a known value, and the blocks it strands
 *      dead code        ->  anything computed and not used
 *
 *  Each pass relates a function to the function it becomes and says whether
 *  anything happened, which is what "run it again" needs to know.
 */

:- module(opt,
          [ optimise/2,           % +Module, -Module
            optimise_func/2,      % +Func, -Func
            fold_constants/3, propagate_copies/3, simplify_phis/3,
            fold_branches/3, dead_code/3
          ]).

:- use_module(library(assoc)).
:- use_module(library(lists)).
:- use_module(i64).
:- use_module(ir).

optimise(module(Funcs0, Strings), module(Funcs, Strings)) :-
    maplist(optimise_func, Funcs0, Funcs).

%   Every pass runs every round: they are cheap, and one enables another.
optimise_func(F0, F) :-
    fold_constants(F0, F1, C1),
    propagate_copies(F1, F2, C2),
    simplify_phis(F2, F3, C3),
    fold_branches(F3, F4, C4),
    dead_code(F4, F5, C5),
    (   memberchk(true, [C1, C2, C3, C4, C5])
    ->  optimise_func(F5, F)
    ;   F = F5
    ).

%   -- rewriting --------------------------------------------------------------

%!  rewrite(+Func, +Mapping, -Func) is det.
%
%   Replace registers everywhere they are read, phi arguments included.

rewrite(F0, Mapping, F) :-
    ir:walk(F0, Blocks),
    foldl(rewrite_block(Mapping), Blocks, F0, F).

rewrite_block(Mapping, block(Label, Phis0, Instrs0, Preds), F0, F) :-
    maplist(rewrite_phi(Mapping), Phis0, Phis),
    maplist(rewrite_instr(Mapping), Instrs0, Instrs),
    ir:put_block(F0, block(Label, Phis, Instrs, Preds), F).

rewrite_phi(Mapping, Phi0, Phi) :- ir:map_phi_args(Phi0, opt:resolve(Mapping), Phi).
rewrite_instr(Mapping, I0, I) :- ir:map_uses(I0, opt:resolve(Mapping), I).

resolve(Mapping, R0, R) :- follow(Mapping, R0, [], R).

follow(Mapping, R0, Seen, R) :-
    (   get_assoc(R0, Mapping, Next), \+ memberchk(R0, Seen)
    ->  follow(Mapping, Next, [R0|Seen], R)
    ;   R = R0
    ).

constants(F, Known) :-
    ir:walk(F, Blocks),
    findall(D-V,
            ( member(block(_, _, Instrs, _), Blocks), member(const(D, V), Instrs) ),
            Pairs),
    empty_assoc(E), foldl(remember, Pairs, E, Known).

remember(K-V, A0, A) :- put_assoc(K, A0, V, A).

%   -- the passes -------------------------------------------------------------

fold_constants(F0, F, Changed) :-
    constants(F0, Known0),
    ir:walk(F0, Blocks),
    foldl(fold_block, Blocks, F0-Known0-false, F-_-Changed).

fold_block(block(Label, Phis, Instrs0, Preds), F0-K0-C0, F-K-C) :-
    foldl(fold_one, Instrs0, []-K0-C0, Reversed-K-C),
    reverse(Reversed, Instrs),
    ir:put_block(F0, block(Label, Phis, Instrs, Preds), F).

fold_one(I, Acc0-K0-C0, [Kept|Acc0]-K-C) :-
    (   folded(I, K0, New)
    ->  Kept = New, C = true,
        ( New = const(D, V) -> put_assoc(D, K0, V, K) ; K = K0 )
    ;   Kept = I, C = C0, K = K0
    ).

folded(bin(D, Op, L, R), Known, New) :-
    (   get_assoc(L, Known, A), get_assoc(R, Known, B)
    ->  i64:i64_arith(Op, A, B, V), New = const(D, V)
    ;   get_assoc(R, Known, 0), memberchk(Op, [+, -, or, xor, shl, shr])
    ->  New = move(D, L)
    ;   get_assoc(R, Known, 1), memberchk(Op, [*, /])
    ->  New = move(D, L)
    ;   get_assoc(L, Known, 0), Op == (+)
    ->  New = move(D, R)
    ).
folded(cmp(D, Op, L, R), Known, const(D, V)) :-
    get_assoc(L, Known, A), get_assoc(R, Known, B),
    ( i64:i64_order(Op, A, B) -> V = 1 ; V = 0 ).

propagate_copies(F0, F, Changed) :-
    ir:walk(F0, Blocks),
    findall(D-S,
            ( member(block(_, _, Instrs, _), Blocks), member(move(D, S), Instrs) ),
            Pairs),
    (   Pairs == []
    ->  F = F0, Changed = false
    ;   empty_assoc(E), foldl(remember, Pairs, E, Mapping),
        rewrite(F0, Mapping, F1),
        ir:walk(F1, Rewritten),
        foldl(drop_moves, Rewritten, F1, F),
        Changed = true
    ).

drop_moves(block(Label, Phis, Instrs0, Preds), F0, F) :-
    exclude(is_move, Instrs0, Instrs),
    ir:put_block(F0, block(Label, Phis, Instrs, Preds), F).

is_move(move(_, _)).

simplify_phis(F0, F, Changed) :-
    ir:walk(F0, Blocks),
    empty_assoc(E),
    foldl(simplify_block, Blocks, F0-E-false, F1-Mapping-Changed),
    ( Changed == true -> rewrite(F1, Mapping, F) ; F = F1 ).

simplify_block(block(Label, Phis0, Instrs, Preds), F0-M0-C0, F-M-C) :-
    foldl(simplify_phi, Phis0, []-M0-C0, Reversed-M-C),
    reverse(Reversed, Phis),
    ir:put_block(F0, block(Label, Phis, Instrs, Preds), F).

simplify_phi(Phi, Kept0-M0-C0, Kept-M-C) :-
    Phi = phi(D, _),
    ir:phi_regs(Phi, Regs),
    exclude(==(D), Regs, Others0),
    sort(Others0, Others),
    (   Others = [One]
    ->  put_assoc(D, M0, One, M), C = true, Kept = Kept0
    ;   M = M0, C = C0, Kept = [Phi|Kept0]
    ).

fold_branches(F0, F, Changed) :-
    constants(F0, Known),
    ir:walk(F0, Blocks),
    foldl(fold_branch(Known), Blocks, F0-false, F1-Changed),
    ( Changed == true -> ir:drop_unreachable(F1, F) ; F = F1 ).

fold_branch(Known, Block, F0-C0, F-C) :-
    ir:terminator(Block, T),
    (   T = cbr(Test, Then, Else, _),
        ( get_assoc(Test, Known, Value) -> true ; Then == Else, Value = none )
    ->  ( ( Value == none ; Value =\= 0 ) -> Taken = Then ; Taken = Else ),
        ir:set_terminator(Block, jmp(Taken), Updated),
        ir:put_block(F0, Updated, F),
        C = true
    ;   F = F0, C = C0
    ).

dead_code(F0, F, Changed) :- dead_code_loop(F0, F, false, Changed).

dead_code_loop(F0, F, Changed0, Changed) :-
    used_registers(F0, Used),
    ir:walk(F0, Blocks),
    foldl(drop_dead(Used), Blocks, F0-false, F1-Round),
    (   Round == true
    ->  dead_code_loop(F1, F, true, Changed)
    ;   F = F1, Changed = Changed0
    ).

used_registers(F, Used) :-
    ir:walk(F, Blocks),
    findall(R,
            ( member(block(_, Phis, Instrs, _), Blocks),
              (   member(Phi, Phis), ir:phi_regs(Phi, Rs), member(R, Rs)
              ;   member(I, Instrs), ir:uses(I, Rs), member(R, Rs)
              ) ),
            Regs),
    list_to_ord_set(Regs, Used).

drop_dead(Used, block(Label, Phis0, Instrs0, Preds), F0-C0, F-C) :-
    include(live_phi(Used), Phis0, Phis),
    include(live_instr(Used), Instrs0, Instrs),
    (   ( Phis \== Phis0 ; Instrs \== Instrs0 )
    ->  C = true
    ;   C = C0
    ),
    ir:put_block(F0, block(Label, Phis, Instrs, Preds), F).

live_phi(Used, phi(D, _)) :- memberchk(D, Used).

live_instr(Used, I) :-
    (   ir:defs(I, D)
    ->  ( memberchk(D, Used) -> true ; ir:has_effect(I) )
    ;   true
    ).
