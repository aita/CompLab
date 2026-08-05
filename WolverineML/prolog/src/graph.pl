/** <module> Register allocation by graph colouring, with iterated coalescing.
 *
 *  The idea is Chaitin's: build a graph whose nodes are values and whose edges
 *  join values that are live at the same time, then colour it with as many
 *  colours as the machine has registers.  Colouring a graph is hard in
 *  general, but Kempe's observation makes it practical: a node with fewer than
 *  K neighbours can always be coloured whatever happens to the rest of the
 *  graph.  So remove such nodes one at a time and push them on a stack; when
 *  the graph is empty, pop the stack and give each node a colour its
 *  neighbours have not taken.  If every remaining node has K or more
 *  neighbours, guess that one of them will not get a colour and carry on -- if
 *  the guess was wrong the value is rewritten to live in memory and the whole
 *  thing runs again (Briggs' optimistic colouring).
 *
 *  On top of that sits coalescing, which is why leaving SSA first costs
 *  nothing.  Leaving SSA fills the predecessors of every join with copies;
 *  coalescing merges the two ends of a copy so that it disappears.  Merging
 *  aggressively can make a graph uncolourable, so a merge only happens when
 *  Briggs' test proves it cannot: the merged node must have fewer than K
 *  neighbours of significant degree.  That test is only exact enough to be
 *  useful if degrees are up to date, and simplifying lowers degrees while
 *  merging raises them -- so the two run interleaved, with freezing (giving up
 *  on a copy so its nodes can be simplified) as the way out when neither
 *  applies.  Hence "iterated" (George and Appel, 1996).
 *
 *  This machine has no fixed registers to colour against, so the calling
 *  convention is carried as a set of colours each node may not take: a value
 *  live across a call may not take a caller-saved one.  A node with `f`
 *  forbidden colours and `d` neighbours needs `d + f < K` to be trivially
 *  colourable, so that sum is what stands in for the degree everywhere below.
 *
 *  Every worklist is an ordset, so "the least" is the head of a list and the
 *  colouring a program gets is the colouring it gets again.
 */

:- module(graph, [allocate/3]).         % +Func, +Machine, -Func

:- use_module(library(assoc)).
:- use_module(library(record)).
:- use_module(library(lists)).
:- use_module(library(ordsets)).
:- use_module(library(pairs)).
:- use_module(hints).
:- use_module(ir).
:- use_module(liveness).
:- use_module(registers).
:- use_module(spill).
:- use_module(state).

%   What the colouring carries.  `protected` holds values a previous round
%   produced by reloading something: their live ranges are a load and its one
%   use, so spilling one again would only make another of the same and the
%   rewriting would never end.
:- record colouring(func, machine, protected:list=[],
                    adjacent=t, degree=t, forbidden=t, preferred=t,
                    moves=t, nmoves:integer=0, moves_of=t,
                    worklist_moves:list=[], active_moves:list=[],
                    simplify:list=[], freeze:list=[], spills:list=[],
                    stack:list=[], on_stack:list=[], coalesced:list=[],
                    alias=t, colour=t).

%   -- colouring a function, for as long as it spills -------------------------

allocate(F0, Machine, F) :- rounds(F0, Machine, [], F).

rounds(F0, Machine, Protected, F) :-
    ir:recompute_preds(F0, F1),
    run(F1, Machine, Protected, Colour, Spilled),
    (   Spilled == []
    ->  finish(F1, Colour, F)
    ;   foldl(spill_victim, Spilled, F1-Protected, F2-Protected1),
        rounds(F2, Machine, Protected1, F)
    ).

finish(F0, Colour, F) :-
    registers:callee_saved(Callee),
    assoc_to_values(Colour, Values),
    sort(Values, Unique),
    include(is_callee(Callee), Unique, Saved),
    ir:set_colours_of_func(Colour, F0, F1),
    ir:set_saved_of_func(Saved, F1, F).

is_callee(Callee, C) :- memberchk(C, Callee).

%   Spilling a reload would only make another reload of the same thing.
impossible(F) :-
    ir:func_name(F, Name),
    format(atom(M), '`~w` needs more registers at once than the machine has', [Name]),
    throw(out_of_registers(M)).

spill_victim(Victim, F0-Protected0, F-Protected) :-
    ( memberchk(Victim, Protected0) -> impossible(F0) ; true ),
    spill:spill(F0, Victim, F, Reloads),
    ord_union(Protected0, Reloads, Protected).

