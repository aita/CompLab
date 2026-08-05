/** <module> The type checker, which also decides which variables escape.
 *
 *  Types are monomorphic and there is nothing to infer but the type of a
 *  `val`.  A `fun` without a result type is a procedure and returns `unit`,
 *  which is what makes recursion checkable without inference: every function's
 *  signature is known before any body is.
 *
 *  The pass has a second job.  A variable read from inside a function nested
 *  more deeply than the one that binds it cannot live in a register, because
 *  the inner function reaches it through a static link at run time.  Every
 *  lookup that crosses a function boundary adds the variable to a set, and the
 *  lowering pass gives those a frame slot instead.
 *
 *  Nothing here writes on the tree.  The type of a node, the symbol a name
 *  stands for and the offset of a field are holes the parser left, and
 *  checking binds them: `Type = int` rather than `e.ty = INT`.  The one thing
 *  that is not a hole is the escape set, because a variable can be found to
 *  escape long after its own declaration has been checked and a bound
 *  variable cannot be bound again.
 */

:- module(typecheck, [check/2]).       % +Decls, -Escapes

:- use_module(library(assoc)).
:- use_module(library(record)).
:- use_module(library(ordsets)).
:- use_module(library(pairs)).
:- use_module(ast).
:- use_module(diag).
:- use_module(state).
:- use_module(types).

%   What the checker carries: the scopes it looks names up in, how deeply
%   nested it is, how many loops it is inside, the labels it has handed out,
%   two counters, the fields of every record type, and the variables it has
%   found to escape.
:- record ck(scopes:list=[], depth:integer=0, loops:integer=0, labels=t,
             next_var:integer=0, next_rec:integer=0, records=t,
             escapes:list=[]).

:- discontiguous check_node//3.

%   name, argument types, result, and the symbol the runtime exports.
builtin("print",       [string],              unit,   "wol_print").
builtin("println",     [string],              unit,   "wol_println").
builtin("printInt",    [int],                 unit,   "wol_print_int").
builtin("flush",       [],                    unit,   "wol_flush").
builtin("getChar",     [],                    string, "wol_getchar").
builtin("ord",         [string],              int,    "wol_ord").
builtin("chr",         [int],                 string, "wol_chr").
builtin("size",        [string],              int,    "wol_size").
builtin("substring",   [string, int, int],    string, "wol_substring").
builtin("concat",      [string, string],      string, "wol_concat").
builtin("intToString", [int],                 string, "wol_int_to_string").
builtin("stringToInt", [string],              int,    "wol_string_to_int").
builtin("exit",        [int],                 unit,   "wol_exit").

arithmetic(+).  arithmetic(-).  arithmetic(*).  arithmetic(/).  arithmetic(mod).
ordering(<).    ordering(<=).   ordering(>).    ordering(>=).
equality(=).    equality(<>).

%!  check(+Decls, -Escapes) is det.
%
%   Type the program, binding every hole in the tree, and answer with the
%   ordered set of variable ids that escape.

check(Decls, Escapes) :-
    prelude(Prelude),
    make_ck([scopes([Prelude])], Ck0),
    phrase(( push_scope, check_decls(Decls), pop_scope ), [Ck0], [Ck]),
    ck_escapes(Ck, Escapes).

prelude(scope(Types, Vals)) :-
    list_to_assoc(["int"-int, "string"-string, "bool"-bool, "unit"-unit], Types),
    findall(Name-Sym,
            ( builtin(Name, Params, Result, Symbol),
              numbered_params(Params, 0, ParamSyms),
              Sym = fun_sym(Name, Symbol, ParamSyms, Result, 0, runtime) ),
            Runtime),
    findall(Name-Sym,
            ( member(Name, ["array", "length", "not"]),
              atom_string(Builtin, Name),
              Sym = fun_sym(Name, Name, [], unit, 0, Builtin) ),
            Special),
    append(Runtime, Special, Pairs),
    list_to_assoc(Pairs, Vals).

