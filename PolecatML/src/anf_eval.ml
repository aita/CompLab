(* The third way to run a program: an interpreter over A-normal form.

   It is shorter than the evaluator over the core tree, and the reason is the
   form rather than the effort.  Nothing here evaluates an operand: an operand is
   an atom, and [atom] is a lookup.  So the only recursive call that computes
   anything is the one for a `let`, and everything else — a branch, a jump, a
   tail call, a return — hands the work to whatever comes next, in tail position.

   That is also what makes the machine's three features fall out for free.  A
   tail call is `Ret (App ...)`, which calls [eval] in tail position, so OCaml
   makes it a jump.  A jump to a join point is [eval] on the join's body, in tail
   position again, so a branch that rejoins costs nothing and holds nothing.  And
   a `let` is the one place a value has to be kept while something else runs,
   which is precisely what the machine's operand stack is for. *)

module Env = Map.Make (Int)

type value =
  | VInt of int64
  | VBool of bool
  | VUnit
  | VTuple of value array
  | VClosure of Anf.lambda * env ref

(* A join point is not a value: it cannot be passed, returned or stored, and the
   only thing that can be done with it is to jump to it.  So it lives in a table
   of its own beside the variables, and a program cannot get at it by name. *)
and env = { vars : value Env.t; joins : join Env.t }

and join = { parameter : Anf.name; body : Anf.expr; defined_in : env }

exception Error of string

let die fmt = Printf.ksprintf (fun message -> raise (Error message)) fmt

let rec show = function
  | VInt n -> Int64.to_string n
  | VBool true -> "true"
  | VBool false -> "false"
  | VUnit -> "()"
  | VTuple vs -> "(" ^ String.concat ", " (Array.to_list (Array.map show vs)) ^ ")"
  | VClosure _ -> "fn"

let int_of = function VInt n -> n | v -> die "%s is not an integer" (show v)
let bool_of = function VBool b -> b | v -> die "%s is not a boolean" (show v)

let empty = { vars = Env.empty; joins = Env.empty }
let bind env (n : Anf.name) value = { env with vars = Env.add n.Core.id value env.vars }

let bind_all env names values =
  List.fold_left2 (fun env n v -> bind env n v) env names values

let atom env (a : Anf.atom) =
  match a with
  | Anf.Int n -> VInt n
  | Anf.Bool b -> VBool b
  | Anf.Unit -> VUnit
  | Anf.Var n -> (
      match Env.find_opt n.Core.id env.vars with
      | Some v -> v
      | None -> die "%s is not bound" (Core.show_name n))

let prim op args =
  match
    try Core.apply_prim op (List.map int_of args)
    with Core.Prim_error message -> die "%s" message
  with
  | Core.Prim_int n -> VInt n
  | Core.Prim_bool b -> VBool b

let rec eval env (e : Anf.expr) =
  match e with
  | Anf.Ret c -> comp env c
  | Anf.Let (n, c, rest) ->
      let value = comp env c in
      eval (bind env n value) rest
  | Anf.If (a, t, f) -> if bool_of (atom env a) then eval env t else eval env f
  (* The same knot the core evaluator ties: the closures of a group see an
     environment they are themselves in. *)
  | Anf.Letrec (group, rest) ->
      let cell = ref env in
      let env =
        List.fold_left
          (fun env (n, l) -> bind env n (VClosure (l, cell)))
          env group
      in
      cell := env;
      eval env rest
  (* A join point remembers where it was written, not where it is jumped to:
     names bound inside a branch are not in scope in the code both branches
     share. *)
  | Anf.Join (j, parameter, body, rest) ->
      let point = { parameter; body; defined_in = env } in
      eval { env with joins = Env.add j.Core.id point env.joins } rest
  | Anf.Jump (j, a) -> (
      match Env.find_opt j.Core.id env.joins with
      | Some point -> eval (bind point.defined_in point.parameter (atom env a)) point.body
      | None -> die "%s is not a join point here" (Core.show_name j))

and comp env (c : Anf.comp) =
  match c with
  | Anf.Atom a -> atom env a
  | Anf.Prim (op, args) -> prim op (List.map (atom env) args)
  | Anf.Tuple args -> VTuple (Array.of_list (List.map (atom env) args))
  | Anf.Proj (i, a) -> (
      match atom env a with
      | VTuple fields when i < Array.length fields -> fields.(i)
      | v -> die "%s has no field %d" (show v) i)
  | Anf.Fn l -> VClosure (l, ref env)
  | Anf.App (callee, args) -> (
      let values = List.map (atom env) args in
      match atom env callee with
      | VClosure (l, cell) ->
          if List.length l.Anf.params <> List.length values then
            die "this function takes %d argument(s), not %d"
              (List.length l.Anf.params) (List.length values);
          (* A jump cannot leave the function it is written in, and the join
             points in scope where the closure was built are not in scope in its
             body — so they are dropped rather than carried, and a normaliser
             that let one escape is caught here instead of working by luck. *)
          let inside = { !cell with joins = Env.empty } in
          eval (bind_all inside l.Anf.params values) l.Anf.body
      | v -> die "%s is not a function" (show v))

let program (anf : Anf.expr) = eval empty anf
