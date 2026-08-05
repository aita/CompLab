/** <module> ARMv8 assembly, in AAPCS64.
 *
 *  The frame is the ordinary one.  `x29` points at the saved frame record, the
 *  slots an escaping variable or a spill lives in are below it, the
 *  callee-saved registers this function actually used are below those, and
 *  outgoing stack arguments sit at the bottom, at `sp`, where the callee
 *  expects them.
 *
 *      x29 -> | saved x29, x30 |
 *             | slot 0         |   x29 - 8      also where a static link points
 *             | slot 1         |   x29 - 16
 *             | ...            |
 *             | saved x19...   |
 *      sp  -> | outgoing args  |
 *
 *  A phi that reaches here is a copy on an edge, so the copies go at the end
 *  of the predecessor, all at once: the values are read before any is written,
 *  which is what copies:sequentialize arranges.  When the copies form a cycle
 *  it borrows a register the function never used, and when there is none it
 *  swaps the two ends with three `eor`s, so no register has to be reserved.
 *
 *  Emitting is a grammar whose terminals are lines, which is what a code
 *  generator is: a relation between a function and the assembly that says it.
 */

:- module(emit,
          [ emit_module/2,        % +Module, -Text
            escape/2,             % +Text, -Written
            borrow_nothing/1      % ?Flag
          ]).

:- use_module(library(assoc)).
:- use_module(library(lists)).
:- use_module(copies).
:- use_module(ir).
:- use_module(mach).
:- use_module(registers).

:- dynamic borrow_nothing/1.
borrow_nothing(false).

unscaled(ldr, ldur).
unscaled(str, stur).

%   The one register kept back.  A frame big enough to put a slot out of reach
%   of `ldur` is only discovered after allocation has added its spill slots, so
%   the address has to be computed somewhere the allocator does not know about.
spare(S) :- registers:scratch([S|_]).

%   Nothing of ours is live at the top of the prologue except the incoming
%   arguments, so a caller-saved register that is not one of them is free there.
prologue_temp(9).

%   -- the frame --------------------------------------------------------------

frame_of(F, frame(Slots, Saved, StackArgs, Size)) :-
    ir:func_nslots(F, Slots),
    ir:func_saved(F, Saved),
    registers:argument_regs(Args), length(Args, InRegisters),
    ir:walk(F, Blocks),
    findall(N,
            ( member(block(_, _, Instrs, _), Blocks),
              member(call(_, _, CallArgs), Instrs),
              length(CallArgs, Given), N is Given - InRegisters ),
            Counts),
    max_list([0|Counts], StackArgs),
    length(Saved, SavedCount),
    ir:word(W),
    Raw is W * (Slots + SavedCount + StackArgs),
    Size is (Raw + 15) /\ \(15).

saved_offset(frame(Slots, _, _, _), Index, Offset) :-
    ir:word(W), Offset is -(W * (Slots + Index + 1)).

%   -- emitting ---------------------------------------------------------------

emit_module(module(Funcs, Strings), Text) :-
    phrase(module_lines(Funcs, Strings), Lines),
    atomic_list_concat(Lines, '\n', Atom),
    format(string(Text), '~w\n', [Atom]).

module_lines(Funcs, Strings) -->
    ['\t.text'],
    functions(Funcs),
    (   { Strings == [] } -> []
    ;   ['\t.section .rodata'], literals(Strings)
    ),
    ['\t.section .note.GNU-stack,"",%progbits'].

functions([]) --> [].
functions([F|Fs]) --> function(F), [''], functions(Fs).

literals([]) --> [].
literals([Sym-Body|Rest]) -->
    { escape(Body, Written), string_length(Body, Length),
      format(atom(Label), '~w:', [Sym]),
      format(atom(Quad), '\t.quad ~d', [Length]),
      format(atom(Ascii), '\t.ascii "~w"', [Written]) },
    ['\t.p2align 3', Label, Quad, Ascii, '\t.byte 0'],
    literals(Rest).