numbered_params([], _, []).
numbered_params([T|Ts], I, [var_sym(-1, Name, T, false, 0)|Rest]) :-
    format(string(Name), 'a~d', [I]),
    J is I + 1,
    numbered_params(Ts, J, Rest).

%   -- scopes -----------------------------------------------------------------

push_scope -->
    get_via(ck_scopes, Ss),
    { empty_assoc(T), empty_assoc(V) },
    set_via(set_scopes_of_ck, [scope(T, V)|Ss]).

pop_scope --> get_via(ck_scopes, [_|Ss]), set_via(set_scopes_of_ck, Ss).

bind_val(Name, Sym) -->
    get_via(ck_scopes, [scope(T, V0)|Ss]),
    { put_assoc(Name, V0, Sym, V) },
    set_via(set_scopes_of_ck, [scope(T, V)|Ss]).

bind_type(Name, Type) -->
    get_via(ck_scopes, [scope(T0, V)|Ss]),
    { put_assoc(Name, T0, Type, T) },
    set_via(set_scopes_of_ck, [scope(T, V)|Ss]).

lookup_val(Name, Span, Sym) -->
    get_via(ck_scopes, Ss),
    { (  member(scope(_, Vals), Ss), get_assoc(Name, Vals, Found)
      -> Sym = Found
      ;  format(atom(M), '`~w` is not bound', [Name]), diag:throw_type(Span, M)
      ) }.

lookup_type(Name, Span, Type) -->
    get_via(ck_scopes, Ss),
    { (  member(scope(Types, _), Ss), get_assoc(Name, Types, Found)
      -> Type = Found
      ;  format(atom(M), '`~w` is not a type', [Name]), diag:throw_type(Span, M)
      ) }.

unique_label(Name, Label) -->
    get_via(ck_labels, L0),
    { ( get_assoc(Name, L0, N) -> true ; N = 0 ),
      N1 is N + 1,
      put_assoc(Name, L0, N1, L),
      ( N =:= 0 -> format(string(Label), 'wol_~w', [Name])
      ;            format(string(Label), 'wol_~w.~d', [Name, N]) ) },
    set_via(set_labels_of_ck, L).

fresh_var(Id) -->
    get_via(ck_next_var, Id), { Next is Id + 1 }, set_via(set_next_var_of_ck, Next).

fresh_record(Id) -->
    get_via(ck_next_rec, Id), { Next is Id + 1 }, set_via(set_next_rec_of_ck, Next).

note_escape(Id) -->
    get_via(ck_escapes, E0), { ord_add_element(E0, Id, E) }, set_via(set_escapes_of_ck, E).

remember_fields(Id, Fields) -->
    get_via(ck_records, R0), { put_assoc(Id, R0, Fields, R) }, set_via(set_records_of_ck, R).

record_fields(record(Id, _, _), Fields) -->
    get_via(ck_records, R), { get_assoc(Id, R, Fields) }.

%   -- what a mismatch says ---------------------------------------------------

unify(Want, Got, Span, Where) :-
    (   types:compatible(Want, Got)
    ->  true
    ;   types:type_text(Want, W), types:type_text(Got, G),
        format(atom(M), 'expected `~w`, found `~w` ~w', [W, G, Where]),
        diag:throw_type(Span, M)
    ).

%   -- declarations -----------------------------------------------------------

check_decls(Ds) --> fold(check_decl, Ds).

check_decl(type_decl(Binds, _)) --> !,
    %   The names come first so that a record may mention itself, or another in
    %   the same group; the fields are resolved once every name is bound.
    fold(declare_record, Binds, Records),
    fold(declare_alias, Binds),
    fold(resolve_record, Records).
check_decl(val_decl(Name, Written, Init, Mutable, Span, Sym)) --> !,
    check_exp(Init, Got0),
    { ast:exp_span(Init, InitSpan) },
    (   { Written == none }
    ->  { Got = Got0 }
    ;   resolve(Written, Want),
        { unify(Want, Got0, InitSpan, "in this binding"), Got = Want }
    ),
    (   { Name == none }
    ->  { unify(unit, Got, InitSpan, "in `val () =`") }
    ;   { Got == nil_t }
    ->  { format(atom(M), '`~w` needs a type annotation to hold `nil`', [Name]),
          diag:throw_type(Span, M) }
    ;   get_via(ck_depth, Depth),
        fresh_var(Id),
        { Sym = var_sym(Id, Name, Got, Mutable, Depth) },
        bind_val(Name, Sym)
    ).
