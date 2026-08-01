(* A second implementation of the language: substitution-free, tree-walking,
   directly over the core tree.

   This is not how the language runs.  It exists so that every test can be run
   twice and the answers compared: once by compiling to the machine, and once by
   an evaluator small enough to be read in one sitting and believed.  When the
   two disagree, one of them is wrong and the program is not — which is a much
   better position to debug a compiler from than a single implementation that is
   its own oracle.

   It has proper tail calls too, for a reason worth stating: every recursive call
   below that stands in tail position of the *core* expression also stands in
   tail position of the OCaml function, so OCaml makes it a jump.  The evaluator
   does not implement tail calls; it inherits them. *)

module Env = Map.Make (Int)

type value =
  | VInt of int64
  | VBool of bool
  | VUnit
  | VTuple of value array
  | VClosure of Core.lambda * env ref

and env = value Env.t

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

let prim op args =
  match (op, args) with
  | Core.Neg, [ a ] -> VInt (Int64.neg (int_of a))
  | _, [ a; b ] -> (
      let a = int_of a and b = int_of b in
      let cmp f = VBool (f (Int64.compare a b) 0) in
      match op with
      | Core.Add -> VInt (Int64.add a b)
      | Core.Sub -> VInt (Int64.sub a b)
      | Core.Mul -> VInt (Int64.mul a b)
      | Core.Div -> if b = 0L then die "division by zero" else VInt (Int64.div a b)
      | Core.Mod -> if b = 0L then die "division by zero" else VInt (Int64.rem a b)
      | Core.Eq -> cmp ( = )
      | Core.Ne -> cmp ( <> )
      | Core.Lt -> cmp ( < )
      | Core.Le -> cmp ( <= )
      | Core.Gt -> cmp ( > )
      | Core.Ge -> cmp ( >= )
      | Core.Neg -> die "neg takes one argument")
  | _ -> die "%s got the wrong number of arguments" (Core.prim_name op)

let bind env names values =
  List.fold_left2
    (fun env (n : Core.name) v -> Env.add n.Core.id v env)
    env names values

let rec eval env (e : Core.expr) =
  match e with
  | Core.Int n -> VInt n
  | Core.Bool b -> VBool b
  | Core.Unit -> VUnit
  | Core.Var n -> (
      match Env.find_opt n.Core.id env with
      | Some v -> v
      | None -> die "%s is not bound" (Core.show_name n))
  | Core.Tuple es -> VTuple (Array.of_list (List.map (eval env) es))
  | Core.Proj (i, e) -> (
      match eval env e with
      | VTuple fields when i < Array.length fields -> fields.(i)
      | v -> die "%s has no field %d" (show v) i)
  | Core.Prim (op, args) -> prim op (List.map (eval env) args)
  | Core.If (c, t, f) -> if bool_of (eval env c) then eval env t else eval env f
  | Core.Let (binder, rhs, body) ->
      let v = eval env rhs in
      let env = match binder with Some n -> Env.add n.Core.id v env | None -> env in
      eval env body
  | Core.Untuple (rhs, binders, body) ->
      let fields =
        match eval env rhs with
        | VTuple fields -> fields
        | v -> die "%s is not a tuple" (show v)
      in
      let env, _ =
        List.fold_left
          (fun (env, i) binder ->
            match binder with
            | Some (n : Core.name) -> (Env.add n.Core.id fields.(i) env, i + 1)
            | None -> (env, i + 1))
          (env, 0) binders
      in
      eval env body
  (* The knot: the closures see an environment that is not finished until they
     are in it, so they share the cell it will be written into. *)
  | Core.Letrec (group, body) ->
      let cell = ref env in
      let env =
        List.fold_left
          (fun env ((n : Core.name), l) ->
            Env.add n.Core.id (VClosure (l, cell)) env)
          env group
      in
      cell := env;
      eval env body
  | Core.Fn l -> VClosure (l, ref env)
  | Core.App (f, args) -> (
      let callee = eval env f in
      let values = List.map (eval env) args in
      match callee with
      | VClosure (l, cell) ->
          if List.length l.Core.params <> List.length values then
            die "this function takes %d argument(s), not %d"
              (List.length l.Core.params) (List.length values);
          eval (bind !cell l.Core.params values) l.Core.body
      | v -> die "%s is not a function" (show v))

let program core = eval Env.empty core
