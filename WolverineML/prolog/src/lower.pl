/** <module> Lowering: the typed syntax tree becomes a control flow graph.
 *
 *  Two things are worth knowing about this pass.
 *
 *  It never builds a phi.  A variable written in two branches is written to
 *  the same register twice, and `ssa` is what turns those two writes into one
 *  phi.  Lowering only has to make sure a definition reaches every use, which
 *  structured control flow does for free.
 *
 *  It decides where a variable lives.  A variable the checker did not put in
 *  the escape set becomes a register; one that escaped becomes a frame slot,
 *  reached through load_slot/store_slot in its own function and through a
 *  chain of static links from a nested one.  Where each variable lives is an
 *  assoc from its id, which is what the other ports write on the symbol.
 *
 *  The pass has a great deal of state -- the half-built function, the block
 *  being written into, the break targets, the string pool -- so it is a DCG,
 *  and `state.pl` says why.  Lowering a nested function saves the five
 *  function-shaped fields and puts them back afterwards, which is what having
 *  a second object for it is in Python.
 */

:- module(lower, [lower/4]).      % +Decls, +Escapes, +Checks, -Module

:- use_module(library(assoc)).
:- use_module(library(record)).
:- use_module(library(ordsets)).
:- use_module(library(pairs)).
:- use_module(library(yall)).
:- use_module(ast).
:- use_module(ir).
:- use_module(state).
:- use_module(types).

%   What lowering carries.  The first six belong to the module and the last
%   six to the function being written, which is why lowering a nested function
%   saves those six and puts them back.
:- record lw(checks=true, escapes:list=[], homes=t, strings:list=[],
             string_ids=t, made=t, next_index:integer=0,
             func=none, index:integer= -1, cur=none, breaks:list=[],
             counter:integer=0, has_children=false).

:- discontiguous lower_node//3.

%!  lower(+Decls, +Escapes, +Checks, -Module) is det.

lower(Decls, Escapes, Checks, module(Funcs, Strings)) :-
    make_lw([checks(Checks), escapes(Escapes)], Lw0),
    phrase(( new_function("wol_main", "main", 0),
             lower_decls(Decls),
             terminate(ret(none)),
             finish ),
           [Lw0], [Lw]),
    lw_made(Lw, Made),
    assoc_to_list(Made, Pairs),
    pairs_values(Pairs, Funcs),
    lw_strings(Lw, Strings).

%   -- the module the whole compilation shares --------------------------------

intern_string(Text, Symbol) -->
    get_via(lw_string_ids, Ids),
    (   { get_assoc(Text, Ids, Found) }
    ->  { Symbol = Found }
    ;   get_via(lw_strings, Strings),
        { length(Strings, N), format(string(Symbol), '.Lstr~d', [N]),
          put_assoc(Text, Ids, Symbol, Ids1),
          append(Strings, [Symbol-Text], Strings1) },
        set_via(set_string_ids_of_lw, Ids1),
        set_via(set_strings_of_lw, Strings1)
    ).

new_function(Label, Name, Depth) -->
    get_via(lw_next_index, Index), { Next is Index + 1 },
    set_via(set_next_index_of_lw, Next),
    { ir:new_func(Label, Name, Depth, F0), ir:add_block(F0, entry, F1) },
    set_via(set_func_of_lw, F1), set_via(set_index_of_lw, Index), set_via(set_cur_of_lw, entry),
    set_via(set_breaks_of_lw, []), set_via(set_counter_of_lw, 0), set_via(set_has_children_of_lw, false),
    (   { Depth > 0 }
    ->  fresh_slot(Slot),
        get_via(lw_func, F2), { ir:set_link_slot_of_func(Slot, F2, F3) },
        set_via(set_func_of_lw, F3)
    ;   []
    ).

%   -- the function being built -----------------------------------------------

fresh_reg(R) --> get_via(lw_func, F0), { ir:new_reg(F0, R, F) }, set_via(set_func_of_lw, F).
fresh_slot(S) --> get_via(lw_func, F0), { ir:new_slot(F0, S, F) }, set_via(set_func_of_lw, F).