run(F, Machine, Protected, Colour, Spilled) :-
    make_colouring([func(F), machine(Machine), protected(Protected)], C0),
    phrase(( build, make_worklists, main_loop, assign_colours(Spilled) ),
           [C0], [C]),
    colouring_colour(C, Colour).

%   Each of the four fails when its own worklist is empty, so the order the
%   clauses are written in is the order they are preferred and the loop stops
%   when none of them applies.
main_loop --> simplify, !, main_loop.
main_loop --> coalesce, !, main_loop.
main_loop --> freeze, !, main_loop.
main_loop --> select_spill, !, main_loop.
main_loop --> [].

%   -- the graph --------------------------------------------------------------

k(K) --> get_via(colouring_machine, M), { registers:register_count(M, K) }.

adjacent(R, Set) --> get_via(colouring_adjacent, A), { get_assoc(R, A, Set) }.
forbidden(R, Set) --> get_via(colouring_forbidden, A), { get_assoc(R, A, Set) }.
degree(R, D) --> get_via(colouring_degree, A), { get_assoc(R, A, D) }.

%   The degree, counting a forbidden colour as a neighbour holding it.
weight(R, W) -->
    degree(R, D), forbidden(R, Bars), { length(Bars, N), W is D + N }.

node(R) --> known(R), !.
node(R) -->
    get_via(colouring_adjacent, A), { put_assoc(R, A, [], A1) },
    set_via(set_adjacent_of_colouring, A1),
    get_via(colouring_degree, D), { put_assoc(R, D, 0, D1) },
    set_via(set_degree_of_colouring, D1),
    get_via(colouring_forbidden, Fb), { put_assoc(R, Fb, [], Fb1) },
    set_via(set_forbidden_of_colouring, Fb1).

known(R) --> get_via(colouring_adjacent, A), { get_assoc(R, A, _) }.

add_edge(A, A) --> !.
add_edge(A, B) --> adjacent(A, SetA), { memberchk(B, SetA) }, !.
add_edge(A, B) -->
    adjacent(A, SetA), adjacent(B, SetB),
    { ord_add_element(SetA, B, SetA1), ord_add_element(SetB, A, SetB1) },
    get_via(colouring_adjacent, Adj0),
    { put_assoc(A, Adj0, SetA1, Adj1), put_assoc(B, Adj1, SetB1, Adj2) },
    set_via(set_adjacent_of_colouring, Adj2),
    bump_degree(A, 1), bump_degree(B, 1).

bump_degree(R, By) -->
    get_via(colouring_degree, D0), { get_assoc(R, D0, N), M is N + By,
                            put_assoc(R, D0, M, D) },
    set_via(set_degree_of_colouring, D).

build -->
    get_via(colouring_func, F),
    { hints:preferences(F, Preferred) }, set_via(set_preferred_of_colouring, Preferred),
    { liveness:analyse(F, Live), ir:walk(F, Blocks),
      ir:func_params(F, Params) },
    fold(declare_block, Blocks),
    fold(node, Params),
    fold(build_block(Live), Blocks).

declare_block(block(_, _, Instrs, _)) --> fold(declare_instr, Instrs).

declare_instr(I) -->
    { ir:uses(I, Regs) }, fold(node, Regs),
    ( { ir:defs(I, D) } -> node(D) ; [] ).

build_block(Live, block(Label, _, Instrs, _)) -->
    { liveness:live_out(Live, Label, Out), reverse(Instrs, Backwards) },
    fold(build_instr, Backwards, Out, Alive),
    at_entry(Label, Alive).

at_entry(Label, Alive) -->
    get_via(colouring_func, F), { ir:func_entry(F, Label) }, !,
    entry_edges(Alive).
at_entry(_, _) --> [].

%   `fold//4` here threads the live set as well as the state, because the walk
%   is backwards through the block and the live set is what it is carrying.
fold(_, [], Alive, Alive) --> [].
fold(Goal, [X|Xs], Alive0, Alive) -->
    call(Goal, X, Alive0, Alive1),
    fold(Goal, Xs, Alive1, Alive).

build_instr(I, Alive0, Alive) -->
    (   { I = move(Dst, Src) }
    ->  { ord_del_element(Alive0, Src, Alive1) },
        record_move(Dst, Src)
    ;   { Alive1 = Alive0 }
    ),
    (   { ir:defs(I, Defined) }
    ->  { ord_add_element(Alive1, Defined, Alive2) },
        fold(add_edge(Defined), Alive2),
        forbid_caller_saved(I, Alive2, Defined),
        { ord_del_element(Alive2, Defined, Alive3) }
    ;   { Alive3 = Alive1 },
        forbid_caller_saved(I, Alive1, none)
    ),
    { ir:uses(I, Regs), list_to_ord_set(Regs, Read), ord_union(Alive3, Read, Alive) }.

