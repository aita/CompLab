(* Rename every binder apart.

   After this pass a name identifies a binding globally, which is what lets the
   later passes use plain sets and maps keyed by name: the optimizer can move a
   `let` without capturing anything, and Closure can compute free variables
   without worrying about shadowing. *)

open Anf

let renamed x env = match Ident.Map.find_opt x env with Some y -> y | None -> x

let rec rename_exp env exp =
  let var x = renamed x env in
  match exp with
  | Int _ | Static _ -> exp
  | Var x -> Var (var x)
  | Neg x -> Neg (var x)
  | Field (x, i) -> Field (var x, i)
  | Byte (x, y) -> Byte (var x, var y)
  | Bin (op, x, y) -> Bin (op, var x, var y)
  | If_eq (x, y, e1, e2) -> If_eq (var x, var y, rename_exp env e1, rename_exp env e2)
  | If_le (x, y, e1, e2) -> If_le (var x, var y, rename_exp env e1, rename_exp env e2)
  | Let ((x, t), e1, e2) ->
    let x' = Ident.fresh x in
    Let ((x', t), rename_exp env e1, rename_exp (Ident.Map.add x x' env) e2)
  | Let_rec (fds, body) ->
    let env =
      List.fold_left
        (fun env fd ->
          let x = fst fd.name in
          Ident.Map.add x (Ident.fresh x) env)
        env fds
    in
    let fds =
      List.map
        (fun fd ->
          let args = List.map (fun (x, t) -> (Ident.fresh x, t)) fd.args in
          let body_env =
            List.fold_left2
              (fun env (x, _) (x', _) -> Ident.Map.add x x' env)
              env fd.args args
          in
          {
            name = (renamed (fst fd.name) env, snd fd.name);
            args;
            body = rename_exp body_env fd.body;
          })
        fds
    in
    Let_rec (fds, rename_exp env body)
  | App (f, xs) -> App (var f, List.map var xs)
  | App_external (f, xs) -> App_external (f, List.map var xs)
  | Tuple xs -> Tuple (List.map var xs)
  | Block (tag, xs) -> Block (tag, List.map var xs)
  | Let_tuple (xts, y, body) ->
    let xts' = List.map (fun (x, t) -> (Ident.fresh x, t)) xts in
    let env =
      List.fold_left2 (fun env (x, _) (x', _) -> Ident.Map.add x x' env) env xts xts'
    in
    Let_tuple (xts', var y, rename_exp env body)
  | Array (x, y) -> Array (var x, var y)
  | Get (x, y) -> Get (var x, var y)
  | Put (x, y, z) -> Put (var x, var y, var z)

let rename exp = rename_exp Ident.Map.empty exp
