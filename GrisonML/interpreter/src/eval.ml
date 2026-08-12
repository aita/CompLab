(* The evaluator: a tree walker over the desugared syntax.

   It carries no types.  What it does carry, and what an untyped tree walker
   for a smaller language would not need, is the sealing of modules: a
   signature hides names, so the evaluator has to drop them too, or a later
   "import" would bring into scope a name the type checker had already
   decided was not there. *)

open Ast
open Value

let rt loc fmt =
  Printf.ksprintf (fun m -> raise (Runtime (Diag.where loc ^ ": " ^ m))) fmt

(* ------------------------------------------------------------------
 * Paths
 * ------------------------------------------------------------------ *)

let rec walk_mods loc mods = function
  | [] -> assert false
  | [ n ] -> (
    match SMap.find_opt n mods with
    | Some m -> m
    | None -> rt loc "there is no module %s here" n)
  | n :: rest -> (
    match SMap.find_opt n mods with
    | Some (MStruct f) -> walk_mods loc f.f_mods rest
    | Some (MFunctor _) -> rt loc "%s is a functor, so it has no members" n
    | None -> rt loc "there is no module %s here" n)

let lookup_mod loc env path = walk_mods loc env.mods path

let scope loc env = function
  | [] -> (env.vals, env.cons)
  | path -> (
    match lookup_mod loc env path with
    | MStruct f -> (f.f_vals, f.f_cons)
    | MFunctor _ -> rt loc "%s is a functor, so it has no members" (String.concat "." path))

let lookup_val loc env (path, n) =
  let vals, _ = scope loc env path in
  match SMap.find_opt n vals with
  | Some r when !r == VUndef -> rt loc "%s is used before its definition has run" n
  | Some r -> !r
  | None -> rt loc "%s is not bound" (show_path (path, n))

let lookup_con loc env (path, n) =
  let _, cons = scope loc env path in
  match SMap.find_opt n cons with
  | Some a -> a
  | None -> rt loc "%s is not a constructor" (show_path (path, n))

(* ------------------------------------------------------------------
 * Signatures, as the sets of names they expose.  A signature cannot name a
 * constructor -- there is no variant spec in the grammar -- so sealing always
 * hides every constructor of the module it seals.
 * ------------------------------------------------------------------ *)

let specs_of env (se : sigexp) =
  let loc = se.se_loc in
  match se.se_path with
  | [ n ] -> (
    match SMap.find_opt n env.sigs with
    | Some s -> s
    | None -> rt loc "there is no signature %s" n)
  | p -> rt loc "%s is not a signature; signatures are declared at the top level"
           (String.concat "." p)

let rec exposed loc env specs =
  List.concat_map
    (fun sp ->
      match sp.sp with
      | SpVal (n, _) -> [ `Val n ]
      | SpMod (n, se) -> [ `Mod (n, specs_of env se) ]
      | SpInclude se -> exposed loc env (specs_of env se)
      | SpType _ -> [])
    specs

let rec seal_by loc env specs frag =
  let names = exposed loc env specs in
  let keep_val n = List.exists (function `Val m -> m = n | _ -> false) names in
  let sub_specs n =
    List.find_map (function `Mod (m, s) when m = n -> Some s | _ -> None) names
  in
  { f_vals = SMap.filter (fun n _ -> keep_val n) frag.f_vals;
    f_cons = SMap.empty;
    f_mods =
      SMap.filter_map
        (fun n m ->
          match sub_specs n with
          | None -> None
          | Some s -> (
            match m with
            | MStruct f -> Some (MStruct (seal_by loc env s f))
            | MFunctor _ -> Some m))
        frag.f_mods }

let seal loc env ascr frag =
  match ascr with
  | None -> frag
  | Some se -> seal_by loc env (specs_of env se) frag

(* ------------------------------------------------------------------
 * Patterns
 * ------------------------------------------------------------------ *)

