/** <module> Which colour a value would like, which is the calling convention asking.
 *
 *  The allocator does not have to satisfy these -- a preference is dropped the
 *  moment it clashes with something the colouring actually requires -- but
 *  taking one when it is free is what stops the emitter having to move a value
 *  into `x2` on the way into a call, or out of `x0` on the way back from one.
 */

:- module(hints, [preferences/2]).      % +Func, -Assoc

:- use_module(library(assoc)).
:- use_module(library(lists)).
:- use_module(ir).
:- use_module(registers).

preferences(F, Wanted) :-
    registers:argument_regs(Args),
    ir:func_params(F, Params),
    positional(Params, Args, FromParams),
    ir:walk(F, Blocks),
    findall(Pair,
            ( member(block(_, _, Instrs, _), Blocks), member(I, Instrs),
              instruction_hint(Args, I, Pair) ),
            FromCode),
    append(FromParams, FromCode, All),
    empty_assoc(E),
    foldl(remember, All, E, Wanted).

remember(K-V, A0, A) :- put_assoc(K, A0, V, A).

positional([], _, []) :- !.
positional(_, [], []) :- !.
positional([R|Rs], [C|Cs], [R-C|Rest]) :- positional(Rs, Cs, Rest).

instruction_hint(Args, call(D, _, CallArgs), Pair) :-
    (   positional(CallArgs, Args, Pairs), member(Pair, Pairs)
    ;   D \== none, Args = [First|_], Pair = D-First
    ).
instruction_hint(Args, ret(V), V-First) :-
    V \== none, Args = [First|_].