fresh(Hint, Label) -->
    get_via(lw_counter, N), { M is N + 1, format(atom(Label), '~w~d', [Hint, M]) },
    set_via(set_counter_of_lw, M),
    get_via(lw_func, F0), { ir:add_block(F0, Label, F) }, set_via(set_func_of_lw, F).

emit(I) -->
    get_via(lw_cur, Label), get_via(lw_func, F0),
    { ir:get_block(F0, Label, B0), ir:append_instr(B0, I, B), ir:put_block(F0, B, F) },
    set_via(set_func_of_lw, F).

terminate(T) --> emit(T), fresh(dead, Label), set_via(set_cur_of_lw, Label).

jump(Label) --> terminate(jmp(Label)).

branch(Test, Yes, No) --> terminate(cbr(Test, Yes, No, '')).

constant(Value, R) --> fresh_reg(R), emit(const(R, Value)).

binop(Op, L, Rhs, R) --> fresh_reg(R), emit(bin(R, Op, L, Rhs)).

compare(Op, L, Rhs, R) --> fresh_reg(R), emit(cmp(R, Op, L, Rhs)).

call_runtime(Name, Args, R) --> fresh_reg(R), emit(call(R, Name, Args)).

add_param(R) -->
    get_via(lw_func, F0),
    { ir:func_params(F0, Ps), append(Ps, [R], Ps1),
      ir:set_params_of_func(Ps1, F0, F) },
    set_via(set_func_of_lw, F).

%   -- finishing a function ---------------------------------------------------

finish -->
    get_via(lw_func, F0), { ir:drop_unreachable(F0, F1) }, set_via(set_func_of_lw, F1),
    drop_unused_static_link,
    get_via(lw_func, F), get_via(lw_index, Index),
    get_via(lw_made, Made0), { put_assoc(Index, Made0, F, Made) },
    set_via(set_made_of_lw, Made).

%   A function nobody nests inside, and that never looks outward, keeps no
%   static link: the slot goes, and every later slot moves down one.
drop_unused_static_link -->
    get_via(lw_func, F0), get_via(lw_has_children, Kids),
    { ir:func_link_slot(F0, Slot) },
    (   { Slot < 0 ; Kids == true }
    ->  []
    ;   { ir:walk(F0, Blocks),
          ( member(block(_, _, Instrs, _), Blocks), member(load_slot(_, Slot), Instrs)
          -> Reads = true ; Reads = false ) },
        (   { Reads == true }
        ->  []
        ;   { maplist(renumber_block(Slot), Blocks, Renumbered),
              foldl(replace_block, Renumbered, F0, F1),
              ir:func_nslots(F1, N), M is N - 1,
              ir:set_nslots_of_func(M, F1, F2),
              ir:set_link_slot_of_func(-1, F2, F) },
            set_via(set_func_of_lw, F)
        )
    ).

renumber_block(Slot, block(L, P, Instrs0, Preds), block(L, P, Instrs, Preds)) :-
    include(not_link_store(Slot), Instrs0, Kept),
    maplist(renumber_slot(Slot), Kept, Instrs).

replace_block(Block, F0, F) :- ir:put_block(F0, Block, F).

not_link_store(Slot, store_slot(Slot, _)) :- !, fail.
not_link_store(_, _).

renumber_slot(Slot, store_slot(S0, R), store_slot(S, R)) :- S0 > Slot, !, S is S0 - 1.
renumber_slot(Slot, load_slot(R, S0), load_slot(R, S)) :- S0 > Slot, !, S is S0 - 1.
renumber_slot(_, I, I).

%   -- declarations -----------------------------------------------------------

lower_decls(Ds) --> fold(lower_decl, Ds).

lower_decl(type_decl(_, _)) --> !, [].
lower_decl(fun_decl(Binds, _)) --> !,
    set_via(set_has_children_of_lw, true),
    fold(lower_function, Binds).
lower_decl(val_decl(_, _, Init, _, _, Sym)) -->
    lower_exp(Init, Value),
    give_a_home(Sym, Value).

%   `val () = ...` leaves no symbol at all, and a `val` of type unit has no
%   value to keep anywhere.
give_a_home(Sym, _) --> { var(Sym) }, !.
give_a_home(Sym, _) --> { types:var_sym_type(Sym, unit) }, !.
give_a_home(Sym, Value) --> bind_var(Sym, Value).