let rec match_pat env p v acc =
  match (p.p, v) with
  | PAnn (p, _), _ -> match_pat env p v acc
  | PWild, _ -> Some acc
  | PVar n, _ -> Some ((n, ref v) :: acc)
  | PLit LUnit, VUnit -> Some acc
  | PLit (LInt a), VInt b when a = b -> Some acc
  | PLit (LReal a), VReal b when a = b -> Some acc
  | PLit (LChar a), VChar b when a = b -> Some acc
  | PLit (LString a), VStr b when String.equal a b -> Some acc
  | PLit (LBool a), VBool b when a = b -> Some acc
  | PLit _, _ -> None
  | PCon ((_, c), arg), VCon (d, varg) ->
    if not (String.equal c d) then None
    else (
      match (arg, varg) with
      | None, _ -> Some acc
      | Some p, Some v -> match_pat env p v acc
      | Some _, None -> rt p.ploc "%s is applied to a value it does not take" c)
  | PCon _, _ -> rt p.ploc "a constructor pattern met a value that is not one"
  | PTuple ps, VTuple vs when List.length ps = List.length vs ->
    List.fold_left2
      (fun acc p v -> match acc with None -> None | Some acc -> match_pat env p v acc)
      (Some acc) ps vs
  | PTuple _, _ -> rt p.ploc "a tuple pattern met a value that is not one"
  | PRec fs, VRec vfs ->
    List.fold_left
      (fun acc (f, p) ->
        match acc with
        | None -> None
        | Some acc -> (
          match List.assoc_opt f vfs with
          | Some v -> match_pat env p v acc
          | None -> rt p.ploc "this record has no field %s" f))
      (Some acc) fs
  | PRec _, _ -> rt p.ploc "a record pattern met a value that is not one"

(* ------------------------------------------------------------------
 * Expressions
 * ------------------------------------------------------------------ *)

let bind_all env bs =
  { env with vals = List.fold_left (fun m (n, r) -> SMap.add n r m) env.vals bs }

let rec eval env e =
  match e.e with
  | ELit LUnit -> VUnit
  | ELit (LInt n) -> VInt n
  | ELit (LReal r) -> VReal r
  | ELit (LChar c) -> VChar c
  | ELit (LString s) -> VStr s
  | ELit (LBool b) -> VBool b
  | EVar q -> lookup_val e.eloc env q
  | ECon ((_, n) as q) ->
    if lookup_con e.eloc env q = 0 then VCon (n, None)
    else VPrim (n, fun v -> VCon (n, Some v))
  | EFn rs -> VClos (rs, env)
  | EApp (f, a) -> apply e.eloc (eval env f) (eval env a)
  | EInfix _ -> rt e.eloc "internal: an infix chain reached the evaluator"
  | EUn ("-", a) -> (
    match eval env a with
    | VInt n -> VInt (-n)
    | VReal r -> VReal (-.r)
    | _ -> rt e.eloc "negation needs a number")
  | EUn ("not", a) -> (
    match eval env a with
    | VBool b -> VBool (not b)
    | _ -> rt e.eloc "not needs a boolean")
  | EUn (o, _) -> rt e.eloc "unknown prefix operator %s" o
  | EProj (r, f) -> (
    match eval env r with
    | VRec fs -> (
      match List.assoc_opt f fs with
      | Some v -> v
      | None -> rt e.eloc "this record has no field %s" f)
    | _ -> rt e.eloc "field %s was asked of something that is not a record" f)
  | ETuple es -> VTuple (List.map (eval env) es)
  | ERec fs ->
    (* by name, so that a record prints and compares the same however it was
       written, and matches the order its type is in *)
    let fs = List.map (fun (f, v) -> (f, eval env v)) fs in
    VRec (List.sort (fun (a, _) (b, _) -> String.compare a b) fs)
  | ELet (ds, b) ->
    let env, _ = decls env ds in
    eval env b
  | ESeq es ->
    let rec go = function
      | [] -> VUnit
      | [ e ] -> eval env e
      | e :: rest -> ignore (eval env e); go rest
    in
    go es
  | EIf (c, t, f) -> (
    match eval env c with
    | VBool true -> eval env t
    | VBool false -> eval env f
    | _ -> rt e.eloc "the condition of if is not a boolean")
  | ECase (s, rs) -> rules e.eloc env rs (eval env s)
  | EAnd (a, b) -> (
    match eval env a with VBool false -> VBool false | _ -> eval env b)
  | EOr (a, b) -> (
    match eval env a with VBool true -> VBool true | _ -> eval env b)
  | EAnn (a, _) -> eval env a

and rules loc env rs v =
  match rs with
  | [] -> rt loc "no case matches %s" (show v)
  | r :: rest -> (
    match match_pat env r.r_pat v [] with
    | None -> rules loc env rest v
    | Some bs -> (
      let env' = bind_all env bs in
      match r.r_guard with
      | None -> eval env' r.r_body
      | Some g -> (
        match eval env' g with
        | VBool true -> eval env' r.r_body
        | VBool false -> rules loc env rest v
        | _ -> rt loc "a guard is not a boolean")))

and apply loc f a =
  match f with
  | VClos (rs, env) -> rules loc env rs a
  | VPrim (_, fn) -> fn a
  | _ -> rt loc "%s is applied to an argument, but it is not a function" (show f)

(* ------------------------------------------------------------------
 * Declarations
 * ------------------------------------------------------------------ *)