function(F) -->
    { ir:func_label(F, Label), frame_of(F, Frame),
      format(atom(Globl), '\t.globl ~w', [Label]),
      format(atom(Type), '\t.type ~w, %function', [Label]),
      format(atom(Head), '~w:', [Label]),
      format(atom(Epilogue), '.Lepi_~w', [Label]),
      format(atom(EpilogueLabel), '~w:', [Epilogue]),
      format(atom(Size), '\t.size ~w, .-~w', [Label, Label]),
      ir:block_labels(F, Order) },
    [Globl, Type, Head],
    prologue(F, Frame),
    blocks(F, Frame, Epilogue, Order),
    [EpilogueLabel],
    restore(F, Frame),
    line('mov sp, x29'),
    line('ldp x29, x30, [sp], #16'),
    line('ret'),
    [Size].

line(Text) --> { format(atom(Line), '\t~w', [Text]) }, [Line].

%   Most lines are a format string and its arguments, so they say so.
line(Format, Args) --> { format(atom(Text), Format, Args) }, line(Text).

prologue(F, Frame) -->
    line('stp x29, x30, [sp, #-16]!'),
    line('mov x29, sp'),
    { Frame = frame(_, Saved, _, Size) },
    (   { Size =:= 0 } -> []
    ;   { Size =< 4095 }
    ->  line('sub sp, sp, #~d', [Size])
    ;   { prologue_temp(T) }, immediate(T, Size),
        line('sub sp, sp, x~d', [T])
    ),
    save_registers(Frame, Saved, 0),
    { ir:func_params(F, Params), registers:argument_regs(Args),
      registers_read(F, Read),
      param_copies(Params, Args, F, Read, Moves) },
    copies(F, Moves).

save_registers(_, [], _) --> [].
save_registers(Frame, [R|Rs], I) -->
    { saved_offset(Frame, I, Offset), J is I + 1 },
    access(str, R, 29, Offset),
    save_registers(Frame, Rs, J).

restore(_, Frame) --> { Frame = frame(_, Saved, _, _) }, restore_all(Frame, Saved, 0).

restore_all(_, [], _) --> [].
restore_all(Frame, [R|Rs], I) -->
    { saved_offset(Frame, I, Offset), J is I + 1 },
    access(ldr, R, 29, Offset),
    restore_all(Frame, Rs, J).

param_copies([], _, _, _, []).
param_copies(_, [], _, _, []).
param_copies([P|Ps], [C|Cs], F, Read, Moves) :-
    (   memberchk(P, Read)
    ->  colour_of(F, P, Colour), Moves = [Colour-C|Rest]
    ;   Moves = Rest
    ),
    param_copies(Ps, Cs, F, Read, Rest).

blocks(_, _, _, []) --> [].
blocks(F, Frame, Epilogue, [Label|Rest]) -->
    { ir:func_label(F, FuncLabel),
      format(atom(Head), '.L~w_~w:', [FuncLabel, Label]),
      ( Rest = [Next|_] -> true ; Next = none ),
      ir:get_block(F, Label, Block) },
    [Head],
    block_body(F, Frame, Epilogue, Block, Next),
    blocks(F, Frame, Epilogue, Rest).

block_body(F, Frame, Epilogue, block(Label, _, Instrs, _), Next) -->
    { once(append(Front, [Terminator], Instrs)) },
    instructions(F, Frame, Front),
    terminator(F, Epilogue, Label, Terminator, Next).

instructions(_, _, []) --> [].
instructions(F, Frame, [I|Is]) --> instruction(F, Frame, I), instructions(F, Frame, Is).

%   -- the terminators --------------------------------------------------------

terminator(F, _, Label, jmp(Target), Next) -->
    edge(F, Label, Target),
    go_to(F, Target, Next).

