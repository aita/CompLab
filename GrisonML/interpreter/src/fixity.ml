(* Shaping infix chains.

   The grammar states the precedence of the built-in operators twice: once as
   the ladder of expression productions, and once again by allowing
   "infixl / infixr / infix" to name any operator at all.  Only one of the two
   can be the parser's, so the parser has neither: it hands over a flat chain
   and the ladder is the table below.  A declaration then really can change the
   shape of an expression, including the shape of "+" and "::".

   An operator that has never been declared is infixl 9, so that a new one is
   tighter than everything the ladder names -- which is where a chain of
   arithmetic wants it. *)

open Ast

type t = (string * (assoc * int)) list

let ladder : t =
  [ ("or", (Left, 1));
    ("and", (Left, 2));
    ("==", (Non, 3));
    ("!=", (Non, 3));
    ("<", (Non, 3));
    ("<=", (Non, 3));
    (">", (Non, 3));
    (">=", (Non, 3));
    ("::", (Right, 4));
    ("+", (Left, 5));
    ("-", (Left, 5));
    ("^", (Left, 5));
    ("*", (Left, 6));
    ("/", (Left, 6));
    ("%", (Left, 6)) ]

let undeclared = (Left, 9)

let look (tbl : t) op = match List.assoc_opt op tbl with Some f -> f | None -> undeclared

let build op loc l r =
  match op with
  | "::" -> mk_e loc (EApp (mk_e loc (ECon cons_path), mk_e loc (ETuple [ l; r ])))
  | "and" -> mk_e loc (EAnd (l, r))
  | "or" -> mk_e loc (EOr (l, r))
  | _ -> mk_e loc (EApp (mk_e loc (EApp (mk_e loc (EVar ([], op)), l)), r))

(* Precedence climbing over the flat chain.  [climb] returns the expression it
   could build without going below [floor], and whatever chain is left. *)
let rec climb tbl lhs ops floor =
  match ops with
  | [] -> (lhs, [])
  | (op, loc, rhs) :: rest ->
    let assoc, prec = look tbl op in
    if prec < floor then (lhs, ops)
    else begin
      let inner = if assoc = Right then prec else prec + 1 in
      let rhs, rest = climb tbl rhs rest inner in
      (match rest with
       | (op', loc', _) :: _ ->
         let assoc', prec' = look tbl op' in
         if prec' = prec && (assoc = Non || assoc' = Non) then
           Diag.at loc' "%s and %s are non-associative at the same precedence" op op'
         else if prec' = prec && assoc' <> assoc then
           Diag.at loc' "%s and %s associate differently at the same precedence" op op'
       | [] -> ());
      climb tbl (build op loc lhs rhs) rest floor
    end

let resolve_chain tbl head ops =
  match climb tbl head ops 0 with
  | e, [] -> e
  | _, (op, loc, _) :: _ -> Diag.at loc "%s cannot be shaped into this expression" op

(* ------------------------------------------------------------------
 * Rewriting.  The table only ever grows, and only at the top level, so it is
 * threaded through a declaration list and passed down into everything else.
 * ------------------------------------------------------------------ *)

let rec exp tbl e =
  let keep d = { e with e = d } in
  match e.e with
  | ELit _ | EVar _ | ECon _ -> e
  | EInfix (h, ops) ->
    resolve_chain tbl (exp tbl h) (List.map (fun (o, l, r) -> (o, l, exp tbl r)) ops)
  | EFn rs ->
    let rs' = map_share (rule tbl) rs in
    if rs' == rs then e else keep (EFn rs')
  | EApp (f, a) ->
    let f' = exp tbl f and a' = exp tbl a in
    if f' == f && a' == a then e else keep (EApp (f', a'))
  | EUn (o, a) ->
    let a' = exp tbl a in
    if a' == a then e else keep (EUn (o, a'))
  | EProj (a, f) ->
    let a' = exp tbl a in
    if a' == a then e else keep (EProj (a', f))
  | ETuple es ->
    let es' = map_share (exp tbl) es in
    if es' == es then e else keep (ETuple es')
  | ERec fs ->
    let fs' = map_share_snd (exp tbl) fs in
    if fs' == fs then e else keep (ERec fs')
  | ELet (ds, b) ->
    let _, ds' = decls tbl ds in
    let b' = exp tbl b in
    if ds' == ds && b' == b then e else keep (ELet (ds', b'))
  | ESeq es ->
    let es' = map_share (exp tbl) es in
    if es' == es then e else keep (ESeq es')
  | EIf (c, t, f) ->
    let c' = exp tbl c and t' = exp tbl t and f' = exp tbl f in
    if c' == c && t' == t && f' == f then e else keep (EIf (c', t', f'))
  | ECase (s, rs) ->
    let s' = exp tbl s and rs' = map_share (rule tbl) rs in
    if s' == s && rs' == rs then e else keep (ECase (s', rs'))
  | EAnd (a, b) ->
    let a' = exp tbl a and b' = exp tbl b in
    if a' == a && b' == b then e else keep (EAnd (a', b'))
  | EOr (a, b) ->
    let a' = exp tbl a and b' = exp tbl b in
    if a' == a && b' == b then e else keep (EOr (a', b'))
  | EAnn (a, t) ->
    let a' = exp tbl a in
    if a' == a then e else keep (EAnn (a', t))

and rule tbl r =
  let g' = opt_share (exp tbl) r.r_guard and b' = exp tbl r.r_body in
  if g' == r.r_guard && b' == r.r_body then r else { r with r_guard = g'; r_body = b' }

and decl tbl d =
  match d.d with
  | DFixity (a, p, ops) ->
    let tbl = List.fold_left (fun tbl o -> (o, (a, p)) :: tbl) tbl ops in
    (tbl, d)
  | DVal (p, t, e0) ->
    let e' = exp tbl e0 in
    (tbl, if e' == e0 then d else { d with d = DVal (p, t, e') })
  | DFun cs ->
    let cs' =
      map_share
        (fun c ->
          let b = exp tbl c.c_body in
          if b == c.c_body then c else { c with c_body = b })
        cs
    in
    (tbl, if cs' == cs then d else { d with d = DFun cs' })
  | DRec bs ->
    let bs' =
      map_share
        (fun ((n, e0, l) as b) ->
          let e' = exp tbl e0 in
          if e' == e0 then b else (n, e', l))
        bs
    in
    (tbl, if bs' == bs then d else { d with d = DRec bs' })
  | DType _ | DSig _ | DImport _ | DInclude _ -> (tbl, d)
  | DMod (MDefine (n, ps, a, items)) ->
    let _, items' = decls tbl items in
    (tbl, if items' == items then d else { d with d = DMod (MDefine (n, ps, a, items')) })
  | DMod (MBindTo _) -> (tbl, d)

and decls tbl ds =
  (* the table only grows, so the list is threaded rather than mapped *)
  let tbl = ref tbl in
  let ds' =
    map_share
      (fun d ->
        let t, d' = decl !tbl d in
        tbl := t;
        d')
      ds
  in
  (!tbl, ds')
