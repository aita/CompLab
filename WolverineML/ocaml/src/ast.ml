(* The syntax tree.

   The tree the parser builds is untyped; the checker fills in the [ty] and [sym]
   fields as it goes, and everything after it reads them.

   Every expression is a span, a type the checker writes in, and the node itself,
   so that the span and the type are said once rather than in twenty
   constructors. *)

type ty_exp = { ty_at : Diag.span; ty_node : ty_node }

and ty_node =
  | Ty_name of string
  | Ty_array of ty_exp
  | Ty_record of ty_field list

and ty_field = { field_name : string; field_ty : ty_exp; field_at : Diag.span }

type exp = { at : Diag.span; mutable ty : Types.ty option; node : node }

and node =
  | Int_lit of int64
  | Str_lit of string
  | Bool_lit of bool
  | Nil_lit
  | Unit_lit
  | Var of var
  | Call of call
  | Record_lit of record_lit
  | Index of exp * exp
  | Field of field
  | Neg of exp
  | Bin of string * exp * exp
  (* [andalso] and [orelse], which are control flow, not operators. *)
  | Logic of string * exp * exp
  | Assign of exp * exp
  | If of exp * exp * exp option
  | While of exp * exp
  | For of for_exp
  | Break
  | Seq of exp list
  | Let of decl list * exp

and var = { name : string; mutable var_sym : Types.var_sym option }

and call = { callee : string; args : exp list; mutable fun_sym : Types.fun_sym option }

and record_lit = { tyname : string; mutable inits : field_init list }

and field_init = { init_name : string; value : exp; init_at : Diag.span }

and field = { record : exp; select : string; mutable offset : int }

and for_exp = {
  binder : string;
  lo : exp;
  hi : exp;
  body : exp;
  mutable loop_sym : Types.var_sym option;
}

and decl =
  | Type_decl of type_bind list
  | Val_decl of val_decl
  | Fun_decl of fun_bind list

and type_bind = { bind_name : string; bound : ty_exp; bind_at : Diag.span }

and val_decl = {
  decl_at : Diag.span;
  (* [None] for [val () =]. *)
  bound_name : string option;
  written : ty_exp option;
  init : exp;
  is_var : bool;
  mutable decl_sym : Types.var_sym option;
}

and fun_bind = {
  fun_label : string;
  fun_params : param list;
  (* [None] for a procedure. *)
  result : ty_exp option;
  fun_body : exp;
  fun_at : Diag.span;
  mutable sym : Types.fun_sym option;
}

and param = {
  param_name : string;
  param_ty : ty_exp;
  param_at : Diag.span;
  mutable param_sym : Types.var_sym option;
}

type program = decl list

(* [exp] builds a node with its span and no type yet, which is what the parser
   always wants. *)
let exp at node = { at; ty = None; node }

let decl_at = function
  | Type_decl binds -> (List.hd binds).bind_at
  | Val_decl d -> d.decl_at
  | Fun_decl binds -> (List.hd binds).fun_at
