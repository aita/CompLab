(* Type checking, and with it the module system.

   The core is Hindley-Milner with levels (Types).  What is above it is the
   part the grammar asks for and a core-only ML does not have: sig, mod,
   parameterized mod, "where type", and the rule that a signature seals what
   it is given.

   A signature is elaborated twice against the module it is matched with.
   Once realized -- every abstract type in it standing for the type the module
   actually has -- and that copy is what the values are checked against, so
   that the check knows t is int when it has to.  Once sealed -- every
   abstract type in it a type constructor nobody else has -- and that copy is
   what the rest of the program sees.  The two elaborations are the same
   function with one argument different, and the second one is what makes
   ascription opaque.

   A functor keeps its body as syntax and elaborates it again at every
   application.  That is what generativity is: two applications run the
   elaboration twice, so the abstract types they produce are two different
   type constructors, and no argument can be matched against a parameter
   without the body being read in terms of that argument.  It is checked once
   at its definition too, against a parameter that is nothing but its
   signature, so that a body that could never work is rejected where it is
   written. *)

open Ast
module SMap = Map.Make (String)

type sg = {
  sg_types : Types.tycon SMap.t;
  sg_cons : Types.con SMap.t;
  sg_vals : Types.scheme SMap.t;
  sg_mods : mv SMap.t;
}

and mv =
  | SStruct of sg
  | SFunctor of fsig

and fsig = {
  fs_params : (string * sigexp) list;
  fs_ascr : sigexp option;
  fs_body : decl list;
  fs_env : tenv;
}

and tenv = {
  te_types : Types.tycon SMap.t;
  te_cons : Types.con SMap.t;
  te_vals : Types.scheme SMap.t;
  te_mods : mv SMap.t;
  te_sigs : spec list SMap.t;
}

let empty_sg =
  { sg_types = SMap.empty; sg_cons = SMap.empty; sg_vals = SMap.empty; sg_mods = SMap.empty }

let union a b = SMap.union (fun _ _ y -> Some y) a b

let merge_sg env s =
  { env with
    te_types = union env.te_types s.sg_types;
    te_cons = union env.te_cons s.sg_cons;
    te_vals = union env.te_vals s.sg_vals;
    te_mods = union env.te_mods s.sg_mods }

let merge_sgs a b =
  { sg_types = union a.sg_types b.sg_types;
    sg_cons = union a.sg_cons b.sg_cons;
    sg_vals = union a.sg_vals b.sg_vals;
    sg_mods = union a.sg_mods b.sg_mods }

let unify loc a b =
  try Types.unify a b with Types.Clash m -> Diag.at loc "%s" m

let unify_why loc why a b =
  try Types.unify a b with Types.Clash m -> Diag.at loc "%s: %s" why m

(* the same, where saying what was being unified would cost a string on every
   call and is only ever read on the ones that fail *)
let unify_lazy loc why a b =
  try Types.unify a b with Types.Clash m -> Diag.at loc "%s: %s" (why ()) m

let rec walk_ty f t =
  match Types.repr t with
  | Types.TVar r -> f r
  | Types.TApp (_, args) -> List.iter (walk_ty f) args
  | Types.TArrow (a, b) -> walk_ty f a; walk_ty f b
  | Types.TTup ts -> List.iter (walk_ty f) ts
  | Types.TRecord row -> walk_ty f row
  | Types.TRowNil -> ()
  | Types.TRowCons (_, t, rest) -> walk_ty f t; walk_ty f rest

(* Quantify: the rigid variables of an annotation that this type uses, and
   then everything above the current level. *)
let close rigids t =
  let used = ref [] in
  walk_ty (fun r -> if List.memq r rigids && not (List.memq r !used) then used := r :: !used) t;
  { Types.s_vars = List.rev !used @ Types.free_vars t; s_body = t }

(* ------------------------------------------------------------------
 * Paths
 * ------------------------------------------------------------------ *)

let rec walk_mods loc mods = function
  | [] -> assert false
  | [ n ] -> (
    match SMap.find_opt n mods with
    | Some m -> m
    | None -> Diag.at loc "there is no module %s here" n)
  | n :: rest -> (
    match SMap.find_opt n mods with
    | Some (SStruct s) -> walk_mods loc s.sg_mods rest
    | Some (SFunctor _) -> Diag.at loc "%s is a functor, so it has no members" n
    | None -> Diag.at loc "there is no module %s here" n)

let struct_at loc env path =
  match walk_mods loc env.te_mods path with
  | SStruct s -> s
  | SFunctor _ -> Diag.at loc "%s is a functor, so it has no members" (String.concat "." path)

