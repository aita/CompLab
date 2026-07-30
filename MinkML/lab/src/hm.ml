(* The `hm` system: Hindley-Milner inference, as Algorithm W.

   This is the baseline the other systems are variations on, and it is written
   the way the algorithm is presented on paper rather than the way an efficient
   implementation would do it:

     * A substitution is a finite map from type variables to types, and
       unification *returns* one.  Nothing is mutated.  Composing those
       substitutions and applying them at the right moments is most of the
       code.
     * Generalisation asks which variables are free in the type but not in the
       environment, which means walking the whole environment at every `let`.

   Both of those are what the `row` system replaces: there, unification links
   mutable cells destructively, and generalisation compares a level number
   instead of scanning the environment.  The two agree on every program they
   both accept -- tests/compare.mnk is checked by each of them and both outputs
   are in the same golden file -- so what is left to compare is the mechanism.

   Set `--dump-infer` to watch the substitutions being built. *)

type ty =
  | TCon of string (* int, bool, unit, and rigid names from annotations *)
  | TVar of string (* a unification variable *)
  | TArrow of ty * ty
  | TPair of ty * ty

(* A scheme is a type with some of its variables quantified.  Only `let` and
   the top level introduce them, which is what "let-polymorphism" means. *)
type scheme = Forall of string list * ty

module Vars = Set.Make (String)
module Map = Stdlib.Map.Make (String)

type subst = ty Map.t
type env = scheme Map.t

let counter = ref 0
let trace = ref false

let fresh () =
  incr counter;
  TVar (Printf.sprintf "?%d" !counter)

let reset () = counter := 0

let rec show ?(prec = 0) t =
  let paren p s = if prec > p then "(" ^ s ^ ")" else s in
  match t with
  | TCon c -> c
  | TVar v -> v
  | TArrow (a, b) -> paren 1 (Printf.sprintf "%s -> %s" (show ~prec:2 a) (show ~prec:1 b))
  | TPair (a, b) -> paren 3 (Printf.sprintf "%s * %s" (show ~prec:4 a) (show ~prec:4 b))

(* Printing a scheme renames its quantified variables to 'a, 'b, ... so that the
   same type always prints the same way, whatever the counter happens to be. *)
let show_scheme (Forall (vs, t)) =
  let supply = [| "'a"; "'b"; "'c"; "'d"; "'e"; "'f"; "'g"; "'h" |] in
  (* Named in the order they appear in the type, not the order they were
     created, so that the same type always prints the same way -- and prints the
     same way the `row` system prints it. *)
  let order = ref [] in
  let rec walk = function
    | TVar v -> if List.mem v vs && not (List.mem v !order) then order := !order @ [ v ]
    | TArrow (a, b) | TPair (a, b) ->
        walk a;
        walk b
    | TCon _ -> ()
  in
  walk t;
  let vs = !order @ List.filter (fun v -> not (List.mem v !order)) vs in
  let names =
    List.mapi
      (fun i v ->
        ( v,
          TCon
            (if i < Array.length supply then supply.(i)
             else Printf.sprintf "'t%d" i) ))
      vs
  in
  let rec go t =
    match t with
    | TVar v -> ( match List.assoc_opt v names with Some n -> n | None -> t)
    | TArrow (a, b) -> TArrow (go a, go b)
    | TPair (a, b) -> TPair (go a, go b)
    | TCon _ -> t
  in
  let body = show (go t) in
  match vs with
  | [] -> body
  | _ -> Printf.sprintf "forall %s. %s" (String.concat " " (List.map (fun (_, n) -> show n) names)) body

let log fmt =
  if !trace then Printf.ksprintf (fun s -> print_endline ("  " ^ s)) fmt
  else Printf.ksprintf (fun _ -> ()) fmt

(* Substitutions. *)

let rec apply (s : subst) t =
  match t with
  | TVar v -> ( match Map.find_opt v s with Some t' -> apply s t' | None -> t)
  | TArrow (a, b) -> TArrow (apply s a, apply s b)
  | TPair (a, b) -> TPair (apply s a, apply s b)
  | TCon _ -> t

