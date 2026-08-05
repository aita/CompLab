:- begin_tests(typecheck).

:- use_module('../src/parser', []).
:- use_module('../src/typecheck', []).
:- use_module('../src/ast', []).
:- use_module('../src/types', []).

accepts(Source, Decls, Escapes) :-
    parser:parse(Source, Decls),
    typecheck:check(Decls, Escapes).

accepts(Source) :- accepts(Source, _, _).

rejects(Source, Message) :-
    catch(accepts(Source), wolv_error(type, _, M), true),
    ( var(M) -> throw(accepted(Source)) ; true ),
    sub_string(M, _, _, _, Message).

lines(Parts, Source) :- atomic_list_concat(Parts, '\n', A), atom_string(A, Source).

test('arithmetic is on ints') :-
    accepts("val x = 1 + 2"),
    rejects("val x = 1 + \"a\"", "expected `int`, found `string`"),
    rejects("val x = true + 1", "expected `int`, found `bool`").

test('concatenation is on strings') :-
    accepts("val s = \"a\" ^ \"b\""),
    rejects("val s = \"a\" ^ 1", "expected `string`, found `int`").

test('comparison gives bool') :-
    accepts("val b = 1 < 2 andalso 3 >= 4"),
    rejects("val b = \"a\" < 1", "expected `string`, found `int`"),
    rejects("val b = true < false", "compares int or string").

test('equality needs one type') :-
    accepts("val b = 1 = 2"),
    accepts("val b = \"a\" <> \"b\""),
    rejects("val b = 1 = true", "compares `int` with `bool`").

test('conditions are bool') :-
    accepts("val x = if true then 1 else 2"),
    rejects("val x = if 1 then 1 else 2", "expected `bool`, found `int`"),
    rejects("val x = if true then 1 else \"a\"", "the branches differ"),
    rejects("val () = if true then 1", "in an `if` with no `else`").

test('a val cannot be assigned') :-
    lines(['var x = 1', 'val () = x := 2'], Good), accepts(Good),
    lines(['val x = 1', 'val () = x := 2'], Bad), rejects(Bad, "is a `val`").

test('functions check their arguments') :-
    lines(['fun f (a : int) : int = a', 'val x = f (1)'], Good), accepts(Good),
    lines(['fun f (a : int) : int = a', 'val x = f (1, 2)'], Many),
    rejects(Many, "takes 1 argument"),
    lines(['fun f (a : int) : int = a', 'val x = f ("s")'], Wrong),
    rejects(Wrong, "expected `int`").

test('a fun without a result is a procedure') :-
    lines(['fun f () = print ("x")', 'val () = f ()'], Good), accepts(Good),
    rejects("fun f () = 1", "expected `unit`, found `int`").

test('functions are not values') :-
    lines(['fun f () : int = 1', 'val x = f'], Source),
    rejects(Source, "functions are not values").

test('records are nominal') :-
    lines(['type p = { x : int }', 'val a = p { x = 1 }', 'val b = a.x'], Good),
    accepts(Good),
    lines(['type p = { x : int } and q = { x : int }',
           'fun f (r : p) : int = r.x', 'val x = f (q { x = 1 })'], Mixed),
    rejects(Mixed, "expected `p`, found `q`"),
    lines(['type p = { x : int }', 'val a = p { y = 1 }'], NoField),
    rejects(NoField, "has no field `y`"),
    lines(['type p = { x : int, y : int }', 'val a = p { x = 1 }'], Missing),
    rejects(Missing, "field `y` is missing").

test('nil belongs to every record type') :-
    lines(['type p = { x : int }', 'val a : p = nil', 'val b = a = nil'], Good),
    accepts(Good),
    rejects("val a = nil", "needs a type annotation"),
    lines(['type p = { x : int }', 'val a : p = nil', 'val b = a = 1'], Bad),
    rejects(Bad, "compares").

test('arrays know their element') :-
    lines(['val a = array (3, 0)', 'val x = a[0] + 1'], Good), accepts(Good),
    lines(['type ints = int array', 'val a : ints = array (3, 0)'], Named),
    accepts(Named),
    lines(['val a = array (3, 0)', 'val x = a[0] ^ "s"'], Bad),
    rejects(Bad, "expected `string`"),
    lines(['val a = array (3, 0)', 'val x = a[true]'], Index),
    rejects(Index, "as an array index"),
    rejects("val x = length (1)", "`length` wants an array").

test('break is inside a loop') :-
    accepts("val () = while true do break"),
    accepts("val () = for i = 0 to 3 do break"),
    rejects("val () = break", "outside any loop"),
    rejects("val () = while true do let fun f () = break in f () end",
            "outside any loop").

test('escape analysis marks what a nested function reads') :-
    lines(['fun outer () : int =',
           '  let var kept = 1',
           '      val plain = 2',
           '      fun inner () : int = kept',
           '  in inner () + plain end'], Source),
    accepts(Source, [fun_decl([fun_bind(_, _, _, Body, _, _)], _)], Escapes),
    ast:exp_node(Body, let_exp([Kept, Plain|_], _)),
    Kept = val_decl(_, _, _, _, _, KeptSym), types:var_sym_id(KeptSym, KeptId),
    Plain = val_decl(_, _, _, _, _, PlainSym), types:var_sym_id(PlainSym, PlainId),
    memberchk(KeptId, Escapes),
    \+ memberchk(PlainId, Escapes).

test('a parameter escapes too') :-
    lines(['fun outer (n : int) : int =',
           '  let fun inner () : int = n in inner () end'], Source),
    accepts(Source, [fun_decl([fun_bind(_, [param(_, _, _, Sym)], _, _, _, _)], _)],
            Escapes),
    types:var_sym_id(Sym, Id),
    memberchk(Id, Escapes).

test('recursive types') :-
    lines(['type list = { head : int, tail : list }',
           'fun sum (l : list) : int = if l = nil then 0 else l.head + sum (l.tail)'],
          Source),
    accepts(Source),
    accepts("type a = b array and b = { next : a }").

test('unbound names') :-
    rejects("val x = y", "`y` is not bound"),
    rejects("val x : t = 1", "`t` is not a type"),
    rejects("val x = f ()", "`f` is not bound").

:- end_tests(typecheck).