check_decl(fun_decl(Binds, _)) --> !,
    fold(declare_function, Binds),
    fold(check_function, Binds).
check_decl(D) -->
    { D =.. [_|Args], last(Args, Span), diag:throw_type(Span, "unknown declaration") }.

declare_record(type_bind(Name, ty_record(Fields, _), _), Id-Fields-Rec) --> !,
    fresh_record(Id),
    { Rec = record(Id, Name, _Arity) },
    bind_type(Name, Rec).
declare_record(_, none) --> [].

declare_alias(type_bind(_, ty_record(_, _), _)) --> !, [].
declare_alias(type_bind(Name, Written, _)) --> resolve(Written, Type), bind_type(Name, Type).

resolve_record(none) --> !, [].
resolve_record(Id-Written-record(Id, _, Arity)) -->
    field_types(Written, [], Fields),
    { length(Fields, Arity) },
    remember_fields(Id, Fields).

field_types([], _, []) --> [].
field_types([ty_field(Name, Written, Span)|Rest], Seen, [Name-Type|Types]) -->
    { (  memberchk(Name, Seen)
      -> format(atom(M), 'duplicate field `~w`', [Name]), diag:throw_type(Span, M)
      ;  true ) },
    resolve(Written, Type),
    field_types(Rest, [Name|Seen], Types).

%!  resolve(+Written, -Type)// is det.

resolve(ty_name(Name, Span), Type) --> !, lookup_type(Name, Span, Type).
resolve(ty_array(Written, _), array(Elem)) --> !, resolve(Written, Elem).
resolve(ty_record(_, Span), _) --> !,
    { diag:throw_type(Span, "a record type has to be given a name by `type`") }.
resolve(Written, _) -->
    { Written =.. [_|Args], last(Args, Span), diag:throw_type(Span, "unknown type") }.

declare_function(fun_bind(Name, Params, Written, _, _, Sym)) -->
    get_via(ck_depth, Depth), { Inner is Depth + 1 },
    param_syms(Params, [], Inner, Syms),
    (   { Written == none } -> { Result = unit }
    ;   resolve(Written, Result)
    ),
    unique_label(Name, Label),
    { Sym = fun_sym(Name, Label, Syms, Result, Inner, none) },
    bind_val(Name, Sym).

param_syms([], _, _, []) --> [].
param_syms([param(Name, Written, Span, Sym)|Rest], Seen, Depth, [Sym|Syms]) -->
    { (  memberchk(Name, Seen)
      -> format(atom(M), 'duplicate parameter `~w`', [Name]), diag:throw_type(Span, M)
      ;  true ) },
    resolve(Written, Type),
    fresh_var(Id),
    { Sym = var_sym(Id, Name, Type, false, Depth) },
    param_syms(Rest, [Name|Seen], Depth, Syms).

check_function(fun_bind(Name, Params, _, Body, _, Sym)) -->
    { Sym = fun_sym(_, _, _, Result, _, _) },
    get_via(ck_depth, Outer), { Inner is Outer + 1 },
    get_via(ck_loops, Loops),
    set_via(set_depth_of_ck, Inner), set_via(set_loops_of_ck, 0),
    push_scope,
    fold(bind_param, Params),
    check_exp(Body, Got),
    { ast:exp_span(Body, Span),
      format(atom(Where), 'in the body of `~w`', [Name]),
      unify(Result, Got, Span, Where) },
    pop_scope,
    set_via(set_loops_of_ck, Loops), set_via(set_depth_of_ck, Outer).

bind_param(param(Name, _, _, Sym)) --> bind_val(Name, Sym).

%   -- expressions ------------------------------------------------------------

%!  check_exp(+Exp, -Type)// is det.
%
%   The type of the expression, which is also bound into the tree.

