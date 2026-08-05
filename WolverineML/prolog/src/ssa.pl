/** <module> SSA construction, the textbook way.
 *
 *  Dominators by the iterative algorithm of Cooper, Harvey and Kennedy,
 *  dominance frontiers from those, phis at the frontiers of every definition,
 *  and then one walk of the dominator tree renaming as it goes.  This is
 *  minimal SSA and nothing cleverer: a phi is placed wherever the frontier
 *  says, whether or not the variable is live there, and the dead ones leave in
 *  opt:dead_code.
 *
 *  Only registers written more than once take part.  Everything lowering
 *  produced once -- a temporary -- is already in SSA and is left with the name
 *  it has.
 */

:- module(ssa,
          [ dominance/2,          % +Func, -Dominance
            dominance_idom/2,     % +Dominance, -Assoc
            dominates/3,          % +Dominance, +A, +B   (semidet)
            construct/2,          % +Func, -Func
            construct_module/2,   % +Module, -Module
            split_critical_edges/2, % +Func, -Func
            verify/1              % +Func
          ]).

:- use_module(library(assoc)).
:- use_module(library(record)).
:- use_module(library(lists)).
:- use_module(library(pairs)).
:- use_module(ir).
:- use_module(state).

%   What renaming carries: the function it is rewriting, the dominator tree it
%   walks, which variable each phi stands for, which registers are variables at
%   all, a stack of names per variable, and the registers invented for a
%   variable read on a path that never wrote it.
:- record rn(func, dom, phi_vars=t, vars:list=[], stacks=t,
             undefined=t, undef_order:list=[]).

%   -- dominance --------------------------------------------------------------

dominance_idom(dom(Idom, _, _, _), Idom).

%!  dominates(+Dominance, +A, +B) is semidet.

dominates(Dom, A, B) :-
    (   A == B
    ->  true
    ;   dominance_idom(Dom, Idom), get_assoc(B, Idom, Parent),
        Parent \== B,
        dominates(Dom, A, Parent)
    ).

dominance(F, dom(Idom, Children, Frontier, Order)) :-
    ir:rpo(F, Order),
    rank_of(Order, 0, Ranks0), list_to_assoc(Ranks0, Ranks),
    ir:func_entry(F, Entry),
    list_to_assoc([Entry-Entry], Idom0),
    Order = [_|Rest],
    idom_fixpoint(Rest, F, Ranks, Idom0, Idom),
    children_of(Order, Idom, Children),
    frontier_of(Order, F, Idom, Frontier).

rank_of([], _, []).
rank_of([L|Ls], I, [L-I|Rest]) :- J is I + 1, rank_of(Ls, J, Rest).

idom_fixpoint(Order, F, Ranks, Idom0, Idom) :-
    foldl(idom_step(F, Ranks), Order, Idom0-false, Idom1-Changed),
    (   Changed == true
    ->  idom_fixpoint(Order, F, Ranks, Idom1, Idom)
    ;   Idom = Idom1
    ).

idom_step(F, Ranks, Label, Idom0-Changed0, Idom-Changed) :-
    ir:get_block(F, Label, block(_, _, _, Preds)),
    include(known(Idom0), Preds, Known),
    (   Known == []
    ->  Idom = Idom0, Changed = Changed0
    ;   Known = [First|More],
        foldl(intersect(Ranks, Idom0), More, First, New),
        (   get_assoc(Label, Idom0, New)
        ->  Idom = Idom0, Changed = Changed0
        ;   put_assoc(Label, Idom0, New, Idom), Changed = true
        )
    ).

known(Idom, Label) :- get_assoc(Label, Idom, _).

intersect(Ranks, Idom, B, A, Common) :- walk_up(Ranks, Idom, A, B, Common).

walk_up(_, _, A, B, A) :- A == B, !.
walk_up(Ranks, Idom, A0, B0, Common) :-
    climb(Ranks, Idom, A0, B0, A),
    climb(Ranks, Idom, B0, A, B),
    walk_up(Ranks, Idom, A, B, Common).

