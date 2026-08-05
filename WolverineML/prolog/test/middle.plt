:- begin_tests(middle).

%   SSA construction, the optimiser, and instruction selection.

:- use_module('../src/parser', []).
:- use_module('../src/typecheck', []).
:- use_module('../src/lower', []).
:- use_module('../src/ssa', []).
:- use_module('../src/opt', []).
:- use_module('../src/select', []).
:- use_module('../src/dag', []).
:- use_module('../src/ir', []).
:- use_module('../src/liveness', []).
:- use_module('../src/driver', []).

lines(Parts, Source) :- atomic_list_concat(Parts, '\n', A), atom_string(A, Source).

built(Source, Checks, Module) :-
    parser:parse(Source, Decls),
    typecheck:check(Decls, Escapes),
    lower:lower(Decls, Escapes, Checks, Module).

in_ssa(Source, Checks, Module) :-
    built(Source, Checks, M0), ssa:construct_module(M0, Module).

selected(Source, Checks, module(Funcs, Strings)) :-
    in_ssa(Source, Checks, module(Funcs0, Strings)),
    opt:optimise(module(Funcs0, Strings), module(Funcs1, _)),
    maplist(ssa:split_critical_edges, Funcs1, Funcs2),
    select:select_module(module(Funcs2, Strings), module(Funcs, _)).

func_named(module(Funcs, _), Name, F) :-
    member(F, Funcs), ir:func_name(F, Name), !.

instructions(F, Instrs) :-
    ir:walk(F, Blocks),
    findall(I, ( member(block(_, _, Is, _), Blocks), member(I, Is) ), Instrs).

forms(Source, Name, Forms) :-
    selected(Source, false, M), func_named(M, Name, F), instructions(F, Instrs),
    findall(Form, member(mach(Form, _, _, _, _, _), Instrs), Forms).

forms(Source, Forms) :- forms(Source, "f", Forms).

count_of(Xs, X, N) :- include(==(X), Xs, Some), length(Some, N).

loop_source(Source) :-
    lines(['fun count (n : int) : int =',
           '  let var i = 0',
           '      var total = 0',
           '  in',
           '    while i < n do (total := total + i; i := i + 1);',
           '    total',
           '  end',
           'val () = printInt (count (10))'], Source).

function_source(Body, Source) :-
    format(atom(Head), 'fun f (a : int, b : int, c : int) : int = ~w', [Body]),
    lines([Head, 'val () = printInt (f (1, 2, 3))'], Source).

tour(Source) :- read_file_to_string('examples/tour.wol', Source, []).

%   -- SSA ---------------------------------------------------------------------

test('lowering writes a variable more than once') :-
    loop_source(Source), built(Source, false, module([_, F|_], _)),
    instructions(F, Instrs),
    findall(D, ( member(I, Instrs), ir:defs(I, D) ), Defs),
    msort(Defs, Sorted),
    append(_, [X, X|_], Sorted),
    ir:walk(F, Blocks),
    forall(member(block(_, Phis, _, _), Blocks), Phis == []).

test('construction gives one definition and phis') :-
    loop_source(Source), in_ssa(Source, false, module([_, F|_], _)),
    ssa:verify(F),
    ir:walk(F, Blocks),
    once(( member(block(_, [_|_], _, _), Blocks) )).

test('every function of the tour verifies') :-
    tour(Source), in_ssa(Source, true, module(Funcs, _)),
    forall(member(F, Funcs), ssa:verify(F)).

test('the dominators of a diamond') :-
    lines(['fun f (c : bool) : int = if c then 1 else 2',
           'val () = printInt (f (true))'], Source),
    in_ssa(Source, false, module([_, F|_], _)),
    ssa:dominance(F, Dom), ir:func_entry(F, Entry),
    ir:block_labels(F, Labels),
    forall(member(L, Labels), ssa:dominates(Dom, Entry, L)),
    ir:walk(F, Blocks),
    include([block(_, _, _, [_, _|_])]>>true, Blocks, Joins),
    Joins = [_|_],
    ssa:dominance_idom(Dom, Idom),
    forall(member(block(J, _, _, _), Joins), get_assoc(J, Idom, Entry)).

test('a phi names exactly its predecessors') :-
    loop_source(Source), in_ssa(Source, false, module(Funcs, _)),
    forall(( member(F, Funcs), ir:walk(F, Blocks),
             member(block(_, Phis, _, Preds), Blocks), member(Phi, Phis) ),
           ( ir:phi_preds(Phi, Named), msort(Named, S), msort(Preds, S) )).

%   -- the optimiser -----------------------------------------------------------

test('constants fold') :-
    in_ssa("val () = printInt (2 * 3 + 4)", false, M0),
    opt:optimise(M0, module([F|_], _)),
    instructions(F, Instrs),
    findall(V, member(const(_, V), Instrs), [10]).

test('dead code goes') :-
    lines(['fun f (n : int) : int = let val unused = n * n in n + 1 end',
           'val () = printInt (f (2))'], Source),
    in_ssa(Source, false, M0),
    opt:optimise(M0, module([_, F|_], _)),
    instructions(F, Instrs),
    \+ member(bin(_, *, _, _), Instrs).

