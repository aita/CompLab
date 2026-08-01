(* The core language: what is left of a program once the reader has been served.

   Compared with the surface tree, three things have gone.  Names are unique, so
   nothing below has to think about shadowing — a `let x` inside a `let x` is two
   different [name]s and the second one does not hide anything.  Patterns have
   become [Untuple], which is the only irrefutable destructuring this language
   has.  And every sugar — `andalso`, `not`, annotations, `fun ... and ...` — has
   turned into the six forms that actually mean something: bind, branch,
   allocate, project, apply, and compute.

   This is the last tree.  [Resolve] turns names into slot numbers, and after
   that the program is a graph of functions, not a tree of expressions. *)

type name = { id : int; text : string }

let counter = ref 0
let reset () = counter := 0

let fresh text =
  incr counter;
  { id = !counter; text }

let show_name n = Printf.sprintf "%s.%d" n.text n.id

type prim =
  | Add
  | Sub
  | Mul
  | Div
  | Mod
  | Neg
  | Eq
  | Ne
  | Lt
  | Le
  | Gt
  | Ge

let prim_name = function
  | Add -> "add"
  | Sub -> "sub"
  | Mul -> "mul"
  | Div -> "div"
  | Mod -> "mod"
  | Neg -> "neg"
  | Eq -> "eq"
  | Ne -> "ne"
  | Lt -> "lt"
  | Le -> "le"
  | Gt -> "gt"
  | Ge -> "ge"

type expr =
  | Int of int64
  | Bool of bool
  | Unit
  | Var of name
  | Tuple of expr list
  | Proj of int * expr (* zero-based, unlike the `#1` the reader writes *)
  | Prim of prim * expr list
  | If of expr * expr * expr
  | Let of name option * expr * expr (* [None] evaluates and discards *)
  | Untuple of expr * name option list * expr (* take a tuple apart, in place *)
  | Letrec of (name * lambda) list * expr
  | Fn of lambda
  | App of expr * expr list

and lambda = { lname : string option; params : name list; body : expr }

(* The free variables of an expression, in the order they are first met.

   [Resolve] turns this list into a closure's capture vector, so the order has to
   be a property of the expression and not of a hash table: two runs of the
   compiler on the same program have to produce the same captures in the same
   places. *)
let free_vars expr =
  let found = Hashtbl.create 16 in
  let acc = ref [] in
  let rec go bound expr =
    match expr with
    | Int _ | Bool _ | Unit -> ()
    | Var n ->
        if (not (Hashtbl.mem bound n.id)) && not (Hashtbl.mem found n.id) then (
          Hashtbl.add found n.id ();
          acc := n :: !acc)
    | Tuple es -> List.iter (go bound) es
    | Proj (_, e) -> go bound e
    | Prim (_, es) -> List.iter (go bound) es
    | If (c, t, f) ->
        go bound c;
        go bound t;
        go bound f
    | Let (binder, rhs, body) ->
        go bound rhs;
        scoped bound (Option.to_list binder) (fun bound -> go bound body)
    | Untuple (rhs, binders, body) ->
        go bound rhs;
        scoped bound (List.filter_map Fun.id binders) (fun bound -> go bound body)
    | Letrec (group, body) ->
        let names = List.map fst group in
        scoped bound names (fun bound ->
            List.iter (fun (_, l) -> go_lambda bound l) group;
            go bound body)
    | Fn l -> go_lambda bound l
    | App (f, args) ->
        go bound f;
        List.iter (go bound) args
  and go_lambda bound l = scoped bound l.params (fun bound -> go bound l.body)
  (* Names are unique, so a scope can be a single table that is added to and
     taken from again — there is nothing to shadow. *)
  and scoped bound names k =
    List.iter (fun n -> Hashtbl.add bound n.id ()) names;
    k bound;
    List.iter (fun n -> Hashtbl.remove bound n.id) names
  in
  go (Hashtbl.create 16) expr;
  List.rev !acc

let free_vars_lambda l = free_vars (Fn l)

(* The free variables of a whole recursive group: the members do not count as
   free in each other, which is what makes one capture vector serve them all. *)
let free_vars_group group = free_vars (Letrec (group, Unit))
