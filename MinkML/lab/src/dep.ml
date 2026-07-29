(* The `dep` system: dependent types, checked bidirectionally, with equality of
   types decided by normalisation by evaluation.

   Types and terms are the same language here, so `(n : nat) -> vec a n` is a
   term like any other and the checker has to *run* terms to compare types.  It
   does that the NbE way rather than by substituting syntax: a term is
   evaluated into a semantic value in which functions are OCaml closures, and
   two types are equal when their values are.  Anything blocked on a variable
   becomes a neutral value, and reading a value back into syntax gives the
   normal form -- which is what this system prints instead of running the
   program, since normalising *is* running it.

   What is in the language: a hierarchy of universes, dependent functions and
   pairs, the natural numbers with their eliminator, and propositional equality
   with `refl` and `J`.  That is enough to state and prove things about the
   programs in it, and to build indexed families -- `vec` in the examples is
   defined by recursion on a natural number into `Type`, which needs no new
   machinery at all.

   What is deliberately missing is recursion.  `fun` in this system defines a
   function that cannot call itself, because a proof assistant that allows
   arbitrary recursion proves everything.  Structural recursion goes through
   `natrec`. *)

type term =
  | Var of string
  | Univ of int
  | Pi of string * term * term
  | Lam of string * term
  | App of term * term
  | Sigma of string * term * term
  | Pair of term * term
  | Fst of term
  | Snd of term
  | Nat
  | Zero
  | Suc of term
  | NatRec of term * term * term * term (* motive, base, step, n *)
  | Unit
  | TT
  | Eq of term * term * term (* Eq A a b *)
  | Refl of term * term (* refl A a *)
  | J of term * term * term * term * term * term

type value =
  | VUniv of int
  | VPi of string * value * closure
  | VLam of string * closure
  | VSigma of string * value * closure
  | VPair of value * value
  | VNat
  | VZero
  | VSuc of value
  | VUnit
  | VTT
  | VEq of value * value * value
  | VRefl of value * value
  | VNeutral of neutral

and neutral =
  | NVar of int * string (* a rigid variable, remembered by level *)
  | NApp of neutral * value
  | NFst of neutral
  | NSnd of neutral
  | NNatRec of value * value * value * neutral
  | NJ of value * value * value * value * value * neutral

and closure = { cenv : env; cvar : string; cbody : term }
and env = (string * value) list

(* Evaluation.  Every eliminator has a `do_` function that either computes or
   builds a neutral value, and that is the entire dynamic semantics. *)
let rec eval (env : env) (t : term) : value =
  match t with
  | Var x -> (
      match List.assoc_opt x env with
      | Some v -> v
      | None -> Loc.fail ~where:"internal error" Loc.unknown "unbound %s in eval" x)
  | Univ i -> VUniv i
  | Pi (x, a, b) -> VPi (x, eval env a, { cenv = env; cvar = x; cbody = b })
  | Lam (x, body) -> VLam (x, { cenv = env; cvar = x; cbody = body })
  | App (f, a) -> apply (eval env f) (eval env a)
  | Sigma (x, a, b) -> VSigma (x, eval env a, { cenv = env; cvar = x; cbody = b })
  | Pair (a, b) -> VPair (eval env a, eval env b)
  | Fst e -> do_fst (eval env e)
  | Snd e -> do_snd (eval env e)
  | Nat -> VNat
  | Zero -> VZero
  | Suc n -> VSuc (eval env n)
  | NatRec (m, z, s, n) ->
      do_natrec (eval env m) (eval env z) (eval env s) (eval env n)
  | Unit -> VUnit
  | TT -> VTT
  | Eq (a, x, y) -> VEq (eval env a, eval env x, eval env y)
  | Refl (a, x) -> VRefl (eval env a, eval env x)
  | J (a, x, m, base, y, p) ->
      do_j (eval env a) (eval env x) (eval env m) (eval env base) (eval env y)
        (eval env p)