%   A value live across a call cannot sit in a caller-saved register.
forbid_caller_saved(call(_, _, _), Alive, Defined) --> !,
    get_via(colouring_machine, M),
    { registers:machine_caller(M, Caller),
      list_to_ord_set(Caller, CallerSet),
      exclude(==(Defined), Alive, Others) },
    fold(forbid(CallerSet), Others).
forbid_caller_saved(_, _, _) --> [].

forbid(Colours, R) -->
    forbidden(R, Set0), { ord_union(Set0, Colours, Set) },
    get_via(colouring_forbidden, A0), { put_assoc(R, A0, Set, A) }, set_via(set_forbidden_of_colouring, A).

record_move(Dst, Src) -->
    get_via(colouring_nmoves, Index), { Next is Index + 1 }, set_via(set_nmoves_of_colouring, Next),
    get_via(colouring_moves, M0), { put_assoc(Index, M0, Dst-Src, M) }, set_via(set_moves_of_colouring, M),
    note_move(Dst, Index), note_move(Src, Index),
    get_via(colouring_worklist_moves, W0), { ord_add_element(W0, Index, W) },
    set_via(set_worklist_moves_of_colouring, W).

note_move(R, Index) -->
    get_via(colouring_moves_of, A0),
    { ( get_assoc(R, A0, Set0) -> true ; Set0 = [] ),
      ord_add_element(Set0, Index, Set),
      put_assoc(R, A0, Set, A) },
    set_via(set_moves_of_of_colouring, A).

%   Parameters arrive together, so they interfere with each other.
entry_edges(Alive) -->
    get_via(colouring_func, F), { ir:func_params(F, Params) },
    entry_pairs(Params, Alive).

entry_pairs([], _) --> [].
entry_pairs([P|Ps], Alive) -->
    fold(add_edge(P), Alive),
    fold(add_edge(P), Ps),
    entry_pairs(Ps, Alive).

%   -- the worklists ----------------------------------------------------------

make_worklists -->
    get_via(colouring_adjacent, A), { assoc_to_keys(A, Regs) },
    fold(classify, Regs).

classify(R) --> weight(R, W), k(K), { W >= K }, !, add_to(spills, R).
classify(R) --> move_related(R), !, add_to(freeze, R).
classify(R) --> add_to(simplify, R).

%   A worklist is named by the pair of relations that read and write it, so
%   `add_to` and `remove_from` do not have to know which one they were given.
worklist(simplify, colouring_simplify, set_simplify_of_colouring).
worklist(freeze, colouring_freeze, set_freeze_of_colouring).
worklist(spills, colouring_spills, set_spills_of_colouring).
worklist(on_stack, colouring_on_stack, set_on_stack_of_colouring).
worklist(coalesced, colouring_coalesced, set_coalesced_of_colouring).
worklist(active_moves, colouring_active_moves, set_active_moves_of_colouring).
worklist(worklist_moves, colouring_worklist_moves, set_worklist_moves_of_colouring).

add_to(Field, R) -->
    { worklist(Field, Get, Set) },
    get_via(Get, Set0), { ord_add_element(Set0, R, Set1) }, set_via(Set, Set1).

remove_from(Field, R) -->
    { worklist(Field, Get, Set) },
    get_via(Get, Set0), { ord_del_element(Set0, R, Set1) }, set_via(Set, Set1).

node_moves(R, Indices) -->
    get_via(colouring_moves_of, A), get_via(colouring_active_moves, Active),
    get_via(colouring_worklist_moves, Worklist),
    { ( get_assoc(R, A, Mine) -> true ; Mine = [] ),
      ord_union(Active, Worklist, Live),
      ord_intersection(Mine, Live, Indices) }.

move_related(R) --> node_moves(R, [_|_]).

neighbours(R, Ns) -->
    adjacent(R, Set), get_via(colouring_on_stack, Stack), get_via(colouring_coalesced, Merged),
    { ord_subtract(Set, Stack, Left), ord_subtract(Left, Merged, Ns) }.

simplify -->
    get_via(colouring_simplify, [R|_]),
    remove_from(simplify, R),
    get_via(colouring_stack, Stack), set_via(set_stack_of_colouring, [R|Stack]),
    add_to(on_stack, R),
    neighbours(R, Ns),
    fold(decrement_degree, Ns).

decrement_degree(R) -->
    weight(R, Was), k(K),
    bump_degree(R, -1),
    became_trivial(Was, K, R).

