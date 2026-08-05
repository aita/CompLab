/** <module> The data-flow DAG of one basic block.
 *
 *  Instruction selection wants to see a block as expressions, not as a list:
 *  `a + (i << 3)` is one ARM instruction and `a + b*c` is another, and neither
 *  is visible while the operands are separate lines with names in between.  So
 *  each block is read into a graph -- a node per instruction, an edge per
 *  operand -- and the selector covers that graph with instructions.
 *
 *  It is a graph and not a tree because a value can be read twice.  That is
 *  what `Users` counts, and it is what decides whether a node may be folded
 *  into the instruction that reads it or has to become an instruction of its
 *  own: a node read twice would otherwise be computed twice.  A value that
 *  leaves the block counts as read as well, and so does one a phi in a
 *  successor names.
 *
 *  Only pure nodes are ever folded, and only into a reader whose instruction
 *  really absorbs them.  Both halves matter.  Folding moves a computation to
 *  where it is read, which is fine for arithmetic and not fine for a load,
 *  because a store in between would change what it reads; and folding a chain
 *  of nodes that nothing absorbs would move a whole expression to its last
 *  line, leaving every value it read alive until then.  So the selector plans
 *  first, and everything else is computed where it was written.
 *
 *  A node is `node(Index, Instr, Operands, Users, Reader, Escapes)`, where an
 *  operand is a node index or `none` for a value from outside the block, and
 *  Reader is the only node that reads it when there is exactly one.
 */

:- module(dag,
          [ build/3,              % +Block, +LiveOut, -Dag
            nodes/2,              % +Dag, -Nodes
            node_at/3,            % +Dag, +Index, -Node
            node_index/2, node_instr/2, node_operands/2, node_users/2,
            node_reader/2, node_escapes/2, node_value/2,
            alone/1,              % +Node   (semidet)
            rematerialisable/2,   % +Dag, +Index   (semidet)
            constant_at/3,        % +Dag, +Index, -Value
            show/2                % +Dag, -Text
          ]).

:- use_module(library(assoc)).
:- use_module(library(lists)).
:- use_module(library(ordsets)).
:- use_module(ir).

nodes(dag(Nodes), Nodes).

node_index(node(I, _, _, _, _, _), I).
node_instr(node(_, I, _, _, _, _), I).
node_operands(node(_, _, O, _, _, _), O).
node_users(node(_, _, _, U, _, _), U).
node_reader(node(_, _, _, _, R, _), R).
node_escapes(node(_, _, _, _, _, E), E).

node_value(Node, V) :- node_instr(Node, I), ir:defs(I, V).

node_at(dag(Nodes), Index, Node) :- integer(Index), nth0(Index, Nodes, Node).

%!  alone(+Node) is semidet.
%
%   Read exactly once, inside the block, and computable where read.

alone(node(_, Instr, _, 1, _, false)) :- Instr = bin(_, _, _, _).

%!  rematerialisable(+Dag, +Index) is semidet.
%
%   A constant, which costs nothing to repeat and is often not an instruction
%   at all once it has become an immediate operand.

rematerialisable(Dag, Index) :-
    node_at(Dag, Index, node(_, const(_, _), _, _, _, false)).

%!  constant_at(+Dag, +Index, -Value) is semidet.
%
%   The value at Index, if it is a constant -- however many read it.  Even one
%   that has to exist in a register for somebody else can be an immediate here,
%   so this asks less than folding does.

constant_at(Dag, Index, Value) :-
    node_at(Dag, Index, node(_, const(_, Value), _, _, _, _)).

%!  build(+Block, +LiveOut, -Dag) is det.
%
%   Read a block into a graph.  LiveOut includes what the phis will read.

build(block(_, _, Instrs, _), LiveOut, dag(Nodes)) :-
    empty_assoc(E),
    numbered(Instrs, 0, E, Bare),
    findall(Operand-Reader,
            ( member(bare(Reader, _, Operands), Bare), member(Operand, Operands),
              Operand \== none ),
            Edges),
    maplist(finish_node(Edges, LiveOut), Bare, Nodes).

numbered([], _, _, []).
numbered([I|Is], Index, ByValue0, [bare(Index, I, Operands)|Rest]) :-
    ir:uses(I, Regs),
    maplist(operand_of(ByValue0), Regs, Operands),
    (   ir:defs(I, D)
    ->  put_assoc(D, ByValue0, Index, ByValue)
    ;   ByValue = ByValue0
    ),
    Next is Index + 1,
    numbered(Is, Next, ByValue, Rest).

operand_of(ByValue, R, Operand) :-
    ( get_assoc(R, ByValue, Index) -> Operand = Index ; Operand = none ).

finish_node(Edges, LiveOut, bare(Index, Instr, Operands),
            node(Index, Instr, Operands, Users, Reader, Escapes)) :-
    findall(R, member(Index-R, Edges), Readers),
    length(Readers, Users),
    ( Readers = [Only] -> Reader = Only ; Reader = none ),
    (   ir:defs(Instr, V), ord_memberchk(V, LiveOut)
    ->  Escapes = true
    ;   Escapes = false
    ).

show(dag(Nodes), Text) :-
    maplist(node_line, Nodes, Lines),
    atomic_list_concat(Lines, '\n', Atom),
    atom_string(Atom, Text).

node_line(node(Index, Instr, Operands, Users, _, Escapes), Line) :-
    findall(T, ( member(O, Operands),
                 ( O == none -> T = '-' ; T = O ) ), Reads),
    atomic_list_concat(Reads, ', ', ReadText),
    ( Escapes == true -> Star = '*' ; Star = '' ),
    ( ir:has_effect(Instr) -> Bang = '!' ; Bang = '' ),
    atomic_list_concat([Star, Bang], Marks),
    ir:show_instr(Instr, dag:plain, Shown),
    pad_left(Index, 3, Number),
    pad_right(Marks, 2, MarkText),
    pad_right(Shown, 38, ShownText),
    format(atom(Line), '  ~w~w ~w reads [~w]  users ~d',
           [Number, MarkText, ShownText, ReadText, Users]).

plain(R, Text) :- format(string(Text), '%~d', [R]).

pad_left(Value, Width, Out) :-
    format(atom(Text), '~w', [Value]),
    atom_length(Text, N),
    ( N >= Width -> Out = Text
    ; Fill is Width - N, format(atom(Out), '~*c~w', [Fill, 0' , Text]) ).

pad_right(Value, Width, Out) :-
    format(atom(Text), '~w', [Value]),
    atom_length(Text, N),
    ( N >= Width -> Out = Text
    ; Fill is Width - N, format(atom(Out), '~w~*c', [Text, Fill, 0' ]) ).