lower_function(Bind) -->
    { Bind = fun_bind(_, _, _, Body, _, fun_sym(Name, Label, Syms, Result, Depth, _)) },
    save_context(Ctx),
    new_function(Label, Name, Depth),
    static_link_param(Depth),
    get_via(lw_func, F1), { ir:func_params(F1, Taken), length(Taken, Start) },
    bind_params(Syms, Start),
    lower_exp(Body, Value),
    { ( Result == unit -> Returned = none ; Returned = Value ) },
    terminate(ret(Returned)),
    finish,
    restore_context(Ctx).

%   A nested function takes its parent's frame pointer as a hidden first
%   argument and keeps it in slot 0.
static_link_param(Depth) --> { Depth =:= 0 }, !.
static_link_param(_) -->
    fresh_reg(Link), add_param(Link),
    get_via(lw_func, F), { ir:func_link_slot(F, Slot) },
    emit(store_slot(Slot, Link)).

bind_params([], _) --> [].
bind_params([Sym|Syms], Index) -->
    { ir:argument_registers(Max), Next is Index + 1 },
    one_param(Sym, Index, Max),
    bind_params(Syms, Next).

%   The ninth argument and beyond are already in the frame when the callee
%   starts, so they never take a register at entry.
one_param(Sym, Index, Max) -->
    { Index >= Max, Slot is -(Index - Max + 1) }, !,
    set_home(Sym, slot(Slot)).
one_param(Sym, _, _) --> fresh_reg(R), add_param(R), param_home(Sym, R).

param_home(Sym, R) -->
    escaping(Sym), !,
    fresh_slot(Slot), set_home(Sym, slot(Slot)), emit(store_slot(Slot, R)).
param_home(Sym, R) --> set_home(Sym, reg(R)).

save_context(ctx(F, I, Cur, Breaks, Counter, Kids)) -->
    get_via(lw_func, F), get_via(lw_index, I), get_via(lw_cur, Cur),
    get_via(lw_breaks, Breaks), get_via(lw_counter, Counter),
    get_via(lw_has_children, Kids).

restore_context(ctx(F, I, Cur, Breaks, Counter, Kids)) -->
    set_via(set_func_of_lw, F), set_via(set_index_of_lw, I), set_via(set_cur_of_lw, Cur),
    set_via(set_breaks_of_lw, Breaks), set_via(set_counter_of_lw, Counter),
    set_via(set_has_children_of_lw, Kids).

%   -- where a variable lives -------------------------------------------------

escaping(Sym) -->
    get_via(lw_escapes, Escapes),
    { types:var_sym_id(Sym, Id), ord_memberchk(Id, Escapes) }.

set_home(Sym, Home) -->
    get_via(lw_homes, H0),
    { types:var_sym_id(Sym, Id), put_assoc(Id, H0, Home, H) },
    set_via(set_homes_of_lw, H).

home(Sym, Home) -->
    get_via(lw_homes, H),
    { types:var_sym_id(Sym, Id), get_assoc(Id, H, Home) }.

%!  bind_var(+Sym, +Value)// is det.
%
%   Give a variable its home, and put the initial value in it.

bind_var(Sym, Value) -->
    escaping(Sym), !,
    fresh_slot(Slot), set_home(Sym, slot(Slot)), emit(store_slot(Slot, Value)).
bind_var(Sym, Value) -->
    fresh_reg(R), set_home(Sym, reg(R)), emit(move(R, Value)).

%!  frame_at(+Depth, -Reg)// is det.
%
%   A register holding the frame pointer of the function at Depth.

frame_at(Depth, R) -->
    fresh_reg(R0),
    get_via(lw_func, F), { ir:func_depth(F, Here), ir:func_link_slot(F, Slot) },
    frame_from(Depth, Here, Slot, R0, R).

frame_from(Depth, Depth, _, R, R) --> !, emit(frame_addr(R)).
frame_from(Depth, Here, Slot, R0, R) -->
    emit(load_slot(R0, Slot)),
    { Outer is Here - 1 },
    climb(Outer, Depth, R0, R).

