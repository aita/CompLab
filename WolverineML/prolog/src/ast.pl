/** <module> The shape of the syntax tree, and the holes the checker fills.
 *
 *  The tree is terms, and an expression is `exp(Node, Span, Type)`.  The third
 *  argument is unbound when the parser is done with it: the checker binds it,
 *  and so binds the type of every node in the tree without building a second
 *  one.  That is what a logic variable is for, and it is the whole answer to
 *  the problem every other port in this tree solves by mutating a field.
 *
 *  Four other holes work the same way -- `Sym` on a variable, a call and a
 *  `for`, `Offset` on a field selection, and `Ordered` on a record literal,
 *  which the checker fills with the initialisers put into declaration order.
 *  Nothing else about the tree changes after it is built.
 *
 *      exp(int_lit(Value), Span, Type)
 *      exp(str_lit(Text), Span, Type)
 *      exp(bool_lit(true), Span, Type)
 *      exp(nil_lit, Span, Type)
 *      exp(unit_lit, Span, Type)
 *      exp(var_ref(Name, Sym), Span, Type)
 *      exp(call_exp(Name, Args, Sym), Span, Type)
 *      exp(record_lit(TypeName, Fields, Ordered), Span, Type)
 *      exp(index_exp(Array, Index), Span, Type)
 *      exp(field_exp(Record, Name, Offset), Span, Type)
 *      exp(neg_exp(Operand), Span, Type)
 *      exp(bin_exp(Op, Lhs, Rhs), Span, Type)
 *      exp(logic_exp(Op, Lhs, Rhs), Span, Type)
 *      exp(assign_exp(Target, Value), Span, Type)
 *      exp(if_exp(Test, Then, Else), Span, Type)      Else is `none` or an exp
 *      exp(while_exp(Test, Body), Span, Type)
 *      exp(for_exp(Name, Lo, Hi, Body, Sym), Span, Type)
 *      exp(break_exp, Span, Type)
 *      exp(seq_exp(Items), Span, Type)
 *      exp(let_exp(Decls, Body), Span, Type)
 *
 *  A declaration is one of
 *
 *      type_decl(Binds, Span)          type_bind(Name, TypeExp, Span)
 *      val_decl(Name, TypeExp, Init, Mutable, Span, Sym)   Name is `none` for `val ()`
 *      fun_decl(Binds, Span)           fun_bind(Name, Params, Result, Body, Span, Sym)
 *
 *  and a type as it is written is `ty_name(Name, Span)`, `ty_array(Elem, Span)`
 *  or `ty_record(Fields, Span)` over `ty_field(Name, TypeExp, Span)`.
 */

:- module(ast,
          [ exp_span/2,           % +Exp, -Span
            exp_type/2,           % +Exp, -Type
            exp_node/2,           % +Exp, -Node
            place/1               % +Exp   (semidet)
          ]).

exp_node(exp(Node, _, _), Node).
exp_span(exp(_, Span, _), Span).
exp_type(exp(_, _, Type), Type).

%!  place(+Exp) is semidet.
%
%   Whether the expression is something that can be assigned to.

place(exp(var_ref(_, _), _, _)).
place(exp(index_exp(_, _), _, _)).
place(exp(field_exp(_, _, _), _, _)).
