(* Two things happen here, and after them neither the type checker nor the
   evaluator has to know that "fun" exists.

   A "fun" declaration becomes one expression.  Several clauses over several
   parameters become nested "fn"s over fresh names and one "case" over the
   tuple of them, which is what makes the clauses of

     fun zip [] _ = [] | zip _ [] = [] | zip (x :: xs) (y :: ys) = ...

   choose together rather than one parameter at a time.  A single clause keeps
   its patterns, so that it does not pay for a case it cannot use.

   Adjacent "fun" declarations become one recursive group.  The grammar has no
   "and", so a function can only see itself; a run of them seeing each other is
   the reading that makes mutual recursion writable at all, and it costs
   nothing but the rule that a "val" between two "fun"s separates them. *)

open Ast

let counter = ref 0

(* '@' is not an identifier character, so these cannot collide with a name
   the program can write. *)
let fresh () =
  incr counter;
  Printf.sprintf "@%d" !counter

let rec exp e =
  let keep d = { e with e = d } in
  match e.e with
  | ELit _ | EVar _ | ECon _ -> e
  | EInfix _ -> Diag.at e.eloc "internal: an infix chain reached Desugar"
  | EFn rs ->
    let rs' = map_share rule rs in
    if rs' == rs then e else keep (EFn rs')
  | EApp (f, a) ->
    let f' = exp f and a' = exp a in
    if f' == f && a' == a then e else keep (EApp (f', a'))
  | EUn (o, a) ->
    let a' = exp a in
    if a' == a then e else keep (EUn (o, a'))
  | EProj (a, f) ->
    let a' = exp a in
    if a' == a then e else keep (EProj (a', f))
  | ETuple es ->
    let es' = map_share exp es in
    if es' == es then e else keep (ETuple es')
  | ERec fs ->
    let fs' = map_share_snd exp fs in
    if fs' == fs then e else keep (ERec fs')
  | ELet (ds, b) ->
    let ds' = decls ds and b' = exp b in
    if ds' == ds && b' == b then e else keep (ELet (ds', b'))
  | ESeq es ->
    let es' = map_share exp es in
    if es' == es then e else keep (ESeq es')
  | EIf (c, t, f) ->
    let c' = exp c and t' = exp t and f' = exp f in
    if c' == c && t' == t && f' == f then e else keep (EIf (c', t', f'))
  | ECase (s, rs) ->
    let s' = exp s and rs' = map_share rule rs in
    if s' == s && rs' == rs then e else keep (ECase (s', rs'))
  | EAnd (a, b) ->
    let a' = exp a and b' = exp b in
    if a' == a && b' == b then e else keep (EAnd (a', b'))
  | EOr (a, b) ->
    let a' = exp a and b' = exp b in
    if a' == a && b' == b then e else keep (EOr (a', b'))
  | EAnn (a, t) ->
    let a' = exp a in
    if a' == a then e else keep (EAnn (a', t))

and rule r =
  let g' = opt_share exp r.r_guard and b' = exp r.r_body in
  if g' == r.r_guard && b' == r.r_body then r else { r with r_guard = g'; r_body = b' }

and clause_body c =
  let b = exp c.c_body in
  match c.c_ret with None -> b | Some t -> mk_e b.eloc (EAnn (b, t))

and one_fun cs =
  let c0 = List.hd cs in
  let name = c0.c_name in
  let arity = List.length c0.c_params in
  List.iter
    (fun c ->
      if c.c_name <> name then
        Diag.at c.c_loc "this clause defines %s, but the first one defines %s" c.c_name name;
      if List.length c.c_params <> arity then
        Diag.at c.c_loc "%s takes %d parameters here and %d in its first clause" name
          (List.length c.c_params) arity)
    cs;
  let loc = c0.c_loc in
  let fn p body = mk_e loc (EFn [ { r_pat = p; r_guard = None; r_body = body } ]) in
  let body =
    match (arity, cs) with
    | 0, [ c ] -> clause_body c
    | 0, _ -> Diag.at (List.nth cs 1).c_loc "%s takes no parameters, so it has one clause" name
    | _, [ c ] -> List.fold_right fn c.c_params (clause_body c)
    | _ ->
      let vs = List.init arity (fun _ -> fresh ()) in
      let var v = mk_e loc (EVar ([], v)) in
      let scrutinee =
        match vs with [ v ] -> var v | _ -> mk_e loc (ETuple (List.map var vs))
      in
      let rules =
        List.map
          (fun c ->
            let p = match c.c_params with [ p ] -> p | ps -> mk_p c.c_loc (PTuple ps) in
            { r_pat = p; r_guard = None; r_body = clause_body c })
          cs
      in
      List.fold_right
        (fun v body -> fn (mk_p loc (PVar v)) body)
        vs
        (mk_e loc (ECase (scrutinee, rules)))
  in
  (name, body, loc)

and decl d =
  match d.d with
  | DVal (p, t, e0) ->
    let e' = exp e0 in
    if e' == e0 then d else { d with d = DVal (p, t, e') }
  | DFun _ -> assert false (* handled by [decls] *)
  | DRec bs ->
    let bs' =
      map_share
        (fun ((n, e0, l) as b) ->
          let e' = exp e0 in
          if e' == e0 then b else (n, e', l))
        bs
    in
    if bs' == bs then d else { d with d = DRec bs' }
  | DType _ | DFixity _ | DSig _ | DImport _ | DInclude _ -> d
  | DMod (MDefine (n, ps, a, items)) ->
    let items' = decls items in
    if items' == items then d else { d with d = DMod (MDefine (n, ps, a, items')) }
  | DMod (MBindTo _) -> d

and decls ds =
  match ds with
  | [] -> []
  | { d = DFun _; _ } :: _ ->
    let rec span acc = function
      | ({ d = DFun cs; _ } as d) :: rest -> span ((d.dloc, cs) :: acc) rest
      | rest -> (List.rev acc, rest)
    in
    let run, rest = span [] ds in
    let loc = fst (List.hd run) in
    let group = List.map (fun (_, cs) -> one_fun cs) run in
    mk_d loc (DRec group) :: decls rest
  | d :: rest ->
    let d' = decl d and rest' = decls rest in
    if d' == d && rest' == rest then ds else d' :: rest'

let program ds = decls ds