test('unreachable blocks go') :-
    in_ssa("val () = if true then print (\"a\") else print (\"b\")", false, M0),
    opt:optimise(M0, module([F|_], _)),
    instructions(F, Instrs),
    findall(C, member(call(_, C, _), Instrs), ["wol_print"]).

test('splitting leaves phis only after a jump') :-
    loop_source(Source), in_ssa(Source, true, M0),
    opt:optimise(M0, module(Funcs0, _)),
    maplist(ssa:split_critical_edges, Funcs0, Funcs),
    forall(member(F, Funcs),
           ( ssa:verify(F),
             ir:walk(F, Blocks),
             forall(( member(B, Blocks), ir:succs(B, [_, _|_]) ),
                    ( ir:succs(B, Succs),
                      forall(member(S, Succs),
                             ir:get_block(F, S, block(_, [], _, _))) )) )).

%   -- the tiles ---------------------------------------------------------------

test('multiply-add is one instruction') :-
    function_source('a + b * c', Source), forms(Source, Chosen),
    memberchk(madd, Chosen), \+ memberchk(mul, Chosen).

test('multiply-subtract is one instruction') :-
    function_source('a - b * c', Source), forms(Source, Chosen),
    memberchk(msub, Chosen), \+ memberchk(mul, Chosen).

test('a shifted operand beats a multiply-add') :-
    %   `a + b * 8` is one instruction with a shift and two as a multiply-add.
    function_source('a + b * 8', Source), forms(Source, Chosen),
    count_of(Chosen, adds, 1),
    \+ memberchk(madd, Chosen), \+ memberchk(lsli, Chosen).

test('a small constant is an immediate') :-
    function_source('a + 5', One), forms(One, [addi]),
    function_source('(a + 5) - 7', Two), forms(Two, [addi, subi]).

test('a large constant is not') :-
    function_source('a + 100000', Source), forms(Source, Chosen),
    memberchk(const, Chosen).

test('a multiply by a power of two is a shift') :-
    function_source('a * 8', Source), forms(Source, Chosen),
    memberchk(lsli, Chosen), \+ memberchk(mul, Chosen).

test('a comparison read only by its branch sets the flags') :-
    lines(['fun f (a : int) : int = if a < 3 then 1 else 2',
           'val () = printInt (f (1))'], Source),
    selected(Source, false, module(Funcs, _)),
    findall(Code,
            ( member(F, Funcs), ir:walk(F, Blocks), member(B, Blocks),
              ir:terminator(B, cbr(_, _, _, Code)) ),
            Codes),
    memberchk(lt, Codes),
    forms(Source, Chosen), \+ memberchk(cset, Chosen).

test('a comparison read by something else is a value') :-
    lines(['fun f (a : int) : bool = a < 3', 'val () = print ("x")'], Source),
    forms(Source, Chosen), memberchk(cset, Chosen).

test('an array element takes two instructions') :-
    lines(['val a = array (4, 0)', 'val () = printInt (a[2] + a[3])'], Source),
    driver:options(false, true, none, Options),
    driver:compile_to_asm(Source, Options, Text),
    split_string(Text, "\n", "", Lines),
    include([L]>>sub_string(L, 0, _, _, "\tldr "), Lines, Loads),
    length(Loads, 2).

%   -- what the plan is for ----------------------------------------------------

test('a constant read twice is still an immediate') :-
    %   It costs nothing to repeat, so two readers may both take it.
    function_source('(a + 1) * (b + 1)', Source), forms(Source, Chosen),
    count_of(Chosen, addi, 2),
    \+ memberchk(const, Chosen).

test('a chain of additions is not deferred to its last line') :-
    %   Folding a whole spine would keep every term live until the end.
    lines(['fun sum (a : int, b : int, c : int, d : int, e : int, f : int) : int =',
           '  a + b + c + d + e + f',
           'val () = printInt (sum (1, 2, 3, 4, 5, 6))'], Source),
    selected(Source, false, M), func_named(M, "sum", F),
    liveness:analyse(F, Live), liveness:pressure(F, Live, Pressure),
    Pressure =< 8.

test('a node read twice is computed once') :-
    function_source('let val t = a * b in t + t end', Source),
    forms(Source, Chosen), count_of(Chosen, mul, 1).

test('the graph counts its readers') :-
    function_source('a + b', Source),
    selected(Source, false, M), func_named(M, "f", F),
    liveness:analyse(F, Live),
    forall(( ir:walk(F, Blocks), member(B, Blocks), B = block(Label, _, _, _),
             liveness:live_out(Live, Label, Out), dag:build(B, Out, Dag),
             dag:nodes(Dag, Nodes), member(N, Nodes) ),
           ( dag:node_index(N, I), dag:node_users(N, Users),
             findall(x, ( member(Other, Nodes), dag:node_operands(Other, Ops),
                          member(I, Ops) ), Reads),
             length(Reads, Users) )).

test('selection keeps it in SSA') :-
    function_source('a + b * c + 8', Source),
    selected(Source, true, module(Funcs, _)),
    forall(member(F, Funcs), ssa:verify(F)).

:- end_tests(middle).
