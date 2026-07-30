(* Terms, variable bindings, the trail, and unification.

   A variable is a mutable cell.  Binding one pushes it onto a global trail;
   backtracking pops the trail down to a mark and empties those cells again.
   That is the whole memory model.  Nothing is shared between a stored clause
   and a running goal, because the engine builds a fresh copy of a clause
   every time it tries it (see [Db.instantiate]). *)

type term =
  | Atom of string
  | Int of int
  | Float of float
  | Var of var
  | Struct of string * term array
  | Local of int
      (* Only ever appears inside a stored clause, where it stands for "the
         i-th variable of this clause".  [Db.instantiate] replaces it with a
         fresh [Var] before the clause is used, so a [Local] reaching
         unification or printing is an implementation bug, not a program
         error. *)

and var = {
  v_id : int;
  mutable v_value : term option; (* None while unbound *)
}

let nil = Atom "[]"
let true_ = Atom "true"

(* Arity 0 is spelt [Atom], never [Struct (f, [||])], so that equality and the
   standard order of terms do not have to consider two spellings of one term. *)
let struct_ name args = if Array.length args = 0 then Atom name else Struct (name, args)

let next_var_id =
  let counter = ref 0 in
  fun () ->
    incr counter;
    !counter

let fresh_var () = Var { v_id = next_var_id (); v_value = None }