check_exp(exp(Node, Span, Type), Type) --> check_node(Node, Span, Type).

check_node(int_lit(_), _, int) --> [].
check_node(str_lit(_), _, string) --> [].
check_node(bool_lit(_), _, bool) --> [].
check_node(nil_lit, _, nil_t) --> [].
check_node(unit_lit, _, unit) --> [].

check_node(var_ref(Name, Sym), Span, Type) -->
    lookup_val(Name, Span, Found),
    (   { Found = fun_sym(_, _, _, _, _, _) }
    ->  { format(atom(M), '`~w` is a function, and functions are not values', [Name]),
          diag:throw_type(Span, M) }
    ;   { Sym = Found, types:var_sym_type(Sym, Type) },
        %   Read from deeper than it was bound: it cannot live in a register.
        get_via(ck_depth, Here),
        { types:var_sym_depth(Sym, There), types:var_sym_id(Sym, Id) },
        (   { There < Here } -> note_escape(Id) ; [] )
    ).

check_node(call_exp(Name, Args, Sym), Span, Type) -->
    lookup_val(Name, Span, Found),
    (   { Found = var_sym(_, _, _, _, _) }
    ->  { format(atom(M), '`~w` is a variable, not a function', [Name]),
          diag:throw_type(Span, M) }
    ;   { Sym = Found, Sym = fun_sym(_, _, Params, Result, _, Builtin) },
        (   { Builtin == array }  -> array_call(Name, Args, Span, Type)
        ;   { Builtin == length } -> length_call(Name, Args, Span, Type)
        ;   { Builtin == not }
        ->  { arity(Name, Args, 1, Span) },
            { Args = [A] }, check_exp(A, Got),
            { unify(bool, Got, Span, "in a call to `not`"), Type = bool }
        ;   { length(Params, N), arity(Name, Args, N, Span),
              pairs_up(Args, Params, Pairs),
              format(atom(Where), 'in a call to `~w`', [Name]) },
            fold(check_argument(Where), Pairs),
            { Type = Result }
        )
    ).

pairs_up([], [], []).
pairs_up([A|As], [P|Ps], [A-P|Rest]) :- pairs_up(As, Ps, Rest).

check_argument(Where, Arg-Param) -->
    check_exp(Arg, Got),
    { types:var_sym_type(Param, Want), ast:exp_span(Arg, Span),
      unify(Want, Got, Span, Where) }.

arity(Name, Args, Want, Span) :-
    length(Args, Given),
    (   Given =:= Want
    ->  true
    ;   ( Want =:= 1 -> Plural = "" ; Plural = "s" ),
        format(atom(M), '`~w` takes ~d argument~w, given ~d',
               [Name, Want, Plural, Given]),
        diag:throw_type(Span, M)
    ).

array_call(Name, Args, Span, array(Elem)) -->
    { arity(Name, Args, 2, Span), Args = [N, Init] },
    check_exp(N, Got),
    { ast:exp_span(N, NSpan), unify(int, Got, NSpan, "as an array length") },
    check_exp(Init, Elem),
    { (  Elem == nil_t
      -> ast:exp_span(Init, ISpan),
         diag:throw_type(ISpan, "`array` cannot tell which record `nil` stands for")
      ;  true ) }.

length_call(Name, Args, Span, int) -->
    { arity(Name, Args, 1, Span), Args = [A] },
    check_exp(A, Got),
    { (  Got = array(_)
      -> true
      ;  types:type_text(Got, T), ast:exp_span(A, ASpan),
         format(atom(M), '`length` wants an array, found `~w`', [T]),
         diag:throw_type(ASpan, M) ) }.

check_node(record_lit(TypeName, Fields, Ordered), Span, Rec) -->
    lookup_type(TypeName, Span, Rec),
    { (  types:record_type(Rec)
      -> true
      ;  format(atom(M), '`~w` is not a record type', [TypeName]),
         diag:throw_type(Span, M) ) },
    record_fields(Rec, Declared),
    %   The fields are put into declaration order, which is the order the
    %   lowering stores them in, and that order is the hole the tree left.
    { given_once(Fields, Declared, Rec, []),
      in_order(Declared, Fields, Span, Pairs),
      pairs_keys(Pairs, Ordered) },
    fold(check_init, Pairs).

