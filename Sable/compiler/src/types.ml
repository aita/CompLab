(* Types, unification, and let-polymorphism.

   Generalization is by levels (Rémy's method, the one OCaml itself uses).
   Every unbound type variable records the `let` nesting depth at which it was
   created.  Unifying a variable with a type pushes the levels inside that type
   down to the variable's own, so a variable that has escaped into an outer
   scope carries a level that says so.  Generalizing at depth d then quantifies
   exactly the variables whose level is deeper than d: those are the ones no
   outer binding can still constrain.  It costs one traversal per `let` instead
   of scanning the environment.

   The parser attaches a type variable to every binder, pattern variable and
   `match` for the later passes to read back.  Those slots are write-only as far
   as inference is concerned: they are created before inference starts, so at
   depth 0, and unifying against one would drag every variable in the inferred
   type down to depth 0 and quantify nothing.  Inference works with its own
   variables and calls [assign] at the end.  See Typing. *)

type t =
  | Unit
  | Bool
  | Int
  | String (* immutable, byte-packed *)
  | List of t (* built in, so it can be genuinely polymorphic *)
  | Named of string (* a datatype introduced by a `type` declaration *)
  | Fun of t list * t (* uncurried: all arguments are applied at once *)
  | Tuple of t list
  | Array of t
  | Var of var ref

and var =
  | Unbound of int * int (* identity, level *)
  | Link of t

exception Unify of t * t
exception Occurs

(* A type together with the variables a use of it may rename. *)
type scheme = { quantified : int list; body : t }

let current_level = ref 0
let enter_level () = incr current_level
let leave_level () = decr current_level
let next_id = ref 0

let fresh_var () =
  incr next_id;
  Var (ref (Unbound (!next_id, !current_level)))

(* Follow links to the outermost real constructor. *)
let rec repr t = match t with Var { contents = Link t } -> repr t | t -> t

let children f t =
  match repr t with
  | Fun (args, result) ->
    List.iter f args;
    f result
  | Tuple ts -> List.iter f ts
  | Array t | List t -> f t
  | _ -> ()

(* Before linking a variable, check it does not occur in what it is about to
   become, and pull the levels inside down to its own: anything reachable from
   a variable at depth d is no deeper than d. *)
let rec occurs_and_lower id level t =
  match repr t with
  | Var ({ contents = Unbound (id', level') } as r) ->
    if id' = id then raise Occurs;
    if level' > level then r := Unbound (id', level)
  | t -> children (occurs_and_lower id level) t

let rec unify t1 t2 =
  let a = repr t1 and b = repr t2 in
  match (a, b) with
  | Unit, Unit | Bool, Bool | Int, Int | String, String -> ()
  | Named x, Named y when x = y -> ()
  | List e1, List e2 -> unify e1 e2
  | Array e1, Array e2 -> unify e1 e2
  | Fun (a1, r1), Fun (a2, r2) when List.length a1 = List.length a2 ->
    List.iter2 unify a1 a2;
    unify r1 r2
  | Tuple ts1, Tuple ts2 when List.length ts1 = List.length ts2 ->
    List.iter2 unify ts1 ts2
  | Var r1, Var r2 when r1 == r2 -> ()
  | Var ({ contents = Unbound (id, level) } as r), other
  | other, Var ({ contents = Unbound (id, level) } as r) ->
    (try occurs_and_lower id level other with Occurs -> raise (Unify (a, b)));
    r := Link other
  | _ -> raise (Unify (a, b))

(* Link a slot the parser created, without disturbing any level.  Sound only
   because nothing ever unifies against these slots; they exist so that the
   passes after Typing can read a type off a binder. *)
let assign slot t =
  match slot with
  | Var ({ contents = Unbound _ } as r) -> r := Link t
  | _ -> ()

(* ------------------------------------------------------- polymorphism *)

let monomorphic body = { quantified = []; body }

(* Quantify the variables no enclosing binding can still constrain. *)
let generalize body =
  let ids = ref [] in
  let rec collect t =
    match repr t with
    | Var { contents = Unbound (id, level) } ->
      if level > !current_level && not (List.mem id !ids) then ids := id :: !ids
    | t -> children collect t
  in
  collect body;
  { quantified = !ids; body }

(* A use of a scheme gets its own copy of the quantified variables. *)
let instantiate scheme =
  if scheme.quantified = [] then scheme.body
  else begin
    let fresh = List.map (fun id -> (id, fresh_var ())) scheme.quantified in
    let rec copy t =
      match repr t with
      | Var { contents = Unbound (id, _) } as v -> (
        match List.assoc_opt id fresh with Some replacement -> replacement | None -> v)
      | Fun (args, result) -> Fun (List.map copy args, copy result)
      | Tuple ts -> Tuple (List.map copy ts)
      | Array t -> Array (copy t)
      | List t -> List (copy t)
      | t -> t
    in
    copy scheme.body
  end

(* Hold a type at the outermost level so that no `let` will ever quantify it.
   Used for the operands of a comparison, which have to settle on a type this
   compiler can compare with one instruction. *)
let rec pin t =
  match repr t with
  | Var ({ contents = Unbound (id, _) } as r) -> r := Unbound (id, 0)
  | t -> children pin t

(* Variables still unbound once the whole program is checked are not ambiguous
   in any interesting way -- every value is one machine word -- so pick `int`. *)
let rec resolve t =
  match repr t with
  | Var ({ contents = Unbound _ } as r) ->
    r := Link Int;
    Int
  | Fun (args, result) -> Fun (List.map resolve args, resolve result)
  | Tuple ts -> Tuple (List.map resolve ts)
  | Array t -> Array (resolve t)
  | List t -> List (resolve t)
  | t -> t

let to_string t =
  let names = ref [] in
  let name_of id =
    match List.assoc_opt id !names with
    | Some n -> n
    | None ->
      let n = List.length !names in
      let letter = String.make 1 (Char.chr (Char.code 'a' + (n mod 26))) in
      let name = "'" ^ if n < 26 then letter else letter ^ string_of_int (n / 26) in
      names := (id, name) :: !names;
      name
  in
  let rec show t =
    match repr t with
    | Unit -> "unit"
    | Bool -> "bool"
    | Int -> "int"
    | String -> "string"
    | List t -> show t ^ " list"
    | Named n -> n
    | Fun (args, result) ->
      "(" ^ String.concat " * " (List.map show args) ^ " -> " ^ show result ^ ")"
    | Tuple ts -> "(" ^ String.concat " * " (List.map show ts) ^ ")"
    | Array t -> show t ^ " array"
    | Var { contents = Unbound (id, _) } -> name_of id
    | Var _ -> assert false
  in
  show t
