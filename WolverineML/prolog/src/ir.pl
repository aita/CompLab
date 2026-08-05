/** <module> The three-address IR, and the control flow graph both IRs use.
 *
 *  There are two instruction sets in this compiler.  This module has the
 *  first: three-address code over virtual registers, which is what lowering
 *  produces, what `ssa` puts into SSA and what `opt` rewrites.  The second is
 *  in `mach`, and instruction selection replaces the arithmetic of this one
 *  with it.
 *
 *  An instruction is a term:
 *
 *      const(Dst, Value)          load_slot(Dst, Slot)    jmp(Target)
 *      str_const(Dst, Symbol)     store_slot(Slot, Src)   cbr(Test, Then, Else, Code)
 *      move(Dst, Src)             frame_addr(Dst)         ret(Value)
 *      bin(Dst, Op, Lhs, Rhs)     call(Dst, Callee, Args)
 *      cmp(Dst, Op, Lhs, Rhs)     phi(Dst, Args)
 *      load(Dst, Base, Offset)    mach(Form, Dst, Srcs, Imm, Symbol, Effect)
 *      store(Base, Offset, Src)
 *
 *  and the five questions every pass asks one -- defs/2, uses/2, map_uses/3,
 *  set_def/3, has_effect/1 -- are relations over those terms.  Two of them are
 *  worth reading as relations rather than as functions: defs/2 simply has no
 *  solution for an instruction that writes nothing, and map_uses/3 relates an
 *  instruction to another instruction rather than changing one, because
 *  nothing here is changed.
 *
 *  What the two instruction sets share is everything else -- the registers,
 *  the blocks, the graph, the frame -- so liveness, dominance, the allocator
 *  and the verifiers work on either without knowing what an `madd` is.
 *
 *  A function is a record: `library(record)` turns one declaration into the
 *  thirteen accessors and the thirteen setters, so `func_order/2` is a
 *  relation between a function and its block order and `set_order_of_func/3`
 *  is a relation between two functions.  A block is `block(Label, Phis,
 *  Instrs, Preds)` and lives in an assoc under its label.
 */

:- module(ir,
          [ word/1, argument_registers/1, slot_offset/2,
            defs/2, uses/2, map_uses/3, set_def/3, has_effect/1,
            terminator_instr/1, show_instr/3,
            phi_arg/3, set_phi_arg/4, rename_phi_pred/4, keep_phi_args/3,
            map_phi_args/3, phi_preds/2, phi_regs/2, phi_args_from/3,
            func_label/2, func_name/2, func_params/2, func_depth/2,
            func_entry/2, func_blocks/2, func_order/2, func_nregs/2,
            func_nslots/2, func_link_slot/2, func_colours/2,
            func_spill_slots/2, func_saved/2,
            set_params_of_func/3, set_order_of_func/3, set_nslots_of_func/3,
            set_link_slot_of_func/3, set_colours_of_func/3,
            set_spill_slots_of_func/3, set_saved_of_func/3,
            new_func/4, new_reg/3, new_slot/3, add_block/3,
            get_block/3, put_block/3, walk/2, block_labels/2,
            terminator/2, set_terminator/3, succs/2,
            rename_target/4, recompute_preds/2, reachable/2, drop_unreachable/2,
            rpo/2, reg_name/3, show_func/2, show_module/2,
            emit_into/3, append_instr/3, insert_before_terminator/3
          ]).

:- use_module(library(assoc)).
:- use_module(library(lists)).
:- use_module(library(pairs)).
:- use_module(library(record)).

%   One function: a frame, a set of parameters, and a graph of blocks.  The
%   empty assoc is the atom `t`, which is why the three maps can have a
%   default at all.

:- record func(label, name, params:list=[], depth:integer=0, entry=entry,
               blocks=t, order:list=[], nregs:integer=0, nslots:integer=0,
               link_slot:integer= -1, colours=t, spill_slots=t, saved:list=[]).

