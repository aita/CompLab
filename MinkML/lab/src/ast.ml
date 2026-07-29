(* One syntax tree for every system.

   There is no separate grammar of types.  A type is a term: `int -> bool` is
   an [Arrow] node, `{ v : int | v > 0 }` is a [Refine] node, and `x * y` is
   the same [Bin ("*", _, _)] node whether it means multiplication or a
   product type.  Each system reads the tree it understands out of this one
   and rejects the rest, which is what lets the same program be handed to two
   different type systems. *)

type label = string

(* How much a function may use its argument: `->` is [Many], `-o` is [One]. *)
type mult = One | Many

(* `{ l = e }` binds fields with [Eq] and `{ l : t }` declares them with
   [Colon]; the two are the record literal and the record type. *)
type sep = Eq | Colon

type t = { it : desc; loc : Loc.t }

and desc =
  | Var of string
  | Int of int
  | Bool of bool
  | Unit
  | Lam of binder list * t
  | App of t * t
  | LetIn of decl * t
  | If of t * t * t
  | Ann of t * t (* (e : T) *)
  | Bin of string * t * t (* + - * / % == != < <= > >= && || ==> ; *)
  | Uop of string * t (* - not ! ? *)
  | Pair of t * t
  | Rec of sep * field list * t option (* { l = e, ..r } / { l : T, ..r } *)
  | VariantTy of field list * t option (* [ L : T, ..r ] *)
  | Choice of string * field list (* +{ L : S } / &{ L : S } *)
  | Proj of t * label
  | Restrict of t * label (* e \ l *)
  | Inject of label * t option (* `L e *)
  | Match of t * (pat * t) list
  | Branch of t * (label * string * t) list (* branch c with `L c' -> e *)
  | Select of label * t (* select `L c *)
  | Arrow of mult * string option * t * t (* A -> B, A -o B, (x : A) -> B *)
  | Prod of string option * t * t (* (x : A) * B -- the dependent pair *)
  | Forall of string list * t
  | Refine of string * t * t (* { v : B | p } *)

and binder = { bname : string; bann : t option }
and field = { flabel : label; fbody : t }

(* A binding, shared by `let ... in ...` and the top level.  [params] is the
   sugar `let f (x : A) (y : B) : C = e`, which is a [Lam] with the result
   annotation pushed onto the body. *)
and decl = {
  drec : bool;
  dpat : dpat;
  dparams : binder list;
  dret : t option;
  dbody : t;
  dloc : Loc.t;
}

and dpat = DName of string | DPair of string * string | DUnit

and pat =
  | PWild
  | PVar of string
  | PUnit
  | PPair of pat * pat
  | PInject of label * pat option

type toplevel =
  | TLet of decl
  | TType of { tname : string; tparams : string list; tbody : t; tloc : Loc.t }

type program = { system : string option; items : toplevel list }

let mk loc it = { it; loc }

(* `let f (x : A) : C = e` is `let f = fun (x : A) -> (e : C)`. *)
let decl_body (d : decl) =
  let body =
    match d.dret with
    | None -> d.dbody
    | Some ret -> mk d.dbody.loc (Ann (d.dbody, ret))
  in
  match d.dparams with [] -> body | ps -> mk d.dloc (Lam (ps, body))

let rec pat_vars = function
  | PWild | PUnit -> []
  | PVar x -> [ x ]
  | PPair (a, b) -> pat_vars a @ pat_vars b
  | PInject (_, None) -> []
  | PInject (_, Some p) -> pat_vars p