%   It has just become trivially colourable, so the copies around it may have
%   become safe to merge as well.
became_trivial(W, K, R) -->
    { W =:= K }, !,
    neighbours(R, Ns),
    { append(Ns, [R], Nearby) },
    enable_moves(Nearby),
    remove_from(spills, R),
    ( move_related(R) -> add_to(freeze, R) ; add_to(simplify, R) ).
became_trivial(_, _, _) --> [].

enable_moves(Nodes) --> fold(enable_moves_of, Nodes).

enable_moves_of(R) --> node_moves(R, Indices), fold(enable_move, Indices).

enable_move(Index) -->
    get_via(colouring_active_moves, Active), { memberchk(Index, Active) }, !,
    remove_from(active_moves, Index), add_to(worklist_moves, Index).
enable_move(_) --> [].

%   -- coalescing -------------------------------------------------------------

get_alias(R, Alias) -->
    get_via(colouring_coalesced, Merged), get_via(colouring_alias, A),
    { follow(Merged, A, R, Alias) }.

follow(Merged, A, R0, R) :-
    (   memberchk(R0, Merged)
    ->  get_assoc(R0, A, Next), follow(Merged, A, Next, R)
    ;   R = R0
    ).

coalesce -->
    get_via(colouring_worklist_moves, [Index|_]),
    remove_from(worklist_moves, Index),
    get_via(colouring_moves, Moves), { get_assoc(Index, Moves, Dst-Src) },
    get_alias(Dst, U), get_alias(Src, V),
    merge_or_not(Index, U, V).

%   The first clause is `U == V` written where Prolog does that test.
merge_or_not(_, U, U) --> !, add_to_worklist(U).
merge_or_not(_, U, V) --> interfering(U, V), !, add_to_worklist(U), add_to_worklist(V).
merge_or_not(_, U, V) --> conservative(U, V), !, combine(U, V), add_to_worklist(U).
merge_or_not(Index, _, _) --> add_to(active_moves, Index).

interfering(U, V) --> adjacent(U, Neighbours), { memberchk(V, Neighbours) }.

%!  add_to_worklist(+R)// is det.
%
%   A node that is trivially colourable and no longer part of any copy can be
%   simplified.  `freeze_move` wants exactly the same thing of the other end.

add_to_worklist(R) -->
    weight(R, W), k(K), { W < K }, \+ move_related(R), !,
    remove_from(freeze, R), add_to(simplify, R).
add_to_worklist(_) --> [].

%!  conservative(+U, +V)// is semidet.
%
%   Briggs: the merged node must have fewer than K significant neighbours.
%   The colours the two ends may not take add up as well, and a colour the
%   merged node is barred from is one more thing standing in its way.

conservative(U, V) -->
    neighbours(U, Nu), neighbours(V, Nv),
    { ord_union(Nu, Nv, Together) },
    forbidden(U, Fu), forbidden(V, Fv),
    { ord_union(Fu, Fv, Barred), length(Barred, B) },
    count_significant(Together, 0, Significant),
    k(K),
    { Significant + B < K }.

count_significant([], N, N) --> [].
count_significant([R|Rs], N0, N) -->
    weight(R, W), k(K),
    { W >= K -> N1 is N0 + 1 ; N1 = N0 },
    count_significant(Rs, N1, N).

combine(U, V) -->
    remove_from(freeze, V), remove_from(spills, V),
    add_to(coalesced, V),
    get_via(colouring_alias, A0), { put_assoc(V, A0, U, A) }, set_via(set_alias_of_colouring, A),
    merge_moves(U, V),
    forbidden(V, Fv), fold(forbid_one(U), Fv),
    prefer_from(U, V),
    enable_moves([V]),
    neighbours(V, Ns),
    fold(reconnect(U), Ns),
    now_significant(U).

now_significant(U) -->
    weight(U, W), k(K), get_via(colouring_freeze, Frozen),
    { W >= K, memberchk(U, Frozen) }, !,
    remove_from(freeze, U), add_to(spills, U).
now_significant(_) --> [].

merge_moves(U, V) -->
    get_via(colouring_moves_of, A0),
    { ( get_assoc(U, A0, Mine) -> true ; Mine = [] ),
      ( get_assoc(V, A0, Theirs) -> true ; Theirs = [] ),
      ord_union(Mine, Theirs, Both),
      put_assoc(U, A0, Both, A) },
    set_via(set_moves_of_of_colouring, A).

forbid_one(R, Colour) --> forbid([Colour], R).