%   Falling through to the block the comparison was true for: the branch has to
%   say the opposite.
terminator(F, _, _, cbr(_, Then, Else, Code), Then) -->
    { Code \== '' }, !,
    { block_label(F, Else, ElseLabel), mach:opposite(Code, Opposite),
      format(atom(Branch), 'b.~w ~w', [Opposite, ElseLabel]) },
    line(Branch).
terminator(F, _, _, cbr(_, Then, Else, Code), Next) -->
    { Code \== '' }, !,
    { block_label(F, Then, ThenLabel),
      format(atom(Branch), 'b.~w ~w', [Code, ThenLabel]) },
    line(Branch),
    go_to(F, Else, Next).
terminator(F, _, _, cbr(Test, Then, Else, _), Then) --> !,
    { block_label(F, Else, ElseLabel), colour_of(F, Test, C),
      format(atom(Branch), 'cbz x~d, ~w', [C, ElseLabel]) },
    line(Branch).
terminator(F, _, _, cbr(Test, Then, Else, _), Next) -->
    { block_label(F, Then, ThenLabel), colour_of(F, Test, C),
      format(atom(Branch), 'cbnz x~d, ~w', [C, ThenLabel]) },
    line(Branch),
    go_to(F, Else, Next).
terminator(F, Epilogue, _, ret(Value), Next) -->
    return_value(F, Value),
    leave(Epilogue, Next).

block_label(F, Label, Written) :-
    ir:func_label(F, L), format(atom(Written), '.L~w_~w', [L, Label]).

%   A jump to the block that comes next is no jump at all.
go_to(_, Target, Target) --> !.
go_to(F, Target, _) -->
    { block_label(F, Target, Label), format(atom(B), 'b ~w', [Label]) },
    line(B).

return_value(_, none) --> !.
return_value(F, Value) -->
    { registers:argument_regs([First|_]), colour_of(F, Value, C) },
    mov(First, C).

%   The epilogue follows the last block, so the last `ret` needs no branch.
leave(_, none) --> !.
leave(Epilogue, _) --> line('b ~w', [Epilogue]).

%   The copies a phi stands for, made real on this edge.
edge(F, _, Target) --> { ir:get_block(F, Target, block(_, [], _, _)) }, !.
edge(F, Source, Target) -->
    { ir:get_block(F, Target, block(_, Phis, _, _)),
      findall(D-S,
              ( member(Phi, Phis), Phi = phi(Dst, _),
                colour_of(F, Dst, D),
                ir:phi_arg(Phi, Source, Arg), colour_of(F, Arg, S) ),
              Moves) },
    copies(F, Moves).

copies(F, Moves) -->
    { borrowed(F, Moves, Borrowed),
      copies:sequentialize(Moves, Borrowed, Steps) },
    steps(Steps).

steps([]) --> [].
steps([mov(D, S)|Rest]) --> mov(D, S), steps(Rest).
steps([swap(A, B)|Rest]) -->
    { format(atom(X), 'eor x~d, x~d, x~d', [A, A, B]),
      format(atom(Y), 'eor x~d, x~d, x~d', [B, A, B]),
      format(atom(Z), 'eor x~d, x~d, x~d', [A, A, B]) },
    line(X), line(Y), line(Z),
    steps(Rest).

%!  borrowed(+Func, +Moves, -Register) is det.
%
%   A register free to clobber here, if the function left one over.
%
%   A caller-saved register this function never gave to a value holds nothing
%   of ours anywhere, and one that this copy neither reads nor writes holds
%   nothing of the copy's either.  With no such register the copies swap
%   instead, which needs no scratch at all.

borrowed(_, _, none) :- borrow_nothing(true), !.
borrowed(F, Moves, Borrowed) :-
    ir:func_colours(F, Colours),
    assoc_to_values(Colours, Taken),
    findall(R, ( member(D-S, Moves), member(R, [D, S]) ), Touched),
    registers:caller_saved(Candidates),
    ( free_here(Candidates, Taken, Touched, R) -> Borrowed = R ; Borrowed = none ).