word(8).

%   How many arguments AAPCS64 passes in registers.  The rest go on the stack,
%   and the frame layout below knows where.
argument_registers(8).

%!  slot_offset(+Slot, -Offset) is det.
%
%   Where a frame slot sits, relative to the frame pointer.  Slot 0 of every
%   nested function holds its static link, so a frame chain can be walked
%   without knowing whose frame it is.  Negative slots are the arguments the
%   caller had to pass on the stack: they are already in the frame, above the
%   saved frame record, so nothing has to be copied for them and they never
%   take a register at entry.

slot_offset(Slot, Offset) :-
    word(W),
    (   Slot < 0
    ->  Offset is 16 + W * (-Slot - 1)
    ;   Offset is -(W * (Slot + 1))
    ).

%   -- the five questions -----------------------------------------------------

%!  defs(+Instr, -Reg) is semidet.
%
%   The register it writes.  No solution when it writes none, which is what
%   `is None` is in the other ports.

defs(const(D, _), D).
defs(str_const(D, _), D).
defs(move(D, _), D).
defs(bin(D, _, _, _), D).
defs(cmp(D, _, _, _), D).
defs(load(D, _, _), D).
defs(load_slot(D, _), D).
defs(frame_addr(D), D).
defs(call(D, _, _), D) :- D \== none.
defs(phi(D, _), D).
defs(mach(_, D, _, _, _, _), D) :- D \== none.

%!  uses(+Instr, -Regs) is det.
%
%   The registers it reads.  A phi's arguments are read on the edges, not
%   here, so they are not among them.

uses(const(_, _), []).
uses(str_const(_, _), []).
uses(move(_, S), [S]).
uses(bin(_, _, L, R), [L, R]).
uses(cmp(_, _, L, R), [L, R]).
uses(load(_, B, _), [B]).
uses(store(B, _, S), [B, S]).
uses(load_slot(_, _), []).
uses(store_slot(_, S), [S]).
uses(frame_addr(_), []).
uses(call(_, _, Args), Args).
uses(phi(_, _), []).
uses(jmp(_), []).
%   After selection a branch may read the flags a comparison just set instead
%   of testing a register, and then it reads no register at all.
uses(cbr(T, _, _, Code), Regs) :- ( Code == '' -> Regs = [T] ; Regs = [] ).
uses(ret(V), Regs) :- ( V == none -> Regs = [] ; Regs = [V] ).
uses(mach(_, _, Srcs, _, _, _), Srcs).

%!  map_uses(+Instr, :Goal, -Rewritten) is det.
%
%   The instruction with every register it reads replaced by what Goal makes
%   of it, in the order they are numbered.

:- meta_predicate map_uses(+, 2, -).

map_uses(const(D, V), _, const(D, V)).
map_uses(str_const(D, S), _, str_const(D, S)).
map_uses(move(D, S0), G, move(D, S)) :- call(G, S0, S).
map_uses(bin(D, Op, L0, R0), G, bin(D, Op, L, R)) :- call(G, L0, L), call(G, R0, R).
map_uses(cmp(D, Op, L0, R0), G, cmp(D, Op, L, R)) :- call(G, L0, L), call(G, R0, R).
map_uses(load(D, B0, O), G, load(D, B, O)) :- call(G, B0, B).
map_uses(store(B0, O, S0), G, store(B, O, S)) :- call(G, B0, B), call(G, S0, S).
map_uses(load_slot(D, S), _, load_slot(D, S)).
map_uses(store_slot(Sl, S0), G, store_slot(Sl, S)) :- call(G, S0, S).
map_uses(frame_addr(D), _, frame_addr(D)).
map_uses(call(D, C, A0), G, call(D, C, A)) :- maplist(G, A0, A).
map_uses(phi(D, A), _, phi(D, A)).
map_uses(jmp(T), _, jmp(T)).
map_uses(cbr(T0, Th, El, Code), G, cbr(T, Th, El, Code)) :-
    ( Code == '' -> call(G, T0, T) ; T = T0 ).