and decl env frag d =
  let add_vals bs =
    ( { env with vals = List.fold_left (fun m (n, r) -> SMap.add n r m) env.vals bs },
      { frag with f_vals = List.fold_left (fun m (n, r) -> SMap.add n r m) frag.f_vals bs } )
  in
  match d.d with
  | DVal (p, _, e) -> (
    let v = eval env e in
    match match_pat env p v [] with
    | Some bs -> add_vals bs
    | None -> rt d.dloc "the pattern of this val does not match %s" (show v))
  | DFun _ -> assert false (* Desugar replaced it *)
  | DRec bs ->
    let refs = List.map (fun (n, _, _) -> (n, ref VUndef)) bs in
    let env' = bind_all env refs in
    List.iter2 (fun (_, e, _) (_, r) -> r := eval env' e) bs refs;
    add_vals refs
  | DType (_, TDAlias _) -> (env, frag)
  | DType (_, TDVariant cs) ->
    let add m = List.fold_left (fun m (n, a, _) -> SMap.add n (if a = None then 0 else 1) m) m cs in
    ({ env with cons = add env.cons }, { frag with f_cons = add frag.f_cons })
  | DFixity _ -> (env, frag)
  | DSig (n, specs) -> ({ env with sigs = SMap.add n specs env.sigs }, frag)
  | DImport (path, clause) -> import env frag d.dloc path clause
  | DInclude path -> (
    match lookup_mod d.dloc env path with
    | MStruct f -> (merge_frag env f, merge_frags frag f)
    | MFunctor _ -> rt d.dloc "a functor cannot be included")
  | DMod m ->
    let n, v = module_decl env d.dloc m in
    ({ env with mods = SMap.add n v env.mods },
     { frag with f_mods = SMap.add n v frag.f_mods })

and import env frag loc path clause =
  let m = lookup_mod loc env path in
  match (clause, m) with
  | Some (IAs n), _ ->
    ({ env with mods = SMap.add n m env.mods },
     { frag with f_mods = SMap.add n m frag.f_mods })
  | _, MFunctor _ -> rt loc "a functor can only be imported under a name, with as"
  | None, MStruct f -> (merge_frag env f, merge_frags frag f)
  | Some (INames ns), MStruct f ->
    let pick acc n =
      match
        ( SMap.find_opt n f.f_vals,
          SMap.find_opt n f.f_cons,
          SMap.find_opt n f.f_mods )
      with
      | Some r, _, _ -> { acc with f_vals = SMap.add n r acc.f_vals }
      | _, Some a, _ -> { acc with f_cons = SMap.add n a acc.f_cons }
      | _, _, Some m -> { acc with f_mods = SMap.add n m acc.f_mods }
      | None, None, None -> rt loc "%s does not define %s" (String.concat "." path) n
    in
    let picked = List.fold_left pick empty_frag ns in
    (merge_frag env picked, merge_frags frag picked)

and module_decl env loc m =
  match m with
  | MDefine (n, [], ascr, items) ->
    let _, f = decls env items in
    (n, MStruct (seal loc env ascr f))
  | MDefine (n, params, ascr, items) ->
    (n, MFunctor { fu_params = params; fu_ascr = ascr; fu_body = items; fu_env = env })
  | MBindTo (n, ascr, me) -> (
    match module_exp env me with
    | MStruct f -> (n, MStruct (seal loc env ascr f))
    | MFunctor _ as fn ->
      if ascr <> None then rt loc "a functor cannot be given a signature here";
      (n, fn))

and module_exp env me =
  let loc = me.meloc in
  match me.me with
  | MEPath p -> lookup_mod loc env p
  | MEApp (p, arg) -> (
    match lookup_mod loc env p with
    | MStruct _ -> rt loc "%s is not a functor" (String.concat "." p)
    | MFunctor f -> (
      let argv = module_exp env arg in
      match (f.fu_params, argv) with
      | [], _ -> rt loc "%s takes no parameters" (String.concat "." p)
      | (pn, psig) :: rest, MStruct af ->
        let af = seal_by loc f.fu_env (specs_of f.fu_env psig) af in
        let inner =
          { f.fu_env with mods = SMap.add pn (MStruct af) f.fu_env.mods }
        in
        if rest <> [] then MFunctor { f with fu_params = rest; fu_env = inner }
        else
          let _, body = decls inner f.fu_body in
          MStruct (seal loc inner f.fu_ascr body)
      | _, MFunctor _ -> rt loc "a functor cannot be given a functor as an argument"))

and decls env ds =
  List.fold_left (fun (env, frag) d -> decl env frag d) (env, empty_frag) ds
