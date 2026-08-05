/** <module> Semantic types, and the symbols that carry them.
 *
 *  Types are monomorphic and are terms:
 *
 *      int  string  bool  unit  nil_t
 *      array(Element)
 *      record(Id, Name, Arity)
 *
 *  A record is nominal, and two record types with the same fields are
 *  different types, so it carries an identity that nothing else does: Id is a
 *  number, and same/2 compares those and not the fields.  Arity -- how many
 *  fields it has, which is all the lowering needs -- is a hole the checker
 *  fills once the fields are resolved, so that a type that mentions itself is
 *  still a finite term.
 *
 *  A variable is `var_sym(Id, Name, Type, Mutable, Depth)` and carries no
 *  answer to "does it escape": that is decided long after the symbol is made,
 *  and the checker answers with a set of the ids that do.
 */

:- module(types,
          [ same/2,               % +A, +B          (semidet)
            compatible/2,         % +A, +B          (semidet)
            type_text/2,          % +Type, -Text
            record_type/1,        % +Type           (semidet)
            var_sym_id/2,         % +Sym, -Id
            var_sym_type/2,       % +Sym, -Type
            var_sym_depth/2,      % +Sym, -Depth
            fun_sym_result/2      % +Sym, -Type
          ]).

%!  same(+A, +B) is semidet.
%
%   Type equality: nominal for records, structural for arrays.

same(int, int).
same(string, string).
same(bool, bool).
same(unit, unit).
same(nil_t, nil_t).
same(record(A, _, _), record(B, _, _)) :- A == B.
same(array(A), array(B)) :- same(A, B).

%!  compatible(+A, +B) is semidet.
%
%   Equality, but `nil` stands in for any record.

compatible(nil_t, record(_, _, _)) :- !.
compatible(record(_, _, _), nil_t) :- !.
compatible(nil_t, nil_t) :- !.
compatible(A, B) :- same(A, B).

record_type(record(_, _, _)).

%!  type_text(+Type, -Text) is det.

type_text(int, "int").
type_text(string, "string").
type_text(bool, "bool").
type_text(unit, "unit").
type_text(nil_t, "nil").
type_text(record(_, Name, _), Name).
type_text(array(Elem), Text) :-
    type_text(Elem, Inner),
    format(string(Text), '~w array', [Inner]).

var_sym_id(var_sym(Id, _, _, _, _), Id).
var_sym_type(var_sym(_, _, Type, _, _), Type).
var_sym_depth(var_sym(_, _, _, _, Depth), Depth).

fun_sym_result(fun_sym(_, _, _, Result, _, _), Result).