map_uses(ret(V0), G, ret(V)) :- ( V0 == none -> V = none ; call(G, V0, V) ).
map_uses(mach(F, D, S0, I, Y, E), G, mach(F, D, S, I, Y, E)) :- maplist(G, S0, S).

%!  set_def(+Instr, +Reg, -Rewritten) is det.

set_def(const(_, V), D, const(D, V)).
set_def(str_const(_, S), D, str_const(D, S)).
set_def(move(_, S), D, move(D, S)).
set_def(bin(_, Op, L, R), D, bin(D, Op, L, R)).
set_def(cmp(_, Op, L, R), D, cmp(D, Op, L, R)).
set_def(load(_, B, O), D, load(D, B, O)).
set_def(load_slot(_, S), D, load_slot(D, S)).
set_def(frame_addr(_), D, frame_addr(D)).
set_def(call(_, C, A), D, call(D, C, A)).
set_def(phi(_, A), D, phi(D, A)).
set_def(mach(F, _, S, I, Y, E), D, mach(F, D, S, I, Y, E)).

%!  has_effect(+Instr) is semidet.
%
%   True when it has to be kept even if its result is dead.

has_effect(store(_, _, _)).
has_effect(store_slot(_, _)).
has_effect(call(_, _, _)).
has_effect(jmp(_)).
has_effect(cbr(_, _, _, _)).
has_effect(ret(_)).
has_effect(mach(_, _, _, _, _, true)).

terminator_instr(jmp(_)).
terminator_instr(cbr(_, _, _, _)).
terminator_instr(ret(_)).

%   -- printing one instruction -----------------------------------------------

:- meta_predicate show_instr(+, 2, -).

show_instr(I, Namer, Text) :- shown(I, Namer, Text).

:- meta_predicate shown(+, 2, -).

shown(const(D, V), N, T) :- reg(N, D, Dt), format(string(T), '~w = ~d', [Dt, V]).
shown(str_const(D, S), N, T) :- reg(N, D, Dt), format(string(T), '~w = &~w', [Dt, S]).
shown(move(D, S), N, T) :-
    reg(N, D, Dt), reg(N, S, St), format(string(T), '~w = ~w', [Dt, St]).
shown(bin(D, Op, L, R), N, T) :-
    reg(N, D, Dt), reg(N, L, Lt), reg(N, R, Rt),
    format(string(T), '~w = ~w ~w ~w', [Dt, Lt, Op, Rt]).
shown(cmp(D, Op, L, R), N, T) :-
    reg(N, D, Dt), reg(N, L, Lt), reg(N, R, Rt),
    format(string(T), '~w = ~w ~w ~w', [Dt, Lt, Op, Rt]).
shown(load(D, B, O), N, T) :-
    reg(N, D, Dt), reg(N, B, Bt), format(string(T), '~w = [~w + ~d]', [Dt, Bt, O]).
shown(store(B, O, S), N, T) :-
    reg(N, B, Bt), reg(N, S, St), format(string(T), '[~w + ~d] = ~w', [Bt, O, St]).
shown(load_slot(D, S), N, T) :-
    reg(N, D, Dt), format(string(T), '~w = slot~d', [Dt, S]).
shown(store_slot(Sl, S), N, T) :-
    reg(N, S, St), format(string(T), 'slot~d = ~w', [Sl, St]).
shown(frame_addr(D), N, T) :- reg(N, D, Dt), format(string(T), '~w = frame', [Dt]).
shown(call(D, C, Args), N, T) :-
    maplist(reg(N), Args, Texts),
    atomic_list_concat(Texts, ', ', Written),
    (   D == none
    ->  format(string(T), '~w(~w)', [C, Written])
    ;   reg(N, D, Dt), format(string(T), '~w = ~w(~w)', [Dt, C, Written])
    ).
