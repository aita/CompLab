(* K-normalization: every intermediate result is named by a `let`.

   This is the shape the whole back end wants.  Each subexpression a machine
   instruction consumes is already a variable, so instruction selection never
   has to invent an evaluation order, and a variable's live range is exactly the
   region where the back end must keep it in a register.

   Two representation choices worth stating: `unit`, `bool` and `int` are all
   one machine word (unit is 0, true is 1), and comparisons only exist as the
   test of a branch -- a comparison used as a value becomes an `if` yielding 1
   or 0, which the optimizer usually folds back into a branch. *)

type binop = Add | Sub | Mul | Div | Rem

type t =
  | Int of int
  | Var of Ident.t
  | Neg of Ident.t
  | Bin of binop * Ident.t * Ident.t
  | IfEq of Ident.t * Ident.t * t * t
  | IfLe of Ident.t * Ident.t * t * t (* x <= y *)
  | Let of (Ident.t * Types.t) * t * t
  | LetRec of fundef list * t
  | App of Ident.t * Ident.t list
  | ExtFunApp of Ident.t * Ident.t list
  | Tuple of Ident.t list
  | LetTuple of (Ident.t * Types.t) list * Ident.t * t
  | Block of int * Ident.t list (* a tagged block: a constructor's value *)
  | Static of Ident.label (* a read-only block: a constant constructor *)
  | Field of Ident.t * int (* word i of a block *)
  | Array of Ident.t * Ident.t
  | Get of Ident.t * Ident.t
  | Put of Ident.t * Ident.t * Ident.t

and fundef = {
  name : Ident.t * Types.t;
  args : (Ident.t * Types.t) list;
  body : t;
}

let string_of_binop = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Rem -> "mod"

let binop_of_arith = function
  | Syntax.Add -> Add
  | Syntax.Sub -> Sub
  | Syntax.Mul -> Mul
  | Syntax.Div -> Div
  | Syntax.Rem -> Rem

(* Free variables.  Function names count as free occurrences: a `let rec` that
   is never mentioned can be dropped, and Closure needs exactly this notion to
   decide which definitions still need a heap closure. *)
let rec free_vars = function
  | Int _ | Static _ -> Ident.Set.empty
  | Var x | Neg x | Field (x, _) -> Ident.Set.singleton x
  | Bin (_, x, y) | Array (x, y) | Get (x, y) -> Ident.Set.of_list [ x; y ]
  | Put (x, y, z) -> Ident.Set.of_list [ x; y; z ]
  | IfEq (x, y, e1, e2) | IfLe (x, y, e1, e2) ->
    Ident.Set.add x
      (Ident.Set.add y (Ident.Set.union (free_vars e1) (free_vars e2)))
  | Let ((x, _), e1, e2) ->
    Ident.Set.union (free_vars e1) (Ident.Set.remove x (free_vars e2))
  | LetRec (fds, e) ->
    let names = Ident.Set.of_list (List.map (fun fd -> fst fd.name) fds) in
    let bodies =
      List.fold_left
        (fun acc fd ->
          let args = Ident.Set.of_list (List.map fst fd.args) in
          Ident.Set.union acc (Ident.Set.diff (free_vars fd.body) args))
        Ident.Set.empty fds
    in
    Ident.Set.diff (Ident.Set.union bodies (free_vars e)) names
  | App (f, xs) -> Ident.Set.of_list (f :: xs)
  | ExtFunApp (_, xs) | Tuple xs | Block (_, xs) -> Ident.Set.of_list xs
  | LetTuple (xts, y, e) ->
    Ident.Set.add y
      (Ident.Set.diff (free_vars e) (Ident.Set.of_list (List.map fst xts)))

(* [insert_let (e, t) k] names [e] unless it is already a variable, then
   continues with that name. *)
let insert_let (e, t) k =
  match e with
  | Var x -> k x
  | _ ->
    let x = Ident.fresh "t" in
    let body, t' = k x in
    (Let ((x, t), e, body), t')

let external_result name =
  match List.assoc_opt name Typing.externals with
  | Some (Types.Fun (_, tres)) -> tres
  | _ -> failwith ("Knormal: unknown external " ^ name)

let rec normalize_exp env (exp : Syntax.t) : t * Types.t =
  match exp with
  | Syntax.Unit -> (Int 0, Types.Unit)
  | Syntax.Bool b -> (Int (if b then 1 else 0), Types.Bool)
  | Syntax.Int n -> (Int n, Types.Int)
  | Syntax.Not e ->
    normalize_exp env (Syntax.If (e, Syntax.Bool false, Syntax.Bool true))
  | Syntax.Neg e -> insert_let (normalize_exp env e) (fun x -> (Neg x, Types.Int))
  | Syntax.Arith (op, e1, e2) ->
    insert_let (normalize_exp env e1) (fun x ->
        insert_let (normalize_exp env e2) (fun y ->
            (Bin (binop_of_arith op, x, y), Types.Int)))
  | Syntax.Cmp _ ->
    (* A comparison in value position: materialize the boolean. *)
    normalize_exp env (Syntax.If (exp, Syntax.Bool true, Syntax.Bool false))
  | Syntax.If (Syntax.Not cond, e1, e2) ->
    normalize_exp env (Syntax.If (cond, e2, e1))
  | Syntax.If (Syntax.Cmp (op, a, b), e1, e2) ->
    (* Fuse the comparison into the branch.  Only `=` and `<=` reach the back
       end; the other four are these two with the arms or the operands
       swapped. *)
    let branch make left right then_ else_ =
      insert_let (normalize_exp env left) (fun x ->
          insert_let (normalize_exp env right) (fun y ->
              let e1', t = normalize_exp env then_ in
              let e2', _ = normalize_exp env else_ in
              (make x y e1' e2', t)))
    in
    let if_eq x y a b = IfEq (x, y, a, b) and if_le x y a b = IfLe (x, y, a, b) in
    (match op with
     | Syntax.Eq -> branch if_eq a b e1 e2
     | Syntax.Ne -> branch if_eq a b e2 e1
     | Syntax.Le -> branch if_le a b e1 e2
     | Syntax.Gt -> branch if_le a b e2 e1
     | Syntax.Ge -> branch if_le b a e1 e2
     | Syntax.Lt -> branch if_le b a e2 e1)
  | Syntax.If (cond, e1, e2) ->
    (* An arbitrary boolean: test it against `false`. *)
    normalize_exp env
      (Syntax.If (Syntax.Cmp (Syntax.Eq, cond, Syntax.Bool false), e2, e1))
  | Syntax.Let ((x, t), e1, e2) ->
    let e1', _ = normalize_exp env e1 in
    let e2', t2 = normalize_exp (Ident.Map.add x t env) e2 in
    (Let ((x, t), e1', e2'), t2)
  | Syntax.Var x -> (Var x, Ident.Map.find x env)
  | Syntax.LetRec (fds, body) ->
    let env =
      List.fold_left
        (fun env (fd : Syntax.fundef) -> Ident.Map.add (fst fd.name) (snd fd.name) env)
        env fds
    in
    let fds =
      List.map
        (fun (fd : Syntax.fundef) ->
          let body_env =
            List.fold_left (fun env (x, t) -> Ident.Map.add x t env) env fd.args
          in
          { name = fd.name; args = fd.args; body = fst (normalize_exp body_env fd.body) })
        fds
    in
    let body', t = normalize_exp env body in
    (LetRec (fds, body'), t)
  | Syntax.App (Syntax.Var f, args) when not (Ident.Map.mem f env) ->
    insert_lets env args (fun xs -> (ExtFunApp (f, xs), external_result f))
  | Syntax.App (fn, args) ->
    let fn', tfn = normalize_exp env fn in
    let tres =
      match Types.repr tfn with Types.Fun (_, t) -> t | _ -> Types.fresh_var ()
    in
    insert_let (fn', tfn) (fun f ->
        insert_lets env args (fun xs -> (App (f, xs), tres)))
  | Syntax.Tuple es ->
    let rec loop named types = function
      | [] -> (Tuple (List.rev named), Types.Tuple (List.rev types))
      | e :: rest ->
        let e', t = normalize_exp env e in
        insert_let (e', t) (fun x -> loop (x :: named) (t :: types) rest)
    in
    loop [] [] es
  | Syntax.LetTuple (xts, e1, e2) ->
    insert_let (normalize_exp env e1) (fun y ->
        let env = List.fold_left (fun env (x, t) -> Ident.Map.add x t env) env xts in
        let e2', t2 = normalize_exp env e2 in
        (LetTuple (xts, y, e2'), t2))
  | Syntax.Array (size, init) ->
    insert_let (normalize_exp env size) (fun n ->
        let init', t = normalize_exp env init in
        insert_let (init', t) (fun v -> (Array (n, v), Types.Array t)))
  | Syntax.Get (arr, idx) ->
    let arr', tarr = normalize_exp env arr in
    let telt =
      match Types.repr tarr with Types.Array t -> t | _ -> Types.fresh_var ()
    in
    insert_let (arr', tarr) (fun a ->
        insert_let (normalize_exp env idx) (fun i -> (Get (a, i), telt)))
  | Syntax.Put (arr, idx, v) ->
    insert_let (normalize_exp env arr) (fun a ->
        insert_let (normalize_exp env idx) (fun i ->
            insert_let (normalize_exp env v) (fun x -> (Put (a, i, x), Types.Unit))))
  | Syntax.Constr (name, args) ->
    let c = Datatype.constr_exn name in
    let t = Types.Named c.Datatype.owner in
    if args = [] then (Static (Datatype.const_label c), t)
    else insert_lets env args (fun xs -> (Block (c.Datatype.tag, xs), t))
  | Syntax.Field (e, i, t) ->
    insert_let (normalize_exp env e) (fun x -> (Field (x, i), t))
  | Syntax.Match_failure t ->
    (* Never returns; the 0 only gives the expression a value. *)
    (Let ((Ident.fresh "fail", Types.Unit), ExtFunApp ("match_failure", []), Int 0), t)
  | Syntax.Match _ ->
    failwith "Knormal: `match` should have been compiled away by Match_compile"

(* Name a whole list of subexpressions, left to right. *)
and insert_lets env exps k =
  let rec loop named = function
    | [] -> k (List.rev named)
    | e :: rest -> insert_let (normalize_exp env e) (fun x -> loop (x :: named) rest)
  in
  loop [] exps

let normalize exp = fst (normalize_exp Ident.Map.empty exp)