climb(Here, Depth, R, R) --> { Here =< Depth }, !, [].
climb(Here, Depth, R0, R) -->
    fresh_reg(Next), { ir:slot_offset(0, Offset) },
    emit(load(Next, R0, Offset)),
    { Shallower is Here - 1 },
    climb(Shallower, Depth, Next, R).

read_var(Sym, R) --> home(Sym, reg(R)), !.
read_var(Sym, R) -->
    home(Sym, slot(Slot)), bound_here(Sym), !,
    fresh_reg(R), emit(load_slot(R, Slot)).
read_var(Sym, R) -->
    home(Sym, slot(Slot)),
    { types:var_sym_depth(Sym, There), ir:slot_offset(Slot, Offset) },
    frame_at(There, Base),
    fresh_reg(R),
    emit(load(R, Base, Offset)).

%   Bound by the function being lowered, rather than by one further out.
bound_here(Sym) -->
    get_via(lw_func, F),
    { ir:func_depth(F, Depth), types:var_sym_depth(Sym, Depth) }.

write_var(Sym, Value) --> home(Sym, reg(R)), !, emit(move(R, Value)).
write_var(Sym, Value) -->
    home(Sym, slot(Slot)), bound_here(Sym), !,
    emit(store_slot(Slot, Value)).
write_var(Sym, Value) -->
    home(Sym, slot(Slot)),
    { types:var_sym_depth(Sym, There), ir:slot_offset(Slot, Offset) },
    frame_at(There, Base),
    emit(store(Base, Offset, Value)).

%   -- expressions ------------------------------------------------------------

value_of(E, R) -->
    lower_exp(E, R0),
    { ( R0 == none -> throw(error(domain_error(value, E), _)) ; R = R0 ) }.

%!  lower_exp(+Exp, -Reg)// is det.
%
%   Reg is the register the expression left its value in, or `none`.

lower_exp(exp(Node, _, Type), R) --> lower_node(Node, Type, R).

lower_node(int_lit(V), _, R) --> constant(V, R).
lower_node(bool_lit(B), _, R) --> { B == true -> V = 1 ; V = 0 }, constant(V, R).
lower_node(nil_lit, _, R) --> constant(0, R).
lower_node(unit_lit, _, none) --> [].
lower_node(str_lit(Text), _, R) -->
    intern_string(Text, Symbol), fresh_reg(R), emit(str_const(R, Symbol)).
lower_node(var_ref(_, Sym), _, R) --> read_var(Sym, R).
lower_node(neg_exp(Operand), _, R) -->
    constant(0, Zero), value_of(Operand, V), binop(-, Zero, V, R).

lower_node(bin_exp(Op, Lhs, Rhs), _, R) -->
    value_of(Lhs, L), value_of(Rhs, Rr),
    binary(Op, Lhs, L, Rr, R).

binary(^, _, L, Rr, R) --> !, call_runtime("wol_concat", [L, Rr], R).
binary(/, _, L, Rr, R) --> !, check_nonzero(Rr), binop(/, L, Rr, R).
%   The remainder is spelled out rather than left to the emitter: the quotient
%   it needs in between is a value like any other, and the allocator can find
%   it a register.  The emitter fuses the last two back into one `msub`.
binary(mod, _, L, Rr, R) --> !,
    check_nonzero(Rr),
    binop(/, L, Rr, Quotient),
    binop(*, Quotient, Rr, Product),
    binop(-, L, Product, R).
binary(Op, _, L, Rr, R) --> { memberchk(Op, [+, -, *]) }, !, binop(Op, L, Rr, R).
%   Strings compare by content, which is a call and then a comparison with zero.
binary(Op, Lhs, L, Rr, R) --> { ast:exp_type(Lhs, string) }, !,
    call_runtime("wol_string_cmp", [L, Rr], Order),
    constant(0, Zero),
    compare(Op, Order, Zero, R).
binary(Op, _, L, Rr, R) --> compare(Op, L, Rr, R).