let apply_scheme s (Forall (vs, t)) =
  (* The quantified variables are bound here, so the substitution must not
     touch them. *)
  let s = List.fold_left (fun s v -> Map.remove v s) s vs in
  Forall (vs, apply s t)

let apply_env s (env : env) = Map.map (apply_scheme s) env

(* s2 after s1.  Applying the result is the same as applying s1 and then s2. *)
let compose (s2 : subst) (s1 : subst) : subst =
  Map.union (fun _ a _ -> Some a) s2 (Map.map (apply s2) s1)

let empty_subst : subst = Map.empty

let rec ftv = function
  | TVar v -> Vars.singleton v
  | TArrow (a, b) | TPair (a, b) -> Vars.union (ftv a) (ftv b)
  | TCon _ -> Vars.empty

let ftv_scheme (Forall (vs, t)) = Vars.diff (ftv t) (Vars.of_list vs)

let ftv_env (env : env) =
  Map.fold (fun _ sch acc -> Vars.union acc (ftv_scheme sch)) env Vars.empty

(* Unification.  It returns the substitution that makes the two types equal, or
   fails.  The occurs check is what stops `?1 = ?1 -> ?1`. *)
let rec unify loc t1 t2 : subst =
  log "unify  %s  ~  %s" (show t1) (show t2);
  match (t1, t2) with
  | TCon a, TCon b when a = b -> empty_subst
  | TVar a, TVar b when a = b -> empty_subst
  | TVar a, t | t, TVar a ->
      if Vars.mem a (ftv t) then
        Loc.type_error loc "this type would contain itself: %s occurs in %s" a
          (show t);
      log "solve  %s := %s" a (show t);
      Map.singleton a t
  | TArrow (a1, b1), TArrow (a2, b2) | TPair (a1, b1), TPair (a2, b2) ->
      let s1 = unify loc a1 a2 in
      let s2 = unify loc (apply s1 b1) (apply s1 b2) in
      compose s2 s1
  | _ -> Loc.type_error loc "cannot unify %s with %s" (show t1) (show t2)

