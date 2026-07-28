(* K-normalization: every intermediate result is named by a `let`.

   The form is MinCaml's K-normal form.  What makes a term K-normal is one
   condition -- every operand is a variable -- and the type below is what
   states it: `Bin of binop * Ident.t * Ident.t`, never `t * t`.  So a term of
   this type is K-normal by construction, and [normalize] cannot produce
   anything else.

   Two conventions ride along, and neither is in the type:

     - bindings are associated to the right, so a `let` never sits in the
       right-hand side of a `let`.  This is MinCaml's Assoc pass; it takes a
       K-normal term to a K-normal term, and [let_bind] does it while building
       rather than in a pass afterwards, so the shape does not depend on `-O`.
     - after Alpha, every binder in the program has a distinct name.

   [check] states both for a term the type cannot; see the bottom of the file.

   This is the shape the whole back end wants.  Each subexpression a machine
   instruction consumes is already a variable, so instruction selection never
   has to invent an evaluation order, and a variable's live range is exactly the
   region where the back end must keep it in a register.

   Two representation choices worth stating: `unit`, `bool` and `int` are all
   one machine word (unit is 0, true is 1), and comparisons only exist as the
   test of a branch -- a comparison used as a value becomes an `if` yielding 1
   or 0, which the optimizer usually folds back into a branch.

   A-normal form asks for one more condition on top of this: a conditional
   appears only in tail position.  That one is not met and does not need to be
   -- selection emits a join block (doc/knormal.md §1). *)

type binop = Add | Sub | Mul | Div | Rem