free_here(Candidates, Taken, Touched, R) :-
    member(R, Candidates),
    \+ memberchk(R, Taken),
    \+ memberchk(R, Touched).

%   -- one instruction --------------------------------------------------------

mov(D, D) --> !.
mov(D, S) --> line('mov x~d, x~d', [D, S]).

immediate(D, Value) -->
    { Word is Value /\ 0xFFFFFFFFFFFFFFFF },
    in_pieces(Word, D).

in_pieces(0, D) --> !, line('mov x~d, #0', [D]).
in_pieces(Word, D) --> { chunks(Word, 0, Chunks) }, movz_movk(Chunks, D, true).

chunks(_, 4, []) :- !.
chunks(Word, I, [I-Chunk|Rest]) :-
    Shift is I * 16,
    Chunk is (Word >> Shift) /\ 0xFFFF,
    J is I + 1,
    chunks(Word, J, Rest).

movz_movk([], _, _) --> [].
movz_movk([_-0|Rest], D, First) --> !, movz_movk(Rest, D, First).
movz_movk([I-Chunk|Rest], D, First) -->
    { ( First == true -> Op = movz ; Op = movk ),
      ( I =:= 0 -> format(atom(L), '~w x~d, #~d', [Op, D, Chunk])
      ; Shift is I * 16,
        format(atom(L), '~w x~d, #~d, lsl #~d', [Op, D, Chunk, Shift]) ) },
    line(L),
    movz_movk(Rest, D, false).

%!  access(+Op, +Reg, +Base, +Offset)// is det.
%
%   `ldr`/`str`, in whichever addressing mode reaches this far.

access(Op, Reg, Base, Offset) --> { base_name(Base, Where) }, mode(Op, Reg, Where, Offset).

base_name(31, sp) :- !.
base_name(Base, Where) :- format(atom(Where), 'x~d', [Base]).

%   Scaled, unscaled, and the one that has to compute the address, in the order
%   of how far each reaches.
mode(Op, Reg, Where, Offset) -->
    { ir:word(W), 0 =< Offset, Offset =< 32760, Offset mod W =:= 0 }, !,
    line('~w x~d, [~w, #~d]', [Op, Reg, Where, Offset]).
mode(Op, Reg, Where, Offset) -->
    { -256 =< Offset, Offset =< 255 }, !,
    { unscaled(Op, Unscaled),
      format(atom(L), '~w x~d, [~w, #~d]', [Unscaled, Reg, Where, Offset]) },
    line(L).
mode(Op, Reg, Where, Offset) -->
    { spare(Spare) },
    immediate(Spare, Offset),
    line('~w x~d, [~w, x~d]', [Op, Reg, Where, Spare]).

colour_of(F, R, Colour) :-
    ir:func_colours(F, Colours),
    ( get_assoc(R, Colours, Colour) -> true ; throw(error(never_coloured(R), _)) ).

instruction(F, _, move(D, S)) --> !,
    { colour_of(F, D, Dc), colour_of(F, S, Sc) }, mov(Dc, Sc).
instruction(F, _, load_slot(D, Slot)) --> !,
    { colour_of(F, D, Dc), ir:slot_offset(Slot, Offset) },
    access(ldr, Dc, 29, Offset).
instruction(F, _, store_slot(Slot, S)) --> !,
    { colour_of(F, S, Sc), ir:slot_offset(Slot, Offset) },
    access(str, Sc, 29, Offset).
instruction(F, _, frame_addr(D)) --> !,
    { colour_of(F, D, Dc) }, mov(Dc, 29).
instruction(F, _, call(D, Callee, Args)) --> !,
    { registers:argument_regs(Regs), length(Regs, N),
      split_args(Args, N, InRegisters, Rest) },
    stack_arguments(F, Rest, 0),
    { findall(C-V, ( nth0(I, InRegisters, A), nth0(I, Regs, C),
                     colour_of(F, A, V) ), Moves) },
    copies(F, Moves),
    line('bl ~w', [Callee]),
    (   { D == none }
    ->  []
    ;   { colour_of(F, D, Dc), Regs = [First|_] }, mov(Dc, First)
    ).