shown(phi(D, Args), N, T) :-
    findall(Part, ( member(P-R, Args), reg(N, R, Rt),
                    format(atom(Part), '~w: ~w', [P, Rt]) ), Parts),
    atomic_list_concat(Parts, ', ', Written),
    reg(N, D, Dt),
    format(string(T), '~w = phi [~w]', [Dt, Written]).
shown(jmp(Target), _, T) :- format(string(T), 'jmp ~w', [Target]).
shown(cbr(Test, Then, Else, Code), N, T) :-
    (   Code == ''
    ->  reg(N, Test, Tt), format(atom(Written), '~w ?', [Tt])
    ;   format(atom(Written), '~w?', [Code])
    ),
    format(string(T), 'br ~w ~w : ~w', [Written, Then, Else]).
shown(ret(V), N, T) :-
    ( V == none -> T = "ret" ; reg(N, V, Vt), format(string(T), 'ret ~w', [Vt]) ).
shown(mach(Form, D, Srcs, Imm, Sym, _), N, T) :-
    maplist(reg(N), Srcs, Texts),
    (   Sym \== ''
    ->  append(Texts, [Sym], Operands)
    ;   ( Imm =\= 0 ; Form == const )
    ->  format(atom(ImmText), '#~d', [Imm]), append(Texts, [ImmText], Operands)
    ;   Operands = Texts
    ),
    atomic_list_concat(Operands, ', ', Written),
    %   `form ` with nothing after it loses the space, which is what the
    %   Python tree's `rstrip` is doing.
    ( Operands == [] -> Line = Form ; format(atom(Line), '~w ~w', [Form, Written]) ),
    (   D == none
    ->  atom_string(Line, T)
    ;   reg(N, D, Dt), format(string(T), '~w = ~w', [Dt, Line])
    ).

:- meta_predicate reg(2, +, -).
reg(Namer, R, Text) :- call(Namer, R, Text).

%   -- a phi's arguments, which are an ordered list of edges -------------------

phi_args_from(Preds, Reg, Args) :- findall(P-Reg, member(P, Preds), Args).

phi_arg(phi(_, Args), Pred, Reg) :- memberchk(Pred-Reg, Args).

set_phi_arg(phi(D, Args0), Pred, Reg, phi(D, Args)) :-
    (   selectchk(Pred-_, Args0, Pred-Reg, Args)
    ->  true
    ;   append(Args0, [Pred-Reg], Args)
    ).

%!  rename_phi_pred(+Phi, +Old, +New, -Renamed) is det.
%
%   Take Old out and put New on the end, which is where a split edge belongs.

rename_phi_pred(phi(D, Args0), Old, New, phi(D, Args)) :-
    (   selectchk(Old-Reg, Args0, Rest)
    ->  append(Rest, [New-Reg], Args)
    ;   Args = Args0
    ).

keep_phi_args(phi(D, Args0), Keep, phi(D, Args)) :-
    include(pred_kept(Keep), Args0, Args).

pred_kept(Keep, Pred-_) :- memberchk(Pred, Keep).

:- meta_predicate map_phi_args(+, 2, -), map_one_arg(2, +, -).
map_phi_args(phi(D, Args0), Goal, phi(D, Args)) :-
    maplist(map_one_arg(Goal), Args0, Args).

map_one_arg(Goal, Pred-R0, Pred-R) :- call(Goal, R0, R).

phi_preds(phi(_, Args), Preds) :- pairs_keys(Args, Preds).
phi_regs(phi(_, Args), Regs) :- pairs_values(Args, Regs).

%   -- the graph --------------------------------------------------------------

new_func(Label, Name, Depth, Func) :-
    make_func([label(Label), name(Name), depth(Depth)], Func).

