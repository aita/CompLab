/** <module> The machine IR: what instruction selection replaces the arithmetic with.
 *
 *  One term, because on this machine an instruction is a form, a register it
 *  writes and some it reads: `mach(Form, Dst, Srcs, Imm, Symbol, Effect)`, and
 *  ir.pl answers the five questions about it like any other.  The form names
 *  an entry in the table below, and the table is the whole instruction set the
 *  compiler can choose from.
 *
 *  The machine IR is that plus the part of `ir` that was already machine-level:
 *  a call, a move, a frame slot, a phi and the three terminators.  What it may
 *  no longer contain is the arithmetic -- const, bin, cmp, load, store,
 *  str_const -- and verify/1 is what says so, because a compiler that quietly
 *  kept an abstract instruction until the emitter would only find out there.
 *
 *  Four forms are not one instruction each, and the emitter expands them:
 *
 *      const   a constant, which is a `mov` or up to four `movz`/`movk`
 *      adr     the address of a string, which is `adrp` and an `add`
 *      ldr     a load, whose addressing mode depends on how far the offset reaches
 *      str     a store, likewise
 */

:- module(mach,
          [ form/3,               % ?Form, -Template, -Operands
            condition/2,          % ?Comparison, ?Code
            opposite/2,           % ?Code, ?Opposite
            expanded/1,           % ?Form
            known_form/1,         % +Form   (semidet)
            verify/1, verify_module/1
          ]).

:- use_module(ir).

%   How each form is written down, once the registers have their colours.  The
%   operand names say what the emitter has to supply: `d` is the register
%   written and `s0`, `s1`, `s2` the ones read.
form(add,  'add ~w, ~w, ~w',           [d, s0, s1]).
form(addi, 'add ~w, ~w, #~d',          [d, s0, imm]).
form(adds, 'add ~w, ~w, ~w, lsl #~d',  [d, s0, s1, imm]).
form(sub,  'sub ~w, ~w, ~w',           [d, s0, s1]).
form(subi, 'sub ~w, ~w, #~d',          [d, s0, imm]).
form(subs, 'sub ~w, ~w, ~w, lsl #~d',  [d, s0, s1, imm]).
form(mul,  'mul ~w, ~w, ~w',           [d, s0, s1]).
form(madd, 'madd ~w, ~w, ~w, ~w',      [d, s0, s1, s2]).
form(msub, 'msub ~w, ~w, ~w, ~w',      [d, s0, s1, s2]).
form(sdiv, 'sdiv ~w, ~w, ~w',          [d, s0, s1]).
form(and,  'and ~w, ~w, ~w',           [d, s0, s1]).
form(orr,  'orr ~w, ~w, ~w',           [d, s0, s1]).
form(eor,  'eor ~w, ~w, ~w',           [d, s0, s1]).
form(eori, 'eor ~w, ~w, #~d',          [d, s0, imm]).
form(lsl,  'lsl ~w, ~w, ~w',           [d, s0, s1]).
form(lsli, 'lsl ~w, ~w, #~d',          [d, s0, imm]).
form(asr,  'asr ~w, ~w, ~w',           [d, s0, s1]).
form(asri, 'asr ~w, ~w, #~d',          [d, s0, imm]).
form(cmp,  'cmp ~w, ~w',               [s0, s1]).
form(cmpi, 'cmp ~w, #~d',              [s0, imm]).
form(cset, 'cset ~w, ~w',              [d, sym]).

known_form(F) :- form(F, _, _), !.

%   Which condition code each comparison sets, and which one says the opposite
%   -- the emitter needs the opposite when the branch it is writing falls
%   through to the block the comparison was true for.
condition(=, eq).      condition(<>, ne).
condition(<, lt).      condition(<=, le).
condition(>, gt).      condition(>=, ge).
condition('u<', lo).   condition('u>=', hs).

opposite(eq, ne).  opposite(ne, eq).  opposite(lt, ge).  opposite(ge, lt).
opposite(gt, le).  opposite(le, gt).  opposite(lo, hs).  opposite(hs, lo).

%   The ones the emitter writes itself, because they are not one instruction.
expanded(const).  expanded(adr).  expanded(ldr).  expanded(str).

abstract(const(_, _)).      abstract(str_const(_, _)).
abstract(bin(_, _, _, _)).  abstract(cmp(_, _, _, _)).
abstract(load(_, _, _)).    abstract(store(_, _, _)).

%!  verify(+Func) is det.
%
%   Insist that selection left nothing of the three-address IR behind.

verify(F) :-
    ir:func_name(F, Name),
    ir:walk(F, Blocks),
    forall(( member(block(Label, _, Instrs, _), Blocks), member(I, Instrs) ),
           verify_instr(Name, Label, I)).

verify_instr(Name, Label, I) :-
    (   abstract(I)
    ->  functor(I, Kind, _),
        throw(error(survived_selection(Kind, Name, Label), _))
    ;   I = mach(Form, _, _, _, _, _)
    ->  ( ( known_form(Form) ; expanded(Form) ) -> true
        ; throw(error(no_such_instruction(Form), _)) )
    ;   true
    ).

verify_module(module(Funcs, _)) :- maplist(verify, Funcs).
