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
  | Bin of Anf.binop * Ident.t * Ident.t
  | If_eq of Ident.t * Ident.t * t * t
  | If_le of Ident.t * Ident.t * t * t
  | Let of (Ident.t * Types.t) * t * t
  | Make_closure of (Ident.t * Types.t) * closure * t
  | Call_closure of Ident.t * Ident.t list
  | Call_direct of Ident.label * Ident.t list
  | Tuple of Ident.t list
  | Let_tuple of (Ident.t * Types.t) list * Ident.t * t
  | Block of int * Ident.t list
  | Static of Ident.label
  | Field of Ident.t * int
  | Byte of Ident.t * Ident.t
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
  | Byte (x, y) -> Ident.Set.of_list [ x; y ]
  | Bin (_, x, y) | Array (x, y) | Get (x, y) -> Ident.Set.of_list [ x; y ]
  | Put (x, y, z) -> Ident.Set.of_list [ x; y; z ]
  | If_eq (x, y, e1, e2) | If_le (x, y, e1, e2) ->
    Ident.Set.add x
      (Ident.Set.add y (Ident.Set.union (free_vars e1) (free_vars e2)))
  | Let ((x, _), e1, e2) ->
    Ident.Set.union (free_vars e1) (Ident.Set.remove x (free_vars e2))
  | Make_closure ((x, _), { captured; _ }, e) ->
    Ident.Set.remove x (Ident.Set.union (Ident.Set.of_list captured) (free_vars e))
  | Call_closure (f, xs) -> Ident.Set.of_list (f :: xs)
  | Call_direct (_, xs) | Tuple xs | Block (_, xs) -> Ident.Set.of_list xs
  | Let_tuple (xts, y, e) ->
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
  | Anf.Int n -> Int n
  | Anf.Var x -> Var x
  | Anf.Neg x -> Neg x
  | Anf.Bin (op, x, y) -> Bin (op, x, y)
  | Anf.If_eq (x, y, e1, e2) -> If_eq (x, y, recur e1, recur e2)
  | Anf.If_le (x, y, e1, e2) -> If_le (x, y, recur e1, recur e2)
  | Anf.Let ((x, t), e1, e2) ->
    Let ((x, t), recur e1, convert_exp (Ident.Map.add x t env) known e2)
  | Anf.App (f, xs) when Ident.Set.mem f known -> Call_direct (Ident.to_label f, xs)
  | Anf.App (f, xs) -> Call_closure (f, xs)
  | Anf.App_external (f, xs) -> Call_direct (Ident.extern_label f, xs)
  | Anf.Tuple xs -> Tuple xs
  | Anf.Block (tag, xs) -> Block (tag, xs)
  | Anf.Static label -> Static label
  | Anf.Field (x, i) -> Field (x, i)
  | Anf.Byte (x, y) -> Byte (x, y)
  | Anf.Let_tuple (xts, y, e) ->
    let env = List.fold_left (fun env (x, t) -> Ident.Map.add x t env) env xts in
    Let_tuple (xts, y, convert_exp env known e)
  | Anf.Array (x, y) -> Array (x, y)
  | Anf.Get (x, y) -> Get (x, y)
  | Anf.Put (x, y, z) -> Put (x, y, z)
  | Anf.Let_rec (fds, cont) -> convert_group env known fds cont

and convert_group env known fds cont =
  let names = List.map (fun (fd : Anf.fundef) -> fst fd.name) fds in
  let env =
    List.fold_left
      (fun env (fd : Anf.fundef) -> Ident.Map.add (fst fd.name) (snd fd.name) env)
      env fds
  in
  let convert_bodies known =
    List.map
      (fun (fd : Anf.fundef) ->
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
      (fun acc (fd : Anf.fundef) body ->
        Ident.Set.union acc
          (Ident.Set.diff (free_vars body)
             (Ident.Set.of_list (List.map fst fd.args @ names))))
      Ident.Set.empty fds bodies
  in
  if Ident.Set.is_empty captured then begin
    (* Every member is directly callable.  A member used as a value inside a
       body just allocates a code-pointer-only closure there. *)
    List.iter2
      (fun (fd : Anf.fundef) body ->
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
