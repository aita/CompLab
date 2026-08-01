(* Hindley-Milner over the surface tree.

   The checker is the usual one: an environment from names to schemes, a level
   counter that goes up inside a binding and comes back down when it is
   generalised, and unification for everything else.  Two things are worth
   knowing.

   Comparison is on `int` only.  The machine has [EqI64] and its five friends
   and nothing else, so `=` at any other type has no instruction to become.  A
   polymorphic equality would need either a tag test at run time or a dictionary,
   and both are larger decisions than a comparison operator should make.

   `#n e` needs to know how wide `e` is.  There are no row variables here, so
   the checker asks what `e` turned out to be, and if that is still a variable it
   says so and asks for an annotation.  Destructuring with a pattern does not
   have the problem, because the pattern says the width. *)

module Env = Map.Make (String)

type env = Types.t Env.t (* the types may contain [Qvar]: they are schemes *)

let unify pos expected actual =
  try Types.unify expected actual with
  | Types.Mismatch (a, b) ->
      let x, y = Types.show_two a b in
      Diag.error pos "this is `%s` where `%s` was expected" y x
  | Types.Occurs (a, b) ->
      let x, y = Types.show_two a b in
      Diag.error pos "`%s` would have to contain itself as `%s`" x y

(* A written type.  A type variable in an annotation is a fresh unification
   variable shared across the declaration it appears in, so `fn (x : 'a) => x`
   states a shape rather than a promise: the annotation constrains, it does not
   quantify. *)
let rec ty_of_ast vars = function
  | Ast.Ty_name ("int", _) -> Types.Int
  | Ast.Ty_name ("bool", _) -> Types.Bool
  | Ast.Ty_name ("unit", _) -> Types.Unit
  | Ast.Ty_name (name, pos) -> Diag.error pos "there is no type called `%s`" name
  | Ast.Ty_var (name, _) -> (
      match Hashtbl.find_opt vars name with
      | Some t -> t
      | None ->
          let t = Types.fresh 0 in
          Hashtbl.add vars name t;
          t)
  | Ast.Ty_tuple (ts, _) -> Types.Tuple (List.map (ty_of_ast vars) ts)
  | Ast.Ty_arrow (ps, r, _) ->
      Types.Arrow (List.map (ty_of_ast vars) ps, ty_of_ast vars r)

(* A pattern says what it matches and what it binds.  The bindings come out
   monomorphic; whoever asked for the pattern generalises them. *)
let rec check_pat vars level pat =
  match pat with
  | Ast.P_var (name, _) ->
      let t = Types.fresh level in
      (t, [ (name, t) ])
  | Ast.P_wild _ -> (Types.fresh level, [])
  | Ast.P_unit _ -> (Types.Unit, [])
  | Ast.P_tuple (ps, _) ->
      let ts, binds = List.split (List.map (check_pat vars level) ps) in
      (Types.Tuple ts, List.concat binds)
  | Ast.P_annot (p, written, pos) ->
      let t, binds = check_pat vars level p in
      unify pos (ty_of_ast vars written) t;
      (t, binds)

