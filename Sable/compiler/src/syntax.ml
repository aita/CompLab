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
  | Let_rec of fundef list * t (* a whole `let rec .. and ..` group *)
  | App of t * t list
  | Tuple of t list
  | Let_tuple of (Ident.t * Types.t) list * t * t
  | Array of t * t (* Array.make size init *)
  | Get of t * t
  | Put of t * t * t
  | Str of string
  | Str_length of t
  | Str_get of t * t (* s.[i], the byte as an integer *)
  | Nil
  | Cons of t * t
  | Annot of t * Types.t (* generated: `(e : ty)`, how a signature is checked *)
  | Qualified of string list * Ident.t (* M.x, M.N.x -- resolved away by Modules *)
  | Type_decl of type_decl * t (* type t = A | B in e *)
  | Module of string * module_exp * t (* module M = <me> in e *)
  | Module_type of string * signature * t (* module type S = sig .. end in e *)
  | Functor of string * string * signature * item list * t
    (* module F (X : S) = struct .. end in e *)
  | Open of string list * t (* open M in e *)
  | Constr of string * t list (* a fully applied constructor *)
  | Match of match_info * t * case list
  | Field of t * int * Types.t (* generated: word i of a block *)
  | Match_failure of Types.t (* generated: no case applied *)

(* The contents of a `struct`.  Modules are a naming discipline and nothing
   else, so these become ordinary nested `let`s; see Modules. *)
and module_exp =
  | Mod_struct of item list
  | Mod_path of string list
  | Mod_apply of string list * module_exp (* F (Arg) *)
  | Mod_sealed of module_exp * signature (* (me : S) *)

and signature = Sig_name of string | Sig_items of sig_item list

(* `type t` with no definition is an abstract type: the signature promises the
   name exists without saying what its constructors are. *)
and sig_item = Sig_type of string | Sig_val of Ident.t * Types.t

and type_decl = { tname : string; tconstrs : (string * Types.t list) list }

and item =
  | Item_let of (Ident.t * Types.t) * t
  | Item_let_tuple of (Ident.t * Types.t) list * t
  | Item_let_rec of fundef list
  | Item_type of type_decl
  | Item_module of string * module_exp
  | Item_module_type of string * signature
  | Item_functor of string * string * signature * item list
  | Item_open of string list

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
  | Pnil
  | Pcons of pattern * pattern
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
  | Pnil -> "[]"
  | Pcons (head, tail) -> string_of_pattern head ^ " :: " ^ string_of_pattern tail
  | Pconstr (c, []) -> Ident.display c
  | Pconstr (c, ps) ->
    Ident.display c ^ " (" ^ String.concat ", " (List.map string_of_pattern ps) ^ ")"

(* Variables bound by a pattern, left to right. *)
let rec pattern_vars = function
  | Pwild _ | Pint _ | Pbool _ | Punit | Pnil -> []
  | Pvar (x, t) -> [ (x, t) ]
  | Pcons (head, tail) -> pattern_vars head @ pattern_vars tail
  | Ptuple ps | Pconstr (_, ps) -> List.concat_map pattern_vars ps
