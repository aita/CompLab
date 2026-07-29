(* The `refine` system: refinement types, checked bidirectionally, with the
   arithmetic handed to a solver.

   A base type carries a predicate: `{ v : int | v > 0 }` is the integers that
   are positive, and `v` is the value being described.  A function type may
   name its argument, so the result can talk about it:

       fun idx (n : { v : int | v >= 0 }) : { v : int | v > n } = n + 1

   Checking such a program never guesses a predicate.  Every step either
   pushes an expected type inwards or produces a subtyping question, and
   subtyping between two refined base types is an implication -- everything the
   environment knows, and the predicate on the left, must entail the predicate
   on the right.  Those implications are the verification conditions; smt.ml
   decides them.

   Two things make the implications small enough to be decidable.  A variable
   is given the singleton type `{ v : int | v == x }`, so equalities flow
   without any need to look inside the environment again; and any argument that
   is not already a name or a literal is bound to a fresh one first, which is
   the same trick as normalising to A-normal form, done here on the fly.

   What is deliberately missing is inference of refinements.  Liquid typing
   solves for the predicates from a set of qualifiers; here every function says
   what it promises, and the checker only verifies it. *)

type base = BInt | BBool | BUnit

type ty =
  | Base of base * string * Logic.expr (* { v : base | p } *)
  | Fun of string * ty * ty (* (x : T) -> U *)
  | Pair of ty * ty

let base_name = function BInt -> "int" | BBool -> "bool" | BUnit -> "unit"
let sort_of_base = function BBool -> Logic.Bool | _ -> Logic.Int

let counter = ref 0

let fresh base =
  incr counter;
  Printf.sprintf "%s%d" base !counter

let rec show ?(prec = 0) t =
  let paren p s = if prec > p then "(" ^ s ^ ")" else s in
  match t with
  | Base (b, _, Logic.True) -> base_name b
  | Base (b, v, p) -> Printf.sprintf "{ %s : %s | %s }" v (base_name b) (Logic.show p)
  | Fun (x, a, b) ->
      let dom =
        if occurs x b then Printf.sprintf "(%s : %s)" x (show a) else show ~prec:2 a
      in
      paren 1 (Printf.sprintf "%s -> %s" dom (show ~prec:1 b))
  | Pair (a, b) -> paren 3 (Printf.sprintf "%s * %s" (show ~prec:4 a) (show ~prec:4 b))

(* Does the name still matter?  Only for printing: a function type prints its
   binder when the result mentions it. *)
and occurs x t =
  match t with
  | Base (_, v, p) -> v <> x && List.mem x (Logic.vars_of p [])
  | Fun (y, a, b) -> occurs x a || (y <> x && occurs x b)
  | Pair (a, b) -> occurs x a || occurs x b

let rec subst_ty x e t =
  match t with
  | Base (b, v, p) -> if v = x then t else Base (b, v, Logic.subst x e p)
  | Fun (y, a, b) ->
      Fun (y, subst_ty x e a, if y = x then b else subst_ty x e b)
  | Pair (a, b) -> Pair (subst_ty x e a, subst_ty x e b)

(* The environment: what each name has, what is known about them, and the path
   conditions collected from the branches taken to get here. *)
type env = {
  binds : (string * ty) list;
  vars : Logic.binding list; (* in scope for the solver, oldest first *)
  hyps : Logic.expr list;
}

let empty = { binds = []; vars = []; hyps = [] }

(* Binding a name of refined base type adds what is known about it as a
   hypothesis.  That is the only way facts enter the logic. *)
let bind env x t =
  let env = { env with binds = (x, t) :: env.binds } in
  match t with
  | Base (b, v, p) ->
      {
        env with
        vars = env.vars @ [ { Logic.name = x; sort = sort_of_base b } ];
        hyps = (if p = Logic.True then env.hyps else env.hyps @ [ Logic.subst v (Logic.Var x) p ]);
      }
  | _ -> env

let assume env p = if p = Logic.True then env else { env with hyps = env.hyps @ [ p ] }

let vc env loc note goal =
  Smt.discharge { Logic.vars = env.vars; hyps = env.hyps; goal; loc; note }

(* Subtyping.  Between base types it is one implication; between function types
   it is the usual contravariance, with the argument in scope for the
   codomains. *)
