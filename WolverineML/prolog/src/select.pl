/** <module> Instruction selection: cover the DAG with ARM instructions.
 *
 *  Every node that has to become a register of its own is tiled, largest tile
 *  first, pulling its foldable operands into the tile as it goes.  The tiles
 *  are the things ARM can do in one instruction that the IR needs several
 *  nodes to say:
 *
 *      a + b * c            madd
 *      a - b * c            msub
 *      a + (b << k)         add with a shifted operand
 *      a + 4095             add with an immediate
 *      a * 8                lsl
 *      [a + 24]             a load with the addition as its displacement
 *      a < b, then branch   cmp, and a branch on the flags
 *
 *  What comes out is still the same CFG, and still in SSA -- a tile defines
 *  one new register -- so liveness, the allocator and the verifier carry on as
 *  before.
 *
 *  Choosing a tile emits, so every choice here is committed with `->`: a tile
 *  that half applied and then backtracked would leave the instructions it had
 *  already written where they are.  Prolog would put them back -- the state is
 *  a term like any other -- but reading the pass would then require knowing
 *  that, so it says what it means instead.
 */

:- module(select,
          [ select_func/2,        % +Func, -Func
            select_module/2,      % +Module, -Module
            graphs/2              % +Func, -LabelDagPairs
          ]).

:- use_module(library(lists)).
:- use_module(library(record)).
:- use_module(library(ordsets)).
:- use_module(dag).
:- use_module(ir).
:- use_module(liveness).
:- use_module(mach).
:- use_module(state).

%   What selection carries: the graph it is covering, the instructions it has
%   written so far in reverse, and the two sets the plan decided.
:- record sel(dag, out:list=[], done:list=[], absorbed:list=[]).

immediate(4095).

logical(and, and).  logical(or, orr).  logical(xor, eor).
shift_form(shl, lsl).  shift_form(shr, asr).

select_module(module(Funcs0, Strings), module(Funcs, Strings)) :-
    maplist(select_func, Funcs0, Funcs).

select_func(F0, F) :-
    liveness:analyse(F0, Live),
    ir:walk(F0, Blocks),
    foldl(select_block(Live), Blocks, F0, F).

select_block(Live, block(Label, Phis, _, Preds), F0, F) :-
    ir:get_block(F0, Label, Block),
    liveness:live_out(Live, Label, Out),
    dag:build(Block, Out, Dag),
    run(Dag, Instrs),
    ir:put_block(F0, block(Label, Phis, Instrs, Preds), F).

%!  graphs(+Func, -Pairs) is det.
%
%   The DAGs a selection would work on, for `wolv emit -s dag`.

graphs(F, Pairs) :-
    liveness:analyse(F, Live),
    ir:walk(F, Blocks),
    findall(Label-Dag,
            ( member(Block, Blocks), Block = block(Label, _, _, _),
              liveness:live_out(Live, Label, Out),
              dag:build(Block, Out, Dag) ),
            Pairs).

run(Dag, Instrs) :-
    plan(Dag, Absorbed),
    dag:nodes(Dag, Nodes), length(Nodes, Count), Last is Count - 1,
    ( Count =:= 0 -> Indices = [] ; numlist(0, Last, Indices) ),
    make_sel([dag(Dag), absorbed(Absorbed)], Sel0),
    phrase(fold(tile_top, Indices), [Sel0], [Sel]),
    sel_out(Sel, Reversed),
    reverse(Reversed, Instrs).

%!  plan(+Dag, -Absorbed) is det.
%
%   Decide which nodes a tile is going to swallow, before emitting any.
%
%   Nothing may be deferred on the chance that its reader takes it.  A node
%   left out of the order and then not absorbed would be computed at its reader
%   instead, and a chain of those -- `a + b + c + ...`, where every term has
%   one reader -- would move the whole sum to its last line and keep every term
%   alive until then.

plan(Dag, Absorbed) :-
    dag:nodes(Dag, Nodes),
    findall(Index,
            ( member(N, Nodes),
              dag:alone(N),
              dag:node_reader(N, ReaderIndex), ReaderIndex \== none,
              dag:node_at(Dag, ReaderIndex, Reader),
              dag:node_index(N, Index),
              swallows(Dag, Reader, Index, N) ),
            Absorbed0),
    list_to_ord_set(Absorbed0, Absorbed).

%!  swallows(+Dag, +Reader, +Index, +Node) is semidet.
%
%   Whether the instruction chosen for Reader has room for Node.

swallows(Dag, Reader, Index, N) :-
    dag:node_instr(Reader, Instr),
    dag:node_operands(Reader, Operands),
    (   Instr = bin(_, Op, _, _), memberchk(Op, [+, -])
    ->  nth0(1, Operands, Index),
        ( as_shift(Dag, Index, _, _) -> true ; is_bin(N, *) )
    ;   ( Instr = load(_, _, Offset) ; Instr = store(_, Offset, _) )
    ->  nth0(0, Operands, Index),
        displaces(Dag, N, Offset, _)
    ).