climb(Ranks, Idom, A0, B, A) :-
    get_assoc(A0, Ranks, RankA), get_assoc(B, Ranks, RankB),
    (   RankA > RankB
    ->  get_assoc(A0, Idom, Up), climb(Ranks, Idom, Up, B, A)
    ;   A = A0
    ).

children_of(Order, Idom, Children) :-
    empty_assoc(Empty0),
    foldl(empty_list, Order, Empty0, Empty),
    foldl(add_child(Idom), Order, Empty, Children).

empty_list(Label, A0, A) :- put_assoc(Label, A0, [], A).

add_child(Idom, Label, A0, A) :-
    get_assoc(Label, Idom, Parent),
    (   Parent == Label
    ->  A = A0
    ;   get_assoc(Parent, A0, Kids), append(Kids, [Label], Kids1),
        put_assoc(Parent, A0, Kids1, A)
    ).

frontier_of(Order, F, Idom, Frontier) :-
    empty_assoc(Empty0),
    foldl(empty_list, Order, Empty0, Empty),
    foldl(frontier_at(F, Idom), Order, Empty, Frontier).

frontier_at(F, Idom, Label, A0, A) :-
    ir:get_block(F, Label, block(_, _, _, Preds)),
    (   Preds = [_, _|_]
    ->  get_assoc(Label, Idom, Stop),
        foldl(runner_up(Idom, Label, Stop), Preds, A0, A)
    ;   A = A0
    ).

runner_up(Idom, Label, Stop, Runner, A0, A) :-
    (   Runner \== Stop, get_assoc(Runner, Idom, Up)
    ->  get_assoc(Runner, A0, Set0),
        (   memberchk(Label, Set0)
        ->  A1 = A0
        ;   put_assoc(Runner, A0, [Label|Set0], A1)
        ),
        runner_up(Idom, Label, Stop, Up, A1, A)
    ;   A = A0
    ).

%   -- where each register is written -----------------------------------------
%
%   A register written twice in one block is as much a variable as one written
%   in two blocks, so the count is what decides, and the blocks are what the
%   frontier walk needs.

definitions(F, Sites, Counts) :-
    ir:walk(F, Blocks),
    findall(R-Label,
            ( member(block(Label, _, Instrs, _), Blocks),
              member(I, Instrs), ir:defs(I, R) ),
            Defined),
    ir:func_params(F, Params), ir:func_entry(F, Entry),
    findall(P-Entry, member(P, Params), FromParams),
    append(Defined, FromParams, All),
    empty_assoc(E0), foldl(note_site, All, E0, Sites),
    empty_assoc(C0), foldl(note_count, All, C0, Counts).

note_site(R-Label, A0, A) :-
    (   get_assoc(R, A0, Set0)
    ->  ( memberchk(Label, Set0) -> A = A0 ; put_assoc(R, A0, [Label|Set0], A) )
    ;   put_assoc(R, A0, [Label], A)
    ).

note_count(R-_, A0, A) :-
    ( get_assoc(R, A0, N) -> true ; N = 0 ),
    M is N + 1,
    put_assoc(R, A0, M, A).

variables(Counts, Vars) :-
    assoc_to_list(Counts, Pairs),
    findall(R, ( member(R-N, Pairs), N > 1 ), Vars).

%   -- placing the phis -------------------------------------------------------

place_phis(F0, Dom, Sites, Vars, F, PhiVars) :-
    ir:block_labels(F0, Order),
    empty_assoc(P0), foldl(empty_list, Order, P0, P1),
    foldl(place_for(Dom, Sites), Vars, F0-P1, F-PhiVars).

place_for(Dom, Sites, V, F0-P0, F-P) :-
    get_assoc(V, Sites, Blocks0),
    sort(Blocks0, Sorted),
    reverse(Sorted, Work),          % the top of the stack is the front
    place_loop(Work, Dom, Sites, V, [], F0-P0, F-P).

place_loop([], _, _, _, _, State, State).
place_loop([B|Work], Dom, Sites, V, Placed0, F0-P0, F-P) :-
    Dom = dom(_, _, Frontier, _),
    get_assoc(B, Frontier, Targets0),
    sort(Targets0, Targets),
    foldl(place_at(Sites, V), Targets, work(Work, Placed0, F0, P0), work(Work1, Placed, F1, P1)),
    place_loop(Work1, Dom, Sites, V, Placed, F1-P1, F-P).