let rec sub env loc note t1 t2 =
  (* Two identical types need no implication.  Skipping them is not an
     optimisation for the solver's sake so much as for the reader's: what
     `--dump-vc` prints should be the obligations the program actually has. *)
  if t1 = t2 then ()
  else
  match (t1, t2) with
  | Base (b1, v1, p1), Base (b2, v2, p2) ->
      if b1 <> b2 then
        Loc.type_error loc "this is %s, but %s was expected" (base_name b1)
          (base_name b2);
      if p2 = Logic.True then ()
      else
        let x = fresh "v" in
        let env =
          {
            env with
            vars = env.vars @ [ { Logic.name = x; sort = sort_of_base b1 } ];
            hyps = env.hyps @ (if p1 = Logic.True then [] else [ Logic.subst v1 (Logic.Var x) p1 ]);
          }
        in
        vc env loc note (Logic.subst v2 (Logic.Var x) p2)
  | Fun (x1, a1, b1), Fun (x2, a2, b2) ->
      sub env loc note a2 a1;
      let env' = bind env x2 a2 in
      sub env' loc note (subst_ty x1 (Logic.Var x2) b1) b2
  | Pair (a1, b1), Pair (a2, b2) ->
      sub env loc note a1 a2;
      sub env loc note b1 b2
  | _ ->
      Loc.type_error loc "this has type %s, but %s was expected" (show t1) (show t2)

(* Reading types and predicates out of the syntax tree. *)
let rec read_ty (e : Ast.t) : ty =
  match e.it with
  | Ast.Var "int" -> Base (BInt, "v", Logic.True)
  | Ast.Var "bool" -> Base (BBool, "v", Logic.True)
  | Ast.Var "unit" | Ast.Unit -> Base (BUnit, "v", Logic.True)
  | Ast.Refine (v, base, pred) -> (
      match read_ty base with
      | Base (b, _, Logic.True) -> Base (b, v, read_pred pred)
      | Base _ -> Loc.type_error e.loc "a refinement of a refinement is one too many"
      | _ -> Loc.type_error e.loc "only base types can be refined")
  | Ast.Arrow (Ast.Many, Some x, a, b) -> Fun (x, read_ty a, read_ty b)
  | Ast.Arrow (Ast.Many, None, a, b) -> Fun (fresh "_", read_ty a, read_ty b)
  | Ast.Arrow (Ast.One, _, _, _) ->
      Loc.type_error e.loc "`-o` is a linear arrow; try #system linear"
  | Ast.Bin ("*", a, b) -> Pair (read_ty a, read_ty b)
  | Ast.Forall _ ->
      Loc.type_error e.loc
        "the `refine` system is monomorphic; polymorphism lives in #system poly"
  | Ast.Rec _ | Ast.VariantTy _ ->
      Loc.type_error e.loc "records and variants belong to #system row"
  | Ast.Prod _ -> Loc.type_error e.loc "dependent pairs belong to #system dep"
  | Ast.Choice _ | Ast.Uop (("!" | "?"), _) ->
      Loc.type_error e.loc "session types belong to #system linear"
  | _ -> Loc.type_error e.loc "this is not a type"

(* A predicate is a term, restricted to what the logic can say. *)
and read_pred (e : Ast.t) : Logic.expr =
  match e.it with
  | Ast.Var x -> Logic.Var x
  | Ast.Int n -> Logic.Lit n
  | Ast.Bool true -> Logic.True
  | Ast.Bool false -> Logic.False
  | Ast.Bin ((("+" | "-" | "*" | "/" | "%") as op), a, b) ->
      Logic.Arith (op, read_pred a, read_pred b)
  | Ast.Bin ((("==" | "!=" | "<" | "<=" | ">" | ">=") as op), a, b) ->
      Logic.Cmp (op, read_pred a, read_pred b)
  | Ast.Bin ("&&", a, b) -> Logic.And (read_pred a, read_pred b)
  | Ast.Bin ("||", a, b) -> Logic.Or (read_pred a, read_pred b)
  | Ast.Bin ("==>", a, b) -> Logic.Imp (read_pred a, read_pred b)
  | Ast.Uop ("-", a) -> Logic.Neg (read_pred a)
  | Ast.App ({ it = Ast.Var "not"; _ }, a) -> Logic.Not (read_pred a)
  | Ast.If (c, a, b) -> Logic.Ite (read_pred c, read_pred a, read_pred b)
  | _ ->
      Loc.type_error e.loc
        "a refinement predicate is arithmetic, comparison and logic over the \
         names in scope; this is not"

let arith = [ "+"; "-"; "*"; "/"; "%" ]
let comparisons = [ "=="; "!="; "<"; "<="; ">"; ">=" ]

let int_ = Base (BInt, "v", Logic.True)
let bool_ = Base (BBool, "v", Logic.True)
let unit_ = Base (BUnit, "v", Logic.True)

(* `{ v : b | v == e }`: the type of something whose value is known exactly.
   Giving variables and literals their singleton types is what makes the
   implications above mention them at all. *)
let singleton b e = Base (b, "v", Logic.Cmp ("==", Logic.Var "v", e))

