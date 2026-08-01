(* The surface syntax tree: what the parser makes, and what the type checker
   reads.  Everything after the type checker works on [Core], so this tree keeps
   the shapes that only exist for the reader — `andalso`, `not`, patterns,
   annotations, `fun` with several clauses joined by `and` — and desugaring takes
   them away.

   Every node carries the position of the token that begins it, because the only
   two passes that read this tree are the two that report source errors. *)

type pos = Diag.pos

type ty =
  | Ty_name of string * pos (* int, bool, unit *)
  | Ty_var of string * pos (* 'a *)
  | Ty_tuple of ty list * pos
  | Ty_arrow of ty list * ty * pos (* (int, int) -> int *)

let ty_pos = function
  | Ty_name (_, p) | Ty_var (_, p) | Ty_tuple (_, p) | Ty_arrow (_, _, p) -> p

(* Patterns are irrefutable: a name, a hole, unit, or a tuple of those.  There is
   no sum type in the language yet, so there is nothing to match against and
   nothing for a pattern to fail at — which is why [Desugar] can turn one into
   projections and lets without a decision tree. *)
type pat =
  | P_var of string * pos
  | P_wild of pos
  | P_unit of pos
  | P_tuple of pat list * pos
  | P_annot of pat * ty * pos

let pat_pos = function
  | P_var (_, p) | P_wild p | P_unit p | P_tuple (_, p) | P_annot (_, _, p) -> p

type binop = Add | Sub | Mul | Div | Mod | Eq | Ne | Lt | Le | Gt | Ge

let binop_name = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Mod -> "mod"
  | Eq -> "="
  | Ne -> "<>"
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="

type expr =
  | Int of int64 * pos
  | Bool of bool * pos
  | Unit of pos
  | Var of string * pos
  | Tuple of expr list * pos
  | Proj of int * expr * pos (* #1 e, one-based *)
  | Neg of expr * pos (* ~e *)
  | Not of expr * pos
  | Bin of binop * expr * expr * pos
  | Andalso of expr * expr * pos
  | Orelse of expr * expr * pos
  | If of expr * expr * expr * pos
  | Fn of pat list * expr * pos
  | App of expr * expr list * pos
  | Let of decl list * expr * pos
  | Annot of expr * ty * pos

and decl =
  | D_val of pat * ty option * expr * pos
  | D_fun of fundecl list * pos (* one `fun ... and ...` group *)

and fundecl = {
  f_name : string;
  f_params : pat list;
  f_ret : ty option;
  f_body : expr;
  f_pos : pos;
}

type program = decl list

let expr_pos = function
  | Int (_, p)
  | Bool (_, p)
  | Unit p
  | Var (_, p)
  | Tuple (_, p)
  | Proj (_, _, p)
  | Neg (_, p)
  | Not (_, p)
  | Bin (_, _, _, p)
  | Andalso (_, _, p)
  | Orelse (_, _, p)
  | If (_, _, _, p)
  | Fn (_, _, p)
  | App (_, _, p)
  | Let (_, _, p)
  | Annot (_, _, p) ->
      p

(* The names a declaration binds, left to right.

   The type checker and the desugarer both walk the top level in this order, and
   the driver lines up what one says with what the other computed: the checker
   gives a type per name, the desugarer arranges for the compiled program to
   return the values in the same order.  One function decides that order, so
   there is nothing for the two to disagree about. *)
let rec pat_binders = function
  | P_var (name, pos) -> [ (name, pos) ]
  | P_wild _ | P_unit _ -> []
  | P_tuple (ps, _) -> List.concat_map pat_binders ps
  | P_annot (p, _, _) -> pat_binders p

let decl_binders = function
  | D_val (p, _, _, _) -> pat_binders p
  | D_fun (fs, _) -> List.map (fun f -> (f.f_name, f.f_pos)) fs

let program_binders decls = List.concat_map decl_binders decls