given_once([], _, _, _).
given_once([field_init(Name, _, Span)|Rest], Declared, Rec, Seen) :-
    (   memberchk(Name, Seen)
    ->  format(atom(M), 'field `~w` is given twice', [Name]),
        diag:throw_type(Span, M)
    ;   memberchk(Name-_, Declared)
    ->  given_once(Rest, Declared, Rec, [Name|Seen])
    ;   Rec = record(_, RecName, _),
        format(atom(M), '`~w` has no field `~w`', [RecName, Name]),
        diag:throw_type(Span, M)
    ).

in_order([], _, _, []).
in_order([Name-Type|Rest], Given, Span, [Init-Type|Ordered]) :-
    (   memberchk(field_init(Name, Value, ISpan), Given)
    ->  Init = field_init(Name, Value, ISpan)
    ;   format(atom(M), 'field `~w` is missing', [Name]),
        diag:throw_type(Span, M)
    ),
    in_order(Rest, Given, Span, Ordered).

check_init(field_init(Name, Value, Span)-Want) -->
    check_exp(Value, Got),
    { format(atom(Where), 'in field `~w`', [Name]),
      unify(Want, Got, Span, Where) }.

check_node(index_exp(Array, Index), Span, Elem) -->
    check_exp(Array, Got),
    { (  Got = array(E)
      -> Elem = E
      ;  types:type_text(Got, T),
         format(atom(M), '`~w` is not an array', [T]),
         diag:throw_type(Span, M) ) },
    check_exp(Index, IGot),
    { ast:exp_span(Index, ISpan), unify(int, IGot, ISpan, "as an array index") }.

check_node(field_exp(Record, Name, Offset), Span, Type) -->
    check_exp(Record, Rec),
    { (  types:record_type(Rec)
      -> true
      ;  types:type_text(Rec, T),
         format(atom(M), '`~w` is not a record', [T]),
         diag:throw_type(Span, M) ) },
    record_fields(Rec, Fields),
    { (  nth0(Offset, Fields, Name-Type)
      -> true
      ;  Rec = record(_, RecName, _),
         format(atom(M), '`~w` has no field `~w`', [RecName, Name]),
         diag:throw_type(Span, M) ) }.

check_node(neg_exp(Operand), Span, int) -->
    check_exp(Operand, Got),
    { unify(int, Got, Span, "in a negation") }.

check_node(bin_exp(Op, Lhs, Rhs), Span, Type) -->
    check_exp(Lhs, L), check_exp(Rhs, R),
    { ast:exp_span(Lhs, LSpan), ast:exp_span(Rhs, RSpan),
      binop_type(Op, L, R, Span, LSpan, RSpan, Type) }.

binop_type(Op, L, R, _, LSpan, RSpan, int) :-
    arithmetic(Op), !,
    format(atom(Left), 'on the left of `~w`', [Op]),
    format(atom(Right), 'on the right of `~w`', [Op]),
    unify(int, L, LSpan, Left),
    unify(int, R, RSpan, Right).
binop_type(^, L, R, _, LSpan, RSpan, string) :- !,
    unify(string, L, LSpan, "on the left of `^`"),
    unify(string, R, RSpan, "on the right of `^`").
binop_type(Op, L, R, Span, _, RSpan, bool) :-
    ordering(Op), !,
    (   memberchk(L, [int, string])
    ->  format(atom(Right), 'on the right of `~w`', [Op]),
        unify(L, R, RSpan, Right)
    ;   types:type_text(L, T),
        format(atom(M), '`~w` compares int or string, not `~w`', [Op, T]),
        diag:throw_type(Span, M)
    ).
