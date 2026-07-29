(* The tree the rest of the program works on.

   The parser fills in the shape; the fields marked mutable are what the checker
   writes once it has decided what a name means and what type an expression
   has. *)

open Diagnostics

(* What the source says a type is, before names have been resolved. *)
type type_expr = {
  te_span : span;
  te_kind : type_expr_kind;
  mutable te_resolved : Types.t option;
}

and type_expr_kind =
  (* A possibly qualified name, with type arguments for `array<T>`. *)
  | Te_named of string list * type_expr list
  | Te_pointer of type_expr
  | Te_function of type_expr list * type_expr

type unary_op = Plus | Minus | Not | Complement | Dereference | Address_of

type binary_op =
  | Multiply
  | Divide
  | Remainder
  | Add
  | Subtract
  | Less
  | Less_equal
  | Greater
  | Greater_equal
  | Equal
  | Not_equal
  | And
  | Or

type expr = {
  e_span : span;
  e_kind : expr_kind;
  mutable e_type : Types.t option;
}

and expr_kind =
  | E_int of int64
  | E_float of float
  | E_string of string
  | E_char of int
  | E_bool of bool
  | E_null
  | E_name of name
  | E_array of array_literal
  | E_struct of struct_literal
  | E_fun of func_def
  | E_call of expr * expr list
  | E_index of expr * expr
  | E_field of field_access
  | E_unary of unary_op * expr
  | E_cast of expr * type_expr
  | E_binary of binary
  | E_assign of expr * expr
  (* `if (c) { ...; value } else { ...; other }` standing for a value. *)
  | E_if of conditional

(* What a bare identifier turned out to name. *)
and name = { n_name : string; mutable n_resolution : name_resolution }

and name_resolution =
  | Unresolved
  | Local
  | Global of global_decl
  | Named_function of func_decl
  | Module of module_ast

(* `[a, b, c]`, or `[value; count]` when the count is there. *)
and array_literal = { ar_elements : expr list; ar_count : expr option }

and struct_literal = {
  sl_path : string list;
  sl_fields : field_init list;
  mutable sl_structure : Types.structure option;
}

and field_init = {
  fi_name : string;
  fi_value : expr;
  fi_span : span;
  mutable fi_index : int;
}

and field_access = {
  fa_subject : expr;
  fa_name : string;
  mutable fa_resolution : field_resolution;
  (* Set when the subject is a pointer to a struct and the field was reached
     through it. *)
  mutable fa_through_pointer : bool;
}

(* What `a.b` turned out to mean. *)
and field_resolution =
  | Field_unresolved
  | Struct_field of int
  | Length
  | Module_function of func_decl
  | Module_global of global_decl

and binary = {
  bin_op : binary_op;
  bin_left : expr;
  bin_right : expr;
  (* The type both operands were brought to; for a comparison this is not the
     type of the expression itself. *)
  mutable bin_operand : Types.t option;
}

(* One `if`, whether it is read as a statement or as a value. The checker
   decides which, and moves the arms' last statement into [blk_value] when the
   arms have to stand for values. *)
and conditional = {
  if_span : span;
  if_condition : expr;
  if_then : block;
  if_else : else_branch option;
}

and else_branch = Else_block of block | Else_if of conditional

(* A block, and the expression it yields when it stands for a value. *)
and block = {
  blk_span : span;
  mutable blk_statements : stmt list;
  mutable blk_value : expr option;
}

and stmt = { s_span : span; s_kind : stmt_kind }

and stmt_kind =
  | S_var of var_decl
  | S_fun of func_def
  | S_return of expr option
  | S_if of conditional
  | S_while of expr * block
  | S_for of for_stmt
  | S_break
  | S_continue
  | S_expr of expr
  | S_block of block

and var_decl = {
  vd_name : string;
  vd_declared : type_expr;
  vd_initializer : expr;
  mutable vd_type : Types.t option;
}

(* Any of the three parts may be absent. The initialiser is either a variable
   declaration or an expression statement. *)