let initial_env () =
  let env = empty in
  let env = { env with binds = ("not", Fun ("_", bool_, bool_)) :: env.binds } in
  { env with binds = ("print", Fun ("_", int_, unit_)) :: env.binds }

let base_of loc t =
  match t with
  | Base (b, _, _) -> b
  | _ -> Loc.type_error loc "expected a base type, not %s" (show t)

let rec synth env (e : Ast.t) : ty * env =
  match e.it with
  | Ast.Int n -> (singleton BInt (Logic.Lit n), env)
  | Ast.Bool b -> (singleton BBool (if b then Logic.True else Logic.False), env)
  | Ast.Unit -> (unit_, env)
  | Ast.Var x -> (
      match List.assoc_opt x env.binds with
      | Some (Base (b, _, _)) -> (singleton b (Logic.Var x), env)
      | Some t -> (t, env)
      | None -> Loc.type_error e.loc "unbound variable %s" x)
  | Ast.Ann (body, ann) ->
      let t = read_ty ann in
      let env = check env body t in
      (t, env)
  | Ast.Lam (bs, body) -> synth_lam env e.loc bs body
  | Ast.App (f, a) ->
      let tf, env = synth env f in
      let x, dom, cod =
        match tf with
        | Fun (x, dom, cod) -> (x, dom, cod)
        | _ -> Loc.type_error e.loc "this is applied to an argument but has type %s" (show tf)
      in
      let env = check env a dom in
      let value, env = value_of env a dom in
      (subst_ty x value cod, env)
  | Ast.Bin (";", a, b) ->
      let _, env = synth env a in
      synth env b
  | Ast.Bin (op, a, b) when List.mem op arith ->
      let env = check env a int_ in
      let env = check env b int_ in
      let va, env = value_of env a int_ in
      let vb, env = value_of env b int_ in
      (* Division and modulo are the one place where a refinement is demanded
         of an operand rather than promised of a result. *)
      if op = "/" || op = "%" then
        vc env b.Ast.loc
          (Printf.sprintf "the right operand of `%s` must not be zero"
             (if op = "/" then "div" else "mod"))
          (Logic.Cmp ("!=", vb, Logic.Lit 0));
      (singleton BInt (Logic.Arith (op, va, vb)), env)
  | Ast.Bin ((("&&" | "||" | "==>") as op), a, b) ->
      let env = check env a bool_ in
      let env = check env b bool_ in
      let va, env = value_of env a bool_ in
      let vb, env = value_of env b bool_ in
      let p =
        match op with
        | "&&" -> Logic.And (va, vb)
        | "||" -> Logic.Or (va, vb)
        | _ -> Logic.Imp (va, vb)
      in
      (singleton BBool p, env)
  | Ast.Bin (op, a, b) when List.mem op comparisons ->
      let ta, env = synth env a in
      let b_base = base_of a.Ast.loc ta in
      let env = check env b (Base (b_base, "v", Logic.True)) in
      let va, env = value_of env a ta in
      let vb, env = value_of env b (Base (b_base, "v", Logic.True)) in
      (singleton BBool (Logic.Cmp (op, va, vb)), env)
  | Ast.Uop ("-", a) ->
      let env = check env a int_ in
      let va, env = value_of env a int_ in
      (singleton BInt (Logic.Neg va), env)
  | Ast.Pair (a, b) ->
      let ta, env = synth env a in
      let tb, env = synth env b in
      (Pair (ta, tb), env)
  | Ast.If (c, thn, els) ->
      let env = check env c bool_ in
      let vc_, env = value_of env c bool_ in
      let t, _ = synth (assume env vc_) thn in
      let _ = check (assume env (Logic.Not vc_)) els t in
      (t, env)
  | Ast.LetIn (d, body) ->
      let env = bind_decl env d in
      synth env body
  | Ast.Forall _ | Ast.Arrow _ | Ast.Refine _ | Ast.Prod _ ->
      Loc.type_error e.loc "a type cannot be used as a term"
  | Ast.Match _ ->
      Loc.type_error e.loc "the `refine` system has no variants to match on"
  | _ ->
      Loc.type_error e.loc
        "the `refine` system does not know this form (it has integers, \
         booleans, pairs and functions)"

(* A lambda can be synthesised only as far as its annotations go: the parameter
   types come from the binders and the result type from the annotation the
   declaration put on the body. *)
and synth_lam env loc bs body =
  match bs with
  | [] -> synth env body
  | b :: rest ->
      let dom =
        match b.Ast.bann with
        | Some ann -> read_ty ann
        | None ->
            Loc.type_error loc
              "the `refine` system needs a type for the parameter %s: it does \
               not invent refinements"
              b.Ast.bname
      in
      let inner = bind env b.Ast.bname dom in
      let cod, _ = synth_lam inner loc rest body in
      (Fun (b.Ast.bname, dom, cod), env)