binop_type(Op, L, R, Span, _, _, bool) :-
    equality(Op), !,
    (   ( L == unit ; R == unit )
    ->  format(atom(M), '`~w` cannot compare `unit`', [Op]),
        diag:throw_type(Span, M)
    ;   types:compatible(L, R)
    ->  true
    ;   types:type_text(L, LT), types:type_text(R, RT),
        format(atom(M), '`~w` compares `~w` with `~w`', [Op, LT, RT]),
        diag:throw_type(Span, M)
    ).
binop_type(Op, _, _, Span, _, _, _) :-
    format(atom(M), 'unknown operator `~w`', [Op]),
    diag:throw_type(Span, M).

check_node(logic_exp(Op, Lhs, Rhs), _, bool) -->
    check_exp(Lhs, L), check_exp(Rhs, R),
    { ast:exp_span(Lhs, LSpan), ast:exp_span(Rhs, RSpan),
      format(atom(Left), 'on the left of `~w`', [Op]),
      format(atom(Right), 'on the right of `~w`', [Op]),
      unify(bool, L, LSpan, Left),
      unify(bool, R, RSpan, Right) }.

check_node(assign_exp(Target, Value), Span, unit) -->
    check_exp(Target, Want),
    { (  Target = exp(var_ref(_, var_sym(_, Name, _, false, _)), _, _)
      -> format(atom(M), '`~w` is a `val`, so it cannot be assigned', [Name]),
         diag:throw_type(Span, M)
      ;  true ) },
    check_exp(Value, Got),
    { ast:exp_span(Value, VSpan), unify(Want, Got, VSpan, "in an assignment") }.

check_node(if_exp(Test, Then, Else), Span, Type) -->
    check_exp(Test, C),
    { ast:exp_span(Test, CSpan), unify(bool, C, CSpan, "as an `if` condition") },
    check_exp(Then, T),
    (   { Else == none }
    ->  { ast:exp_span(Then, TSpan),
          unify(unit, T, TSpan, "in an `if` with no `else`"), Type = unit }
    ;   check_exp(Else, E),
        { (  types:compatible(T, E)
          -> ( T == nil_t -> Type = E ; Type = T )
          ;  types:type_text(T, TT), types:type_text(E, ET),
             format(atom(M), 'the branches differ: `~w` and `~w`', [TT, ET]),
             diag:throw_type(Span, M) ) }
    ).

check_node(while_exp(Test, Body), _, unit) -->
    check_exp(Test, C),
    { ast:exp_span(Test, CSpan), unify(bool, C, CSpan, "as a `while` condition") },
    deeper_loop,
    check_exp(Body, B),
    { ast:exp_span(Body, BSpan), unify(unit, B, BSpan, "in a `while` body") },
    shallower_loop.

check_node(for_exp(Name, Lo, Hi, Body, Sym), _, unit) -->
    check_exp(Lo, L),
    { ast:exp_span(Lo, LSpan), unify(int, L, LSpan, "as a `for` bound") },
    check_exp(Hi, H),
    { ast:exp_span(Hi, HSpan), unify(int, H, HSpan, "as a `for` bound") },
    get_via(ck_depth, Depth), fresh_var(Id),
    { Sym = var_sym(Id, Name, int, false, Depth) },
    push_scope, bind_val(Name, Sym), deeper_loop,
    check_exp(Body, B),
    { ast:exp_span(Body, BSpan), unify(unit, B, BSpan, "in a `for` body") },
    shallower_loop, pop_scope.

check_node(break_exp, Span, unit) -->
    get_via(ck_loops, N),
    { (  N =:= 0
      -> diag:throw_type(Span, "`break` is outside any loop")
      ;  true ) }.

check_node(seq_exp(Items), _, Type) --> seq_type(Items, unit, Type).

seq_type([], Type, Type) --> [].
seq_type([E|Es], _, Type) --> check_exp(E, T), seq_type(Es, T, Type).

check_node(let_exp(Decls, Body), _, Type) -->
    push_scope, check_decls(Decls), check_exp(Body, Type), pop_scope.

deeper_loop --> get_via(ck_loops, N), { M is N + 1 }, set_via(set_loops_of_ck, M).
shallower_loop --> get_via(ck_loops, N), { M is N - 1 }, set_via(set_loops_of_ck, M).