let lookup_tycon loc env (path, n) =
  let tys = match path with [] -> env.te_types | p -> (struct_at loc env p).sg_types in
  match SMap.find_opt n tys with
  | Some tc -> tc
  | None -> Diag.at loc "there is no type %s" (show_path (path, n))

let lookup_val loc env (path, n) =
  let vs = match path with [] -> env.te_vals | p -> (struct_at loc env p).sg_vals in
  match SMap.find_opt n vs with
  | Some s -> s
  | None -> Diag.at loc "%s is not bound" (show_path (path, n))

let lookup_con loc env (path, n) =
  let cs = match path with [] -> env.te_cons | p -> (struct_at loc env p).sg_cons in
  match SMap.find_opt n cs with
  | Some c -> c
  | None -> Diag.at loc "%s is not a constructor" (show_path (path, n))

(* ------------------------------------------------------------------
 * Types, from syntax
 * ------------------------------------------------------------------ *)

type tvs = { mutable tvm : (string * Types.ty) list; tvnew : (unit -> Types.ty) option }

let fixed ps = { tvm = ps; tvnew = None }
let rigids () = { tvm = []; tvnew = Some (fun () -> Types.TVar (Types.newrigid "a")) }
let opens () = { tvm = []; tvnew = Some (fun () -> Types.newvar ()) }

let sort_fields loc what fs =
  let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) fs in
  let rec dup = function
    | (a, _) :: ((b, _) :: _ as rest) ->
      if String.equal a b then Diag.at loc "%s mentions the field %s twice" what a else dup rest
    | _ -> ()
  in
  dup sorted;
  sorted

(* A type variable standing in a row position is a row variable, and it must
   lack the fields the record already shows. *)
let row_var loc tvs n lacks =
  let t =
    match List.assoc_opt n tvs.tvm with
    | Some t -> t
    | None -> (
      match tvs.tvnew with
      | Some f ->
        let t = f () in
        tvs.tvm <- (n, t) :: tvs.tvm;
        t
      | None -> Diag.at loc "the type variable \'%s is not a parameter of this type" n)
  in
  (match t with
   | Types.TVar ({ contents = Types.Unbound (id, lv, c) } as r) ->
     r := Types.Unbound (id, lv, Types.merge_cls c (Types.Row lacks))
   | Types.TVar ({ contents = Types.Rigid (name, c) } as r) ->
     r := Types.Rigid (name, Types.merge_cls c (Types.Row lacks))
   | _ -> Diag.at loc "\'%s is not a row here" n);
  t

let rec elab_ty env tvs (ty : Ast.ty) : Types.ty =
  let loc = ty.tloc in
  match ty.t with
  | Ast.TVar n -> (
    match List.assoc_opt n tvs.tvm with
    | Some t -> t
    | None -> (
      match tvs.tvnew with
      | Some f ->
        let t = f () in
        tvs.tvm <- (n, t) :: tvs.tvm;
        t
      | None -> Diag.at loc "the type variable '%s is not a parameter of this type" n))
  | Ast.TCon (q, args) ->
    let tc = lookup_tycon loc env q in
    let args = List.map (elab_ty env tvs) args in
    if List.length args <> Types.arity tc then
      Diag.at loc "%s takes %d type argument%s, not %d" (show_path q) (Types.arity tc)
        (if Types.arity tc = 1 then "" else "s")
        (List.length args);
    Types.apply_tycon tc args
  | Ast.TArrow (a, b) -> Types.TArrow (elab_ty env tvs a, elab_ty env tvs b)
  | Ast.TTuple ts -> Types.TTup (List.map (elab_ty env tvs) ts)
  | Ast.TRec (fs, rest) ->
    let fs = sort_fields loc "this record type" (List.map (fun (f, t) -> (f, elab_ty env tvs t)) fs) in
    let tail =
      match rest with
      | None -> Types.TRowNil
      | Some n -> row_var loc tvs n (List.map fst fs)
    in
    Types.TRecord (Types.row_of_fields fs tail)

(* A constructor, as a type: its argument arrow, or the datatype itself. *)
let con_ty (c : Types.con) =
  let tc = c.Types.con_tycon in
  let args = List.map (fun _ -> Types.newvar ()) tc.Types.tc_params in
  let map = List.combine tc.Types.tc_params args in
  let result = Types.TApp (tc, args) in
  match c.Types.con_arg with
  | None -> (None, result)
  | Some a -> (Some (Types.subst map a), result)

(* ------------------------------------------------------------------
 * Patterns
 * ------------------------------------------------------------------ *)