and inst (c : closure) (v : value) = eval ((c.cvar, v) :: c.cenv) c.cbody

and apply f a =
  match f with
  | VLam (_, c) -> inst c a
  | VNeutral n -> VNeutral (NApp (n, a))
  | _ -> Loc.fail ~where:"internal error" Loc.unknown "applied a non-function"

and do_fst = function
  | VPair (a, _) -> a
  | VNeutral n -> VNeutral (NFst n)
  | _ -> Loc.fail ~where:"internal error" Loc.unknown "fst of a non-pair"

and do_snd = function
  | VPair (_, b) -> b
  | VNeutral n -> VNeutral (NSnd n)
  | _ -> Loc.fail ~where:"internal error" Loc.unknown "snd of a non-pair"

and do_natrec m z s n =
  match n with
  | VZero -> z
  | VSuc k -> apply (apply s k) (do_natrec m z s k)
  | VNeutral nu -> VNeutral (NNatRec (m, z, s, nu))
  | _ -> Loc.fail ~where:"internal error" Loc.unknown "natrec on a non-number"

(* J computes when the proof is `refl`: that single rule is what makes equality
   proofs usable rather than merely well-typed. *)
and do_j a x m base y p =
  match p with
  | VRefl _ -> base
  | VNeutral n -> VNeutral (NJ (a, x, m, base, y, n))
  | _ -> Loc.fail ~where:"internal error" Loc.unknown "J on a non-proof"

(* Conversion: are these two values the same type or the same term?  Functions
   are compared by applying them to a fresh rigid variable, which is eta
   equality, and pairs component by component. *)
let rec conv lvl a b =
  match (a, b) with
  | VUniv i, VUniv j -> i = j
  | VNat, VNat | VUnit, VUnit | VTT, VTT | VZero, VZero -> true
  | VSuc m, VSuc n -> conv lvl m n
  | VPi (x, d1, c1), VPi (_, d2, c2) | VSigma (x, d1, c1), VSigma (_, d2, c2) ->
      conv lvl d1 d2
      &&
      let v = VNeutral (NVar (lvl, x)) in
      conv (lvl + 1) (inst c1 v) (inst c2 v)
  | VLam (x, c1), VLam (_, c2) ->
      let v = VNeutral (NVar (lvl, x)) in
      conv (lvl + 1) (inst c1 v) (inst c2 v)
  | VLam (x, c), other | other, VLam (x, c) ->
      let v = VNeutral (NVar (lvl, x)) in
      conv (lvl + 1) (inst c v) (apply other v)
  | VPair (a1, b1), VPair (a2, b2) -> conv lvl a1 a2 && conv lvl b1 b2
  | VPair (a1, b1), other | other, VPair (a1, b1) ->
      conv lvl a1 (do_fst other) && conv lvl b1 (do_snd other)
  | VEq (a1, x1, y1), VEq (a2, x2, y2) ->
      conv lvl a1 a2 && conv lvl x1 x2 && conv lvl y1 y2
  | VRefl (a1, x1), VRefl (a2, x2) -> conv lvl a1 a2 && conv lvl x1 x2
  | VNeutral n1, VNeutral n2 -> conv_neutral lvl n1 n2
  | _ -> false

and conv_neutral lvl a b =
  match (a, b) with
  | NVar (i, _), NVar (j, _) -> i = j
  | NApp (f1, a1), NApp (f2, a2) -> conv_neutral lvl f1 f2 && conv lvl a1 a2
  | NFst n1, NFst n2 | NSnd n1, NSnd n2 -> conv_neutral lvl n1 n2
  | NNatRec (m1, z1, s1, n1), NNatRec (m2, z2, s2, n2) ->
      conv lvl m1 m2 && conv lvl z1 z2 && conv lvl s1 s2
      && conv_neutral lvl n1 n2
  | NJ (a1, x1, m1, b1, y1, p1), NJ (a2, x2, m2, b2, y2, p2) ->
      conv lvl a1 a2 && conv lvl x1 x2 && conv lvl m1 m2 && conv lvl b1 b2
      && conv lvl y1 y2 && conv_neutral lvl p1 p2
  | _ -> false