type t =
  | Int of int
  | Var of Ident.t
  | Neg of Ident.t
  | Bin of binop * Ident.t * Ident.t
  | If_eq of Ident.t * Ident.t * t * t
  | If_le of Ident.t * Ident.t * t * t (* x <= y *)
  | Let of (Ident.t * Types.t) * t * t
  | Let_rec of fundef list * t
  | App of Ident.t * Ident.t list
  | App_external of Ident.t * Ident.t list
  | Tuple of Ident.t list
  | Let_tuple of (Ident.t * Types.t) list * Ident.t * t
  | Block of int * Ident.t list (* a tagged block: a constructor's value *)
  | Static of Ident.label (* a read-only block: a constant constructor *)
  | Field of Ident.t * int (* word i of a block *)
  | Byte of Ident.t * Ident.t (* byte i of a string, past its length word *)
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
  | Byte (x, y) -> Ident.Set.of_list [ x; y ]
  | Bin (_, x, y) | Array (x, y) | Get (x, y) -> Ident.Set.of_list [ x; y ]
  | Put (x, y, z) -> Ident.Set.of_list [ x; y; z ]
  | If_eq (x, y, e1, e2) | If_le (x, y, e1, e2) ->
    Ident.Set.add x
      (Ident.Set.add y (Ident.Set.union (free_vars e1) (free_vars e2)))
  | Let ((x, _), e1, e2) ->
    Ident.Set.union (free_vars e1) (Ident.Set.remove x (free_vars e2))
  | Let_rec (fds, e) ->
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
  | App_external (_, xs) | Tuple xs | Block (_, xs) -> Ident.Set.of_list xs
  | Let_tuple (xts, y, e) ->
    Ident.Set.add y
      (Ident.Set.diff (free_vars e) (Ident.Set.of_list (List.map fst xts)))

(* Build `let x = e1 in e2` associated to the right: if e1 binds anything
   itself, those bindings come out in front rather than nesting inside.

   Every binding the compiler makes goes through here -- this module's and the
   optimizer's alike -- so no pass after normalization has to walk into a
   binding position looking for more bindings. *)
let rec let_bind xt e1 e2 =
  match e1 with
  | Let (yt, a, b) -> Let (yt, a, let_bind xt b e2)
  | Let_rec (fds, b) -> Let_rec (fds, let_bind xt b e2)
  | Let_tuple (yts, y, b) -> Let_tuple (yts, y, let_bind xt b e2)
  | _ -> Let (xt, e1, e2)

(* [insert_let (e, t) k] names [e] unless it is already a variable, then
   continues with that name. *)
let insert_let (e, t) k =
  match e with
  | Var x -> k x
  | _ ->
    let x = Ident.fresh "t" in
    let body, t' = k x in
    (let_bind (x, t) e body, t')

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
    let if_eq x y a b = If_eq (x, y, a, b) and if_le x y a b = If_le (x, y, a, b) in
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
    (let_bind (x, t) e1' e2', t2)
  | Syntax.Var x -> (Var x, Ident.Map.find x env)
  | Syntax.Let_rec (fds, body) ->
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
    (Let_rec (fds, body'), t)
  | Syntax.App (Syntax.Var f, args) when not (Ident.Map.mem f env) ->
    insert_lets env args (fun xs -> (App_external (f, xs), external_result f))
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
  | Syntax.Let_tuple (xts, e1, e2) ->
    insert_let (normalize_exp env e1) (fun y ->
        let env = List.fold_left (fun env (x, t) -> Ident.Map.add x t env) env xts in
        let e2', t2 = normalize_exp env e2 in
        (Let_tuple (xts, y, e2'), t2))
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
  | Syntax.Str text -> (Static (Literals.intern text), Types.String)
  | Syntax.Str_length e ->
    (* The length is the first word of the block. *)
    insert_let (normalize_exp env e) (fun s -> (Field (s, 0), Types.Int))
  | Syntax.Str_get (s, i) ->
    insert_let (normalize_exp env s) (fun s ->
        insert_let (normalize_exp env i) (fun i -> (Byte (s, i), Types.Int)))
  | Syntax.Nil -> (Static Datatype.nil_label, Types.List (Types.fresh_var ()))
  | Syntax.Cons (head, tail) ->
    let head', telement = normalize_exp env head in
    insert_let (head', telement) (fun h ->
        insert_let (normalize_exp env tail) (fun t ->
            (Block (1, [ h; t ]), Types.List telement)))
  | Syntax.Constr (name, args) ->
    let c = Datatype.constr_exn name in
    let t = Types.Named c.Datatype.owner in
    if args = [] then (Static (Datatype.const_label c), t)
    else insert_lets env args (fun xs -> (Block (c.Datatype.tag, xs), t))
  | Syntax.Field (e, i, t) ->
    insert_let (normalize_exp env e) (fun x -> (Field (x, i), t))
  | Syntax.Match_failure t ->
    (* Never returns; the 0 only gives the expression a value. *)
    (Let ((Ident.fresh "fail", Types.Unit), App_external ("match_failure", []), Int 0), t)
  | Syntax.Match _ ->
    failwith "Knormal: `match` should have been compiled away by Match_compile"
  | Syntax.At (_, e) | Syntax.Annot (e, _) -> normalize_exp env e
  | Syntax.Type_decl _ | Syntax.Qualified _ | Syntax.Module _ | Syntax.Open _
  | Syntax.Module_type _ | Syntax.Functor _ ->
    failwith "Knormal: modules should have been resolved away by Modules"

(* Name a whole list of subexpressions, left to right. *)
and insert_lets env exps k =
  let rec loop named = function
    | [] -> k (List.rev named)
    | e :: rest -> insert_let (normalize_exp env e) (fun x -> loop (x :: named) rest)
  in
  loop [] exps

let normalize exp = fst (normalize_exp Ident.Map.empty exp)

(* ------------------------------------------------------- the invariant *)

(* What the type cannot say.

   K-normality itself is carried by the type, so a term that type-checks has
   it.  The two conventions from the top of the file are not, and a pass that
   rebuilds a binding by hand rather than through [let_bind] breaks them
   silently: the term still type-checks, and the damage surfaces several passes
   later as a bad register or a name captured by the wrong binder.

     - no binding is the right-hand side of a binding
     - every variable mentioned is bound; after Alpha, bound exactly once

   `--check-knf` runs this after normalization, after alpha renaming, and after
   the optimizer, so a break is reported at the pass that caused it. *)

exception Broken of string

let broken fmt = Printf.ksprintf (fun s -> raise (Broken s)) fmt

let describe = function
  | Let _ -> "let"
  | Let_rec _ -> "let rec"
  | Let_tuple _ -> "let (...)"
  | _ -> "a binding"

let check ?(unique = false) exp =
  (* Alpha's promise, checked across the whole term rather than per scope. *)
  let bound_once = Hashtbl.create 64 in
  let bind scope x =
    if unique then
      if Hashtbl.mem bound_once x then broken "%s is bound in two places" x
      else Hashtbl.add bound_once x ();
    Ident.Set.add x scope
  in
  let binds scope xts = List.fold_left (fun scope (x, _) -> bind scope x) scope xts in
  let use scope x = if not (Ident.Set.mem x scope) then broken "%s is unbound" x in
  let uses scope xs = List.iter (use scope) xs in
  let rec walk scope = function
    | Int _ | Static _ -> ()
    | Var x | Neg x | Field (x, _) -> use scope x
    | Bin (_, x, y) | Byte (x, y) | Array (x, y) | Get (x, y) ->
      use scope x;
      use scope y
    | Put (x, y, z) -> uses scope [ x; y; z ]
    | If_eq (x, y, e1, e2) | If_le (x, y, e1, e2) ->
      use scope x;
      use scope y;
      walk scope e1;
      walk scope e2
    | Let ((x, _), e1, e2) ->
      (match e1 with
       | Let _ | Let_rec _ | Let_tuple _ ->
         broken "the right-hand side of `let %s' is a %s" x (describe e1)
       | _ -> ());
      walk scope e1;
      walk (bind scope x) e2
    | Let_rec (fds, e) ->
      (* The names are in scope in every body, including their own. *)
      let scope = List.fold_left (fun scope fd -> bind scope (fst fd.name)) scope fds in
      List.iter (fun fd -> walk (binds scope fd.args) fd.body) fds;
      walk scope e
    | App (f, xs) ->
      use scope f;
      uses scope xs
    | App_external (_, xs) -> uses scope xs (* the name is a runtime symbol *)
    | Tuple xs | Block (_, xs) -> uses scope xs
    | Let_tuple (xts, y, e) ->
      use scope y;
      walk (binds scope xts) e
  in
  walk Ident.Set.empty exp
