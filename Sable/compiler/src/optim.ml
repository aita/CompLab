(* A small optimizer on K-normal form.

   Three passes, run a few times over:

     flatten_lets   `let x = (let y = e1 in e2) in e3` becomes
                    `let y = e1 in let x = e2 in e3`, undoing the nesting the
                    K-normalizer introduces and putting more of the program
                    within reach of the other two passes.
     propagate      copy propagation, constant folding, and folding a branch
                    whose operands are both known.
     eliminate      drop a `let` whose name is unused and whose right-hand side
                    has no effect.

   These matter to the back end more than they look.  K-normalization names
   every constant and every field access; after propagation and elimination
   those names are gone rather than competing for registers, and the decision
   trees Match_compile emits shed the field loads their branch never reads. *)

open Knormal

(* ------------------------------------------------------- flatten_lets *)

let rec flatten_lets = function
  | IfEq (x, y, e1, e2) -> IfEq (x, y, flatten_lets e1, flatten_lets e2)
  | IfLe (x, y, e1, e2) -> IfLe (x, y, flatten_lets e1, flatten_lets e2)
  | Let (xt, e1, e2) ->
    (* Push the outer binding past everything the inner expression binds. *)
    let rec rebuild = function
      | Let (yt, e3, e4) -> Let (yt, e3, rebuild e4)
      | LetRec (fds, e) -> LetRec (fds, rebuild e)
      | LetTuple (yts, z, e) -> LetTuple (yts, z, rebuild e)
      | e -> Let (xt, e, flatten_lets e2)
    in
    rebuild (flatten_lets e1)
  | LetRec (fds, e) ->
    LetRec
      (List.map (fun fd -> { fd with body = flatten_lets fd.body }) fds, flatten_lets e)
  | LetTuple (xts, y, e) -> LetTuple (xts, y, flatten_lets e)
  | e -> e

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
  | Bin (op, x, y) -> (
    match (const x, const y) with
    | Some a, Some b -> (
      match apply op a b with Some n -> Int n | None -> Bin (op, var x, var y))
    | _ -> Bin (op, var x, var y))
  | IfEq (x, y, e1, e2) -> (
    match (const x, const y) with
    | Some a, Some b -> propagate env (if a = b then e1 else e2)
    | _ -> IfEq (var x, var y, propagate env e1, propagate env e2))
  | IfLe (x, y, e1, e2) -> (
    match (const x, const y) with
    | Some a, Some b -> propagate env (if a <= b then e1 else e2)
    | _ -> IfLe (var x, var y, propagate env e1, propagate env e2))
  | Let ((x, t), e1, e2) -> (
    let e1 = propagate env e1 in
    match e1 with
    | Var y ->
      (* Copy propagation: the binding disappears entirely. *)
      propagate { env with copies = Ident.Map.add x y env.copies } e2
    | Int n ->
      (* Keep the binding -- some uses may still need a register -- but
         remember the value.  If every use folds, elimination collects it. *)
      Let ((x, t), e1, propagate { env with consts = Ident.Map.add x n env.consts } e2)
    | _ -> Let ((x, t), e1, propagate env e2))
  | LetRec (fds, e) ->
    LetRec
      (List.map (fun fd -> { fd with body = propagate env fd.body }) fds, propagate env e)
  | App (f, xs) -> App (var f, List.map var xs)
  | ExtFunApp (f, xs) -> ExtFunApp (f, List.map var xs)
  | Tuple xs -> Tuple (List.map var xs)
  | Block (tag, xs) -> Block (tag, List.map var xs)
  | LetTuple (xts, y, e) -> LetTuple (xts, var y, propagate env e)
  | Array (x, y) -> Array (var x, var y)
  | Get (x, y) -> Get (var x, var y)
  | Put (x, y, z) -> Put (var x, var y, var z)

(* ---------------------------------------------------------- eliminate *)

(* Allocation counts as pure, so an unused tuple, block or array is collected;
   anything that can print or store does not. *)
let rec has_effect = function
  | App _ | ExtFunApp _ | Put _ -> true
  | Let (_, e1, e2) -> has_effect e1 || has_effect e2
  | IfEq (_, _, e1, e2) | IfLe (_, _, e1, e2) -> has_effect e1 || has_effect e2
  | LetRec (_, e) | LetTuple (_, _, e) -> has_effect e
  | _ -> false

let rec eliminate = function
  | IfEq (x, y, e1, e2) -> IfEq (x, y, eliminate e1, eliminate e2)
  | IfLe (x, y, e1, e2) -> IfLe (x, y, eliminate e1, eliminate e2)
  | Let ((x, t), e1, e2) ->
    let e1 = eliminate e1 and e2 = eliminate e2 in
    if has_effect e1 || Ident.Set.mem x (free_vars e2) then Let ((x, t), e1, e2) else e2
  | LetRec (fds, e) ->
    let fds = List.map (fun fd -> { fd with body = eliminate fd.body }) fds in
    let e = eliminate e in
    (* The group can only be entered from the continuation: if no name of it is
       free there, the whole group is unreachable, however much its members
       mention each other. *)
    let used = free_vars e in
    if List.exists (fun fd -> Ident.Set.mem (fst fd.name) used) fds then LetRec (fds, e)
    else e
  | LetTuple (xts, y, e) ->
    let e = eliminate e in
    let used = free_vars e in
    if List.exists (fun (x, _) -> Ident.Set.mem x used) xts then LetTuple (xts, y, e)
    else e
  | e -> e

(* ------------------------------------------------------------- driver *)

(* A fixed number of rounds rather than a fixed point: the terms carry mutable
   type variables, so structural equality on them is not something to lean on,
   and the passes converge in two or three rounds anyway. *)
let optimize ~rounds exp =
  let rec loop n exp =
    if n <= 0 then exp
    else loop (n - 1) (eliminate (propagate nothing_known (flatten_lets exp)))
  in
  loop rounds exp