let rec infer_pat env p : Types.ty * (string * Types.ty) list =
  match p.p with
  | PWild -> (Types.newvar (), [])
  | PVar n ->
    let t = Types.newvar () in
    (t, [ (n, t) ])
  | PLit LUnit -> (Types.t_unit, [])
  | PLit (LInt _) -> (Types.t_int, [])
  | PLit (LReal _) -> (Types.t_real, [])
  | PLit (LChar _) -> (Types.t_char, [])
  | PLit (LString _) -> (Types.t_string, [])
  | PLit (LBool _) -> (Types.t_bool, [])
  | PCon (q, arg) -> (
    let c = lookup_con p.ploc env q in
    let argt, result = con_ty c in
    match (argt, arg) with
    | None, None -> (result, [])
    | Some a, Some ap ->
      let t, bs = infer_pat env ap in
      unify_lazy p.ploc (fun () -> "the argument of " ^ show_path q) a t;
      (result, bs)
    | Some _, None -> Diag.at p.ploc "%s takes an argument" (show_path q)
    | None, Some _ -> Diag.at p.ploc "%s takes no argument" (show_path q))
  | PTuple ps ->
    let ts, bss = List.split (List.map (infer_pat env) ps) in
    (Types.TTup ts, List.concat bss)
  | PRec fs ->
    (* open: a record pattern asks for the fields it names and says nothing
       about the rest, which is what makes it match any record that has them *)
    let fs = List.map (fun (f, p) -> (f, infer_pat env p)) fs in
    let ts = sort_fields p.ploc "this record pattern" (List.map (fun (f, (t, _)) -> (f, t)) fs) in
    let rest = Types.newrow (List.map fst ts) in
    (Types.TRecord (Types.row_of_fields ts rest), List.concat_map (fun (_, (_, bs)) -> bs) fs)
  | PAnn (inner, t) ->
    let ty = elab_ty env (opens ()) t in
    let pt, bs = infer_pat env inner in
    unify_why p.ploc "this pattern does not have the type it is given" pt ty;
    (ty, bs)

let check_linear loc bs =
  let rec go seen = function
    | [] -> ()
    | (n, _) :: rest ->
      if List.mem n seen then Diag.at loc "%s is bound twice in this pattern" n;
      go (n :: seen) rest
  in
  go [] bs

(* ------------------------------------------------------------------
 * Coverage
 * ------------------------------------------------------------------ *)

let warn loc fmt =
  Printf.ksprintf (fun m -> prerr_endline ("warning: " ^ Diag.where loc ^ ": " ^ m)) fmt

(* A constructor always converts to the same head, so the heads are built once
   per constructor rather than once per pattern. *)
let con_heads : (int * string, Exhaust.head) Hashtbl.t = Hashtbl.create 64

let head_of (c : Types.con) name arity =
  let tc = c.Types.con_tycon in
  let key = (tc.Types.tc_id, name) in
  match Hashtbl.find_opt con_heads key with
  | Some h -> h
  | None ->
    let all =
      match tc.Types.tc_def with
      | Types.Variant cs ->
        Some (List.map (fun (n, a) -> (n, if a = None then 0 else 1)) cs)
      | _ -> None
    in
    let h = { Exhaust.h_name = name; h_arity = arity; h_all = all; h_fields = None } in
    Hashtbl.add con_heads key h;
    h

(* A pattern, as the matrix wants it.  The type comes along because a record
   pattern names only the fields it cares about while the column it sits in
   must agree on all of them: the labels are taken from the record's row, not
   from the pattern, and a field the pattern does not name is a wildcard.
   Everything else takes its type only to pass it down. *)
let rec to_spat env ty p =
  match p.p with
  | PWild | PVar _ -> Exhaust.SWild
  | PAnn (inner, _) -> to_spat env ty inner
  | PLit LUnit -> Exhaust.SCon (Exhaust.unit_head, [])
  | PLit (LBool b) -> Exhaust.SCon (Exhaust.bool_head b, [])
  | PLit (LInt n) -> Exhaust.SCon (Exhaust.atom (string_of_int n), [])
  | PLit (LReal r) -> Exhaust.SCon (Exhaust.atom (Printf.sprintf "%g" r), [])
  | PLit (LChar c) -> Exhaust.SCon (Exhaust.atom (Printf.sprintf "'%s'" (Char.escaped c)), [])
  | PLit (LString s) -> Exhaust.SCon (Exhaust.atom (Printf.sprintf "%S" s), [])
  | PCon (q, arg) -> (
    let c = lookup_con p.ploc env q in
    match arg with
    | None -> Exhaust.SCon (head_of c (snd q) 0, [])
    | Some a -> Exhaust.SCon (head_of c (snd q) 1, [ to_spat env (con_arg_ty c ty) a ]))
  | PTuple ps ->
    let ts =
      match Types.head ty with
      | Types.TTup ts when List.length ts = List.length ps -> ts
      | _ -> List.map (fun _ -> Types.newvar ()) ps
    in
    Exhaust.SCon (Exhaust.tuple_head (List.length ps), List.map2 (to_spat env) ts ps)
  | PRec fs ->
    let labels =
      match Types.head ty with
      | Types.TRecord row -> fst (Types.row_parts row)
      | _ -> List.map (fun (f, _) -> (f, Types.newvar ())) fs
    in
    let labels = List.sort (fun (a, _) (b, _) -> String.compare a b) labels in
    let arg (l, lt) =
      match List.assoc_opt l fs with Some sub -> to_spat env lt sub | None -> Exhaust.SWild
    in
    Exhaust.SCon (Exhaust.record_head (List.map fst labels), List.map arg labels)