is_bin(N, Op) :- dag:node_instr(N, bin(_, Op, _, _)).

%!  displaces(+Dag, +Node, +Offset, -Total) is semidet.
%
%   `[pointer + 24]`, when what is added to the pointer is a constant.

displaces(Dag, N, Offset, Total) :-
    is_bin(N, +),
    dag:node_operands(N, [_, Right]),
    dag:constant_at(Dag, Right, Value),
    Total is Offset + Value,
    ir:word(W),
    (   0 =< Total, Total =< 32760, Total mod W =:= 0
    ->  true
    ;   -256 =< Total, Total =< 255
    ).

%!  as_shift(+Dag, +Index, -Node, -Amount) is semidet.
%
%   A `x << k` that can be folded, however it was written: `* 8` says it too.
%   This decides nothing and emits nothing, so the plan and the tiles can both
%   ask it and get the same answer.

as_shift(Dag, Index, N, Amount) :-
    dag:node_at(Dag, Index, N),
    dag:alone(N),
    dag:node_instr(N, bin(_, Op, _, _)),
    dag:node_operands(N, [_, Right]),
    dag:constant_at(Dag, Right, Raw),
    (   Op == (*)
    ->  Raw > 0, Raw /\ (Raw - 1) =:= 0,
        Amount is msb(Raw)
    ;   Op == shl, Amount = Raw
    ),
    Amount >= 0, Amount < 64.

%   -- emitting ---------------------------------------------------------------

emit(I) --> get_via(sel_out, Out), set_via(set_out_of_sel, [I|Out]).

emit_mach(Form, Dst, Srcs) --> emit(mach(Form, Dst, Srcs, 0, '', false)).
emit_imm(Form, Dst, Srcs, Imm) --> emit(mach(Form, Dst, Srcs, Imm, '', false)).
emit_sym(Form, Dst, Sym) --> emit(mach(Form, Dst, [], 0, Sym, false)).

mark_done(Index) -->
    get_via(sel_done, Done), { ord_add_element(Done, Index, D) }, set_via(set_done_of_sel, D).

%   The node is looked up by index rather than taken from a list, because
%   fusing a comparison rewrites the branch below it and the walk has to see
%   the rewrite.
tile_top(Index) --> absorbed(Index), !.          % part of the tile that reads it
tile_top(Index) --> deferred_constant(Index), !. % computed where a register wants it
tile_top(Index) --> fuse_comparison(Index), !.
tile_top(Index) --> mark_done(Index), node_at(Index, N), tile(N, _).

absorbed(Index) -->
    get_via(sel_absorbed, Absorbed), { ord_memberchk(Index, Absorbed) }.

deferred_constant(Index) -->
    get_via(sel_dag, Dag), { dag:rematerialisable(Dag, Index) }.

done(Index) --> get_via(sel_done, Done), { ord_memberchk(Index, Done) }.

deferred(Index) --> absorbed(Index), !.
deferred(Index) --> deferred_constant(Index).

node_at(Index, N) --> get_via(sel_dag, Dag), { dag:node_at(Dag, Index, N) }.

%!  at(+Index, +Fallback, -Reg)// is det.
%
%   The register holding an operand, computing it here if it was deferred.
%
%   Only two kinds of node were left out of the order: a constant, which is
%   tiled the first time somebody needs it in a register and read from there
%   afterwards, and a node the plan said would be absorbed, which ends up here
%   only if the tile that was to absorb it changed its mind.

at(none, Fallback, Fallback) --> !.
at(Index, Fallback, Fallback) --> done(Index), !.
at(Index, _, R) --> deferred(Index), !, mark_done(Index), node_at(Index, N), tile(N, R).
at(_, Fallback, Fallback) --> [].

%   Compute a deferred operand for a reader that has no tile to take it.
force(none) --> !.
force(Index) -->
    node_at(Index, N),
    { ( dag:node_value(N, V) -> true ; V = 0 ) },
    at(Index, V, _).

%   -- one node ---------------------------------------------------------------

tile(N, R) -->
    { dag:node_instr(N, Instr) },
    tile_instr(Instr, N, R).

tile_instr(const(D, V), _, D) --> !, emit_imm(const, D, [], V).
tile_instr(str_const(D, Sym), _, D) --> !, emit_sym(adr, D, Sym).
tile_instr(bin(D, Op, L, Rhs), N, D) --> !, arithmetic(N, D, Op, L, Rhs).
tile_instr(cmp(D, Op, L, Rhs), N, D) --> !,
    compare_into(N, L, Rhs),
    { mach:condition(Op, Code) },
    emit_sym(cset, D, Code).