instruction(F, _, mach(Form, D, Srcs, Imm, Sym, _)) --> !,
    { maplist(colour_of(F), Srcs, Colours) },
    machine(F, Form, D, Colours, Imm, Sym).
instruction(_, _, I) --> { throw(error(cannot_emit(I), _)) }.

split_args(Args, N, First, Rest) :-
    length(Args, Total),
    (   Total =< N
    ->  First = Args, Rest = []
    ;   length(First, N), append(First, Rest, Args)
    ).

stack_arguments(_, [], _) --> [].
stack_arguments(F, [A|As], I) -->
    { colour_of(F, A, C), ir:word(W), Offset is W * I, J is I + 1 },
    access(str, C, 31, Offset),
    stack_arguments(F, As, J).

%   Write down one selected instruction, or the sequence it stands for.
machine(F, const, D, _, Imm, _) --> !, { colour_of(F, D, Dc) }, immediate(Dc, Imm).
machine(F, adr, D, _, _, Sym) --> !,
    { colour_of(F, D, Dc),
      format(atom(A), 'adrp x~d, ~w', [Dc, Sym]),
      format(atom(B), 'add x~d, x~d, :lo12:~w', [Dc, Dc, Sym]) },
    line(A), line(B).
machine(F, ldr, D, [Base|_], Imm, _) --> !,
    { colour_of(F, D, Dc) }, access(ldr, Dc, Base, Imm).
machine(_, str, _, [Base, Value|_], Imm, _) --> !, access(str, Value, Base, Imm).
machine(F, Form, D, Srcs, Imm, Sym) -->
    { mach:form(Form, Template, Operands),
      maplist(operand_text(F, D, Srcs, Imm, Sym), Operands, Args),
      format(atom(L), Template, Args) },
    line(L).

operand_text(F, D, _, _, _, d, Text) :- !, colour_of(F, D, C), format(atom(Text), 'x~d', [C]).
operand_text(_, _, Srcs, _, _, s0, Text) :- !, nth0(0, Srcs, C), format(atom(Text), 'x~d', [C]).
operand_text(_, _, Srcs, _, _, s1, Text) :- !, nth0(1, Srcs, C), format(atom(Text), 'x~d', [C]).
operand_text(_, _, Srcs, _, _, s2, Text) :- !, nth0(2, Srcs, C), format(atom(Text), 'x~d', [C]).
operand_text(_, _, _, Imm, _, imm, Imm) :- !.
operand_text(_, _, _, _, Sym, sym, Sym).

registers_read(F, Read) :-
    ir:walk(F, Blocks),
    findall(R,
            ( member(block(_, Phis, Instrs, _), Blocks),
              (   member(Phi, Phis), ir:phi_regs(Phi, Rs), member(R, Rs)
              ;   member(I, Instrs), ir:uses(I, Rs), member(R, Rs)
              ) ),
            Regs),
    sort(Regs, Read).

%!  escape(+Text, -Written) is det.
%
%   One character of a literal is one byte; write the ones `.ascii` cannot.

escape(Text, Written) :-
    string_codes(Text, Codes),
    maplist(escape_code, Codes, Parts),
    atomic_list_concat(Parts, Atom),
    atom_string(Atom, Written).

escape_code(0x22, '\\"') :- !.
escape_code(0x5C, '\\\\') :- !.
escape_code(C, Char) :- C >= 0x20, C =< 0x7E, !, char_code(Char, C).
escape_code(C, Octal) :-
    format(atom(Digits), '~8r', [C]),
    atom_length(Digits, N),
    Pad is 3 - N,
    (   Pad > 0
    ->  format(atom(Octal), '\\~*c~w', [Pad, 0'0, Digits])
    ;   format(atom(Octal), '\\~w', [Digits])
    ).