place_at(Sites, V, Target, work(Work0, Placed0, F0, P0), work(Work, Placed, F, P)) :-
    (   memberchk(Target, Placed0)
    ->  Work = Work0, Placed = Placed0, F = F0, P = P0
    ;   Placed = [Target|Placed0],
        get_assoc(Target, P0, Vs), append(Vs, [V], Vs1),
        put_assoc(Target, P0, Vs1, P),
        ir:get_block(F0, Target, block(L, Phis, Instrs, Preds)),
        ir:phi_args_from(Preds, V, Args),
        append(Phis, [phi(V, Args)], Phis1),
        ir:put_block(F0, block(L, Phis1, Instrs, Preds), F),
        get_assoc(V, Sites, Written),
        (   memberchk(Target, Written)
        ->  Work = Work0
        ;   Work = [Target|Work0]
        )
    ).

%   -- renaming ---------------------------------------------------------------

construct(F0, F) :-
    ir:recompute_preds(F0, F1),
    dominance(F1, Dom),
    definitions(F1, Sites, Counts),
    variables(Counts, Vars),
    place_phis(F1, Dom, Sites, Vars, F2, PhiVars),
    make_rn([func(F2), dom(Dom), phi_vars(PhiVars), vars(Vars)], Rn0),
    ir:func_params(F2, Params),
    phrase(( fold(rename_param, Params, Renamed),
             set_params(Renamed),
             run_renamer,
             plant_undefined ),
           [Rn0], [Rn]),
    rn_func(Rn, F).

rename_param(P, R) -->
    get_via(rn_vars, Vars),
    ( { memberchk(P, Vars) } -> rename_def(P, R) ; { R = P } ).

set_params(Params) -->
    get_via(rn_func, F0), { ir:set_params_of_func(Params, F0, F) },
    set_via(set_func_of_rn, F).

rename_def(V, Fresh) -->
    get_via(rn_func, F0), { ir:new_reg(F0, Fresh, F) }, set_via(set_func_of_rn, F),
    get_via(rn_stacks, S0),
    { ( get_assoc(V, S0, Stack) -> true ; Stack = [] ),
      put_assoc(V, S0, [Fresh|Stack], S) },
    set_via(set_stacks_of_rn, S).

pop_def(V) -->
    get_via(rn_stacks, S0),
    { get_assoc(V, S0, [_|Rest]), put_assoc(V, S0, Rest, S) },
    set_via(set_stacks_of_rn, S).

%   A variable read on a path that never wrote it reads zero.
top_of(V, R) -->
    get_via(rn_stacks, S),
    (   { get_assoc(V, S, [Top|_]) }
    ->  { R = Top }
    ;   undef(V, R)
    ).

undef(V, R) -->
    get_via(rn_undefined, U0),
    (   { get_assoc(V, U0, Found) }
    ->  { R = Found }
    ;   get_via(rn_func, F0), { ir:new_reg(F0, R, F) }, set_via(set_func_of_rn, F),
        { put_assoc(V, U0, R, U) }, set_via(set_undefined_of_rn, U),
        get_via(rn_undef_order, Order), { append(Order, [R], Order1) },
        set_via(set_undef_order_of_rn, Order1)
    ).

plant_undefined -->
    get_via(rn_undef_order, Order),
    get_via(rn_func, F), { ir:func_entry(F, Entry) },
    fold(plant_one(Entry), Order).

plant_one(Entry, R) -->
    block_at(Entry, block(L, Phis, Instrs, Preds)),
    write_block(block(L, Phis, [const(R, 0)|Instrs], Preds)).

%   -- reading and writing the function being renamed -------------------------

block_at(Label, Block) --> get_via(rn_func, F), { ir:get_block(F, Label, Block) }.

write_block(Block) -->
    get_via(rn_func, F0), { ir:put_block(F0, Block, F) },
    set_via(set_func_of_rn, F).

phi_variables(Label, Vs) -->
    get_via(rn_phi_vars, PhiVars), { get_assoc(Label, PhiVars, Vs) }.

%   -- the walk ---------------------------------------------------------------

