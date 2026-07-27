(* Types, and the destructive unification used by the type checker.

   The language is monomorphic: there is no generalization at `let`, so a type
   variable created for a binding is shared by every use of it.  Polymorphic
   *constructs* (=, Array.make, ...) are syntax rather than functions, so each
   occurrence gets its own fresh variables and the usual ML idioms still work.
   See the README for what this rules out. *)

type t =
  | Unit
  | Bool
  | Int
  | Named of string (* a datatype introduced by a `type` declaration *)
  | Fun of t list * t (* uncurried: all arguments are applied at once *)
  | Tuple of t list
  | Array of t
  | Var of t option ref

exception Unify of t * t

let fresh_var () = Var (ref None)

(* Follow the substitution down to the outermost real constructor. *)
let rec repr = function
  | Var { contents = Some t } -> repr t
  | t -> t

let rec occurs r = function
  | Fun (ts, t) -> List.exists (occurs r) ts || occurs r t
  | Tuple ts -> List.exists (occurs r) ts
  | Array t -> occurs r t
  | Var r' when r == r' -> true
  | Var { contents = Some t } -> occurs r t
  | _ -> false

let rec unify t1 t2 =
  match (t1, t2) with
  | Unit, Unit | Bool, Bool | Int, Int -> ()
  | Named a, Named b when a = b -> ()
  | Fun (a1, r1), Fun (a2, r2) when List.length a1 = List.length a2 ->
    List.iter2 unify a1 a2;
    unify r1 r2
  | Tuple ts1, Tuple ts2 when List.length ts1 = List.length ts2 ->
    List.iter2 unify ts1 ts2
  | Array e1, Array e2 -> unify e1 e2
  | Var r1, Var r2 when r1 == r2 -> ()
  | Var { contents = Some t1' }, _ -> unify t1' t2
  | _, Var { contents = Some t2' } -> unify t1 t2'
  | Var ({ contents = None } as r), _ ->
    if occurs r t2 then raise (Unify (t1, t2));
    r := Some t2
  | _, Var ({ contents = None } as r) ->
    if occurs r t1 then raise (Unify (t1, t2));
    r := Some t1
  | _ -> raise (Unify (t1, t2))

(* Type variables still unresolved once the whole program is checked are not
   ambiguous in any interesting way -- every value is one machine word -- so
   pick `int` and move on. *)
let rec resolve = function
  | Fun (ts, t) -> Fun (List.map resolve ts, resolve t)
  | Tuple ts -> Tuple (List.map resolve ts)
  | Array t -> Array (resolve t)
  | Var ({ contents = None } as r) ->
    r := Some Int;
    Int
  | Var ({ contents = Some t } as r) ->
    let t = resolve t in
    r := Some t;
    t
  | t -> t

let rec to_string t =
  match repr t with
  | Unit -> "unit"
  | Bool -> "bool"
  | Int -> "int"
  | Named n -> n
  | Fun (ts, r) ->
    "(" ^ String.concat " * " (List.map to_string ts) ^ " -> " ^ to_string r ^ ")"
  | Tuple ts -> "(" ^ String.concat " * " (List.map to_string ts) ^ ")"
  | Array t -> to_string t ^ " array"
  | Var _ -> "'_a"