prefer_from(U, V) -->
    get_via(colouring_preferred, P),
    (   { get_assoc(V, P, Want), \+ get_assoc(U, P, _) }
    ->  { put_assoc(U, P, Want, P1) }, set_via(set_preferred_of_colouring, P1)
    ;   []
    ).

reconnect(U, Other) --> add_edge(Other, U), decrement_degree(Other).

%   -- freezing and spilling --------------------------------------------------

freeze -->
    get_via(colouring_freeze, [R|_]),
    remove_from(freeze, R),
    add_to(simplify, R),
    freeze_moves(R).

freeze_moves(R) --> node_moves(R, Indices), fold(freeze_move(R), Indices).

freeze_move(R, Index) -->
    get_via(colouring_moves, Moves), { get_assoc(Index, Moves, Dst-Src) },
    remove_from(active_moves, Index), remove_from(worklist_moves, Index),
    get_alias(Dst, ADst), get_alias(R, AR),
    { ADst == AR -> End = Src ; End = Dst },
    get_alias(End, Other),
    add_to_worklist(Other).

%!  select_spill// is det.
%
%   Guess that the value with the most neighbours per use will not fit.  Never
%   a reload, though: those are cheap by that measure precisely because they
%   were made cheap, and choosing one would undo the last round's work instead
%   of the pressure.

select_spill -->
    get_via(colouring_func, F), { spill:costs(F, Weights) },
    get_via(colouring_spills, All), get_via(colouring_protected, Protected),
    { exclude(among(Protected), All, Unprotected),
      ( Unprotected == [] -> Among = All ; Among = Unprotected ),
      Among = [First|Rest] },
    score(First, Weights, FirstScore),
    best(Rest, Weights, First-FirstScore, Chosen),
    remove_from(spills, Chosen),
    add_to(simplify, Chosen),
    freeze_moves(Chosen).

among(Set, R) :- memberchk(R, Set).

score(R, Weights, Score) -->
    weight(R, W),
    { ( get_assoc(R, Weights, Cost) -> true ; Cost = 0.0 ),
      Score is W / (Cost + 1.0) }.

best([], _, R-_, R) --> [].
best([R|Rs], Weights, Best0-Score0, Best) -->
    score(R, Weights, Score),
    { Score > Score0 -> Next = R-Score ; Next = Best0-Score0 },
    best(Rs, Weights, Next, Best).

%   -- handing out the colours ------------------------------------------------

assign_colours(Spilled) -->
    pop_stack([], Spilled0),
    get_via(colouring_coalesced, Merged),
    fold(colour_coalesced, Merged),
    { list_to_ord_set(Spilled0, Spilled) }.

pop_stack(Spilled, Spilled) --> get_via(colouring_stack, []), !.
pop_stack(Spilled0, Spilled) -->
    get_via(colouring_stack, [R|Rest]),
    set_via(set_stack_of_colouring, Rest),
    remove_from(on_stack, R),
    free_colours(R, Free),
    give_colour(R, Free, Spilled0, Spilled1),
    pop_stack(Spilled1, Spilled).

free_colours(R, Free) -->
    taken_colours(R, Taken),
    get_via(colouring_machine, M), { registers:anywhere(M, Candidates) },
    forbidden(R, Barred),
    { exclude(among(Taken), Candidates, Left),
      exclude(among(Barred), Left, Free) }.

%   Nothing is left for it, so it goes to memory and the whole colouring runs
%   again -- which is what optimistic colouring means.
give_colour(R, [], Spilled, [R|Spilled]) --> !.
give_colour(R, Free, Spilled, Spilled) -->
    get_via(colouring_preferred, P),
    { ( get_assoc(R, P, Want), memberchk(Want, Free) -> C = Want ; Free = [C|_] ) },
    get_via(colouring_colour, Col0), { put_assoc(R, Col0, C, Col) },
    set_via(set_colour_of_colouring, Col).

taken_colours(R, Taken) -->
    adjacent(R, Neighbours),
    get_state(C),
    { colouring_colour(C, Colours), colouring_coalesced(C, Merged),
      colouring_alias(C, A),
      findall(Colour,
              ( member(N, Neighbours), follow(Merged, A, N, Alias),
                get_assoc(Alias, Colours, Colour) ),
              Taken0),
      list_to_ord_set(Taken0, Taken) }.

colour_coalesced(R) -->
    get_alias(R, Alias),
    get_via(colouring_colour, Col0),
    get_via(colouring_machine, M), { registers:anywhere(M, [Default|_]) },
    { ( get_assoc(Alias, Col0, C) -> true ; C = Default ),
      put_assoc(R, Col0, C, Col) },
    set_via(set_colour_of_colouring, Col).