(* Reading a value back into syntax, which is how a normal form is printed. *)
let rec quote lvl v =
  (* The names come from the source and are kept as they are: a printed normal
     form is meant to be read next to the program, not to be re-parsed in a
     context where shadowing matters. *)
  let fresh x = x in
  match v with
  | VUniv i -> Univ i
  | VNat -> Nat
  | VZero -> Zero
  | VSuc n -> Suc (quote lvl n)
  | VUnit -> Unit
  | VTT -> TT
  | VPi (x, d, c) ->
      let x' = fresh x in
      Pi (x', quote lvl d, quote (lvl + 1) (inst c (VNeutral (NVar (lvl, x')))))
  | VSigma (x, d, c) ->
      let x' = fresh x in
      Sigma (x', quote lvl d, quote (lvl + 1) (inst c (VNeutral (NVar (lvl, x')))))
  | VLam (x, c) ->
      let x' = fresh x in
      Lam (x', quote (lvl + 1) (inst c (VNeutral (NVar (lvl, x')))))
  | VPair (a, b) -> Pair (quote lvl a, quote lvl b)
  | VEq (a, x, y) -> Eq (quote lvl a, quote lvl x, quote lvl y)
  | VRefl (a, x) -> Refl (quote lvl a, quote lvl x)
  | VNeutral n -> quote_neutral lvl n

and quote_neutral lvl = function
  | NVar (_, x) -> Var x
  | NApp (f, a) -> App (quote_neutral lvl f, quote lvl a)
  | NFst n -> Fst (quote_neutral lvl n)
  | NSnd n -> Snd (quote_neutral lvl n)
  | NNatRec (m, z, s, n) ->
      NatRec (quote lvl m, quote lvl z, quote lvl s, quote_neutral lvl n)
  | NJ (a, x, m, b, y, p) ->
      J (quote lvl a, quote lvl x, quote lvl m, quote lvl b, quote lvl y,
         quote_neutral lvl p)

(* Printing.  A chain of `suc`s prints as a numeral, because `suc (suc zero)` is
   not how anyone wants to read 2. *)
let rec numeral t n = match t with Zero -> Some n | Suc k -> numeral k (n + 1) | _ -> None

(* Does the bound name still matter?  A function type prints its binder only
   when the result mentions it. *)
let rec mentions x t =
  match t with
  | Var y -> x = y
  | Pi (y, a, b) | Sigma (y, a, b) -> mentions x a || (y <> x && mentions x b)
  | Lam (y, b) -> y <> x && mentions x b
  | App (a, b) | Pair (a, b) -> mentions x a || mentions x b
  | Fst a | Snd a | Suc a -> mentions x a
  | NatRec (a, b, c, d) ->
      mentions x a || mentions x b || mentions x c || mentions x d
  | Eq (a, b, c) -> mentions x a || mentions x b || mentions x c
  | Refl (a, b) -> mentions x a || mentions x b
  | J (a, b, c, d, e, f) ->
      List.exists (mentions x) [ a; b; c; d; e; f ]
  | Univ _ | Nat | Zero | Unit | TT -> false

