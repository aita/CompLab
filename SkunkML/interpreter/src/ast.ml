(* The surface syntax: Standard ML, cut down to what one interpreter can hold.

   Unlike its neighbour MinkML, this tree has a *separate grammar of types*.
   That is not a stylistic choice: the module language needs to talk about type
   components on their own -- `type t` in a signature is a declaration with no
   term anywhere near it -- and a signature has to be elaborated before the
   structure it describes is looked at.  Terms and types are two sorts here
   because the module language makes them two sorts.

   Nothing in this file knows what a type means.  [Sem] reads these type
   expressions into [Types.ty] against an environment; until then `int list`
   is just an application of a path to an argument. *)

type label = string

(* `X.Y.z` -- the qualifiers, then the name.  An unqualified name has none. *)
type path = { quals : string list; base : string }

let ident x = { quals = []; base = x }

let path_str p = String.concat "." (p.quals @ [ p.base ])

type ty =
  | TyVar of string (* 'a *)
  | TyCon of path * ty list (* int, 'a list, (int, string) either *)
  | TyArrow of ty * ty
  | TyTuple of ty list (* int * bool * unit *)
  | TyRecord of (label * ty) list (* { x : int, y : int } *)

type pat = { p : pat_desc; ploc : Loc.t }

and pat_desc =
  | PWild
  | PVar of string
  | PInt of int
  | PStr of string
  (* A constructor pattern.  `true`, `false`, `nil` and `::` are constructors
     like any other, so there is no separate case for them here. *)
  | PCon of path * pat option
  | PTuple of pat list
  (* [flex] is the `...` of `{ name = n, ... }`: the fields not written are
     allowed to exist.  A closed record pattern must mention every field. *)
  | PRecord of (label * pat) list * bool
  | PList of pat list
  | PAs of string * pat (* x as p *)
  | PAnn of pat * ty

type exp = { e : exp_desc; eloc : Loc.t }

and exp_desc =
  | EVar of path
  | EInt of int
  | EStr of string
  | ETuple of exp list
  | ERecord of (label * exp) list
  | EList of exp list
  | ESelect of label (* #lab: a record field, never a tuple component *)
  | EApp of exp * exp
  | EBin of string * exp * exp (* + - * div mod ^ = <> < <= > >= :: @ *)
  | ENeg of exp (* ~e *)
  | EIf of exp * exp * exp
  | EAndalso of exp * exp
  | EOrelse of exp * exp
  | ESeq of exp * exp
  | EFn of (pat * exp) list (* fn p => e | p => e *)
  | ECase of exp * (pat * exp) list
  | ELet of dec list * exp
  | EAnn of exp * ty

and dec = { d : dec_desc; dloc : Loc.t }

and dec_desc =
  (* `val p = e`.  Not recursive: that is what `fun` is for, as in SML. *)
  | DVal of pat * exp
  (* One `fun ... and ...` group.  All the names are in scope in all the
     bodies, which is what makes mutual recursion work. *)
  | DFun of fundec list
  | DType of tybind list
  | DData of databind list
  | DOpen of path list

and fundec = {
  fname : string;
  (* One clause per `|`.  Every clause has the same number of parameters, and
     the elaborator checks that. *)
  fclauses : (pat list * ty option * exp) list;
  floc : Loc.t;
}

and tybind = { tbparams : string list; tbname : string; tbody : ty }

and databind = {
  dbparams : string list;
  dbname : string;
  dbcons : (string * ty option) list;
  dbloc : Loc.t;
}

(* The module language. *)

type sigexp = { s : sigexp_desc; sloc : Loc.t }

and sigexp_desc =
  | SigId of string
  | SigBody of spec list
  (* `S where type 'a t = ty`: the same signature with one abstract type
     component given a definition.  A functor result signature needs it. *)
  | SigWhere of sigexp * tybind

and spec = { sp : spec_desc; sploc : Loc.t }

and spec_desc =
  | SpVal of string * ty
  (* `type 'a t` is abstract, `type 'a t = ty` is transparent. *)
  | SpType of string list * string * ty option
  | SpData of databind list
  | SpStruct of string * sigexp
  | SpInclude of sigexp

type strexp = { st : strexp_desc; stloc : Loc.t }

and strexp_desc =
  | StrId of path
  | StrBody of topdec list
  | StrApp of string * strexp
  (* `str : S` keeps the types transparent, `str :> S` makes them abstract. *)
  | StrAsc of strexp * sigexp * bool (* true for `:>`, the opaque one *)

and topdec = { t : topdec_desc; tloc : Loc.t }

and topdec_desc =
  | TDec of dec
  | TStr of string * strexp
  | TSig of string * sigexp
  | TFun of string * string * sigexp * (sigexp * bool) option * strexp

type program = topdec list