and for_stmt = {
  fo_initializer : stmt option;
  fo_condition : expr option;
  fo_step : expr option;
  fo_body : block;
}

(* The parts shared by a named function and an anonymous one. *)
and func_def = {
  fd_id : int;
  fd_name : string;
  fd_parameters : parameter list;
  fd_declared_result : type_expr;
  (* Absent when the host supplies the function. *)
  fd_body : block option;
  fd_span : span;
  mutable fd_result : Types.t option;
  mutable fd_type : Types.t option;
}

and parameter = {
  p_name : string;
  p_declared : type_expr;
  p_span : span;
  mutable p_type : Types.t option;
}

and struct_decl = {
  sd_name : string;
  sd_exported : bool;
  sd_span : span;
  sd_fields : struct_field list;
  mutable sd_structure : Types.structure option;
  mutable sd_type : Types.t option;
}

and struct_field = { sf_name : string; sf_declared : type_expr; sf_span : span }

(* `type Name = Type;`. Aliases are transparent: the name and what it stands for
   are the same type, not two that convert. *)
and alias_decl = {
  ad_name : string;
  ad_exported : bool;
  ad_span : span;
  ad_target : type_expr;
  mutable ad_owner : module_ast option;
  mutable ad_resolved : Types.t option;
  mutable ad_resolving : bool;
}

and func_decl = {
  fn_definition : func_def;
  fn_exported : bool;
  mutable fn_owner : module_ast option;
}

and global_decl = {
  g_id : int;
  g_name : string;
  g_exported : bool;
  g_span : span;
  g_declared : type_expr;
  g_initializer : expr;
  mutable g_type : Types.t option;
  mutable g_owner : module_ast option;
}

and import = {
  im_name : string;
  im_span : span;
  mutable im_target : module_ast option;
}

and module_ast = {
  m_name : string;
  m_file : string;
  m_span : span;
  m_imports : import list;
  m_structs : struct_decl list;
  m_aliases : alias_decl list;
  m_functions : func_decl list;
  m_globals : global_decl list;
}

(* -------------------------------------------------------------------------- *)
(* Building                                                                     *)
(* -------------------------------------------------------------------------- *)

let next_id = ref 0

let fresh_id () =
  incr next_id;
  !next_id

let type_expr span kind = { te_span = span; te_kind = kind; te_resolved = None }
let expr span kind = { e_span = span; e_kind = kind; e_type = None }
let stmt span kind = { s_span = span; s_kind = kind }
let name text = { n_name = text; n_resolution = Unresolved }

let field_access subject field =
  {
    fa_subject = subject;
    fa_name = field;
    fa_resolution = Field_unresolved;
    fa_through_pointer = false;
  }

let binary op left right =
  { bin_op = op; bin_left = left; bin_right = right; bin_operand = None }

let block span statements value =
  { blk_span = span; blk_statements = statements; blk_value = value }

let func_def ~span ~name ~parameters ~result ~body =
  {
    fd_id = fresh_id ();
    fd_name = name;
    fd_parameters = parameters;
    fd_declared_result = result;
    fd_body = body;
    fd_span = span;
    fd_result = None;
    fd_type = None;
  }

(* -------------------------------------------------------------------------- *)
(* Looking things up                                                            *)
(* -------------------------------------------------------------------------- *)

let find_import module_ast name =
  List.find_opt (fun entry -> entry.im_name = name) module_ast.m_imports

let find_struct module_ast name =
  List.find_opt (fun entry -> entry.sd_name = name) module_ast.m_structs

let find_alias module_ast name =
  List.find_opt (fun entry -> entry.ad_name = name) module_ast.m_aliases

let find_function module_ast name =
  List.find_opt
    (fun entry -> entry.fn_definition.fd_name = name)
    module_ast.m_functions

let find_global module_ast name =
  List.find_opt (fun entry -> entry.g_name = name) module_ast.m_globals

let some what = function
  | Some value -> value
  | None -> failwith (Printf.sprintf "%s was never resolved" what)