let rec show ?(prec = 0) t =
  let paren p s = if prec > p then "(" ^ s ^ ")" else s in
  match numeral t 0 with
  | Some n -> string_of_int n
  | None -> (
      match t with
      | Var x -> x
      | Univ 0 -> "Type"
      | Univ i -> Printf.sprintf "Type %d" i
      | Nat -> "nat"
      | Zero -> "0"
      | Suc n -> paren 9 (Printf.sprintf "suc %s" (show ~prec:10 n))
      | Unit -> "unit"
      | TT -> "tt"
      | Pi (x, a, b) when not (mentions x b) ->
          paren 1 (Printf.sprintf "%s -> %s" (show ~prec:2 a) (show ~prec:1 b))
      | Pi (x, a, b) ->
          paren 1 (Printf.sprintf "(%s : %s) -> %s" x (show a) (show ~prec:1 b))
      | Sigma (x, a, b) when not (mentions x b) ->
          paren 3 (Printf.sprintf "%s * %s" (show ~prec:4 a) (show ~prec:4 b))
      | Sigma (x, a, b) ->
          paren 3 (Printf.sprintf "(%s : %s) * %s" x (show a) (show ~prec:4 b))
      | Lam (x, body) -> paren 0 (Printf.sprintf "fn %s => %s" x (show body))
      | App (f, a) -> paren 9 (Printf.sprintf "%s %s" (show ~prec:9 f) (show ~prec:10 a))
      | Pair (a, b) -> Printf.sprintf "(%s, %s)" (show a) (show b)
      | Fst e -> paren 9 (Printf.sprintf "fst %s" (show ~prec:10 e))
      | Snd e -> paren 9 (Printf.sprintf "snd %s" (show ~prec:10 e))
      | NatRec (m, z, s, n) ->
          paren 9
            (Printf.sprintf "natrec %s %s %s %s" (show ~prec:10 m) (show ~prec:10 z)
               (show ~prec:10 s) (show ~prec:10 n))
      | Eq (a, x, y) ->
          paren 9
            (Printf.sprintf "Eq %s %s %s" (show ~prec:10 a) (show ~prec:10 x)
               (show ~prec:10 y))
      | Refl (a, x) ->
          paren 9 (Printf.sprintf "refl %s %s" (show ~prec:10 a) (show ~prec:10 x))
      | J (a, x, m, b, y, p) ->
          paren 9
            (Printf.sprintf "J %s %s %s %s %s %s" (show ~prec:10 a) (show ~prec:10 x)
               (show ~prec:10 m) (show ~prec:10 b) (show ~prec:10 y)
               (show ~prec:10 p)))

(* The context carries three things at once: what each name's type is, what its
   value is (a rigid variable, or the definition it was given), and how many
   rigid variables exist, which is where fresh ones come from. *)
type ctx = {
  types : (string * value) list;
  venv : env;
  lvl : int;
  (* The name of the declaration being elaborated, when it is a `fun`.  It is
     not in scope inside its own body, and saying so is more useful than
     reporting it as unbound. *)
  banned : string list;
}

let empty_ctx = { types = []; venv = []; lvl = 0; banned = [] }

let bind_var ctx x ty =
  {
    ctx with
    types = (x, ty) :: ctx.types;
    venv = (x, VNeutral (NVar (ctx.lvl, x))) :: ctx.venv;
    lvl = ctx.lvl + 1;
  }

let define ctx x ty v =
  { ctx with types = (x, ty) :: ctx.types; venv = (x, v) :: ctx.venv }

let show_value ctx v = show (quote ctx.lvl v)

let mismatch loc ctx expected got =
  Loc.type_error loc "this has type %s, but %s was expected" (show_value ctx got)
    (show_value ctx expected)

(* The natural numbers as a numeral: `3` is `suc (suc (suc zero))`. *)
let rec numeral_term n = if n <= 0 then Zero else Suc (numeral_term (n - 1))