run_renamer -->
    get_via(rn_func, F), { ir:func_entry(F, Entry) },
    walk_tree([Entry-false], []).

walk_tree([], _) --> [].
walk_tree([Label-true|Stack], Pushed) -->
    { memberchk(Label-Vs, Pushed) },
    fold(pop_def, Vs),
    walk_tree(Stack, Pushed).
walk_tree([Label-false|Stack], Pushed) -->
    rename_block(Label, Mine),
    get_via(rn_dom, dom(_, Children, _, _)),
    { get_assoc(Label, Children, Kids),
      findall(K-false, member(K, Kids), Pushes),
      append(Pushes, [Label-true|Stack], Next) },
    walk_tree(Next, [Label-Mine|Pushed]).

%!  rename_block(+Label, -Renamed)// is det.
%
%   Renamed is the list of variables this block pushed a name for, which is
%   what the walk pops again on the way back up.  The block is read once and
%   written once: the new phis and the new instructions are related to the old
%   ones by the two grammars below, and nothing is replaced in place.

rename_block(Label, Mine) -->
    block_at(Label, block(_, Phis0, Instrs0, Preds)),
    phi_variables(Label, Vs),
    renamed_phis(Phis0, Vs, Phis, PhiMine),
    renamed_instrs(Instrs0, Instrs, InstrMine),
    write_block(block(Label, Phis, Instrs, Preds)),
    { append(PhiMine, InstrMine, Mine) },
    block_at(Label, Block), { ir:succs(Block, Succs) },
    fold(rename_edge(Label), Succs).

%   A phi and the variable it stands for are paired by position, because that
%   is how `place_phis` put them there.
renamed_phis([], [], [], []) --> [].
renamed_phis([phi(_, Args)|Ps], [V|Vs], [phi(Fresh, Args)|Qs], [V|Mine]) -->
    rename_def(V, Fresh),
    renamed_phis(Ps, Vs, Qs, Mine).

renamed_instrs([], [], []) --> [].
renamed_instrs([I0|Is], [I|Rest], Mine) -->
    rename_uses(I0, I1),
    get_via(rn_vars, Vars),
    (   { ir:defs(I1, D), memberchk(D, Vars) }
    ->  rename_def(D, Fresh),
        { ir:set_def(I1, Fresh, I), Mine = [D|More] }
    ;   { I = I1, Mine = More }
    ),
    renamed_instrs(Is, Rest, More).

%   The uses are renamed left to right, because renaming can invent a register
%   for a variable read on a path that never wrote it, and the order it invents
%   them in is the order they are numbered.
rename_uses(I0, I) -->
    { ir:uses(I0, Regs) },
    fold(rename_use, Regs, Replaced),
    { pairs_keys_values(Pairs, Regs, Replaced),
      ir:map_uses(I0, ssa:replace_with(Pairs), I) }.

rename_use(R, R1) -->
    get_via(rn_vars, Vars),
    ( { memberchk(R, Vars) } -> top_of(R, R1) ; { R1 = R } ).

replace_with(Pairs, R, R1) :- ( memberchk(R-Found, Pairs) -> R1 = Found ; R1 = R ).

%   What a successor's phis read on this edge.  The whole phi list is rebuilt
%   and the block written once.
rename_edge(Label, Succ) -->
    phi_variables(Succ, Vs),
    block_at(Succ, block(_, Phis0, Instrs, Preds)),
    edge_args(Label, Phis0, Vs, Phis),
    write_block(block(Succ, Phis, Instrs, Preds)).

edge_args(_, [], _, []) --> [].
edge_args(Label, [Phi0|Ps], [V|Vs], [Phi|Qs]) -->
    top_of(V, R),
    { ir:set_phi_arg(Phi0, Label, R, Phi) },
    edge_args(Label, Ps, Vs, Qs).

construct_module(module(Funcs0, Strings), module(Funcs, Strings)) :-
    maplist(construct, Funcs0, Funcs).

%   -- giving every phi a place to put its copy in ----------------------------