(* Follow a chain of bound variables to whatever is at the end of it. *)
let rec deref t =
  match t with
  | Var { v_value = Some t'; _ } -> deref t'
  | _ -> t

(* ---------------------------------------------------------------- the trail *)

let trail : var Dynarray.t = Dynarray.create ()
let mark () = Dynarray.length trail

let bind v t =
  v.v_value <- Some t;
  Dynarray.add_last trail v

let undo_to m =
  while Dynarray.length trail > m do
    let v = Dynarray.pop_last trail in
    v.v_value <- None
  done

(* ------------------------------------------------------------------- errors *)

(* throw/1 and every built-in failure travel as this, carrying a Prolog term.
   The ball is copied at the throw, so undoing the trail on the way out cannot
   empty the variables inside it. *)
exception Prolog_error of term

(* A whole-run abort: halt/0, halt/1. *)
exception Halt of int

let error_term formal context = Struct ("error", [| formal; context |])
let throw formal context = raise (Prolog_error (error_term formal context))
let context_atom who = if who = "" then fresh_var () else Atom who

let instantiation_error who = throw (Atom "instantiation_error") (context_atom who)
let type_error kind culprit who = throw (Struct ("type_error", [| Atom kind; culprit |])) (context_atom who)

let domain_error domain culprit who =
  throw (Struct ("domain_error", [| Atom domain; culprit |])) (context_atom who)

let existence_error kind what who =
  throw (Struct ("existence_error", [| Atom kind; what |])) (context_atom who)

let evaluation_error what who = throw (Struct ("evaluation_error", [| Atom what |])) (context_atom who)

let permission_error op kind culprit who =
  throw (Struct ("permission_error", [| Atom op; Atom kind; culprit |])) (context_atom who)

let representation_error what who = throw (Struct ("representation_error", [| Atom what |])) (context_atom who)

(* ------------------------------------------------------------- unification *)

let bug what = failwith (Printf.sprintf "internal error: %s" what)

let rec unify a b =
  match (deref a, deref b) with
  | Var v, Var w when v == w -> true
  | Var v, t | t, Var v ->
      bind v t;
      true
  | Atom x, Atom y -> String.equal x y
  | Int x, Int y -> x = y
  | Float x, Float y -> Float.equal x y
  | Struct (f, xs), Struct (g, ys) ->
      String.equal f g && Array.length xs = Array.length ys && unify_args xs ys 0
  | Local _, _ | _, Local _ -> bug "a stored clause reached unification uninstantiated"
  | _ -> false

and unify_args xs ys i =
  i = Array.length xs || (unify xs.(i) ys.(i) && unify_args xs ys (i + 1))

(* A failed unification leaves the bindings it did manage to make on the
   trail; every caller that can fail undoes to its own mark, which subsumes
   them.  Keeping it that way means [unify] itself needs no cleanup path. *)

let rec occurs v t =
  match deref t with
  | Var w -> v == w
  | Struct (_, args) -> Array.exists (occurs v) args
  | _ -> false

let rec unify_oc a b =
  match (deref a, deref b) with
  | Var v, Var w when v == w -> true
  | Var v, t | t, Var v ->
      (not (occurs v t))
      &&
      (bind v t;
       true)
  | Atom x, Atom y -> String.equal x y
  | Int x, Int y -> x = y
  | Float x, Float y -> Float.equal x y
  | Struct (f, xs), Struct (g, ys) ->
      String.equal f g
      && Array.length xs = Array.length ys
      && (let ok = ref true in
          Array.iteri (fun i x -> if !ok then ok := unify_oc x ys.(i)) xs;
          !ok)
  | Local _, _ | _, Local _ -> bug "a stored clause reached unification uninstantiated"
  | _ -> false

(* ------------------------------------------------------- walking over terms *)

let copy_term t =
  let seen = Hashtbl.create 16 in
  let rec go t =
    match deref t with
    | Var v -> (
        match Hashtbl.find_opt seen v.v_id with
        | Some fresh -> fresh
        | None ->
            let fresh = fresh_var () in
            Hashtbl.add seen v.v_id fresh;
            fresh)
    | Struct (f, args) -> Struct (f, Array.map go args)
    | (Atom _ | Int _ | Float _) as t -> t
    | Local _ -> bug "a stored clause reached copy_term uninstantiated"
  in
  go t

(* Depth-first, left to right, first occurrence wins -- the order
   term_variables/2 is specified to produce. *)
let term_variables t =
  let seen = Hashtbl.create 16 in
  let out = ref [] in
  let rec go t =
    match deref t with
    | Var v ->
        if not (Hashtbl.mem seen v.v_id) then begin
          Hashtbl.add seen v.v_id ();
          out := Var v :: !out
        end
    | Struct (_, args) -> Array.iter go args
    | _ -> ()
  in
  go t;
  List.rev !out

let is_ground t = term_variables t = []

(* ------------------------------------------------ standard order of terms *)

(* Var @< Number @< Atom @< Compound.  Two numbers compare by value, and when
   the values are equal the float comes first. *)
let rank t = match t with Var _ -> 0 | Int _ | Float _ -> 1 | Atom _ -> 2 | Struct _ -> 3 | Local _ -> 4

let compare_numbers a b =
  match (a, b) with
  | Int x, Int y -> compare x y
  | Float x, Float y -> Float.compare x y
  | Int x, Float y ->
      let c = Float.compare (float_of_int x) y in
      if c <> 0 then c else 1 (* equal value: Float @< Int *)
  | Float x, Int y ->
      let c = Float.compare x (float_of_int y) in
      if c <> 0 then c else -1
  | _ -> bug "compare_numbers on a non-number"

let rec compare_terms a b =
  let a = deref a and b = deref b in
  let ra = rank a and rb = rank b in
  if ra <> rb then compare ra rb
  else
    match (a, b) with
    | Var v, Var w -> compare v.v_id w.v_id
    | (Int _ | Float _), (Int _ | Float _) -> compare_numbers a b
    | Atom x, Atom y -> String.compare x y
    | Struct (f, xs), Struct (g, ys) ->
        let c = compare (Array.length xs) (Array.length ys) in
        if c <> 0 then c
        else
          let c = String.compare f g in
          if c <> 0 then c else compare_args xs ys 0
    | _ -> bug "compare_terms on a stored clause"

and compare_args xs ys i =
  if i = Array.length xs then 0
  else
    let c = compare_terms xs.(i) ys.(i) in
    if c <> 0 then c else compare_args xs ys (i + 1)

(* Variance: equal up to a one-to-one renaming of variables.  bagof/3 groups
   its witnesses with this, and it is =@=/2. *)
let variant a b =
  let fwd = Hashtbl.create 16 and bwd = Hashtbl.create 16 in
  let rec go a b =
    match (deref a, deref b) with
    | Var v, Var w -> (
        match (Hashtbl.find_opt fwd v.v_id, Hashtbl.find_opt bwd w.v_id) with
        | None, None ->
            Hashtbl.add fwd v.v_id w.v_id;
            Hashtbl.add bwd w.v_id v.v_id;
            true
        | Some w', Some v' -> w' = w.v_id && v' = v.v_id
        | _ -> false)
    | Atom x, Atom y -> String.equal x y
    | Int x, Int y -> x = y
    | Float x, Float y -> Float.equal x y
    | Struct (f, xs), Struct (g, ys) ->
        String.equal f g
        && Array.length xs = Array.length ys
        && (let ok = ref true in
            Array.iteri (fun i x -> if !ok then ok := go x ys.(i)) xs;
            !ok)
    | _ -> false
  in
  go a b

(* ------------------------------------------------------------------- lists *)

let cons h t = Struct (".", [| h; t |])
let rec term_of_list = function [] -> nil | x :: xs -> cons x (term_of_list xs)

(* Some for a proper list, None for a partial or non-list. *)
let list_of_term t =
  let rec go acc t =
    match deref t with
    | Atom "[]" -> Some (List.rev acc)
    | Struct (".", [| h; tl |]) -> go (h :: acc) tl
    | _ -> None
  in
  go [] t

(* What a built-in should complain about when handed something that is not a
   list: an unbound tail is an instantiation error, anything else a type
   error.  Getting this split right is most of what makes error messages from
   list built-ins useful. *)
let expect_list t who =
  match list_of_term t with
  | Some xs -> xs
  | None ->
      let rec culprit t =
        match deref t with
        | Struct (".", [| _; tl |]) -> culprit tl
        | Var _ -> instantiation_error who
        | _ -> type_error "list" t who
      in
      culprit t

let term_of_codes s = term_of_list (List.map (fun c -> Int (Char.code c)) (List.of_seq (String.to_seq s)))

let term_of_chars s =
  term_of_list (List.map (fun c -> Atom (String.make 1 c)) (List.of_seq (String.to_seq s)))

(* ---------------------------------------------------------------- functors *)

(* name/arity of a callable term, or an error saying why it is not callable. *)
let indicator_of t who =
  match deref t with
  | Atom name -> (name, 0)
  | Struct (name, args) -> (name, Array.length args)
  | Var _ -> instantiation_error who
  | (Int _ | Float _) as t -> type_error "callable" t who
  | Local _ -> bug "a stored clause reached indicator_of uninstantiated"

let args_of t = match deref t with Struct (_, args) -> args | _ -> [||]

(* name/arity as the term Name/Arity, which is how Prolog talks about it. *)
let indicator_term (name, arity) = Struct ("/", [| Atom name; Int arity |])