let rec check ctx (e : Ast.t) (ty : value) : term =
  match (e.it, ty) with
  | Ast.Lam (bs, body), VPi _ -> check_lam ctx e.loc bs body ty
  | Ast.Pair (a, b), VSigma (_, dom, cod) ->
      let a' = check ctx a dom in
      let b' = check ctx b (inst cod (eval ctx.venv a')) in
      Pair (a', b')
  | Ast.LetIn (d, body), _ ->
      let ctx', _, _, _, _ = elab_decl ctx d in
      (* A `let` is elaborated away: the definition is substituted by being put
         into the environment, so the body's normal form mentions its value. *)
      check ctx' body ty
  | Ast.Unit, VUniv _ -> Unit
  | _ ->
      let t, got = infer ctx e in
      if not (conv ctx.lvl got ty) then mismatch e.loc ctx ty got;
      t

and check_lam ctx loc bs body ty =
  match (bs, ty) with
  | [], _ -> check ctx body ty
  | b :: rest, VPi (_, dom, cod) ->
      (match b.Ast.bann with
      | None -> ()
      | Some ann ->
          let declared = eval ctx.venv (check ctx ann (VUniv 0)) in
          if not (conv ctx.lvl declared dom) then
            Loc.type_error loc "the parameter %s is declared %s but must be %s"
              b.Ast.bname (show_value ctx declared) (show_value ctx dom));
      let ctx' = bind_var ctx b.Ast.bname dom in
      let cod = inst cod (VNeutral (NVar (ctx.lvl, b.Ast.bname))) in
      let inner =
        match rest with [] -> check ctx' body cod | _ -> check_lam ctx' loc rest body cod
      in
      Lam (b.Ast.bname, inner)
  | b :: _, _ ->
      Loc.type_error loc "%s is a parameter, but the expected type is %s"
        b.Ast.bname (show_value ctx ty)

and infer ctx (e : Ast.t) : term * value =
  match e.it with
  | Ast.Var "Type" -> (Univ 0, VUniv 1)
  | Ast.Var "nat" -> (Nat, VUniv 0)
  | Ast.Var "unit" -> (Unit, VUniv 0)
  | Ast.Var "tt" -> (TT, VUnit)
  | Ast.Unit -> (TT, VUnit)
  | Ast.Var x when List.mem x ctx.banned ->
      Loc.type_error e.loc
        "%s cannot call itself: the `dep` system has no recursion, because a \
         definition that never finishes would prove anything.  Recur with \
         natrec instead"
        x
  | Ast.Var x -> (
      match List.assoc_opt x ctx.types with
      | Some t -> (Var x, t)
      | None -> Loc.type_error e.loc "unbound variable %s" x)
  | Ast.Int n when n >= 0 -> (numeral_term n, VNat)
  | Ast.Ann (body, ann) ->
      let ty = eval ctx.venv (check_ty ctx ann) in
      (check ctx body ty, ty)
  | Ast.Arrow (Ast.Many, name, dom, cod) ->
      let x = Option.value name ~default:"_" in
      let d = check_ty ctx dom in
      let ctx' = bind_var ctx x (eval ctx.venv d) in
      let c = check_ty ctx' cod in
      (Pi (x, d, c), VUniv (max (universe d) (universe c)))
  | Ast.Arrow (Ast.One, _, _, _) ->
      Loc.type_error e.loc "`-o` is a linear arrow; try #system linear"
  | Ast.Prod (name, dom, cod) ->
      let x = Option.value name ~default:"_" in
      let d = check_ty ctx dom in
      let ctx' = bind_var ctx x (eval ctx.venv d) in
      let c = check_ty ctx' cod in
      (Sigma (x, d, c), VUniv (max (universe d) (universe c)))
  | Ast.Bin ("*", a, b) ->
      let d = check_ty ctx a in
      let ctx' = bind_var ctx "_" (eval ctx.venv d) in
      let c = check_ty ctx' b in
      (Sigma ("_", d, c), VUniv (max (universe d) (universe c)))
  | Ast.Lam (bs, body) -> infer_lam ctx e.loc bs body
  | Ast.Pair _ ->
      Loc.type_error e.loc
        "a pair needs its type written down: the second component's type may \
         depend on the first, and there is no way to guess how"
  | Ast.App _ -> infer_app ctx e
  | Ast.LetIn (d, body) ->
      let ctx', _, _, _, _ = elab_decl ctx d in
      infer ctx' body
  | Ast.Bin (";", _, _) ->
      Loc.type_error e.loc "there are no side effects to sequence in this system"
  | Ast.Bin (op, _, _) ->
      Loc.type_error e.loc
        "the `dep` system has no %s: arithmetic on nat goes through natrec" op
  | Ast.If _ ->
      Loc.type_error e.loc "the `dep` system has no booleans; nat and Eq are what there is"
  | Ast.Match _ | Ast.Rec _ | Ast.VariantTy _ | Ast.Proj _ | Ast.Restrict _
  | Ast.Inject _ ->
      Loc.type_error e.loc "records and variants belong to #system row"
  | Ast.Refine _ -> Loc.type_error e.loc "refinement types belong to #system refine"
  | Ast.Choice _ | Ast.Select _ | Ast.Branch _ | Ast.Uop (("!" | "?"), _) ->
      Loc.type_error e.loc "session types belong to #system linear"
  | Ast.Forall _ ->
      Loc.type_error e.loc
        "quantification is a function type here: write (a : Type) -> ... instead \
         of forall"
  | _ -> Loc.type_error e.loc "the `dep` system does not know this form"

(* A type is a term whose type is a universe. *)
and check_ty ctx (e : Ast.t) : term =
  let t, ty = infer ctx e in
  match ty with
  | VUniv _ -> t
  | _ ->
      Loc.type_error e.Ast.loc "this is a term of type %s, not a type"
        (show_value ctx ty)

(* The universe a type lives in.  Only the levels written in the program occur,
   so this walk is enough; there is nothing to unify. *)
and universe t =
  let rec go = function
    | Univ i -> i + 1
    | Pi (_, a, b) | Sigma (_, a, b) -> max (go a) (go b)
    | Nat | Zero | Suc _ | Unit | TT -> 0
    | Eq (a, _, _) -> go a
    | _ -> 0
  in
  go t

(* A motive is a family, and the domain of a family is known from the
   eliminator that asks for it.  So an unannotated `fn n => ...` in that
   position is elaborated with the domain filled in, which is why examples can
   write `natrec (fn _ => nat) ...` instead of `natrec (fn (_ : nat) => nat)`. *)
and infer_family ctx (m : Ast.t) (doms : value list) =
  match (m.Ast.it, doms) with
  | Ast.Lam (b :: rest, body), dom :: more when b.Ast.bann = None ->
      let ctx' = bind_var ctx b.Ast.bname dom in
      (* `fn y => fn p => ...` and `fn y p => ...` are the same family, so the
         remaining domains are handed to whichever shape comes next. *)
      let inner_ast =
        match rest with [] -> body | _ -> { m with Ast.it = Ast.Lam (rest, body) }
      in
      let inner, cod =
        if more = [] then infer ctx' inner_ast else infer_family ctx' inner_ast more
      in
      let cod_term = quote ctx'.lvl cod in
      ( Lam (b.Ast.bname, inner),
        VPi
          ( b.Ast.bname,
            dom,
            { cenv = ctx.venv; cvar = b.Ast.bname; cbody = cod_term } ) )
  | _ -> infer ctx m

and infer_lam ctx loc bs body =
  match bs with
  | [] -> infer ctx body
  | b :: rest ->
      let dom =
        match b.Ast.bann with
        | Some ann -> check_ty ctx ann
        | None ->
            Loc.type_error loc
              "the `dep` system needs a type for the parameter %s" b.Ast.bname
      in
      let dv = eval ctx.venv dom in
      let ctx' = bind_var ctx b.Ast.bname dv in
      let inner, cod = infer_lam ctx' loc rest body in
      (* The codomain is read back so that it can be a type again in this
         context, which is what makes the function type dependent. *)
      let cod_term = quote ctx'.lvl cod in
      ( Lam (b.Ast.bname, inner),
        VPi (b.Ast.bname, dv, { cenv = ctx.venv; cvar = b.Ast.bname; cbody = cod_term })
      )

(* Applications, and the eliminators, which are applications with a fixed
   number of arguments. *)
and infer_app ctx (e : Ast.t) =
  let head, args = Anf.spine e [] in
  let arity name n =
    Loc.type_error e.loc "%s takes %d arguments" name n
  in
  match (head.Ast.it, args) with
  | Ast.Var "Type", [ { it = Ast.Int i; _ } ] -> (Univ i, VUniv (i + 1))
  | Ast.Var "suc", [ n ] -> (Suc (check ctx n VNat), VNat)
  | Ast.Var "fst", [ p ] -> (
      let p', t = infer ctx p in
      match t with
      | VSigma (_, dom, _) -> (Fst p', dom)
      | _ -> Loc.type_error e.loc "fst needs a pair, not %s" (show_value ctx t))
  | Ast.Var "snd", [ p ] -> (
      let p', t = infer ctx p in
      match t with
      | VSigma (_, _, cod) -> (Snd p', inst cod (do_fst (eval ctx.venv p')))
      | _ -> Loc.type_error e.loc "snd needs a pair, not %s" (show_value ctx t))
  | Ast.Var "Eq", [ a; x; y ] ->
      let a' = check_ty ctx a in
      let av = eval ctx.venv a' in
      let x' = check ctx x av and y' = check ctx y av in
      (Eq (a', x', y'), VUniv (universe a'))
  | Ast.Var "refl", [ a; x ] ->
      let a' = check_ty ctx a in
      let av = eval ctx.venv a' in
      let x' = check ctx x av in
      let xv = eval ctx.venv x' in
      (Refl (a', x'), VEq (av, xv, xv))
  (* natrec motive base step n : motive n *)
  | Ast.Var "natrec", [ m; z; s; n ] ->
      (* The motive is inferred rather than checked, because the universe it
         lands in is not fixed: `natrec` into `Type` is how an indexed family
         like `vec` is built, and that motive is a family of types, not of
         values. *)
      let m', mty = infer_family ctx m [ VNat ] in
      let mv = eval ctx.venv m' in
      (match mty with
      | VPi (_, VNat, cod) -> (
          match inst cod (VNeutral (NVar (ctx.lvl, "n"))) with
          | VUniv _ -> ()
          | other ->
              Loc.type_error m.Ast.loc
                "the motive of natrec must land in a universe, not %s"
                (show_value ctx other))
      | _ ->
          Loc.type_error m.Ast.loc
            "the motive of natrec must be a family over nat, not %s"
            (show_value ctx mty));
      let z' = check ctx z (apply mv VZero) in
      let step_ty =
        (* (k : nat) -> motive k -> motive (suc k) *)
        let k = "k" in
        VPi
          ( k,
            VNat,
            {
              cenv = [ ("m", mv) ];
              cvar = k;
              cbody =
                Pi
                  ( "_",
                    App (Var "m", Var k),
                    App (Var "m", Suc (Var k)) );
            } )
      in
      let s' = check ctx s step_ty in
      let n' = check ctx n VNat in
      (NatRec (m', z', s', n'), apply mv (eval ctx.venv n'))
  (* J A x motive base y p : motive y p *)
  | Ast.Var "J", [ a; x; m; base; y; p ] ->
      let a' = check_ty ctx a in
      let av = eval ctx.venv a' in
      let x' = check ctx x av in
      let xv = eval ctx.venv x' in
      (* As with natrec, the motive is inferred: what it must be is a family
         over a point and a proof, in whatever universe it happens to use. *)
      let m', mty =
        infer_family ctx m [ av; VEq (av, xv, VNeutral (NVar (ctx.lvl, "y"))) ]
      in
      let mv = eval ctx.venv m' in
      (match mty with
      | VPi (_, dom, cod) when conv ctx.lvl dom av -> (
          let yv = VNeutral (NVar (ctx.lvl, "y")) in
          match inst cod yv with
          | VPi (_, eq_ty, cod2) when conv (ctx.lvl + 1) eq_ty (VEq (av, xv, yv)) -> (
              match inst cod2 (VNeutral (NVar (ctx.lvl + 1, "p"))) with
              | VUniv _ -> ()
              | other ->
                  Loc.type_error m.Ast.loc
                    "the motive of J must land in a universe, not %s"
                    (show_value ctx other))
          | _ ->
              Loc.type_error m.Ast.loc
                "the motive of J must take a point and a proof of equality to it")
      | _ ->
          Loc.type_error m.Ast.loc "the motive of J must be a family over %s"
            (show_value ctx av));
      let base' = check ctx base (apply (apply mv xv) (VRefl (av, xv))) in
      let y' = check ctx y av in
      let yv = eval ctx.venv y' in
      let p' = check ctx p (VEq (av, xv, yv)) in
      (J (a', x', m', base', y', p'), apply (apply mv yv) (eval ctx.venv p'))
  | Ast.Var (("suc" | "fst" | "snd") as n), _ -> arity n 1
  | Ast.Var "Eq", _ -> arity "Eq" 3
  | Ast.Var "refl", _ -> arity "refl" 2
  | Ast.Var "natrec", _ -> arity "natrec" 4
  | Ast.Var "J", _ -> arity "J" 6
  | _ ->
      List.fold_left
        (fun (f, ft) arg ->
          match ft with
          | VPi (_, dom, cod) ->
              let a = check ctx arg dom in
              (App (f, a), inst cod (eval ctx.venv a))
          | _ ->
              Loc.type_error e.loc "this is applied to an argument but has type %s"
                (show_value ctx ft))
        (infer ctx head) args

(* A declaration.  `Eq` needs the eliminators to be in scope as ordinary names
   inside the closures built above, which is why the environment for a type
   like `Eq A x y` is built by hand there rather than here. *)
and elab_decl ctx (d : Ast.decl) =
  let name =
    match d.Ast.dpat with
    | Ast.DName x -> x
    | Ast.DUnit -> "_"
    | Ast.DPair _ ->
        Loc.type_error d.Ast.dloc "the `dep` system has no pair patterns yet"
  in
  if d.Ast.drec && List.exists (fun (b : Ast.binder) -> b.bann = None) d.Ast.dparams
  then
    Loc.type_error d.Ast.dloc
      "the `dep` system needs a type for every parameter of %s" name;
  let body = Ast.decl_body d in
  let inner = if d.Ast.drec then { ctx with banned = name :: ctx.banned } else ctx in
  let term, ty = infer inner body in
  let v = eval ctx.venv term in
  (* How to show the type.  A normal form unfolds every definition it mentions,
     which is right for values and unreadable for types: the type of a proof
     about `plus` should say `plus`, not the `natrec` that `plus` is.  So an
     annotated declaration reports its annotation, elaborated but not
     normalised, and only an unannotated one reports the normal form. *)
  let display =
    match d.Ast.dret with
    | Some ret -> ( try show (check_ty ctx ret) with Loc.Error _ -> show_value ctx ty)
    | None -> show_value ctx ty
  in
  (define ctx name ty v, name, ty, v, display)

let check_program (items : Ast.toplevel list) =
  let ctx = ref empty_ctx in
  List.filter_map
    (function
      | Ast.TType { tname; tparams; tbody; tloc } ->
          if tparams <> [] then
            Loc.type_error tloc
              "a parameterised alias is a function in this system: write `val %s \
               = fn ... => ...`"
              tname;
          let t, ty = infer !ctx tbody in
          ctx := define !ctx tname ty (eval (!ctx).venv t);
          None
      | Ast.TLet d ->
          let c, name, _, v, display = elab_decl !ctx d in
          ctx := c;
          Some
            {
              System.rname = name;
              rtype = display;
              rvalue = Some (show (quote (!ctx).lvl v));
            })
    items

let system : System.t =
  {
    name = "dep";
    blurb =
      "dependent types: universes, pi, sigma, nat and equality, by \
       normalisation by evaluation";
    check = check_program;
    runs = false;
  }