let instantiate (Forall (vs, t)) =
  let s = List.fold_left (fun s v -> Map.add v (fresh ()) s) empty_subst vs in
  let t' = apply s t in
  if vs <> [] then log "instantiate %s  as  %s" (show_scheme (Forall (vs, t))) (show t');
  t'

(* Generalisation: quantify what the type has and the environment does not.
   The environment scan is the price of not having levels. *)
let generalize (env : env) t =
  let vs = Vars.elements (Vars.diff (ftv t) (ftv_env env)) in
  let sch = Forall (vs, t) in
  log "generalise %s  over env {%s}  =>  %s" (show t)
    (String.concat ", " (Vars.elements (ftv_env env)))
    (show_scheme sch);
  sch

(* Reading a type out of an annotation.  Unknown names become rigid constants
   while the body is checked, and are quantified again afterwards, so an
   annotation is a promise and not a wish -- the same treatment as in `row`. *)
type state = { mutable rigids : string list }

let rec read_ty st (e : Ast.t) : ty =
  match e.it with
  | Ast.Var "int" -> TCon "int"
  | Ast.Var "bool" -> TCon "bool"
  | Ast.Var "unit" | Ast.Unit -> TCon "unit"
  | Ast.Var x ->
      if not (List.mem x st.rigids) then st.rigids <- x :: st.rigids;
      TCon x
  | Ast.Arrow (Ast.Many, None, a, b) -> TArrow (read_ty st a, read_ty st b)
  | Ast.Arrow (Ast.One, _, _, _) ->
      Loc.type_error e.loc "`-o` is a linear arrow; try #system linear"
  | Ast.Arrow (_, Some _, _, _) ->
      Loc.type_error e.loc
        "a named argument needs #system refine or #system dep"
  | Ast.Bin ("*", a, b) -> TPair (read_ty st a, read_ty st b)
  | Ast.Forall (_, body) -> read_ty st body
  | Ast.Rec _ | Ast.VariantTy _ ->
      Loc.type_error e.loc "records and variants belong to #system row"
  | Ast.Refine _ -> Loc.type_error e.loc "refinement types belong to #system refine"
  | Ast.Prod _ -> Loc.type_error e.loc "dependent pairs belong to #system dep"
  | Ast.Choice _ | Ast.Uop (("!" | "?"), _) ->
      Loc.type_error e.loc "session types belong to #system linear"
  | _ -> Loc.type_error e.loc "this is not a type"

(* Turning the rigid constants back into quantified variables. *)
let quantify_rigids st t =
  let names = List.map (fun n -> (n, fresh ())) st.rigids in
  let rec go t =
    match t with
    | TCon c -> ( match List.assoc_opt c names with Some v -> v | None -> t)
    | TArrow (a, b) -> TArrow (go a, go b)
    | TPair (a, b) -> TPair (go a, go b)
    | TVar _ -> t
  in
  go t

let arith = [ "+"; "-"; "*"; "/"; "%" ]
let comparisons = [ "=="; "!="; "<"; "<="; ">"; ">=" ]

let initial_env () =
  let a = TVar "?a" and b = TVar "?b" in
  List.fold_left
    (fun env (n, sch) -> Map.add n sch env)
    Map.empty
    [
      ("not", Forall ([], TArrow (TCon "bool", TCon "bool")));
      ("print", Forall ([ "?a" ], TArrow (a, TCon "unit")));
      ("fst", Forall ([ "?a"; "?b" ], TArrow (TPair (a, b), a)));
      ("snd", Forall ([ "?a"; "?b" ], TArrow (TPair (a, b), b)));
    ]

(* Algorithm W: infer returns a substitution and a type.  Every case that has
   two subterms threads the substitution from the first into the environment of
   the second -- forgetting to do that is the classic way to get this wrong. *)
let rec infer st (env : env) (e : Ast.t) : subst * ty =
  match e.it with
  | Ast.Int _ -> (empty_subst, TCon "int")
  | Ast.Bool _ -> (empty_subst, TCon "bool")
  | Ast.Unit -> (empty_subst, TCon "unit")
  | Ast.Var x -> (
      match Map.find_opt x env with
      | Some sch -> (empty_subst, instantiate sch)
      | None -> Loc.type_error e.loc "unbound variable %s" x)
  | Ast.Ann (body, ann) ->
      let want = read_ty st ann in
      let s1, got = infer st env body in
      let s2 = unify e.loc got (apply s1 want) in
      (compose s2 s1, apply s2 want)
  | Ast.Lam (bs, body) -> infer_lam st env bs body
  | Ast.App (f, a) ->
      let s1, tf = infer st env f in
      let s2, ta = infer st (apply_env s1 env) a in
      let res = fresh () in
      let s3 = unify e.loc (apply s2 tf) (TArrow (ta, res)) in
      (compose s3 (compose s2 s1), apply s3 res)
  | Ast.LetIn (d, body) ->
      let s1, env' = bind_decl st env d in
      let s2, t = infer st env' body in
      (compose s2 s1, t)
  | Ast.If (c, thn, els) ->
      let s1, tc = infer st env c in
      let s2 = unify c.Ast.loc (apply s1 tc) (TCon "bool") in
      let s = compose s2 s1 in
      let s3, t1 = infer st (apply_env s env) thn in
      let s = compose s3 s in
      let s4, t2 = infer st (apply_env s env) els in
      let s = compose s4 s in
      let s5 = unify e.loc (apply s t1) (apply s t2) in
      (compose s5 s, apply s5 (apply s t1))
  | Ast.Pair (a, b) ->
      let s1, ta = infer st env a in
      let s2, tb = infer st (apply_env s1 env) b in
      (compose s2 s1, TPair (apply s2 ta, tb))
  | Ast.Bin (";", a, b) ->
      let s1, _ = infer st env a in
      let s2, t = infer st (apply_env s1 env) b in
      (compose s2 s1, t)
  | Ast.Bin (op, a, b) when List.mem op arith ->
      let s = binary st env a b (TCon "int") in
      (s, TCon "int")
  | Ast.Bin (("&&" | "||" | "==>"), a, b) ->
      let s = binary st env a b (TCon "bool") in
      (s, TCon "bool")
  | Ast.Bin (op, a, b) when List.mem op comparisons ->
      let s1, ta = infer st env a in
      let s2, tb = infer st (apply_env s1 env) b in
      let s = compose s2 s1 in
      let s3 = unify e.loc (apply s ta) (apply s tb) in
      (compose s3 s, TCon "bool")
  | Ast.Uop ("-", a) ->
      let s1, ta = infer st env a in
      let s2 = unify e.loc (apply s1 ta) (TCon "int") in
      (compose s2 s1, TCon "int")
  | Ast.Uop ("not", a) ->
      let s1, ta = infer st env a in
      let s2 = unify e.loc (apply s1 ta) (TCon "bool") in
      (compose s2 s1, TCon "bool")
  | Ast.Match _ ->
      Loc.type_error e.loc
        "the `hm` system has no variants; records and variants are #system row"
  | Ast.Proj _ | Ast.Restrict _ | Ast.Inject _ ->
      Loc.type_error e.loc "records and variants belong to #system row"
  | Ast.Select _ | Ast.Branch _ ->
      Loc.type_error e.loc "channels belong to #system linear"
  | Ast.Arrow _ | Ast.Forall _ | Ast.Refine _ | Ast.Prod _ | Ast.Choice _
  | Ast.Rec _ | Ast.VariantTy _ | Ast.Uop (("!" | "?"), _) ->
      Loc.type_error e.loc "a type cannot be used as a term"
  | Ast.Uop (op, _) | Ast.Bin (op, _, _) ->
      Loc.type_error e.loc "no operator %s here" op

and binary st env a b want =
  let s1, ta = infer st env a in
  let s2 = unify a.Ast.loc (apply s1 ta) want in
  let s = compose s2 s1 in
  let s3, tb = infer st (apply_env s env) b in
  let s = compose s3 s in
  let s4 = unify b.Ast.loc (apply s tb) want in
  compose s4 s

and infer_lam st env bs body =
  match bs with
  | [] -> infer st env body
  | b :: rest ->
      let dom =
        match b.Ast.bann with Some ann -> read_ty st ann | None -> fresh ()
      in
      let env' = Map.add b.Ast.bname (Forall ([], dom)) env in
      let s, cod = infer_lam st env' rest body in
      (s, TArrow (apply s dom, cod))

(* A declaration.  `val` generalises what it inferred; `fun` is recursive, so
   its own name is in scope as a monotype while its body is checked, and only
   then generalised -- which is exactly why polymorphic recursion needs an
   annotation in every HM language. *)
and bind_decl st (env : env) (d : Ast.decl) : subst * env =
  st.rigids <- [];
  let body = Ast.decl_body d in
  let name =
    match d.Ast.dpat with
    | Ast.DName x -> x
    | Ast.DUnit -> "_"
    | Ast.DPair _ ->
        Loc.type_error d.Ast.dloc "the `hm` system has no pair patterns in val"
  in
  if !trace then print_endline (Printf.sprintf "-- infer %s" name);
  let s, t =
    if d.Ast.drec then
      let self = fresh () in
      let env' = Map.add name (Forall ([], self)) env in
      let s1, t = infer st env' body in
      let s2 = unify d.Ast.dloc (apply s1 self) t in
      (compose s2 s1, apply s2 t)
    else infer st env body
  in
  let env = apply_env s env in
  let t = if st.rigids = [] then t else quantify_rigids st t in
  let sch = generalize env t in
  (s, Map.add name sch env)

let check_program (items : Ast.toplevel list) =
  reset ();
  let st = { rigids = [] } in
  let env = ref (initial_env ()) in
  List.filter_map
    (function
      | Ast.TType { tloc; _ } ->
          Loc.type_error tloc "the `hm` system has no type aliases"
      | Ast.TLet d ->
          let _, env' = bind_decl st !env d in
          env := env';
          let name =
            match d.Ast.dpat with Ast.DName x -> x | _ -> "()"
          in
          Some
            {
              System.rname = name;
              rtype =
                (match Map.find_opt name !env with
                | Some sch -> show_scheme sch
                | None -> "unit");
              rvalue = None;
            })
    items

let system : System.t =
  {
    name = "hm";
    blurb = "Hindley-Milner inference as Algorithm W: substitutions, composed by hand";
    check = check_program;
    runs = true;
  }
