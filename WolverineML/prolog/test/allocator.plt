:- begin_tests(allocator).

%   The allocator, the parallel copies, and what the emitter does with them.

:- use_module('../src/parser', []).
:- use_module('../src/typecheck', []).
:- use_module('../src/lower', []).
:- use_module('../src/ssa', []).
:- use_module('../src/opt', []).
:- use_module('../src/select', []).
:- use_module('../src/outofssa', []).
:- use_module('../src/allocator', []).
:- use_module('../src/copies', []).
:- use_module('../src/registers', []).
:- use_module('../src/liveness', []).
:- use_module('../src/driver', []).
:- use_module('../src/ir', []).

lines(Parts, Source) :- atomic_list_concat(Parts, '\n', A), atom_string(A, Source).

busy(Source) :-
    lines(['type point = { x : int, y : int }',
           '',
           'fun busy (n : int) : int =',
           '  let',
           '    var a = n + 1',
           '    var b = n + 2',
           '    var c = n + 3',
           '    var d = n + 4',
           '    var total = 0',
           '  in',
           '    while a < n * 10 do (',
           '      total := total + a * b + c * d;',
           '      a := a + 1;',
           '      b := b + 2;',
           '      c := c + 3;',
           '      d := d + 4',
           '    );',
           '    total',
           '  end',
           '',
           'fun caller (n : int) : int = busy (n) + busy (n + 1) + busy (n + 2)',
           '',
           'val p = point { x = 1, y = 2 }',
           'val () = printInt (caller (3) + p.x)'], Source).

%   The pipeline up to the point where the allocator takes over.
prepared(Source, Module) :-
    parser:parse(Source, Decls),
    typecheck:check(Decls, Escapes),
    lower:lower(Decls, Escapes, true, M0),
    ssa:construct_module(M0, M1),
    opt:optimise(M1, module(Funcs0, Strings)),
    maplist(ssa:split_critical_edges, Funcs0, Funcs1),
    select:select_module(module(Funcs1, Strings), M2),
    outofssa:destruct_module(M2, Module).

prepared(Module) :- busy(Source), prepared(Source, Module).

allocated(Machine, Module) :-
    prepared(M0), allocator:allocate_module(M0, Machine, Module).

allocated(Module) :- registers:whole_machine(M), allocated(M, Module).

instructions(F, Instrs) :-
    ir:walk(F, Blocks),
    findall(I, ( member(block(_, _, Is, _), Blocks), member(I, Is) ), Instrs).

colour_values(F, Values) :-
    ir:func_colours(F, Colours), assoc_to_values(Colours, Values).

moves_left(module(Funcs, _), N) :-
    findall(x,
            ( member(F, Funcs), ir:func_colours(F, Colours),
              instructions(F, Instrs), member(move(D, S), Instrs),
              get_assoc(D, Colours, Dc), get_assoc(S, Colours, Sc), Dc \== Sc ),
            Left),
    length(Left, N).

%   -- what the colouring promises ---------------------------------------------

test('every value gets a colour') :-
    allocated(module(Funcs, _)),
    forall(( member(F, Funcs), ir:func_colours(F, Colours),
             instructions(F, Instrs), member(I, Instrs) ),
           ( ir:uses(I, Regs),
             forall(member(R, Regs), get_assoc(R, Colours, _)),
             ( ir:defs(I, D) -> get_assoc(D, Colours, _) ; true ) )).

test('values live together differ') :-
    allocated(module(Funcs, _)),
    forall(member(F, Funcs), allocator:verify(F)).

test('the verifier rejects a real clash') :-
    %   One colour for everything is wrong, and has to be said so.
    allocated(module(Funcs, _)),
    forall(( member(F, Funcs), colour_values(F, Values),
             sort(Values, [_, _|_]) ),
           ( ir:func_colours(F, Colours), assoc_to_keys(Colours, Regs),
             findall(R-0, member(R, Regs), Flat),
             list_to_assoc(Flat, Flattened),
             ir:set_colours_of_func(Flattened, F, Broken),
             catch(allocator:verify(Broken), error(at_once(_, _, _, _), _), true) )).

test('the verifier accepts a coalesced copy') :-
    %   Both ends of a copy are live after it, and hold the same value.
    ir:new_func("f", "f", 0, F0),
    ir:add_block(F0, entry, F1),
    ir:new_reg(F1, A, F2), ir:new_reg(F2, B, F3),
    ir:get_block(F3, entry, block(L, P, _, Preds)),
    ir:put_block(F3, block(L, P, [const(A, 1), move(B, A),
                                  call(none, "wol_print_int", [A]), ret(B)],
                           Preds), F4),
    ir:recompute_preds(F4, F5),
    list_to_assoc([A-9, B-9], Colours),
    ir:set_colours_of_func(Colours, F5, F),
    allocator:verify(F).

test('a value live across a call is callee-saved') :-
    allocated(module(Funcs, _)),
    registers:callee_saved(Callee),
    forall(( member(F, Funcs), liveness:analyse(F, Live),
             liveness:across_calls(F, Live, Across), member(R, Across) ),
           ( ir:func_colours(F, Colours), get_assoc(R, Colours, C),
             memberchk(C, Callee) )).

test('only the callee-saved it used are saved') :-
    allocated(module(Funcs, _)),
    registers:callee_saved(Callee),
    forall(member(F, Funcs),
           ( colour_values(F, Values), sort(Values, Unique),
             include([C]>>memberchk(C, Callee), Unique, Want),
             ir:func_saved(F, Want) )).