(* The type a constructor's argument has, given the type of the whole.  The
   result of [con_ty] is fresh, so agreeing it with a type that is already
   known can only fill the fresh side in. *)
and con_arg_ty (c : Types.con) ty =
  match (con_ty c, Types.head ty) with
  | (Some a, result), Types.TApp (tc, _) when tc == c.Types.con_tycon ->
    (try Types.unify result ty with Types.Clash _ -> ());
    a
  | (Some a, _), _ -> a
  | (None, _), _ -> Types.newvar ()

(* A pattern that cannot fail.  One rule with one of these is every match a
   desugared "fun" of one clause leaves behind, and there is nothing to ask
   about it. *)
let rec irrefutable p =
  match p.p with PVar _ | PWild -> true | PAnn (p, _) -> irrefutable p | _ -> false

let check_coverage env what loc ty rs =
  match rs with
  | [ { r_pat; r_guard = None; _ } ] when irrefutable r_pat -> ()
  | _ ->
  let entries =
    List.map (fun r -> (r.r_pat.ploc, to_spat env ty r.r_pat, r.r_guard <> None)) rs
  in
  let plain = List.filter_map (fun (_, p, g) -> if g then None else Some p) entries in
  (match Exhaust.uncovered plain with
   | Some w -> warn loc "this %s does not match every value: %s is not matched" what w
   | None -> ());
  let seen = Exhaust.no_rules () in
  List.iter
    (fun (rloc, p, guarded) ->
      if not guarded then begin
        if not (Exhaust.reachable seen p) then warn rloc "this rule cannot be reached";
        Exhaust.remember seen p
      end)
    entries

let bind_mono env bs =
  { env with
    te_vals = List.fold_left (fun m (n, t) -> SMap.add n (Types.mono t) m) env.te_vals bs }

(* ------------------------------------------------------------------
 * Expressions
 * ------------------------------------------------------------------ *)

let rec infer env e : Types.ty =
  match e.e with
  | ELit LUnit -> Types.t_unit
  | ELit (LInt _) -> Types.t_int
  | ELit (LReal _) -> Types.t_real
  | ELit (LChar _) -> Types.t_char
  | ELit (LString _) -> Types.t_string
  | ELit (LBool _) -> Types.t_bool
  | EVar q -> Types.instantiate (lookup_val e.eloc env q)
  | ECon q -> (
    let c = lookup_con e.eloc env q in
    match con_ty c with
    | None, result -> result
    | Some a, result -> Types.TArrow (a, result))
  | EFn rs -> infer_rules env rs
  | EApp (f, a) ->
    let ft = infer env f in
    let at = infer env a in
    let res = Types.newvar () in
    unify_why a.eloc "this argument does not fit" ft (Types.TArrow (at, res));
    res
  | EInfix _ -> Diag.at e.eloc "internal: an infix chain reached the type checker"
  | EUn ("-", a) ->
    let t = infer env a in
    unify_why e.eloc "negation" t (Types.newvar ~cls:Types.Num ());
    t
  | EUn ("not", a) ->
    unify_why e.eloc "not" (infer env a) Types.t_bool;
    Types.t_bool
  | EUn (o, _) -> Diag.at e.eloc "unknown prefix operator %s" o
  | EProj (r, f) ->
    let res = Types.newvar () in
    let rest = Types.newrow [ f ] in
    unify_lazy e.eloc
      (fun () -> "the record this ." ^ f ^ " is taken from")
      (infer env r)
      (Types.TRecord (Types.TRowCons (f, res, rest)));
    res
  | ETuple es -> Types.TTup (List.map (infer env) es)
  | ERec fs ->
    Types.record (sort_fields e.eloc "this record" (List.map (fun (f, v) -> (f, infer env v)) fs))
  | ELet (ds, b) ->
    let env, _ = decls env ds in
    infer env b
  | ESeq es ->
    let rec go = function
      | [] -> Types.t_unit
      | [ e ] -> infer env e
      | e :: rest ->
        unify_why e.eloc "everything but the last expression of begin must be unit" (infer env e)
          Types.t_unit;
        go rest
    in
    go es
  | EIf (c, t, f) ->
    unify_why c.eloc "the condition of if" (infer env c) Types.t_bool;
    let tt = infer env t in
    unify_why f.eloc "the two branches of if" tt (infer env f);
    tt
  | ECase (s, rs) ->
    let st = infer env s in
    let res = Types.newvar () in
    check_rules env st res rs;
    res
  | EAnd (a, b) | EOr (a, b) ->
    unify_why a.eloc "and / or take booleans" (infer env a) Types.t_bool;
    unify_why b.eloc "and / or take booleans" (infer env b) Types.t_bool;
    Types.t_bool
  | EAnn (a, t) ->
    let ty = elab_ty env (opens ()) t in
    check env a ty;
    ty