new_reg(F0, R, F) :-
    func_nregs(F0, R), N is R + 1, set_nregs_of_func(N, F0, F).

new_slot(F0, S, F) :-
    func_nslots(F0, S), N is S + 1, set_nslots_of_func(N, F0, F).

add_block(F0, Label, F) :-
    func_blocks(F0, B0), func_order(F0, Order),
    put_assoc(Label, B0, block(Label, [], [], []), B),
    append(Order, [Label], Order1),
    set_blocks_of_func(B, F0, F1),
    set_order_of_func(Order1, F1, F).

get_block(F, Label, Block) :- func_blocks(F, B), get_assoc(Label, B, Block).

put_block(F0, block(Label, Phis, Instrs, Preds), F) :-
    func_blocks(F0, B0),
    put_assoc(Label, B0, block(Label, Phis, Instrs, Preds), B),
    set_blocks_of_func(B, F0, F).

block_labels(F, Order) :- func_order(F, Order).

walk(F, Blocks) :- func_order(F, Order), maplist(get_block(F), Order, Blocks).

terminator(block(Label, _, Instrs, _), T) :-
    (   last(Instrs, Last)
    ->  (   terminator_instr(Last)
        ->  T = Last
        ;   throw(error(domain_error(terminator, Last), Label))
        )
    ;   throw(error(domain_error(terminated_block, Label), _))
    ).

set_terminator(block(L, P, Instrs0, Preds), T, block(L, P, Instrs, Preds)) :-
    append(Front, [_], Instrs0), !,
    append(Front, [T], Instrs).

succs(Block, Succs) :-
    terminator(Block, T),
    (   T = jmp(Target) -> Succs = [Target]
    ;   T = cbr(_, Then, Else, _)
    ->  ( Then == Else -> Succs = [Then] ; Succs = [Then, Else] )
    ;   Succs = []
    ).

append_instr(block(L, P, Instrs0, Preds), I, block(L, P, Instrs, Preds)) :-
    append(Instrs0, [I], Instrs).

insert_before_terminator(block(L, P, Instrs0, Preds), New,
                         block(L, P, Instrs, Preds)) :-
    append(Front, [Last], Instrs0), !,
    append(Front, New, Middle),
    append(Middle, [Last], Instrs).

%!  emit_into(+Func, +Block, -Func) is det.
%
%   Put a block back into the function it came from.

emit_into(F0, Block, F) :- put_block(F0, Block, F).

rename_target(jmp(Old), Old, New, jmp(New)) :- !.
rename_target(cbr(T, Then0, Else0, Code), Old, New, cbr(T, Then, Else, Code)) :- !,
    ( Then0 == Old -> Then = New ; Then = Then0 ),
    ( Else0 == Old -> Else = New ; Else = Else0 ).
rename_target(I, _, _, I).

recompute_preds(F0, F) :-
    walk(F0, Blocks),
    findall(Succ-Label,
            ( member(B, Blocks), B = block(Label, _, _, _),
              succs(B, Succs), member(Succ, Succs) ),
            Edges),
    foldl(clear_preds, Blocks, F0, F1),
    foldl(add_pred, Edges, F1, F).

clear_preds(block(L, P, I, _), F0, F) :- put_block(F0, block(L, P, I, []), F).

add_pred(Succ-Label, F0, F) :-
    get_block(F0, Succ, block(L, P, I, Preds0)),
    append(Preds0, [Label], Preds),
    put_block(F0, block(L, P, I, Preds), F).

reachable(F, Labels) :-
    func_entry(F, Entry),
    reach([Entry], F, [], Labels).

reach([], _, Seen, Seen).
reach([L|Ls], F, Seen0, Seen) :-
    (   memberchk(L, Seen0)
    ->  reach(Ls, F, Seen0, Seen)
    ;   get_block(F, L, B), succs(B, Succs),
        append(Succs, Ls, Rest),
        reach(Rest, F, [L|Seen0], Seen)
    ).