test('a smaller machine still works') :-
    forall(member(Size, [5, 6, 8, 12, 16, 26]),
           ( registers:limited(Size, Machine),
             allocated(Machine, module(Funcs, _)),
             registers:anywhere(Machine, Allowed),
             forall(member(F, Funcs),
                    ( allocator:verify(F),
                      colour_values(F, Values),
                      forall(member(C, Values), memberchk(C, Allowed)) )) )).

test('a small machine spills') :-
    registers:limited(6, Machine),
    allocated(Machine, module(Funcs, _)),
    once(( member(F0, Funcs), ir:func_spill_slots(F0, S0),
           assoc_to_list(S0, [_|_]) )),
    forall(( member(F, Funcs), ir:func_spill_slots(F, S),
             assoc_to_values(S, Slots), member(Slot, Slots) ),
           ( ir:func_nslots(F, N), Slot < N )).

test('pressure falls to what the machine has') :-
    registers:limited(5, Machine),
    allocated(Machine, module(Funcs, _)),
    registers:register_count(Machine, K),
    forall(member(F, Funcs),
           ( liveness:analyse(F, Live), liveness:pressure(F, Live, P), P =< K )).

test('an impossible demand is reported') :-
    lines(['fun ten (a : int, b : int, c : int, d : int, e : int,',
           '         f : int, g : int, h : int, i : int, j : int) : int = a + j',
           'val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))'], Source),
    prepared(Source, M),
    registers:limited(8, Machine),
    catch(allocator:allocate_module(M, Machine, _), out_of_registers(Message), true),
    sub_string(Message, _, _, _, "more registers").

%   -- what coalescing is for --------------------------------------------------

test('leaving SSA removes every phi') :-
    prepared(module(Funcs, _)),
    forall(( member(F, Funcs), ir:walk(F, Blocks), member(B, Blocks) ),
           B = block(_, [], _, _)).

test('leaving SSA makes copies and coalescing eats them') :-
    prepared(M0),
    M0 = module(Funcs0, _),
    findall(x, ( member(F, Funcs0), instructions(F, Is), member(move(_, _), Is) ),
            Made),
    length(Made, Before), Before > 0,
    registers:whole_machine(Machine),
    allocator:allocate_module(M0, Machine, M),
    moves_left(M, After),
    Limit is Before // 10,
    After =< Limit.

%   -- parallel copies ---------------------------------------------------------

%   Run a parallel copy on a register file and insist the permutation came out
%   right.  This is what caught a swap the ordering was doing twice.
perform([], State, State).
perform([mov(D, S)|Rest], State0, State) :-
    get_assoc(S, State0, V), put_assoc(D, State0, V, State1),
    perform(Rest, State1, State).
perform([swap(A, B)|Rest], State0, State) :-
    get_assoc(A, State0, X), get_assoc(B, State0, Y),
    put_assoc(A, State0, Y, State1), put_assoc(B, State1, X, State2),
    perform(Rest, State2, State).

worked(Moves, Borrowed, Steps) :-
    numlist(0, 31, Regs),
    findall(R-V, ( member(R, Regs), format(atom(V), 'v~d', [R]) ), Pairs),
    list_to_assoc(Pairs, Before),
    copies:sequentialize(Moves, Borrowed, Steps),
    perform(Steps, Before, After),
    forall(member(D-S, Moves),
           ( get_assoc(S, Before, Want), get_assoc(D, After, Want) )).

test('a copy with no cycle is just moves') :-
    worked([1-2, 3-4, 5-5], 9, Steps),
    forall(member(S, Steps), S = mov(_, _)),
    length(Steps, 2).

test('a chain is ordered so nothing is lost') :-
    worked([1-2, 2-3, 3-4], 9, _).

test('a cycle borrows a register when there is one') :-
    worked([1-2, 2-1], 9, Steps),
    forall(member(S, Steps), S = mov(_, _)),
    memberchk(mov(9, _), Steps).

test('a cycle swaps when there is nothing to borrow') :-
    worked([1-2, 2-1], none, [swap(_, _)]).

test('a longer cycle swaps its way round') :-
    worked([1-2, 2-3, 3-1], none, Steps),
    forall(member(S, Steps), S = swap(_, _)),
    length(Steps, 2).

test('two cycles at once') :-
    worked([1-2, 2-1, 3-4, 4-3], none, _),
    worked([1-2, 2-1, 3-4, 4-3], 9, _).

%   -- what the scratch registers used to be for -------------------------------

test('the remainder is a divide and an msub') :-
    lines(['fun f (a : int, b : int) : int = a mod b',
           'val () = printInt (f (7, 2))'], Source),
    driver:default_options(Options),
    driver:compile_to_asm(Source, Options, Text),
    once_only(Text, "sdiv"), once_only(Text, "msub"),
    \+ sub_string(Text, _, _, _, "mul").

once_only(Text, Needle) :-
    findall(x, sub_string(Text, _, _, _, Needle), [_]).

test('ordinary code keeps no register back') :-
    %   x17 is only for an address the emitter cannot reach any other way.
    read_file_to_string('examples/tour.wol', Source, []),
    driver:default_options(Options),
    driver:compile_to_asm(Source, Options, Text),
    \+ sub_string(Text, _, _, _, "x17").

test('x16 is allocatable') :-
    %   It used to be held back for the emitter; a busy function should take it.
    read_file_to_string('test/programs/pressure.wol', Source, []),
    driver:default_options(Options),
    driver:compile_to_asm(Source, Options, Text),
    sub_string(Text, _, _, _, "x16").

:- end_tests(allocator).