%!  split_critical_edges(+Func, -Func) is det.
%
%   An edge from a block with several successors into a block with several
%   predecessors has nowhere to hold the copies a phi turns into, so it gets a
%   block of its own.  The same goes for any edge into a block that still has
%   a phi, so that the emitter only ever has to put copies before a `jmp`.

split_critical_edges(F0, F) :-
    ir:block_labels(F0, Order),
    foldl(split_from, Order, F0, F1),
    ir:recompute_preds(F1, F).

split_from(Label, F0, F) :-
    ir:get_block(F0, Label, B),
    ir:succs(B, Succs),
    (   Succs = [_, _|_]
    ->  foldl(split_edge(Label), Succs, F0, F)
    ;   F = F0
    ).

split_edge(Label, Succ, F0, F) :-
    ir:get_block(F0, Succ, block(_, Phis, _, Preds)),
    (   ( Preds = [_, _|_] ; Phis = [_|_] )
    ->  format(atom(Split), '~w.~w', [Label, Succ]),
        ir:add_block(F0, Split, F1),
        ir:get_block(F1, Split, block(SL, SP, _, SPreds)),
        ir:put_block(F1, block(SL, SP, [jmp(Succ)], SPreds), F2),
        ir:get_block(F2, Label, B0),
        ir:terminator(B0, T0),
        ir:rename_target(T0, Succ, Split, T),
        ir:set_terminator(B0, T, B),
        ir:put_block(F2, B, F3),
        ir:get_block(F3, Succ, block(TL, TPhis0, TInstrs, TPreds)),
        maplist(rename_pred(Label, Split), TPhis0, TPhis),
        ir:put_block(F3, block(TL, TPhis, TInstrs, TPreds), F)
    ;   F = F0
    ).

rename_pred(Old, New, Phi0, Phi) :- ir:rename_phi_pred(Phi0, Old, New, Phi).

%   -- what SSA promises ------------------------------------------------------

%!  verify(+Func) is det.
%
%   One definition per register, and it dominates every use.

verify(F) :-
    dominance(F, Dom),
    ir:walk(F, Blocks),
    findall(R-Label,
            ( member(block(Label, Phis, Instrs, _), Blocks),
              ( member(phi(R, _), Phis) ; member(I, Instrs), ir:defs(I, R) ) ),
            Defs),
    pairs_keys(Defs, Written),
    msort(Written, Sorted),
    ( duplicate(Sorted, Twice) -> throw(error(twice(Twice), _)) ; true ),
    ir:func_params(F, Params), ir:func_entry(F, Entry),
    findall(P-Entry, member(P, Params), FromParams),
    append(Defs, FromParams, All),
    list_to_assoc_keeping_first(All, Definition),
    forall(member(block(Label, Phis, Instrs, Preds), Blocks),
           verify_block(Dom, Definition, Label, Phis, Instrs, Preds)).

duplicate([X, X|_], X) :- !.
duplicate([_|Xs], X) :- duplicate(Xs, X).

list_to_assoc_keeping_first(Pairs, Assoc) :-
    empty_assoc(E), foldl(first_only, Pairs, E, Assoc).

first_only(K-V, A0, A) :- ( get_assoc(K, A0, _) -> A = A0 ; put_assoc(K, A0, V, A) ).

verify_block(Dom, Definition, Label, Phis, Instrs, Preds) :-
    sort(Preds, SortedPreds),
    forall(member(Phi, Phis),
           ( ir:phi_preds(Phi, Named), sort(Named, SortedNamed),
             (   SortedNamed == SortedPreds
             ->  true
             ;   throw(error(phi_preds(Label, SortedNamed, SortedPreds), _))
             ),
             forall(ir:phi_arg(Phi, Pred, R),
                    ( get_assoc(R, Definition, Where)
                    -> ( dominates(Dom, Where, Pred) -> true
                       ; throw(error(does_not_reach(R, Label, Pred), _)) )
                    ;  throw(error(never_defined(R), _)) )) )),
    forall(( member(I, Instrs), ir:uses(I, Rs), member(R, Rs) ),
           ( get_assoc(R, Definition, Where)
           -> ( dominates(Dom, Where, Label) -> true
              ; throw(error(does_not_dominate(R, Label), _)) )
           ;  throw(error(never_defined(R), _)) )).
