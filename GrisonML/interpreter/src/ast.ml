(* The surface syntax.  There is one constructor here for (almost) every
   production of spec/grammar.ebnf; the exceptions are where the parser has
   already done a little work:

   - list expressions and list patterns are built out of [] and :: , so the
     rest of the compiler only ever sees a datatype;
   - an infix chain is left flat in [EInfix] and shaped into a tree by
     [Fixity], because "infixl / infixr / infix" can change the shape after
     the parser has run;
   - "and" and "or" become [EAnd] / [EOr] at that point, since they are short
     circuiting and so are not ordinary applications. *)

type loc = Lexing.position

(* A name qualified by a module path: ([], "x") is x, (["M"; "N"], "x") is
   M.N.x.  The lexer produces the dotted form as a single token, so a path is
   never confused with the record projection e.x. *)
type 'a path = string list * 'a

type lit =
  | LInt of int
  | LReal of float
  | LChar of char
  | LString of string
  | LBool of bool
  | LUnit

type ty = { t : tdesc; tloc : loc }

and tdesc =
  | TVar of string                     (* 'a *)
  | TCon of string path * ty list      (* int, 'a list, (k, v) map, M.t *)
  | TArrow of ty * ty
  | TTuple of ty list
  (* {x : int, y : bool}, or {x : int | 'r}: the fields, and the type
     variable the row goes on with, where it is open *)
  | TRec of (string * ty) list * string option

type pat = { p : pdesc; ploc : loc }

and pdesc =
  | PWild
  | PLit of lit
  | PVar of string
  | PCon of string path * pat option
  | PTuple of pat list
  | PRec of (string * pat) list
  | PAnn of pat * ty

type exp = { e : edesc; eloc : loc }

and edesc =
  | ELit of lit
  | EVar of string path
  | ECon of string path
  | EFn of rule list
  | EApp of exp * exp
  | EInfix of exp * (string * loc * exp) list   (* flat until Fixity runs *)
  | EUn of string * exp                         (* - e, not e *)
  | EProj of exp * string
  | ETuple of exp list
  | ERec of (string * exp) list
  | ELet of decl list * exp
  | ESeq of exp list
  | EIf of exp * exp * exp
  | ECase of exp * rule list
  | EAnd of exp * exp
  | EOr of exp * exp
  | EAnn of exp * ty                            (* from "fun f x : t = e" *)

and rule = { r_pat : pat; r_guard : exp option; r_body : exp }

and clause = {
  c_name : string;
  c_params : pat list;
  c_ret : ty option;
  c_body : exp;
  c_loc : loc;
}

and assoc = Left | Right | Non

and tyhead = { th_params : string list; th_name : string; th_loc : loc }

and tydef =
  | TDAlias of ty
  | TDVariant of (string * ty option * loc) list

and sigexp = {
  se_path : string list;
  se_where : (string path * ty) list;   (* where type M.t = ... *)
  se_loc : loc;
}

and spec = { sp : spdesc; sploc : loc }

and spdesc =
  | SpType of tyhead * ty option        (* None = abstract *)
  | SpVal of string * ty
  | SpMod of string * sigexp
  | SpInclude of sigexp

and mexp = { me : medesc; meloc : loc }

and medesc =
  | MEPath of string list
  | MEApp of string list * mexp

and mdecl =
  (* mod M (P : S) ... : S ... items ... end *)
  | MDefine of string * (string * sigexp) list * sigexp option * decl list
  (* mod M : S = M2(N) *)
  | MBindTo of string * sigexp option * mexp

and iclause =
  | IAs of string
  | INames of string list

and decl = { d : ddesc; dloc : loc }

and ddesc =
  | DVal of pat * ty option * exp
  | DFun of clause list
  (* a run of adjacent "fun" declarations, desugared into one recursive
     group by Desugar; the parser never builds this *)
  | DRec of (string * exp * loc) list
  | DType of tyhead * tydef
  | DFixity of assoc * int * string list
  | DSig of string * spec list
  | DMod of mdecl
  | DImport of string list * iclause option
  | DInclude of string list                      (* include M, in a module *)

let mk_e eloc e = { e; eloc }
let mk_p ploc p = { p; ploc }
let mk_d dloc d = { d; dloc }
let mk_t tloc t = { t; tloc }
let mk_sp sploc sp = { sp; sploc }
let mk_me meloc me = { me; meloc }

let nil_path : string path = ([], "[]")
let cons_path : string path = ([], "::")

(* [a, b, c] is a :: b :: c :: [] *)
let rec list_exp loc = function
  | [] -> mk_e loc (ECon nil_path)
  | x :: rest ->
    mk_e loc (EApp (mk_e loc (ECon cons_path), mk_e loc (ETuple [ x; list_exp loc rest ])))

let rec list_pat loc = function
  | [] -> mk_p loc (PCon (nil_path, None))
  | x :: rest ->
    mk_p loc (PCon (cons_path, Some (mk_p loc (PTuple [ x; list_pat loc rest ]))))

let cons_pat loc h t = mk_p loc (PCon (cons_path, Some (mk_p loc (PTuple [ h; t ]))))

(* :: is the one operator that names a constructor rather than a value: it can
   be given a fixity and it can be written (::) for the function it is, but it
   cannot be bound, because a :: b is decided before any binding is. *)
let is_cons_op o = String.equal o (snd cons_path)

let show_path (ms, x) = String.concat "." (ms @ [ x ])

(* Fixity and Desugar both walk the whole tree and rewrite very little of it.
   These are List.map and Option.map that hand back what they were given when
   nothing in it changed, so that the two passes allocate a node only where
   they actually replace one, rather than two fresh copies of the program. *)

let rec map_share f xs =
  match xs with
  | [] -> []
  | x :: rest ->
    let y = f x in
    let rest' = map_share f rest in
    if y == x && rest' == rest then xs else y :: rest'

let map_share_snd f xs =
  map_share
    (fun ((k, v) as pair) ->
      let v' = f v in
      if v' == v then pair else (k, v'))
    xs

let opt_share f o =
  match o with
  | None -> None
  | Some x ->
    let y = f x in
    if y == x then o else Some y
