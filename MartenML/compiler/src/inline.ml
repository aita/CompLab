(* Replace a call to a small function with a copy of its body.

   K-normal form does most of the work.  Every argument is already a variable,
   so binding the parameters is a substitution rather than a wrapper of `let`s,
   and Alpha's renamer already takes an environment -- handing it
   `parameter -> argument` both substitutes the arguments and freshens the
   copy's own binders in one walk.  That freshening is not optional: two copies
   of a body would otherwise bind the same names twice, which is exactly what
   `--check-knf` reports.

   Only functions that do not call themselves are inlined, and a group of
   mutually recursive functions is left alone.  That is not a restriction worth
   working around: across the examples and tests, every call to a function
   small enough to inline goes to one that is not recursive.  It also makes
   termination obvious -- there is no unrolling to bound.

   What it buys is not mainly the `call` instruction.  A call clobbers every
   caller-saved register, so it forces whatever is live across it into a
   callee-saved register or onto the stack; removing the call removes that
   pressure as well as the argument and result moves at both ends. *)

open Knormal

(* Nodes, counting both arms of a branch.  Rough on purpose: it decides
   nothing except which side of the threshold a function falls. *)
let rec size = function
  | Int _ | Var _ | Neg _ | Bin _ | Static _ | Field _ | Byte _ | Array _ | Get _ | Put _
  | App _ | App_external _ | Tuple _ | Block _ ->
    1
  | If_eq (_, _, e1, e2) | If_le (_, _, e1, e2) -> 1 + size e1 + size e2
  | Let (_, e1, e2) -> 1 + size e1 + size e2
  | Let_tuple (xts, _, e) -> List.length xts + size e
  | Let_rec (fds, e) -> List.fold_left (fun n fd -> n + 1 + size fd.body) (size e) fds

(* A function that mentions its own name calls itself: after Alpha the name is
   unique, so a free occurrence in the body can be nothing else. *)
let self_recursive fd = Ident.Set.mem (fst fd.name) (free_vars fd.body)

let rec apply threshold env exp =
  let recur = apply threshold env in
  match exp with
  | App (f, args) -> (
    match Ident.Map.find_opt f env with
    | Some (params, body) when List.length params = List.length args ->
      let substitution =
        List.fold_left2
          (fun m (p, _) a -> Ident.Map.add p a m)
          Ident.Map.empty params args
      in
      Alpha.rename_exp substitution body
    | _ -> exp)
  | Let (xt, e1, e2) ->
    (* The copy may itself be a chain of `let`s, so the binding is rebuilt
       through `let_bind` rather than `Let` (see Knormal). *)
    let_bind xt (recur e1) (recur e2)
  | Let_rec (fds, body) ->
    let fds = List.map (fun fd -> { fd with body = recur fd.body }) fds in
    (* Registered only after its own body has been through the pass, so a
       function that grew past the threshold by inlining is not itself
       inlined. *)
    let env =
      match fds with
      | [ fd ] when (not (self_recursive fd)) && size fd.body <= threshold ->
        Ident.Map.add (fst fd.name) (fd.args, fd.body) env
      | _ -> env
    in
    Let_rec (fds, apply threshold env body)
  | Let_tuple (xts, y, e) -> Let_tuple (xts, y, recur e)
  | If_eq (x, y, e1, e2) -> If_eq (x, y, recur e1, recur e2)
  | If_le (x, y, e1, e2) -> If_le (x, y, recur e1, recur e2)
  | Int _ | Var _ | Neg _ | Bin _ | Static _ | Field _ | Byte _ | Array _ | Get _ | Put _
  | App_external _ | Tuple _ | Block _ ->
    exp

(* A definition whose every call site was replaced has no free occurrence left,
   and the optimizer's `eliminate` drops the whole group on that basis -- there
   is nothing to remove here. *)
let expand ~threshold exp =
  if threshold <= 0 then exp else apply threshold Ident.Map.empty exp