tile_instr(load(D, Base, Offset), N, D) --> !,
    { dag:node_operands(N, [Which|_]) },
    address(Which, Base, Offset, Pointer, Displacement),
    emit_imm(ldr, D, [Pointer], Displacement).
tile_instr(store(Base, Offset, Src), N, Src) --> !,
    { dag:node_operands(N, [Which, Value]) },
    at(Value, Src, Vr),
    address(Which, Base, Offset, Pointer, Displacement),
    emit(mach(str, none, [Pointer, Vr], Displacement, '', true)).
tile_instr(Instr, N, R) -->
    %   Moves, calls, slot accesses and the terminator are machine instructions
    %   already, and a phi is not in this list at all.  None of them folds
    %   anything, so every operand that was left to be folded has to be
    %   computed here instead.
    { dag:node_operands(N, Operands) },
    fold(force, Operands),
    emit(Instr),
    { ( ir:defs(Instr, D) -> R = D ; R = 0 ) }.

%   -- the tiles --------------------------------------------------------------

arithmetic(N, D, Op, L, Rhs) --> { memberchk(Op, [+, -]) }, !, additive(N, D, Op, L, Rhs).
arithmetic(N, D, *, L, Rhs) --> !, multiply(N, D, L, Rhs).
arithmetic(N, D, /, L, Rhs) --> !, both(N, L, Rhs, Srcs), emit_mach(sdiv, D, Srcs).
arithmetic(N, D, Op, L, Rhs) --> { shift_form(Op, _) }, !, shift(N, D, Op, L, Rhs).
arithmetic(N, D, Op, L, Rhs) --> { logical(Op, _) }, !, logical_op(N, D, Op, L, Rhs).
arithmetic(_, _, Op, _, _) --> { throw(error(no_instruction_for(Op), _)) }.

%   Both operands in registers, which is what the plain forms want.
both(N, L, Rhs, [Lr, Rr]) -->
    { dag:node_operands(N, [Left, Right]) },
    at(Left, L, Lr), at(Right, Rhs, Rr).

%!  additive(+Node, +Dst, +Op, +Lhs, +Rhs)// is det.
%
%   `add` and `sub`, in whichever of their four forms fits.  A shifted operand
%   comes first: `a + b * 8` is one instruction that way and two as a
%   multiply-add, because the 8 would need a register.

%   The clauses are in the order the forms are preferred, and each one tests
%   before it emits, so a form that does not fit leaves nothing behind.
additive(N, D, Op, L, _) --> shift_into(N, D, Op, L), !.
additive(N, D, Op, L, _) --> multiply_into(N, D, Op, L), !.
additive(N, D, Op, L, _) --> immediate_right(N, D, Op, L), !.
additive(N, D, +, _, Rhs) --> immediate_left(N, D, Rhs), !.
additive(N, D, Op, L, Rhs) -->
    both(N, L, Rhs, Srcs),
    { Op == (+) -> Form = add ; Form = sub },
    emit_mach(Form, D, Srcs).

immediate_right(N, D, Op, L) -->
    { dag:node_operands(N, [Left, Right]), immediate(Max) },
    get_via(sel_dag, Dag),
    { dag:constant_at(Dag, Right, V), 0 =< V, V =< Max,
      ( Op == (+) -> Form = addi ; Form = subi ) },
    at(Left, L, Lr),
    emit_imm(Form, D, [Lr], V).

%   Only addition may take its constant from the other side.
immediate_left(N, D, Rhs) -->
    { dag:node_operands(N, [Left, Right]), immediate(Max) },
    get_via(sel_dag, Dag),
    { dag:constant_at(Dag, Left, V), 0 =< V, V =< Max },
    at(Right, Rhs, Rr),
    emit_imm(addi, D, [Rr], V).

multiply(N, D, L, _) --> power_of_two(N, D, L), !.
multiply(N, D, L, Rhs) --> both(N, L, Rhs, Srcs), emit_mach(mul, D, Srcs).

power_of_two(N, D, L) -->
    { dag:node_operands(N, [Left, Right]) },
    get_via(sel_dag, Dag),
    { dag:constant_at(Dag, Right, V), V > 0, V /\ (V - 1) =:= 0, Amount is msb(V) },
    at(Left, L, Lr),
    emit_imm(lsli, D, [Lr], Amount).

shift(N, D, Op, L, _) --> shift_by_immediate(N, D, Op, L), !.
shift(N, D, Op, L, Rhs) -->
    { shift_form(Op, Form) }, both(N, L, Rhs, Srcs), emit_mach(Form, D, Srcs).

shift_by_immediate(N, D, Op, L) -->
    { dag:node_operands(N, [Left, Right]),
      shift_form(Op, Base), atom_concat(Base, i, Form) },
    get_via(sel_dag, Dag),
    { dag:constant_at(Dag, Right, V), 0 =< V, V < 64 },
    at(Left, L, Lr),
    emit_imm(Form, D, [Lr], V).

