(* A small optimizer on K-normal form.

   Two passes, run a few times over:

     propagate      copy propagation, constant folding, and folding a branch
                    whose operands are both known.
     eliminate      drop a `let` whose name is unused and whose right-hand side
                    has no effect.

   These matter to the back end more than they look.  K-normalization names
   every constant and every field access; after propagation and elimination
   those names are gone rather than competing for registers, and the decision
   trees Match_compile emits shed the field loads their branch never reads. *)

open Knormal

(* ---------------------------------------------------------- propagate *)

let apply op a b =
  match op with
  | Add -> Some (a + b)
  | Sub -> Some (a - b)
  | Mul -> Some (a * b)
  | Div -> if b = 0 then None else Some (a / b)
  | Rem -> if b = 0 then None else Some (a mod b)

type known = { consts : int Ident.Map.t; copies : Ident.t Ident.Map.t }

let nothing_known = { consts = Ident.Map.empty; copies = Ident.Map.empty }

let rec propagate env exp =
  let var x = match Ident.Map.find_opt x env.copies with Some y -> y | None -> x in
  let const x = Ident.Map.find_opt (var x) env.consts in
  match exp with
  | Int _ | Static _ -> exp
  | Var x -> ( match const x with Some n -> Int n | None -> Var (var x))
  | Neg x -> ( match const x with Some n -> Int (-n) | None -> Neg (var x))
  | Field (x, i) -> Field (var x, i)
  | Byte (x, y) -> Byte (var x, var y)
  | Bin (op, x, y) -> (
    match (const x, const y) with
    | Some a, Some b -> (
      match apply op a b with Some n -> Int n | None -> Bin (op, var x, var y))
    | _ -> Bin (op, var x, var y))
  | If_eq (x, y, e1, e2) -> (
    match (const x, const y) with
    | Some a, Some b -> propagate env (if a = b then e1 else e2)
    | _ -> If_eq (var x, var y, propagate env e1, propagate env e2))
  | If_le (x, y, e1, e2) -> (
    match (const x, const y) with
    | Some a, Some b -> propagate env (if a <= b then e1 else e2)
    | _ -> If_le (var x, var y, propagate env e1, propagate env e2))
  | Let ((x, t), e1, e2) -> (
    let e1 = propagate env e1 in
    match e1 with
    | Var y ->
      (* Copy propagation: the binding disappears entirely. *)
      propagate { env with copies = Ident.Map.add x y env.copies } e2
    | Int n ->
      (* Keep the binding -- some uses may still need a register -- but
         remember the value.  If every use folds, elimination collects it. *)
      Knormal.let_bind (x, t) e1
        (propagate { env with consts = Ident.Map.add x n env.consts } e2)
    | _ -> Knormal.let_bind (x, t) e1 (propagate env e2))
  | Let_rec (fds, e) ->
    Let_rec
      (List.map (fun fd -> { fd with body = propagate env fd.body }) fds, propagate env e)
  | App (f, xs) -> App (var f, List.map var xs)
  | App_external (f, xs) -> App_external (f, List.map var xs)
  | Tuple xs -> Tuple (List.map var xs)
  | Block (tag, xs) -> Block (tag, List.map var xs)
  | Let_tuple (xts, y, e) -> Let_tuple (xts, var y, propagate env e)
  | Array (x, y) -> Array (var x, var y)
  | Get (x, y) -> Get (var x, var y)
  | Put (x, y, z) -> Put (var x, var y, var z)

(* ---------------------------------------------------------- eliminate *)

(* Allocation counts as pure, so an unused tuple, block or array is collected;
   anything that can print or store does not. *)

(* One bottom-up pass that hands back, for each node, what it needs from
   outside it and whether it can be dropped.  Asking for those separately at
   every binding -- which is what this did before -- walks the continuation
   again per `let`, and K-normalization produces very long chains of them. *)
let rec eliminate exp =
  let pure free = (exp, free, false) in
  let effectful free = (exp, free, true) in
  match exp with
  | Int _ | Static _ -> pure Ident.Set.empty
  | Var x | Neg x | Field (x, _) -> pure (Ident.Set.singleton x)
  | Bin (_, x, y) | Array (x, y) | Get (x, y) | Byte (x, y) ->
    pure (Ident.Set.of_list [ x; y ])
  | Tuple xs | Block (_, xs) -> pure (Ident.Set.of_list xs)
  | Put (x, y, z) -> effectful (Ident.Set.of_list [ x; y; z ])
  | App (f, xs) -> effectful (Ident.Set.of_list (f :: xs))
  | App_external (_, xs) -> effectful (Ident.Set.of_list xs)
  | If_eq (x, y, e1, e2) -> branch (fun a b -> If_eq (x, y, a, b)) x y e1 e2
  | If_le (x, y, e1, e2) -> branch (fun a b -> If_le (x, y, a, b)) x y e1 e2
  | Let ((x, t), e1, e2) ->
    let e1, free1, impure1 = eliminate e1 in
    let e2, free2, impure2 = eliminate e2 in
    if impure1 || Ident.Set.mem x free2 then
      ( Knormal.let_bind (x, t) e1 e2,
        Ident.Set.union free1 (Ident.Set.remove x free2),
        impure1 || impure2 )
    else (e2, free2, impure2)
  | Let_tuple (xts, y, e) ->
    let e, free, impure = eliminate e in
    if List.exists (fun (x, _) -> Ident.Set.mem x free) xts then
      ( Let_tuple (xts, y, e),
        Ident.Set.add y
          (Ident.Set.diff free (Ident.Set.of_list (List.map fst xts))),
        impure )
    else (e, free, impure)
  | Let_rec (fds, body) ->
    let fds, wanted =
      List.fold_left
        (fun (fds, wanted) fd ->
          let body, free, _ = eliminate fd.body in
          let free = Ident.Set.diff free (Ident.Set.of_list (List.map fst fd.args)) in
          ({ fd with body } :: fds, Ident.Set.union wanted free))
        ([], Ident.Set.empty) fds
    in
    let fds = List.rev fds in
    let body, free, impure = eliminate body in
    (* The group can only be entered from the continuation: if no name of it is
       free there, the whole group is unreachable, however much its members
       mention each other. *)
    if List.exists (fun fd -> Ident.Set.mem (fst fd.name) free) fds then
      ( Let_rec (fds, body),
        Ident.Set.diff (Ident.Set.union wanted free)
          (Ident.Set.of_list (List.map (fun fd -> fst fd.name) fds)),
        impure )
    else (body, free, impure)

and branch rebuild x y e1 e2 =
  let e1, free1, impure1 = eliminate e1 in
  let e2, free2, impure2 = eliminate e2 in
  ( rebuild e1 e2,
    Ident.Set.add x (Ident.Set.add y (Ident.Set.union free1 free2)),
    impure1 || impure2 )

let eliminate exp = let e, _, _ = eliminate exp in e

(* ------------------------------------------------------------- driver *)

(* `flatten_lets` used to run here, re-associating what normalization left
   nested -- MinCaml's Assoc.  Knormal.let_bind now associates as it builds and
   the two passes above rebuild their bindings through it, so there is nothing
   left to repair.

   A fixed number of rounds rather than a fixed point: the terms carry mutable
   type variables, so structural equality on them is not something to lean on,
   and the passes converge in two or three rounds anyway. *)
let optimize ~rounds exp =
  let rec loop n exp =
    if n <= 0 then exp
    else loop (n - 1) (eliminate (propagate nothing_known exp))
  in
  loop rounds exp
