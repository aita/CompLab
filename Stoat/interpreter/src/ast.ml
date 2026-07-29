(* Abstract syntax for Stoat.

   A program is a block: a sequence of declarations (which need no separator)
   and expressions (separated by ';').  The value of a block is the value of
   its last item. *)

type binop =
  | Add
  | Sub
  | Mul
  | Div
  | Mod
  | Eq
  | Ne
  | Lt
  | Le
  | Gt
  | Ge

type unop =
  | Neg
  | Not

type expr =
  | Int of int
  | Float of float
  | Str of string
  | Bool of bool
  | Nil
  | ListLit of expr list
  | Var of string
  | Let of string * expr
  | Assign of expr * expr (* the left side is a Var, Field or Index *)
  | Binop of binop * expr * expr
  | Unop of unop * expr
  | And of expr * expr
  | Or of expr * expr
  | Call of expr * expr list
  | Field of expr * string
  | Index of expr * expr
  | Super of string (* super.name, resolved through the MRO *)
  | Fn of string list * block (* anonymous function *)
  | If of expr * block * block option
  | While of expr * block
  | For of string * expr * block
  | Return of expr option
  | Break
  | Continue

and block = stmt list

and stmt = {
  desc : stmt_desc;
  line : int; (* used to locate runtime errors *)
}

and stmt_desc =
  | SExpr of expr
  | SFun of func
  | SClass of cls_decl

and func = {
  fname : string;
  params : string list;
  body : block;
}

and cls_decl = {
  cname : string;
  bases : string list;
  meths : func list;
}

(* Raised by parser actions for things the grammar accepts but the language
   does not, such as '1 + 2 = x'. *)
exception Syntax_error of Lexing.position * string

let is_lvalue = function
  | Var _ | Field _ | Index _ -> true
  | _ -> false

let string_of_binop = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Mod -> "%"
  | Eq -> "=="
  | Ne -> "!="
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="