%   `xor` with one is how `not` arrives.
logical_op(N, D, xor, L, _) -->
    { dag:node_operands(N, [Left, Right]) },
    get_via(sel_dag, Dag),
    { dag:constant_at(Dag, Right, 1) },
    !,
    at(Left, L, Lr),
    emit_imm(eori, D, [Lr], 1).
logical_op(N, D, Op, L, Rhs) -->
    { logical(Op, Form) }, both(N, L, Rhs, Srcs), emit_mach(Form, D, Srcs).

%!  multiply_into(+Node, +Dst, +Op, +Lhs)// is semidet.
%
%   `a + b * c` and `a - b * c` are one instruction each.

multiply_into(N, D, Op, L) -->
    { dag:node_operands(N, [Left, Right]) },
    get_via(sel_dag, Dag),
    { dag:node_at(Dag, Right, Product),
      dag:alone(Product),
      is_bin(Product, *),
      dag:node_instr(Product, bin(_, _, PL, PR)),
      dag:node_operands(Product, [PLeft, PRight]) },
    at(PLeft, PL, A),
    at(PRight, PR, B),
    at(Left, L, C),
    { Op == (+) -> Form = madd ; Form = msub },
    emit_mach(Form, D, [A, B, C]).

%!  shift_into(+Node, +Dst, +Op, +Lhs)// is semidet.
%
%   The second operand of an `add` may be shifted on the way in.

shift_into(N, D, Op, L) -->
    { dag:node_operands(N, [Left, Right]) },
    get_via(sel_dag, Dag),
    { as_shift(Dag, Right, Shifted, Amount),
      dag:node_instr(Shifted, bin(_, _, SL, _)),
      dag:node_operands(Shifted, [SLeft, _]) },
    at(Left, L, A),
    at(SLeft, SL, B),
    { Op == (+) -> Form = adds ; Form = subs },
    emit_imm(Form, D, [A, B], Amount).

%!  address(+Index, +Base, +Offset, -Pointer, -Displacement)// is det.
%
%   A pointer and a displacement, taking in an addition if there is one.

address(Index, _, Offset, Pointer, Total) -->
    taken_in(Index, Offset, NLeft, NL, Total), !,
    at(NLeft, NL, Pointer).
address(Index, Base, Offset, Pointer, Offset) --> at(Index, Base, Pointer).

taken_in(Index, Offset, NLeft, NL, Total) -->
    { Index \== none },
    get_via(sel_dag, Dag),
    { dag:node_at(Dag, Index, N), dag:alone(N),
      displaces(Dag, N, Offset, Total),
      dag:node_instr(N, bin(_, _, NL, _)),
      dag:node_operands(N, [NLeft, _]) }.

%   -- comparisons and the branch that reads them -----------------------------

compare_into(N, L, _) --> compare_with_immediate(N, L), !.
compare_into(N, L, Rhs) --> both(N, L, Rhs, Srcs), emit_mach(cmp, none, Srcs).

compare_with_immediate(N, L) -->
    { dag:node_operands(N, [Left, Right]), immediate(Max) },
    get_via(sel_dag, Dag),
    { dag:constant_at(Dag, Right, V), 0 =< V, V =< Max },
    at(Left, L, Lr),
    emit_imm(cmpi, none, [Lr], V).

%!  fuse_comparison(+Index)// is semidet.
%
%   A comparison the branch below it is the only reader of sets the flags.
%   The branch is rewritten in place, so this is the one tile that reaches
%   forwards into the block it is covering.

fuse_comparison(Index) -->
    get_via(sel_dag, Dag),
    { dag:nodes(Dag, Nodes), length(Nodes, Count), Last is Count - 1,
      Index + 1 =:= Last,
      nth0(Index, Nodes, N),
      dag:node_instr(N, cmp(D, Op, L, Rhs)),
      dag:node_users(N, 1),
      dag:node_escapes(N, false),
      nth0(Last, Nodes, Terminator),
      dag:node_instr(Terminator, cbr(D, Then, Else, '')),
      mach:condition(Op, Code) },
    compare_into(N, L, Rhs),
    replace_terminator(Last, cbr(D, Then, Else, Code)).

%   The terminator is the last node, and it has not been tiled yet, so what
%   changes is the DAG the loop is still walking.
replace_terminator(Index, New) -->
    get_via(sel_dag, Dag),
    { dag:nodes(Dag, Nodes),
      nth0(Index, Nodes, node(I, _, Ops, U, R, E), Rest),
      nth0(Index, Updated, node(I, New, Ops, U, R, E), Rest) },
    set_via(set_dag_of_sel, dag(Updated)).