and check env (e : Ast.t) (t : ty) : env =
  match (e.it, t) with
  | Ast.Lam (bs, body), Fun _ -> check_lam env e.loc bs body t
  | Ast.If (c, thn, els), _ ->
      let env = check env c bool_ in
      let v, env = value_of env c bool_ in
      let _ = check (assume env v) thn t in
      let _ = check (assume env (Logic.Not v)) els t in
      env
  | Ast.LetIn (d, body), _ ->
      let inner = bind_decl env d in
      let _ = check inner body t in
      env
  | Ast.Bin (";", a, b), _ ->
      let _, env = synth env a in
      check env b t
  | Ast.Pair (a, b), Pair (ta, tb) ->
      let env = check env a ta in
      check env b tb
  | _ ->
      let t', env = synth env e in
      sub env e.loc (Printf.sprintf "checking that this has type %s" (show t)) t' t;
      env

and check_lam env loc bs body t =
  match (bs, t) with
  | [], _ -> check env body t
  | b :: rest, Fun (x, dom, cod) ->
      (match b.Ast.bann with
      | None -> ()
      | Some ann ->
          let declared = read_ty ann in
          sub env loc "the parameter's own type must accept what is passed" dom
            declared);
      let inner = bind env b.Ast.bname dom in
      let cod = subst_ty x (Logic.Var b.Ast.bname) cod in
      let _ = match rest with [] -> check inner body cod | _ -> check_lam inner loc rest body cod in
      env
  | b :: _, _ ->
      Loc.type_error loc "%s is a parameter, but the expected type is %s"
        b.Ast.bname (show t)

(* The logical value of an expression.  Names and literals denote themselves;
   anything else is given a name first, which is exactly what normalising to
   A-normal form would have done. *)
and value_of env (e : Ast.t) (t : ty) : Logic.expr * env =
  match e.it with
  | Ast.Var x -> (Logic.Var x, env)
  | Ast.Int n -> (Logic.Lit n, env)
  | Ast.Bool true -> (Logic.True, env)
  | Ast.Bool false -> (Logic.False, env)
  | Ast.Uop ("-", a) ->
      let v, env = value_of env a t in
      (Logic.Neg v, env)
  | Ast.Bin (op, a, b) when List.mem op arith && op <> "/" && op <> "%" ->
      let va, env = value_of env a t in
      let vb, env = value_of env b t in
      (Logic.Arith (op, va, vb), env)
  | _ -> (
      (* Give it a name, and remember everything its type says about it. *)
      match t with
      | Base (b, _, _) ->
          let t', _ = synth env e in
          let x = fresh "t" in
          let env = bind env x (match t' with Base _ -> t' | _ -> Base (b, "v", Logic.True)) in
          (Logic.Var x, env)
      | _ -> (Logic.Var (fresh "opaque"), env))

(* A declaration.  A `fun` is recursive, so its type has to be known before its
   body is checked, which in this system means it has to be written down. *)
and decl_ty (d : Ast.decl) : ty option =
  let rec go = function
    | [] -> Option.map read_ty d.Ast.dret
    | (b : Ast.binder) :: rest -> (
        match (b.bann, go rest) with
        | Some ann, Some cod -> Some (Fun (b.bname, read_ty ann, cod))
        | _ -> None)
  in
  go d.Ast.dparams

and bind_decl env (d : Ast.decl) : env =
  let name =
    match d.Ast.dpat with
    | Ast.DName x -> x
    | Ast.DUnit -> fresh "_"
    | Ast.DPair _ ->
        Loc.type_error d.Ast.dloc "the `refine` system has no pair patterns yet"
  in
  let body = Ast.decl_body d in
  if d.Ast.drec then
    match decl_ty d with
    | None ->
        Loc.type_error d.Ast.dloc
          "`fun %s` is recursive, so the `refine` system needs its parameter \
           and result types written out"
          name
    | Some t ->
        let inner = bind env name t in
        let _ = check inner body t in
        bind env name t
  else
    let t, _ = synth env body in
    bind env name t

let check_program (items : Ast.toplevel list) =
  let env = ref (initial_env ()) in
  List.filter_map
    (function
      | Ast.TType { tloc; _ } ->
          Loc.type_error tloc "the `refine` system has no type aliases yet"
      | Ast.TLet d ->
          env := bind_decl !env d;
          let name =
            match d.Ast.dpat with Ast.DName x -> x | _ -> "()"
          in
          let t =
            match List.assoc_opt name (!env).binds with
            | Some t -> t
            | None -> unit_
          in
          Some { System.rname = name; rtype = show t; rvalue = None })
    items

let system : System.t =
  {
    name = "refine";
    blurb = "refinement types: predicates on base types, discharged by a solver";
    check = check_program;
    runs = true;
  }
