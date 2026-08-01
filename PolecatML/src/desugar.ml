(* Surface tree to core.

   Everything here is a rewriting, and the rewritings are short:

     not e            ->  if e then false else true
     a andalso b      ->  if a then b else false
     a orelse b       ->  if a then true else b
     (e : t)          ->  e
     fun f (p) = ...  ->  letrec f = fn (x) => <p taken apart> ...
     val (a, b) = e   ->  untuple e as (a, b)

   A declaration is a binding that reaches to the end of the block it stands in,
   so the desugarer runs in continuation-passing style: [decl] is handed what
   comes after it, and wraps it.  That is the only structural idea in this file.

   The top level is one expression like any other.  It ends in a tuple of every
   name the program bound, in the order they were written, so that running the
   program produces all of them at once and the driver can print each with the
   type the checker gave it.  A program has no output of its own; its value *is*
   its output. *)

module Env = Map.Make (String)

type env = Core.name Env.t

let lookup env name pos =
  match Env.find_opt name env with
  | Some n -> n
  | None -> Diag.error pos "there is nothing called `%s` here" name

(* [bind pat value k] evaluates [value], takes it apart according to [pat], and
   continues with [k] under the names the pattern bound.  Names come out in the
   order [Ast.pat_binders] gives, which is the order the checker used. *)
let rec bind env pat value k =
  match pat with
  | Ast.P_annot (inner, _, _) -> bind env inner value k
  | Ast.P_var (text, _) ->
      let n = Core.fresh text in
      Core.Let (Some n, value, k (Env.add text n env) [ (text, n) ])
  | Ast.P_wild _ | Ast.P_unit _ -> Core.Let (None, value, k env [])
  | Ast.P_tuple (ps, _) ->
      (* One [Untuple] per level: the fields land in slots, and a field that is
         itself a pattern is taken apart from its slot in turn. *)
      let temps =
        List.map
          (fun p ->
            match p with
            | Ast.P_wild _ | Ast.P_unit _ -> None
            | Ast.P_var (text, _) -> Some (Core.fresh text)
            | _ -> Some (Core.fresh "field"))
          ps
      in
      let rec inner env bound ps temps =
        match (ps, temps) with
        | [], [] -> k env (List.rev bound)
        | Ast.P_var (text, _) :: ps, Some n :: temps ->
            inner (Env.add text n env) ((text, n) :: bound) ps temps
        | (Ast.P_wild _ | Ast.P_unit _) :: ps, None :: temps ->
            inner env bound ps temps
        | p :: ps, Some n :: temps ->
            bind env p (Core.Var n) (fun env more ->
                inner env (List.rev_append more bound) ps temps)
        | _ -> assert false
      in
      Core.Untuple (value, temps, inner env [] ps temps)

(* A parameter is a slot, so a parameter that is a pattern becomes a plain name
   plus a destructuring at the top of the body. *)
and lambda env name params body =
  let names =
    List.map
      (fun p ->
        match p with
        | Ast.P_var (text, _) -> Core.fresh text
        | Ast.P_annot (Ast.P_var (text, _), _, _) -> Core.fresh text
        | _ -> Core.fresh "arg")
      params
  in
  let rec under env params names =
    match (params, names) with
    | [], [] -> expr env body
    | (Ast.P_var (text, _) | Ast.P_annot (Ast.P_var (text, _), _, _)) :: ps, n :: ns
      ->
        under (Env.add text n env) ps ns
    | p :: ps, n :: ns ->
        bind env p (Core.Var n) (fun env _ -> under env ps ns)
    | _ -> assert false
  in
  { Core.lname = name; params = names; body = under env params names }

and expr env e =
  match e with
  | Ast.Int (n, _) -> Core.Int n
  | Ast.Bool (b, _) -> Core.Bool b
  | Ast.Unit _ -> Core.Unit
  | Ast.Var (name, pos) -> Core.Var (lookup env name pos)
  | Ast.Tuple (es, _) -> Core.Tuple (List.map (expr env) es)
  | Ast.Proj (n, e, _) -> Core.Proj (n - 1, expr env e)
  | Ast.Neg (e, _) -> Core.Prim (Core.Neg, [ expr env e ])
  | Ast.Not (e, _) -> Core.If (expr env e, Core.Bool false, Core.Bool true)
  | Ast.Bin (op, l, r, _) ->
      let p =
        match op with
        | Ast.Add -> Core.Add
        | Ast.Sub -> Core.Sub
        | Ast.Mul -> Core.Mul
        | Ast.Div -> Core.Div
        | Ast.Mod -> Core.Mod
        | Ast.Eq -> Core.Eq
        | Ast.Ne -> Core.Ne
        | Ast.Lt -> Core.Lt
        | Ast.Le -> Core.Le
        | Ast.Gt -> Core.Gt
        | Ast.Ge -> Core.Ge
      in
      Core.Prim (p, [ expr env l; expr env r ])
  | Ast.Andalso (l, r, _) -> Core.If (expr env l, expr env r, Core.Bool false)
  | Ast.Orelse (l, r, _) -> Core.If (expr env l, Core.Bool true, expr env r)
  | Ast.If (c, t, f, _) -> Core.If (expr env c, expr env t, expr env f)
  | Ast.Fn (params, body, _) -> Core.Fn (lambda env None params body)
  | Ast.App (f, args, _) -> Core.App (expr env f, List.map (expr env) args)
  | Ast.Let (ds, body, _) -> decls env ds (fun env _ -> expr env body)
  | Ast.Annot (e, _, _) -> expr env e

and decl env d k =
  match d with
  | Ast.D_val (pat, _, e, _) -> bind env pat (expr env e) k
  | Ast.D_fun (clauses, _) ->
      (* One `fun ... and ...` is one recursive group, and the group's names are
         in scope in every member's body and in everything after it. *)
      let names =
        List.map (fun c -> (c.Ast.f_name, Core.fresh c.Ast.f_name)) clauses
      in
      let inner = List.fold_left (fun e (text, n) -> Env.add text n e) env names in
      let group =
        List.map2
          (fun clause (_, n) ->
            (n, lambda inner (Some clause.Ast.f_name) clause.Ast.f_params
                  clause.Ast.f_body))
          clauses names
      in
      Core.Letrec (group, k inner names)

and decls env ds k =
  match ds with
  | [] -> k env []
  | d :: rest ->
      decl env d (fun env bound ->
          decls env rest (fun env more -> k env (bound @ more)))

(* The whole program, and the names it bound in order. *)
let program ds =
  Core.reset ();
  let names = ref [] in
  let body =
    decls Env.empty ds (fun _ bound ->
        names := bound;
        Core.Tuple (List.map (fun (_, n) -> Core.Var n) bound))
  in
  (body, List.map fst !names)