and infer_rules env rs =
  let arg = Types.newvar () and res = Types.newvar () in
  check_rules env arg res rs;
  Types.TArrow (arg, res)

and check_rules env arg res rs =
  List.iter
    (fun r ->
      let pt, bs = infer_pat env r.r_pat in
      check_linear r.r_pat.ploc bs;
      unify_why r.r_pat.ploc "these patterns" arg pt;
      let env = bind_mono env bs in
      (match r.r_guard with
       | Some g -> unify_why g.eloc "a guard" (infer env g) Types.t_bool
       | None -> ());
      check env r.r_body res)
    rs;
  match rs with
  | [] -> ()
  | r :: _ -> check_coverage env "match" r.r_pat.ploc arg rs

(* Checking against a type that is already known, rather than inferring one.
   It only goes as far as the forms that bind or branch, and everything else
   falls back to inference, but that is enough for the annotation on

     val nearer : point -> point -> point = fn a => fn b => ...

   to reach a and b, and so for a projection inside to know what it is taken
   from.  With no rows in the type system, an annotation is the only thing
   that can tell it. *)
and check env e expected =
  match e.e with
  | EFn rs -> (
    match Types.head expected with
    | Types.TArrow (a, b) -> check_rules env a b rs
    | _ -> unify_why e.eloc "this function" (infer env e) expected)
  | ELet (ds, b) ->
    let env, _ = decls env ds in
    check env b expected
  | EIf (c, t, f) ->
    unify_why c.eloc "the condition of if" (infer env c) Types.t_bool;
    check env t expected;
    check env f expected
  | ECase (s, rs) ->
    let st = infer env s in
    check_rules env st expected rs
  | ESeq es ->
    let rec go = function
      | [] -> unify_why e.eloc "an empty begin" Types.t_unit expected
      | [ last ] -> check env last expected
      | e :: rest ->
        unify_why e.eloc "everything but the last expression of begin must be unit" (infer env e)
          Types.t_unit;
        go rest
    in
    go es
  | EAnn (a, t) ->
    let ty = elab_ty env (opens ()) t in
    unify_why e.eloc "this type annotation" ty expected;
    check env a ty
  | _ -> unify_why e.eloc "this expression" (infer env e) expected

(* ------------------------------------------------------------------
 * Declarations
 * ------------------------------------------------------------------ *)