%   `andalso` and `orelse` are branches, so the result needs a register.
lower_node(logic_exp(Op, Lhs, Rhs), _, Result) -->
    fresh_reg(Result),
    fresh(logic, Second), fresh(logicjoin, Join),
    value_of(Lhs, L),
    emit(move(Result, L)),
    ( { Op == andalso } -> branch(L, Second, Join) ; branch(L, Join, Second) ),
    set_via(set_cur_of_lw, Second),
    value_of(Rhs, Rr),
    emit(move(Result, Rr)),
    jump(Join),
    set_via(set_cur_of_lw, Join).

lower_node(call_exp(_, Args, Sym), _, R) -->
    { Sym = fun_sym(_, Label, _, Result, Depth, Builtin) },
    called(Builtin, Args, Label, Result, Depth, R).

called(not, [A], _, _, _, R) --> !,
    value_of(A, V), constant(1, One), binop(xor, V, One, R).
called(array, [N, Init], _, _, _, R) --> !,
    value_of(N, Nr), value_of(Init, Ir),
    call_runtime("wol_array", [Nr, Ir], R).
called(length, [A], _, _, _, R) --> !,
    value_of(A, Arr), check_not_nil(Arr),
    fresh_reg(R), emit(load(R, Arr, 0)).
called(Builtin, Args, Label, Result, Depth, R) -->
    fold(argument, Args, Values),
    static_link(Builtin, Depth, Values, All),
    returning(Result, Label, All, R).

%   A function of ours takes its parent's frame pointer as a hidden first
%   argument; one of the runtime's does not.
static_link(none, Depth, Values, [Link|Values]) --> !,
    { Outer is Depth - 1 }, frame_at(Outer, Link).
static_link(_, _, Values, Values) --> [].

returning(unit, Label, Args, none) --> !, emit(call(none, Label, Args)).
returning(_, Label, Args, R) --> call_runtime(Label, Args, R).

argument(E, R) --> value_of(E, R).

lower_node(record_lit(_, _, Ordered), record(_, _, Arity), Base) -->
    { ir:word(W), Size is W * max(Arity, 1) },
    constant(Size, SizeReg),
    call_runtime("wol_alloc", [SizeReg], Base),
    store_fields(Ordered, 0, Base).

store_fields([], _, _) --> [].
store_fields([field_init(_, Value, _)|Rest], I, Base) -->
    value_of(Value, V),
    { ir:word(W), Offset is W * I, J is I + 1 },
    emit(store(Base, Offset, V)),
    store_fields(Rest, J, Base).

lower_node(index_exp(Array, Index), _, R) -->
    element_address(Array, Index, Addr),
    { ir:word(W) },
    fresh_reg(R), emit(load(R, Addr, W)).

%   The address of `a[i]`, without the length word the elements follow.  The
%   selector turns this into one `add` with a shifted operand, and the word is
%   the load's displacement, so the two instructions that come out are the two
%   the machine has.
element_address(Array, Index, Addr) -->
    value_of(Array, Base), value_of(Index, Idx),
    check_not_nil(Base), check_bounds(Base, Idx),
    constant(3, Three),
    binop(shl, Idx, Three, Shifted),
    binop(+, Base, Shifted, Addr).

lower_node(field_exp(Record, _, Offset), _, R) -->
    value_of(Record, Base), check_not_nil(Base),
    { ir:word(W), Displacement is W * Offset },
    fresh_reg(R), emit(load(R, Base, Displacement)).

lower_node(assign_exp(Target, Value), _, none) -->
    { ast:exp_node(Target, Place) },
    assign_to(Place, Value).

assign_to(var_ref(_, Sym), Value) --> !, value_of(Value, V), write_var(Sym, V).
assign_to(index_exp(Array, Index), Value) --> !,
    element_address(Array, Index, Addr),
    value_of(Value, V), { ir:word(W) },
    emit(store(Addr, W, V)).
assign_to(field_exp(Record, _, Offset), Value) -->
    value_of(Record, Base), check_not_nil(Base),
    value_of(Value, V),
    { ir:word(W), Displacement is W * Offset },
    emit(store(Base, Displacement, V)).