drop_unreachable(F0, F) :-
    reachable(F0, Live),
    func_order(F0, Order0),
    include(among(Live), Order0, Order),
    empty_assoc(Empty),
    foldl(keep_block(F0, Live), Order, Empty, Blocks),
    set_blocks_of_func(Blocks, F0, F1),
    set_order_of_func(Order, F1, F2),
    recompute_preds(F2, F).

among(Set, X) :- memberchk(X, Set).

kept_args(Live, Phi0, Phi) :- keep_phi_args(Phi0, Live, Phi).

keep_block(F0, Live, Label, B0, B) :-
    get_block(F0, Label, block(L, Phis0, Instrs, Preds)),
    maplist(kept_args(Live), Phis0, Phis),
    put_assoc(Label, B0, block(L, Phis, Instrs, Preds), B).

%!  rpo(+Func, -Order) is det.
%
%   Reverse post-order, which is the order every dataflow pass walks in.

rpo(F, Order) :-
    func_entry(F, Entry),
    rpo_walk([Entry-false], F, [], [], Order).

rpo_walk([], _, _, Order, Order).
rpo_walk([Label-true|Stack], F, Seen, Order0, Order) :- !,
    rpo_walk(Stack, F, Seen, [Label|Order0], Order).
rpo_walk([Label-false|Stack], F, Seen, Order0, Order) :-
    (   memberchk(Label, Seen)
    ->  rpo_walk(Stack, F, Seen, Order0, Order)
    ;   get_block(F, Label, B), succs(B, Succs),
        exclude(among([Label|Seen]), Succs, Fresh),
        findall(S-false, member(S, Fresh), Pushes),
        append(Pushes, [Label-true|Stack], Next),
        rpo_walk(Next, F, [Label|Seen], Order0, Order)
    ).

%   -- printing ---------------------------------------------------------------

reg_name(F, R, Text) :-
    func_colours(F, Colours),
    (   get_assoc(R, Colours, Colour)
    ->  format(string(Text), '%~d:~d', [R, Colour])
    ;   format(string(Text), '%~d', [R])
    ).

show_func(F, Text) :-
    func_label(F, Label), func_params(F, Params),
    func_depth(F, Depth), func_nslots(F, Slots),
    maplist(reg_name(F), Params, ParamTexts),
    atomic_list_concat(ParamTexts, ', ', Written),
    format(atom(Head), 'fun ~w(~w)  ; depth ~d, ~d slots',
           [Label, Written, Depth, Slots]),
    walk(F, Blocks),
    foldl(block_lines(F), Blocks, [Head], Reversed),
    reverse(Reversed, Lines),
    atomic_list_concat(Lines, '\n', Atom),
    atom_string(Atom, Text).

block_lines(F, block(Label, Phis, Instrs, Preds), Acc0, Acc) :-
    (   Preds == []
    ->  format(atom(Head), '~w:', [Label])
    ;   atomic_list_concat(Preds, ', ', Written),
        format(atom(Head), '~w:  ; preds: ~w', [Label, Written])
    ),
    append(Phis, Instrs, All),
    foldl(instr_line(F), All, [Head|Acc0], Acc).

instr_line(F, I, Acc, [Line|Acc]) :-
    show_instr(I, reg_name(F), Text),
    format(atom(Line), '    ~w', [Text]).

show_module(module(Funcs, Strings), Text) :-
    maplist(show_func, Funcs, Parts0),
    (   Strings == []
    ->  Parts = Parts0
    ;   findall(Line, ( member(Sym-Body, Strings),
                        format(atom(Line), '~w: "~w"', [Sym, Body]) ), Lines),
        atomic_list_concat(Lines, '\n', Block),
        append(Parts0, [Block], Parts)
    ),
    atomic_list_concat(Parts, '\n\n', Atom),
    format(string(Text), '~w\n', [Atom]).
