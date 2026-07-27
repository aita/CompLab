(* Closure conversion: lift every function to the top level.

   A function that captures nothing is called directly (Call_direct) and needs
   no runtime representation at all.  A function that captures something becomes
   a heap block [ code pointer ; captured values... ]; calling it
   (Call_closure) loads the code pointer and passes the block itself in a
   dedicated register, from which the callee reads its captures.

   Deciding which is which is the usual optimistic fixed point: assume the whole
   `let rec` group is directly callable, convert the bodies, and see whether
   anything is still free.  If something is, redo the group knowing it needs
   closures. *)

type closure = { entry : Ident.label; captured : Ident.t list }

type t =
  | Int of int
  | Var of Ident.t
  | Neg of Ident.t
  | Bin of Knormal.binop * Ident.t * Ident.t
  | IfEq of Ident.t * Ident.t * t * t
  | IfLe of Ident.t * Ident.t * t * t
  | Let of (Ident.t * Types.t) * t * t
  | Make_closure of (Ident.t * Types.t) * closure * t
  | Call_closure of Ident.t * Ident.t list
  | Call_direct of Ident.label * Ident.t list
  | Tuple of Ident.t list
  | LetTuple of (Ident.t * Types.t) list * Ident.t * t
  | Block of int * Ident.t list
  | Static of Ident.label
  | Field of Ident.t * int
  | Array of Ident.t * Ident.t
  | Get of Ident.t * Ident.t
  | Put of Ident.t * Ident.t * Ident.t

type fundef = {
  label : Ident.label;
  args : (Ident.t * Types.t) list;
  captures : (Ident.t * Types.t) list;
  body : t;
}

type program = { functions : fundef list; main : t }

exception Error of string

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
  | Make_closure ((x, _), { captured; _ }, e) ->
    Ident.Set.remove x (Ident.Set.union (Ident.Set.of_list captured) (free_vars e))
  | Call_closure (f, xs) -> Ident.Set.of_list (f :: xs)
  | Call_direct (_, xs) | Tuple xs | Block (_, xs) -> Ident.Set.of_list xs
  | LetTuple (xts, y, e) ->
    Ident.Set.add y
      (Ident.Set.diff (free_vars e) (Ident.Set.of_list (List.map fst xts)))

let lifted : fundef list ref = ref []

(* Allocate a closure for each of [names] that [body] still mentions as a
   value.  Only used for capture-free functions, whose closure is nothing but a
   code pointer and can therefore be built anywhere. *)
let close_over env names body =
  List.fold_left
    (fun body x ->
      if Ident.Set.mem x (free_vars body) then
        Make_closure
          ((x, Ident.Map.find x env), { entry = Ident.to_label x; captured = [] }, body)
      else body)
    body names

let rec convert_exp env known exp =
  let recur = convert_exp env known in
  match exp with
  | Knormal.Int n -> Int n
  | Knormal.Var x -> Var x
  | Knormal.Neg x -> Neg x
  | Knormal.Bin (op, x, y) -> Bin (op, x, y)
  | Knormal.IfEq (x, y, e1, e2) -> IfEq (x, y, recur e1, recur e2)
  | Knormal.IfLe (x, y, e1, e2) -> IfLe (x, y, recur e1, recur e2)
  | Knormal.Let ((x, t), e1, e2) ->
    Let ((x, t), recur e1, convert_exp (Ident.Map.add x t env) known e2)
  | Knormal.App (f, xs) when Ident.Set.mem f known -> Call_direct (Ident.to_label f, xs)
  | Knormal.App (f, xs) -> Call_closure (f, xs)
  | Knormal.ExtFunApp (f, xs) -> Call_direct (Ident.extern_label f, xs)
  | Knormal.Tuple xs -> Tuple xs
  | Knormal.Block (tag, xs) -> Block (tag, xs)
  | Knormal.Static label -> Static label
  | Knormal.Field (x, i) -> Field (x, i)
  | Knormal.LetTuple (xts, y, e) ->
    let env = List.fold_left (fun env (x, t) -> Ident.Map.add x t env) env xts in
    LetTuple (xts, y, convert_exp env known e)
  | Knormal.Array (x, y) -> Array (x, y)
  | Knormal.Get (x, y) -> Get (x, y)
  | Knormal.Put (x, y, z) -> Put (x, y, z)
  | Knormal.LetRec (fds, cont) -> convert_group env known fds cont

and convert_group env known fds cont =
  let names = List.map (fun (fd : Knormal.fundef) -> fst fd.name) fds in
  let env =
    List.fold_left
      (fun env (fd : Knormal.fundef) -> Ident.Map.add (fst fd.name) (snd fd.name) env)
      env fds
  in
  let convert_bodies known =
    List.map
      (fun (fd : Knormal.fundef) ->
        let body_env =
          List.fold_left (fun env (x, t) -> Ident.Map.add x t env) env fd.args
        in
        convert_exp body_env known fd.body)
      fds
  in
  let lifted_before = !lifted in
  let optimistic = List.fold_left (fun set n -> Ident.Set.add n set) known names in
  let bodies = convert_bodies optimistic in
  (* What each body still needs from outside, ignoring the group's own names:
     those are code pointers, not captured values. *)
  let captured =
    List.fold_left2
      (fun acc (fd : Knormal.fundef) body ->
        Ident.Set.union acc
          (Ident.Set.diff (free_vars body)
             (Ident.Set.of_list (List.map fst fd.args @ names))))
      Ident.Set.empty fds bodies
  in
  if Ident.Set.is_empty captured then begin
    (* Every member is directly callable.  A member used as a value inside a
       body just allocates a code-pointer-only closure there. *)
    List.iter2
      (fun (fd : Knormal.fundef) body ->
        lifted :=
          {
            label = Ident.to_label (fst fd.name);
            args = fd.args;
            captures = [];
            body = close_over env names body;
          }
          :: !lifted)
      fds bodies;
    close_over env names (convert_exp env optimistic cont)
  end
  else begin
    if List.length fds > 1 then
      raise
        (Error
           (Printf.sprintf
              "the mutually recursive functions %s capture the variable(s) %s.\n\
               Only a self-recursive function may capture its environment; \
               pass the captured\nvalues as arguments instead."
              (String.concat ", " (List.map Ident.display names))
              (String.concat ", "
                 (List.map Ident.display (Ident.Set.elements captured)))));
    (* One function, and it needs a closure.  Throw away the optimistic bodies:
       its recursive calls have to go through the closure too. *)
    lifted := lifted_before;
    let fd = List.hd fds in
    let body = List.hd (convert_bodies known) in
    (* The function's own name may be free in its body -- that is how it calls
       itself -- so it is captured like any other variable.  Make_closure binds
       the name before storing the captures, which makes that self-reference
       point at the closure being built. *)
    let captures =
      Ident.Set.elements
        (Ident.Set.diff (free_vars body) (Ident.Set.of_list (List.map fst fd.args)))
    in
    let name = fst fd.name in
    lifted :=
      {
        label = Ident.to_label name;
        args = fd.args;
        captures = List.map (fun z -> (z, Ident.Map.find z env)) captures;
        body;
      }
      :: !lifted;
    let cont = convert_exp env known cont in
    if Ident.Set.mem name (free_vars cont) then
      Make_closure
        ((name, snd fd.name), { entry = Ident.to_label name; captured = captures }, cont)
    else cont
  end

let convert exp =
  lifted := [];
  let main = convert_exp Ident.Map.empty Ident.Set.empty exp in
  { functions = List.rev !lifted; main }
