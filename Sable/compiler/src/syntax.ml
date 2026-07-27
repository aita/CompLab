(* The source syntax tree.

   `Field` and `Match_failure` are not part of the surface language: they are
   produced by Match_compile when it turns a `match` into a decision tree, and
   the passes after it treat them like any other expression. *)

type arith = Add | Sub | Mul | Div | Rem
type cmp = Eq | Ne | Lt | Le | Gt | Ge

type t =
  | Unit
  | Bool of bool
  | Int of int
  | Not of t
  | Neg of t
  | Arith of arith * t * t
  | Cmp of cmp * t * t
  | If of t * t * t
  | Let of (Ident.t * Types.t) * t * t
  | Var of Ident.t
  | LetRec of fundef list * t (* a whole `let rec .. and ..` group *)
  | App of t * t list
  | Tuple of t list
  | LetTuple of (Ident.t * Types.t) list * t * t
  | Array of t * t (* Array.make size init *)
  | Get of t * t
  | Put of t * t * t
  | Constr of string * t list (* a fully applied constructor *)
  | Match of match_info * t * case list
  | Field of t * int * Types.t (* generated: word i of a block *)
  | Match_failure of Types.t (* generated: no case applied *)

and case = { pat : pattern; action : t }

(* The parser leaves two type slots for the checker to fill in; Match_compile
   needs both, and by then unification has resolved them. *)
and match_info = { scrutinee_type : Types.t; result_type : Types.t }

and pattern =
  | Pwild of Types.t
  | Pvar of Ident.t * Types.t
  | Pint of int
  | Pbool of bool
  | Punit
  | Ptuple of pattern list
  | Pconstr of string * pattern list

and fundef = {
  name : Ident.t * Types.t;
  args : (Ident.t * Types.t) list;
  body : t;
}

let string_of_arith = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Rem -> "mod"

let string_of_cmp = function
  | Eq -> "="
  | Ne -> "<>"
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="

let rec string_of_pattern = function
  | Pwild _ -> "_"
  | Pvar (x, _) -> x
  | Pint n -> string_of_int n
  | Pbool b -> if b then "true" else "false"
  | Punit -> "()"
  | Ptuple ps -> "(" ^ String.concat ", " (List.map string_of_pattern ps) ^ ")"
  | Pconstr (c, []) -> c
  | Pconstr (c, ps) ->
    c ^ " (" ^ String.concat ", " (List.map string_of_pattern ps) ^ ")"

(* Variables bound by a pattern, left to right. *)
let rec pattern_vars = function
  | Pwild _ | Pint _ | Pbool _ | Punit -> []
  | Pvar (x, t) -> [ (x, t) ]
  | Ptuple ps | Pconstr (_, ps) -> List.concat_map pattern_vars ps
