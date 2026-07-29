(* The clause database.

   A stored clause holds no variables.  Where the source had one, the stored
   term has [Term.Local i], an index into a frame; trying the clause means
   allocating a frame of fresh variables and rebuilding the head and body
   against it.  So each attempt starts from a private copy and backtracking has
   nothing to undo but the trail.

   Before that copy is built, the clause's first argument is compared against
   the goal's as a single tag.  That is the cheap half of what a WAM does with
   first-argument indexing, and it is what keeps a predicate with fifty facts
   from copying fifty clause heads to match one.

   The clause list of a predicate is immutable; assert and retract replace it.
   A call takes the list once, so a goal that modifies a predicate it is
   iterating over sees the predicate as it was when the call began -- Prolog's
   logical update view, for free. *)

type key =
  | KVar (* an unbound first argument matches anything *)
  | KAtom of string
  | KInt of int
  | KOther (* floats and everything else: no filtering *)
  | KStruct of string * int
  | KNone (* the predicate has no arguments *)

type clause = { head : Term.term; body : Term.term; nvars : int; key : key }

type pred = {
  indicator : string * int;
  mutable clauses : clause list;
  mutable dynamic : bool;
}

type t = { preds : (string * int, pred) Hashtbl.t; mutable order : (string * int) list }

let create () = { preds = Hashtbl.create 128; order = [] }

let find db indicator = Hashtbl.find_opt db.preds indicator

let pred db indicator =
  match Hashtbl.find_opt db.preds indicator with
  | Some p -> p
  | None ->
      let p = { indicator; clauses = []; dynamic = false } in
      Hashtbl.add db.preds indicator p;
      db.order <- indicator :: db.order;
      p

let indicators db = List.rev db.order

(* ------------------------------------------------------------- compilation *)

let key_of t =
  match Term.deref t with
  | Term.Var _ | Term.Local _ -> KVar
  | Term.Atom name -> KAtom name
  | Term.Int n -> KInt n
  | Term.Float _ -> KOther
  | Term.Struct (name, args) -> KStruct (name, Array.length args)

let head_key head = match head with Term.Struct (_, args) when Array.length args > 0 -> key_of args.(0) | _ -> KNone

let compatible a b = match (a, b) with KVar, _ | _, KVar | KNone, _ | _, KNone | KOther, _ | _, KOther -> true | a, b -> a = b

let key_string = function
  | KVar -> "any"
  | KNone -> "-"
  | KOther -> "other"
  | KAtom name -> name
  | KInt n -> string_of_int n
  | KStruct (name, arity) -> Printf.sprintf "%s/%d" name arity

let split_clause t =
  match Term.deref t with Term.Struct (":-", [| h; b |]) -> (h, b) | t -> (t, Term.true_)

(* Turn a term into a stored clause: variables become Local slots. *)
let compile t =
  let slots = Hashtbl.create 16 in
  let count = ref 0 in
  let rec go t =
    match Term.deref t with
    | Term.Var v -> (
        match Hashtbl.find_opt slots v.v_id with
        | Some i -> Term.Local i
        | None ->
            let i = !count in
            incr count;
            Hashtbl.add slots v.v_id i;
            Term.Local i)
    | Term.Struct (f, args) -> Term.Struct (f, Array.map go args)
    | (Term.Atom _ | Term.Int _ | Term.Float _) as t -> t
    | Term.Local _ -> Term.bug "a stored clause was compiled twice"
  in
  let head, body = split_clause t in
  let head = go head in
  let body = go body in
  { head; body; nvars = !count; key = head_key head }

let rec instantiate t frame =
  match t with
  | Term.Local i -> frame.(i)
  | Term.Struct (f, args) -> Term.Struct (f, Array.map (fun a -> instantiate a frame) args)
  | t -> t

let frame_for clause = Array.init clause.nvars (fun _ -> Term.fresh_var ())

(* The clause as a term again, for clause/2, retract/1 and listing/1. *)
let clause_term clause =
  let frame = frame_for clause in
  (instantiate clause.head frame, instantiate clause.body frame)

(* ------------------------------------------------------------- maintenance *)

let assertz db t =
  let clause = compile t in
  let name, arity = Term.indicator_of clause.head "assertz/1" in
  let p = pred db (name, arity) in
  p.dynamic <- true;
  p.clauses <- p.clauses @ [ clause ]

let asserta db t =
  let clause = compile t in
  let name, arity = Term.indicator_of clause.head "asserta/1" in
  let p = pred db (name, arity) in
  p.dynamic <- true;
  p.clauses <- clause :: p.clauses

(* Consulting adds clauses without marking the predicate dynamic. *)
let add_clause db t =
  let clause = compile t in
  let name, arity = Term.indicator_of clause.head "consult" in
  let p = pred db (name, arity) in
  p.clauses <- p.clauses @ [ clause ];
  (name, arity)

let remove p clause = p.clauses <- List.filter (fun c -> c != clause) p.clauses

let declare_dynamic db indicator =
  let p = pred db indicator in
  p.dynamic <- true

let abolish db indicator =
  match find db indicator with Some p -> p.clauses <- [] | None -> ()