lower_node(if_exp(Test, Then, Else), Type, Result) -->
    result_register(Type, Result),
    fresh(then, Yes), fresh(else, No), fresh(join, Join),
    value_of(Test, C),
    branch(C, Yes, No),

    set_via(set_cur_of_lw, Yes),
    lower_exp(Then, ThenValue),
    move_result(Result, ThenValue),
    jump(Join),

    set_via(set_cur_of_lw, No),
    (   { Else == none }
    ->  []
    ;   lower_exp(Else, ElseValue), move_result(Result, ElseValue)
    ),
    jump(Join),

    set_via(set_cur_of_lw, Join).

result_register(unit, none) --> !.
result_register(_, R) --> fresh_reg(R).

move_result(none, _) --> !, [].
move_result(_, none) --> !, [].
move_result(Result, Value) --> emit(move(Result, Value)).

lower_node(while_exp(Test, Body), _, none) -->
    fresh(test, TestBlock), fresh(body, BodyBlock), fresh(done, Done),
    jump(TestBlock),
    set_via(set_cur_of_lw, TestBlock),
    value_of(Test, C),
    branch(C, BodyBlock, Done),
    set_via(set_cur_of_lw, BodyBlock),
    push_break(Done),
    lower_exp(Body, _),
    pop_break,
    jump(TestBlock),
    set_via(set_cur_of_lw, Done).

%   `for i = lo to hi` counts up, and stops before overflowing at `hi`.
lower_node(for_exp(_, Lo, Hi, Body, Sym), _, none) -->
    value_of(Lo, L), value_of(Hi, HiValue),
    fresh_reg(H), emit(move(H, HiValue)),
    bind_var(Sym, L),
    fresh(forbody, BodyBlock), fresh(forstep, Step), fresh(fordone, Done),
    compare(<=, L, H, Enter),
    branch(Enter, BodyBlock, Done),

    set_via(set_cur_of_lw, BodyBlock),
    push_break(Done),
    lower_exp(Body, _),
    pop_break,
    read_var(Sym, I),
    compare(<, I, H, Again),
    branch(Again, Step, Done),

    set_via(set_cur_of_lw, Step),
    read_var(Sym, Current),
    constant(1, One),
    binop(+, Current, One, Bumped),
    write_var(Sym, Bumped),
    jump(BodyBlock),

    set_via(set_cur_of_lw, Done).

lower_node(break_exp, _, none) -->
    get_via(lw_breaks, [Target|_]), terminate(jmp(Target)).

lower_node(seq_exp(Items), _, R) --> seq(Items, none, R).

seq([], R, R) --> [].
seq([E|Es], _, R) --> lower_exp(E, V), seq(Es, V, R).

lower_node(let_exp(Decls, Body), _, R) --> lower_decls(Decls), lower_exp(Body, R).

push_break(Label) --> get_via(lw_breaks, Bs), set_via(set_breaks_of_lw, [Label|Bs]).
pop_break --> get_via(lw_breaks, [_|Bs]), set_via(set_breaks_of_lw, Bs).

%   -- run-time checks --------------------------------------------------------

check_not_nil(_) --> unchecked, !.
check_not_nil(Base) -->
    fresh(nil, Bad), fresh(ok, Ok),
    constant(0, Zero), compare(=, Base, Zero, Test),
    branch(Test, Bad, Ok),
    set_via(set_cur_of_lw, Bad),
    emit(call(none, "wol_nil_error", [])),
    jump(Ok),
    set_via(set_cur_of_lw, Ok).

unchecked --> get_via(lw_checks, false).

check_bounds(_, _) --> unchecked, !.
check_bounds(Base, Idx) -->
    fresh_reg(Length), emit(load(Length, Base, 0)),
    fresh(oob, Bad), fresh(ok, Ok),
    compare('u<', Idx, Length, Test),
    branch(Test, Ok, Bad),
    set_via(set_cur_of_lw, Bad),
    emit(call(none, "wol_bounds_error", [Idx, Length])),
    jump(Ok),
    set_via(set_cur_of_lw, Ok).

check_nonzero(_) --> unchecked, !.
check_nonzero(Rhs) -->
    fresh(divzero, Bad), fresh(ok, Ok),
    constant(0, Zero), compare(=, Rhs, Zero, Test),
    branch(Test, Bad, Ok),
    set_via(set_cur_of_lw, Bad),
    emit(call(none, "wol_div_error", [])),
    jump(Ok),
    set_via(set_cur_of_lw, Ok).