let rec check env level expr =
  match expr with
  | Ast.Int _ -> Types.Int
  | Ast.Bool _ -> Types.Bool
  | Ast.Unit _ -> Types.Unit
  | Ast.Var (name, pos) -> (
      match Env.find_opt name env with
      | Some scheme -> Types.instantiate level scheme
      | None -> Diag.error pos "there is nothing called `%s` here" name)
  | Ast.Tuple (es, _) -> Types.Tuple (List.map (check env level) es)
  | Ast.Proj (n, e, pos) -> (
      let t = check env level e in
      match Types.repr t with
      | Types.Tuple ts when n <= List.length ts -> List.nth ts (n - 1)
      | Types.Tuple ts ->
          Diag.error pos "this tuple has %d fields, so there is no `#%d`"
            (List.length ts) n
      | Types.Var _ ->
          Diag.error pos
            "the width of this tuple is not known here; annotate it, or take it \
             apart with a pattern"
      | other -> Diag.error pos "`#%d` needs a tuple, not `%s`" n (Types.show other))
  | Ast.Neg (e, pos) ->
      unify pos Types.Int (check env level e);
      Types.Int
  | Ast.Not (e, pos) ->
      unify pos Types.Bool (check env level e);
      Types.Bool
  | Ast.Bin (op, l, r, _) ->
      unify (Ast.expr_pos l) Types.Int (check env level l);
      unify (Ast.expr_pos r) Types.Int (check env level r);
      (match op with
      | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod -> Types.Int
      | Ast.Eq | Ast.Ne | Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge -> Types.Bool)
  | Ast.Andalso (l, r, _) | Ast.Orelse (l, r, _) ->
      unify (Ast.expr_pos l) Types.Bool (check env level l);
      unify (Ast.expr_pos r) Types.Bool (check env level r);
      Types.Bool
  | Ast.If (c, t, f, _) ->
      unify (Ast.expr_pos c) Types.Bool (check env level c);
      let yes = check env level t in
      let no = check env level f in
      unify (Ast.expr_pos f) yes no;
      yes
  | Ast.Fn (params, body, _) ->
      let vars = Hashtbl.create 4 in
      let ts, binds = List.split (List.map (check_pat vars level) params) in
      let inner =
        List.fold_left (fun e (n, t) -> Env.add n t e) env (List.concat binds)
      in
      Types.Arrow (ts, check inner level body)
  | Ast.App (f, args, pos) ->
      let ft = check env level f in
      let ats = List.map (check env level) args in
      let result = Types.fresh level in
      unify pos ft (Types.Arrow (ats, result));
      result
  | Ast.Let (decls, body, _) ->
      let inner, _ = check_decls env level decls in
      check inner level body
  | Ast.Annot (e, written, pos) ->
      let t = check env level e in
      unify pos (ty_of_ast (Hashtbl.create 4) written) t;
      t

(* A declaration extends the environment and reports what it bound, in the order
   [Ast.decl_binders] gives — the driver lines those names up with the values the
   compiled program returns. *)
and check_decl env level decl =
  match decl with
  | Ast.D_val (pat, written, e, pos) ->
      let vars = Hashtbl.create 4 in
      let t = check env (level + 1) e in
      (match written with Some w -> unify pos (ty_of_ast vars w) t | None -> ());
      let target, binds = check_pat vars (level + 1) pat in
      unify pos target t;
      let bound = List.map (fun (n, t) -> (n, Types.generalize level t)) binds in
      (List.fold_left (fun e (n, s) -> Env.add n s e) env bound, bound)
  | Ast.D_fun (clauses, _) ->
      (* Recursion is monomorphic: inside the group each name has one type, and
         only when the whole group is finished is it generalised. *)
      let slots =
        List.map (fun c -> (c.Ast.f_name, Types.fresh (level + 1))) clauses
      in
      let inner = List.fold_left (fun e (n, t) -> Env.add n t e) env slots in
      List.iter2
        (fun clause (_, slot) ->
          let vars = Hashtbl.create 4 in
          let ts, binds =
            List.split (List.map (check_pat vars (level + 1)) clause.Ast.f_params)
          in
          let body_env =
            List.fold_left (fun e (n, t) -> Env.add n t e) inner (List.concat binds)
          in
          let result = check body_env (level + 1) clause.Ast.f_body in
          (match clause.Ast.f_ret with
          | Some w -> unify clause.Ast.f_pos (ty_of_ast vars w) result
          | None -> ());
          unify clause.Ast.f_pos slot (Types.Arrow (ts, result)))
        clauses slots;
      let bound = List.map (fun (n, t) -> (n, Types.generalize level t)) slots in
      (List.fold_left (fun e (n, s) -> Env.add n s e) env bound, bound)

and check_decls env level decls =
  List.fold_left
    (fun (env, bound) d ->
      let env, more = check_decl env level d in
      (env, bound @ more))
    (env, []) decls

(* The top level: every binding, in order, with the type it was given. *)
let program decls =
  Types.reset ();
  let _, bound = check_decls Env.empty 0 decls in
  bound