and decl env sg d : tenv * sg =
  match d.d with
  | DVal (p, ann, e) ->
    Types.enter ();
    let tv = rigids () in
    let pt, bs = infer_pat env p in
    check_linear d.dloc bs;
    (match Option.map (elab_ty env tv) ann with
     | Some a ->
       unify_why d.dloc "this pattern does not have the type this val is given" pt a;
       check env e a
     | None -> unify_why d.dloc "this pattern" pt (infer env e));
    (* after the right-hand side, so that the pattern's type is known *)
    (match Exhaust.uncovered [ to_spat env pt p ] with
     | Some w -> warn d.dloc "this pattern does not match every value: %s is not matched" w
     | None -> ());
    Types.leave ();
    let rs = List.map snd tv.tvm in
    let rrefs = List.filter_map (function Types.TVar r -> Some r | _ -> None) rs in
    let schemes = List.map (fun (n, t) -> (n, close rrefs t)) bs in
    (add_vals env sg schemes)
  | DFun _ -> assert false (* Desugar replaced it *)
  | DRec bs ->
    Types.enter ();
    let slots = List.map (fun (n, _, _) -> (n, Types.newvar ())) bs in
    let inner = bind_mono env slots in
    List.iter2
      (fun (_, e, loc) (n, t) ->
        unify_lazy loc (fun () -> "the definition of " ^ n) t (infer inner e))
      bs slots;
    Types.leave ();
    add_vals env sg (List.map (fun (n, t) -> (n, close [] t)) slots)
  | DType (h, def) -> type_decl env sg h def
  | DFixity _ -> (env, sg)
  | DSig (n, specs) -> ({ env with te_sigs = SMap.add n specs env.te_sigs }, sg)
  | DImport (path, clause) -> import env sg d.dloc path clause
  | DInclude path ->
    let s = struct_at d.dloc env path in
    (merge_sg env s, merge_sgs sg s)
  | DMod m ->
    let n, v = module_decl env d.dloc m in
    ({ env with te_mods = SMap.add n v env.te_mods }, { sg with sg_mods = SMap.add n v sg.sg_mods })

and add_vals env sg schemes =
  ( { env with te_vals = List.fold_left (fun m (n, s) -> SMap.add n s m) env.te_vals schemes },
    { sg with sg_vals = List.fold_left (fun m (n, s) -> SMap.add n s m) sg.sg_vals schemes } )

and type_decl env sg h def =
  let loc = h.th_loc in
  let params = List.map (fun n -> (n, Types.TVar (Types.newrigid n))) h.th_params in
  let refs = List.filter_map (function _, Types.TVar r -> Some r | _ -> None) params in
  let rec dup = function
    | n :: rest -> if List.mem n rest then Diag.at loc "%s is a parameter twice" n else dup rest
    | [] -> ()
  in
  dup h.th_params;
  match def with
  | TDAlias t ->
    (* an alias cannot see itself, so it is elaborated before it is bound *)
    let body = elab_ty env (fixed params) t in
    let tc = Types.tycon h.th_name refs (Types.Alias body) in
    ( { env with te_types = SMap.add h.th_name tc env.te_types },
      { sg with sg_types = SMap.add h.th_name tc sg.sg_types } )
  | TDVariant cs ->
    let tc = Types.tycon h.th_name refs Types.Abstract in
    let env' = { env with te_types = SMap.add h.th_name tc env.te_types } in
    let cs =
      List.map
        (fun (n, arg, cloc) -> (n, Option.map (elab_ty env' (fixed params)) arg, cloc))
        cs
    in
    let rec dupc seen = function
      | (n, _, cloc) :: rest ->
        if List.mem n seen then Diag.at cloc "%s is declared twice in this type" n
        else dupc (n :: seen) rest
      | [] -> ()
    in
    dupc [] cs;
    let cs = List.map (fun (n, arg, _) -> (n, arg)) cs in
    tc.Types.tc_def <- Types.Variant cs;
    let cons =
      List.map (fun (n, arg) -> (n, { Types.con_tycon = tc; con_arg = arg })) cs
    in
    ( { env' with te_cons = List.fold_left (fun m (n, c) -> SMap.add n c m) env.te_cons cons },
      { sg with
        sg_types = SMap.add h.th_name tc sg.sg_types;
        sg_cons = List.fold_left (fun m (n, c) -> SMap.add n c m) sg.sg_cons cons } )

and import env sg loc path clause =
  let m = walk_mods loc env.te_mods path in
  match (clause, m) with
  | Some (IAs n), _ ->
    ({ env with te_mods = SMap.add n m env.te_mods }, { sg with sg_mods = SMap.add n m sg.sg_mods })
  | _, SFunctor _ -> Diag.at loc "a functor can only be imported under a name, with as"
  | None, SStruct s -> (merge_sg env s, merge_sgs sg s)
  | Some (INames ns), SStruct s ->
    let pick acc n =
      match
        (SMap.find_opt n s.sg_vals, SMap.find_opt n s.sg_cons, SMap.find_opt n s.sg_mods)
      with
      | Some v, _, _ -> { acc with sg_vals = SMap.add n v acc.sg_vals }
      | _, Some c, _ -> { acc with sg_cons = SMap.add n c acc.sg_cons }
      | _, _, Some m -> { acc with sg_mods = SMap.add n m acc.sg_mods }
      | None, None, None -> Diag.at loc "%s does not define %s" (String.concat "." path) n
    in
    let picked = List.fold_left pick empty_sg ns in
    (merge_sg env picked, merge_sgs sg picked)

(* ------------------------------------------------------------------
 * Signatures
 * ------------------------------------------------------------------ *)

and specs_of env (se : sigexp) =
  let loc = se.se_loc in
  let specs =
    match se.se_path with
    | [ n ] -> (
      match SMap.find_opt n env.te_sigs with
      | Some s -> s
      | None -> Diag.at loc "there is no signature %s" n)
    | p ->
      Diag.at loc "%s is not a signature; signatures are declared at the top level"
        (String.concat "." p)
  in
  List.fold_left (fun specs (p, t) -> where_type loc env specs p t) specs se.se_where

and has_abstract loc env specs name =
  List.exists
    (fun sp ->
      match sp.sp with
      | SpType (h, None) -> String.equal h.th_name name
      | SpInclude se -> has_abstract loc env (specs_of env se) name
      | _ -> false)
    specs

(* "where type t = u" turns an abstract specification into a manifest one;
   "where type M.t = u" is handed to M's own signature expression. *)
and where_type loc env specs (path, name) t =
  match path with
  | [] ->
    let found = ref false in
    let specs =
      List.map
        (fun sp ->
          match sp.sp with
          | SpType (h, None) when (not !found) && h.th_name = name ->
            found := true;
            { sp with sp = SpType (h, Some t) }
          (* the type may have come in through an include, in which case the
             clause belongs to that signature expression instead *)
          | SpInclude se when (not !found) && has_abstract loc env (specs_of env se) name ->
            found := true;
            { sp with sp = SpInclude { se with se_where = se.se_where @ [ (([], name), t) ] } }
          | _ -> sp)
        specs
    in
    if not !found then Diag.at loc "this signature has no abstract type %s" name;
    specs
  | m :: rest ->
    let found = ref false in
    let specs =
      List.map
        (fun sp ->
          match sp.sp with
          | SpMod (n, se) when (not !found) && n = m ->
            found := true;
            { sp with sp = SpMod (n, { se with se_where = se.se_where @ [ ((rest, name), t) ] }) }
          | _ -> sp)
        specs
    in
    if not !found then Diag.at loc "this signature has no module %s" m;
    specs

(* Elaborate a specification list.  With [realize], every type it declares is
   the type the given structure has; without it, every abstract type it
   declares is a new one. *)
and elab_specs env ?realize specs : sg =
  let actual loc n =
    match realize with
    | None -> None
    | Some (a : sg) -> (
      match SMap.find_opt n a.sg_types with
      | Some tc -> Some tc
      | None -> Diag.at loc "the module does not define the type %s" n)
  in
  let rec go env sg = function
    | [] -> sg
    | sp :: rest ->
      let loc = sp.sploc in
      let env, sg =
        match sp.sp with
        | SpType (h, manifest) ->
          let params = List.map (fun n -> (n, Types.TVar (Types.newrigid n))) h.th_params in
          let refs = List.filter_map (function _, Types.TVar r -> Some r | _ -> None) params in
          let written = Option.map (elab_ty env (fixed params)) manifest in
          let tc =
            match (actual loc h.th_name, written) with
            | None, None -> Types.tycon h.th_name refs Types.Abstract
            | None, Some body -> Types.tycon h.th_name refs (Types.Alias body)
            | Some tc, w ->
              if Types.arity tc <> List.length refs then
                Diag.at loc "%s has %d type parameters in the module and %d in the signature"
                  h.th_name (Types.arity tc) (List.length refs);
              (match w with
               | None -> ()
               | Some body ->
                 unify_lazy loc
                   (fun () ->
                     Printf.sprintf "the type %s is not the one the signature gives" h.th_name)
                   (Types.apply_tycon tc (List.map snd params))
                   body);
              tc
          in
          ( { env with te_types = SMap.add h.th_name tc env.te_types },
            { sg with sg_types = SMap.add h.th_name tc sg.sg_types } )
        | SpVal (n, t) ->
          let tv = rigids () in
          Types.enter ();
          let ty = elab_ty env tv t in
          Types.leave ();
          let rs = List.filter_map (function _, Types.TVar r -> Some r | _ -> None) tv.tvm in
          let s = { Types.s_vars = rs; s_body = ty } in
          ( { env with te_vals = SMap.add n s env.te_vals },
            { sg with sg_vals = SMap.add n s sg.sg_vals } )
        | SpMod (n, se) ->
          let sub_actual =
            match realize with
            | None -> None
            | Some a -> (
              match SMap.find_opt n a.sg_mods with
              | Some (SStruct s) -> Some s
              | Some (SFunctor _) -> Diag.at loc "%s is a functor, and the signature asks for a module" n
              | None -> Diag.at loc "the module does not define the module %s" n)
          in
          let sub = elab_specs env ?realize:sub_actual (specs_of env se) in
          ( { env with te_mods = SMap.add n (SStruct sub) env.te_mods },
            { sg with sg_mods = SMap.add n (SStruct sub) sg.sg_mods } )
        | SpInclude se ->
          let sub = elab_specs env ?realize (specs_of env se) in
          (merge_sg env sub, merge_sgs sg sub)
      in
      go env sg rest
  in
  go env empty_sg specs

(* The values and sub-modules of a realized signature, against the structure. *)
and check_against loc (spec : sg) (actual : sg) =
  SMap.iter
    (fun n s ->
      match SMap.find_opt n actual.sg_vals with
      | None -> Diag.at loc "the module does not define %s" n
      | Some a ->
        Types.enter ();
        let want = Types.skolemize s in
        let have = Types.instantiate a in
        (try Types.unify have want
         with Types.Clash m ->
           Types.leave ();
           Diag.at loc "%s does not match its specification: %s\n  it has %s\n  the signature asks for %s"
             n m (Types.show have) (Types.show want));
        Types.leave ())
    spec.sg_vals;
  SMap.iter
    (fun n m ->
      match (m, SMap.find_opt n actual.sg_mods) with
      | SStruct s, Some (SStruct a) -> check_against loc s a
      | _, None -> Diag.at loc "the module does not define the module %s" n
      | _ -> Diag.at loc "%s does not match the kind of module the signature asks for" n)
    spec.sg_mods

(* Matching, twice over: the realized view and the sealed one. *)
and match_sig loc env specs actual =
  let realized = elab_specs env ~realize:actual specs in
  check_against loc realized actual;
  let sealed = elab_specs env specs in
  (realized, sealed)

and seal loc env ascr sg =
  match ascr with
  | None -> sg
  | Some se -> snd (match_sig loc env (specs_of env se) sg)

(* ------------------------------------------------------------------
 * Modules
 * ------------------------------------------------------------------ *)

and module_decl env loc m =
  match m with
  | MDefine (n, [], ascr, items) ->
    let _, body = decls env items in
    (n, SStruct (seal loc env ascr body))
  | MDefine (n, params, ascr, items) ->
    check_functor env loc params ascr items;
    (n, SFunctor { fs_params = params; fs_ascr = ascr; fs_body = items; fs_env = env })
  | MBindTo (n, ascr, me) -> (
    match (module_exp env me, ascr) with
    | SStruct s, _ -> (n, SStruct (seal loc env ascr s))
    | (SFunctor _ as f), None -> (n, f)
    | SFunctor _, Some _ -> Diag.at loc "a functor cannot be given a signature here")

(* The body is read once against parameters that are their signatures and
   nothing more, so that it is checked where it is written. *)
and check_functor env loc params ascr items =
  let env =
    List.fold_left
      (fun env (pn, pse) ->
        let sg = elab_specs env (specs_of env pse) in
        { env with te_mods = SMap.add pn (SStruct sg) env.te_mods })
      env params
  in
  let _, body = decls env items in
  ignore (seal loc env ascr body)

and module_exp env me =
  let loc = me.meloc in
  match me.me with
  | MEPath p -> walk_mods loc env.te_mods p
  | MEApp (p, arg) -> (
    match walk_mods loc env.te_mods p with
    | SStruct _ -> Diag.at loc "%s is not a functor" (String.concat "." p)
    | SFunctor f -> (
      match (f.fs_params, module_exp env arg) with
      | [], _ -> Diag.at loc "%s takes no parameters" (String.concat "." p)
      | _, SFunctor _ -> Diag.at loc "a functor cannot be given a functor as an argument"
      | (pn, pse) :: rest, SStruct a ->
        let realized, _ = match_sig loc f.fs_env (specs_of f.fs_env pse) a in
        let inner = { f.fs_env with te_mods = SMap.add pn (SStruct realized) f.fs_env.te_mods } in
        if rest <> [] then SFunctor { f with fs_params = rest; fs_env = inner }
        else
          let _, body = decls inner f.fs_body in
          SStruct (seal loc inner f.fs_ascr body)))

and decls env ds = List.fold_left (fun (env, sg) d -> decl env sg d) (env, empty_sg) ds

(* ------------------------------------------------------------------
 * The initial environment
 * ------------------------------------------------------------------ *)

let initial =
  let types =
    List.fold_left (fun m tc -> SMap.add tc.Types.tc_name tc m) SMap.empty Types.base_types
  in
  let cons =
    match Types.tc_list.Types.tc_def with
    | Types.Variant cs ->
      List.fold_left
        (fun m (n, arg) -> SMap.add n { Types.con_tycon = Types.tc_list; con_arg = arg } m)
        SMap.empty cs
    | _ -> SMap.empty
  in
  let vals = List.fold_left (fun m (n, s) -> SMap.add n s m) SMap.empty Prims.types in
  { te_types = types; te_cons = cons; te_vals = vals; te_mods = SMap.empty; te_sigs = SMap.empty }
