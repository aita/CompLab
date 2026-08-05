/** <module> An indented dump of the typed syntax tree, for `wolv emit -s ast`.
 *
 *  A dump is a relation between a tree and a list of lines, so it is written
 *  as one: show_exp//2 is a grammar whose terminals are lines, and the text
 *  falls out of `phrase/2` at the end.
 */

:- module(astshow, [show_program/3]).   % +Decls, +Escapes, -Text

:- use_module(library(ordsets)).
:- use_module(ast).
:- use_module(types).

show_program(Decls, Escapes, Text) :-
    phrase(decls(Decls, 0, Escapes), Lines),
    with_output_to(string(Text),
                   forall(member(L, Lines), format('~w~n', [L]))).

put(Depth, Text) -->
    { Spaces is Depth * 2, format(atom(Line), '~*c~w', [Spaces, 0' , Text]) },
    [Line].

%   Most lines are a format string and its arguments, so they say so.
put(Depth, Format, Args) -->
    { format(atom(Text), Format, Args) },
    put(Depth, Text).

%!  quoted(+Text, -Written) is det.
%
%   A string literal, written the way the Python tree writes it, so that a dump
%   taken from either is the same dump.  Every character of one is a byte, and
%   a byte that stands for nothing printable is shown as `\xNN`.
%
%   The other ports ask a Unicode database which bytes those are.  Over the
%   range a literal can hold -- U+0000 to U+00FF -- the answer is four fixed
%   ranges: the C0 and C1 controls, no-break space, and the soft hyphen.

quoted(Text, Written) :-
    string_codes(Text, Codes),
    (   memberchk(0'', Codes), \+ memberchk(0'", Codes)
    ->  Quote = 0'"
    ;   Quote = 0''
    ),
    maplist(quoted_code(Quote), Codes, Parts),
    atomics_to_string([Quote|Parts], Body),
    format(string(Written), '~w~c', [Body, Quote]).

atomics_to_string(Parts, String) :-
    maplist(as_text, Parts, Texts),
    atomics_to_string_(Texts, String).

as_text(C, S) :- integer(C), !, char_code(Ch, C), atom_string(Ch, S).
as_text(S, S).

atomics_to_string_(Texts, String) :- atomic_list_concat(Texts, Atom), atom_string(Atom, String).

quoted_code(Quote, C, Out) :-
    (   ( C =:= Quote ; C =:= 0'\\ )
    ->  char_code(Ch, C), format(atom(Out), '\\~w', [Ch])
    ;   C =:= 10 -> Out = '\\n'
    ;   C =:= 13 -> Out = '\\r'
    ;   C =:= 9  -> Out = '\\t'
    ;   ( C =< 0x1F ; C >= 0x7F, C =< 0xA0 ; C =:= 0xAD )
    ->  format(atom(Out), '\\x~|~`0t~16r~2+', [C])
    ;   char_code(Ch, C), Out = Ch
    ).

type_suffix(Exp, Suffix) :-
    ast:exp_type(Exp, Type),
    (   var(Type)
    ->  Suffix = ''
    ;   types:type_text(Type, Text), format(atom(Suffix), ' : ~w', [Text])
    ).

escapes_suffix(Sym, Escapes, Suffix) :-
    (   nonvar(Sym), Sym = var_sym(Id, _, _, _, _), ord_memberchk(Id, Escapes)
    ->  Suffix = ' (escapes)'
    ;   Suffix = ''
    ).

%   -- declarations -----------------------------------------------------------

decls([], _, _) --> [].
decls([D|Ds], Depth, Escapes) --> decl(D, Depth, Escapes), decls(Ds, Depth, Escapes).

decl(type_decl(Binds, _), Depth, _) -->
    type_binds(Binds, Depth).
decl(val_decl(Name, _, Init, Mutable, _, Sym), Depth, Escapes) -->
    { ( Mutable == true -> Keyword = var ; Keyword = val ),
      ( Name == none -> Written = '()' ; Written = Name ),
      escapes_suffix(Sym, Escapes, Home),
      format(atom(Line), '~w ~w~w', [Keyword, Written, Home]),
      Deeper is Depth + 1 },
    put(Depth, Line),
    show_exp(Init, Deeper, Escapes).
decl(fun_decl(Binds, _), Depth, Escapes) --> fun_binds(Binds, Depth, Escapes).

type_binds([], _) --> [].
type_binds([type_bind(Name, _, _)|Rest], Depth) -->
    put(Depth, 'type ~w', [Name]),
    type_binds(Rest, Depth).

fun_binds([], _, _) --> [].
fun_binds([fun_bind(Name, Params, _, Body, _, Sym)|Rest], Depth, Escapes) -->
    { maplist(param_text(Escapes), Params, Texts),
      atomic_list_concat(Texts, ', ', Written),
      ( nonvar(Sym), types:fun_sym_result(Sym, Result)
      -> types:type_text(Result, ResultText)
      ;  ResultText = '?' ),
      format(atom(Line), 'fun ~w(~w) : ~w', [Name, Written, ResultText]),
      Deeper is Depth + 1 },
    put(Depth, Line),
    show_exp(Body, Deeper, Escapes),
    fun_binds(Rest, Depth, Escapes).

param_text(Escapes, param(Name, _, _, Sym), Text) :-
    escapes_suffix(Sym, Escapes, Home),
    format(atom(Text), '~w~w', [Name, Home]).

%   -- expressions ------------------------------------------------------------

show_exp(Exp, Depth, Escapes) -->
    { ast:exp_node(Exp, Node), Deeper is Depth + 1 },
    show_node(Node, Exp, Depth, Deeper, Escapes).

show_node(int_lit(Value), _, Depth, _, _) -->
    put(Depth, 'int ~d', [Value]).
show_node(str_lit(Text), _, Depth, _, _) -->
    { quoted(Text, Q), format(atom(Line), 'string ~w', [Q]) }, put(Depth, Line).
show_node(bool_lit(V), _, Depth, _, _) -->
    put(Depth, 'bool ~w', [V]).
show_node(nil_lit, _, Depth, _, _) --> put(Depth, nil).
show_node(unit_lit, _, Depth, _, _) --> put(Depth, '()').
show_node(var_ref(Name, _), E, Depth, _, _) -->
    { type_suffix(E, T), format(atom(Line), 'var ~w~w', [Name, T]) }, put(Depth, Line).
show_node(call_exp(Name, Args, _), E, Depth, Deeper, Escapes) -->
    { type_suffix(E, T), format(atom(Line), 'call ~w~w', [Name, T]) },
    put(Depth, Line),
    exps(Args, Deeper, Escapes).
show_node(record_lit(TypeName, _, Ordered), E, Depth, Deeper, Escapes) -->
    { type_suffix(E, T), format(atom(Line), 'record ~w~w', [TypeName, T]) },
    put(Depth, Line),
    inits(Ordered, Deeper, Escapes).
show_node(index_exp(Array, Index), E, Depth, Deeper, Escapes) -->
    { type_suffix(E, T), format(atom(Line), 'index~w', [T]) },
    put(Depth, Line),
    show_exp(Array, Deeper, Escapes), show_exp(Index, Deeper, Escapes).
show_node(field_exp(Record, Name, _), E, Depth, Deeper, Escapes) -->
    { type_suffix(E, T), format(atom(Line), 'field .~w~w', [Name, T]) },
    put(Depth, Line),
    show_exp(Record, Deeper, Escapes).
show_node(neg_exp(Operand), _, Depth, Deeper, Escapes) -->
    put(Depth, neg), show_exp(Operand, Deeper, Escapes).
show_node(bin_exp(Op, Lhs, Rhs), E, Depth, Deeper, Escapes) -->
    { type_suffix(E, T), format(atom(Line), '~w~w', [Op, T]) },
    put(Depth, Line),
    show_exp(Lhs, Deeper, Escapes), show_exp(Rhs, Deeper, Escapes).
show_node(logic_exp(Op, Lhs, Rhs), E, Depth, Deeper, Escapes) -->
    { type_suffix(E, T), format(atom(Line), '~w~w', [Op, T]) },
    put(Depth, Line),
    show_exp(Lhs, Deeper, Escapes), show_exp(Rhs, Deeper, Escapes).
show_node(assign_exp(Target, Value), _, Depth, Deeper, Escapes) -->
    put(Depth, ':='),
    show_exp(Target, Deeper, Escapes), show_exp(Value, Deeper, Escapes).
show_node(if_exp(Test, Then, Else), E, Depth, Deeper, Escapes) -->
    { type_suffix(E, T), format(atom(Line), 'if~w', [T]) },
    put(Depth, Line),
    show_exp(Test, Deeper, Escapes), show_exp(Then, Deeper, Escapes),
    ( { Else == none } -> [] ; show_exp(Else, Deeper, Escapes) ).
show_node(while_exp(Test, Body), _, Depth, Deeper, Escapes) -->
    put(Depth, while),
    show_exp(Test, Deeper, Escapes), show_exp(Body, Deeper, Escapes).
show_node(for_exp(Name, Lo, Hi, Body, Sym), _, Depth, Deeper, Escapes) -->
    { escapes_suffix(Sym, Escapes, Home),
      format(atom(Line), 'for ~w~w', [Name, Home]) },
    put(Depth, Line),
    show_exp(Lo, Deeper, Escapes), show_exp(Hi, Deeper, Escapes),
    show_exp(Body, Deeper, Escapes).
show_node(break_exp, _, Depth, _, _) --> put(Depth, break).
show_node(seq_exp(Items), E, Depth, Deeper, Escapes) -->
    { type_suffix(E, T), format(atom(Line), 'seq~w', [T]) },
    put(Depth, Line),
    exps(Items, Deeper, Escapes).
show_node(let_exp(Decls, Body), E, Depth, Deeper, Escapes) -->
    { type_suffix(E, T), format(atom(Line), 'let~w', [T]) },
    put(Depth, Line),
    decls(Decls, Deeper, Escapes),
    put(Depth, in),
    show_exp(Body, Deeper, Escapes).

exps([], _, _) --> [].
exps([E|Es], Depth, Escapes) --> show_exp(E, Depth, Escapes), exps(Es, Depth, Escapes).

inits([], _, _) --> [].
inits([field_init(Name, Value, _)|Rest], Depth, Escapes) -->
    { format(atom(Line), '~w =', [Name]), Deeper is Depth + 1 },
    put(Depth, Line),
    show_exp(Value, Deeper, Escapes),
    inits(Rest, Depth, Escapes).
