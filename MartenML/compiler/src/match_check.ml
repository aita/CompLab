(* Exhaustiveness and redundancy checking for `match`.

   Both questions are the same one: is a pattern vector *useful* with respect to
   the rows above it -- is there a value the rows above reject but this vector
   accepts?  A case that is not useful is unreachable, and the match as a whole
   is exhaustive exactly when a row of wildcards is not useful.  Running the
   algorithm in the form that returns the witness rather than a boolean gives a
   concrete missing value to show the user.  (Maranget, "Warnings for pattern
   matching".)

   The helpers here -- heads, specialization, the default matrix -- are the same
   ones Match_compile uses to build the decision tree, so they live in this
   module and are shared. *)

open Syntax

(* The constructor at the root of a pattern.  Variables and wildcards have
   none: they match everything. *)
type head =
  | Hnil
  | Hcons
  | Hconstr of Datatype.constr
  | Hint of int
  | Hbool of bool
  | Hunit
  | Htuple of int

let head_of = function
  | Pwild _ | Pvar _ -> None
  | Pint n -> Some (Hint n)
  | Pbool b -> Some (Hbool b)
  | Punit -> Some Hunit
  | Pnil -> Some Hnil
  | Pcons _ -> Some Hcons
  | Ptuple ps -> Some (Htuple (List.length ps))
  | Pconstr (name, _) -> Some (Hconstr (Datatype.constr_exn name))

let head_eq a b =
  match (a, b) with
  | Hconstr c1, Hconstr c2 -> c1.Datatype.cname = c2.Datatype.cname
  | Hint m, Hint n -> m = n
  | Hbool p, Hbool q -> p = q
  | Hunit, Hunit | Hnil, Hnil | Hcons, Hcons -> true
  | Htuple m, Htuple n -> m = n
  | _ -> false

let head_arity = function
  | Hconstr c -> List.length c.Datatype.arg_types
  | Htuple n -> n
  | Hcons -> 2
  | Hint _ | Hbool _ | Hunit | Hnil -> 0

(* The types of the columns a head expands into. *)
let sub_types column_type = function
  | Hcons -> (
    match Types.repr column_type with
    | Types.List element -> [ element; Types.List element ]
    | _ -> failwith "Match_check: `::` pattern on a non-list type")
  | Hconstr c -> c.Datatype.arg_types
  | Htuple _ -> (
    match Types.repr column_type with
    | Types.Tuple ts -> ts
    | _ -> failwith "Match_check: tuple pattern on a non-tuple type")
  | Hint _ | Hbool _ | Hunit | Hnil -> []

let sub_patterns = function
  | Ptuple ps | Pconstr (_, ps) -> ps
  | Pcons (head, tail) -> [ head; tail ]
  | _ -> []

let wildcards n = List.init n (fun _ -> Pwild (Types.fresh_var ()))

(* Rows that can still match once the first column is known to be [h], with
   that column replaced by the head's arguments. *)
let specialize h matrix =
  let arity = head_arity h in
  List.filter_map
    (fun row ->
      match row with
      | [] -> None
      | p :: rest -> (
        match head_of p with
        | None -> Some (wildcards arity @ rest)
        | Some h' -> if head_eq h h' then Some (sub_patterns p @ rest) else None))
    matrix

(* Rows that can still match once the first column is known *not* to be any of
   the heads appearing in it. *)
let default_matrix matrix =
  List.filter_map
    (fun row ->
      match row with
      | [] -> None
      | p :: rest -> ( match head_of p with None -> Some rest | Some _ -> None))
    matrix

let column_heads matrix =
  List.fold_left
    (fun acc row ->
      match row with
      | [] -> acc
      | p :: _ -> (
        match head_of p with
        | Some h when not (List.exists (head_eq h) acc) -> acc @ [ h ]
        | _ -> acc))
    [] matrix

(* If the heads present in a column already cover every constructor of its
   type, return that full signature; otherwise the column needs a default
   branch.  `int` is never complete. *)
let complete_signature column_type heads =
  let covered signature =
    if List.for_all (fun h -> List.exists (head_eq h) heads) signature then Some signature
    else None
  in
  match Types.repr column_type with
  | Types.Named n ->
    covered (List.map (fun c -> Hconstr c) (Datatype.constrs_of n))
  | Types.List _ -> covered [ Hnil; Hcons ]
  | Types.Bool -> covered [ Hbool true; Hbool false ]
  | Types.Unit -> covered [ Hunit ]
  | Types.Tuple ts -> covered [ Htuple (List.length ts) ]
  | _ -> None

(* A head of [column_type] that does not appear in [heads], as a witness
   pattern.  Used to describe a value the match fails to cover. *)
let uncovered_witness column_type heads =
  let absent h = not (List.exists (head_eq h) heads) in
  let of_head h =
    match h with
    | Hconstr c -> Pconstr (c.Datatype.cname, wildcards (head_arity h))
    | Hint n -> Pint n
    | Hbool b -> Pbool b
    | Hunit -> Punit
    | Hnil -> Pnil
    | Hcons -> Pcons (Pwild (Types.fresh_var ()), Pwild (Types.fresh_var ()))
    | Htuple n -> Ptuple (wildcards n)
  in
  if heads = [] then Pwild (Types.fresh_var ())
  else
    match Types.repr column_type with
    | Types.Named n -> (
      match List.filter (fun c -> absent (Hconstr c)) (Datatype.constrs_of n) with
      | c :: _ -> of_head (Hconstr c)
      | [] -> Pwild (Types.fresh_var ()))
    | Types.List _ -> if absent Hnil then Pnil else of_head Hcons
    | Types.Bool -> if absent (Hbool true) then Pbool true else Pbool false
    | Types.Int ->
      let rec first n = if absent (Hint n) then Pint n else first (n + 1) in
      first 0
    | _ -> Pwild (Types.fresh_var ())

let rec split_at n xs =
  if n = 0 then ([], xs)
  else
    match xs with
    | [] -> ([], [])
    | x :: rest ->
      let front, back = split_at (n - 1) rest in
      (x :: front, back)

let rebuild h args =
  match (h, args) with
  | Hcons, [ head; tail ] -> Pcons (head, tail)
  | Hnil, _ -> Pnil
  | _ -> (
    match h with
    | Hconstr c -> Pconstr (c.Datatype.cname, args)
    | Htuple _ -> Ptuple args
    | Hint n -> Pint n
    | Hbool b -> Pbool b
    | Hunit -> Punit
    | _ -> assert false)

(* A value matched by no row, if there is one. *)
let rec find_missing matrix column_types =
  match column_types with
  | [] -> if matrix = [] then Some [] else None
  | ty :: rest_types -> (
    let heads = column_heads matrix in
    match complete_signature ty heads with
    | Some signature ->
      List.find_map
        (fun h ->
          let sub = sub_types ty h in
          match find_missing (specialize h matrix) (sub @ rest_types) with
          | Some witness ->
            let args, tail = split_at (List.length sub) witness in
            Some (rebuild h args :: tail)
          | None -> None)
        signature
    | None -> (
      match find_missing (default_matrix matrix) rest_types with
      | Some witness -> Some (uncovered_witness ty heads :: witness)
      | None -> None))

(* Does [row] accept a value that every row of [matrix] rejects? *)
let rec is_useful matrix row column_types =
  match (column_types, row) with
  | [], _ -> matrix = []
  | ty :: rest_types, p :: rest_row -> (
    match head_of p with
    | Some h ->
      is_useful (specialize h matrix) (sub_patterns p @ rest_row)
        (sub_types ty h @ rest_types)
    | None -> (
      let heads = column_heads matrix in
      match complete_signature ty heads with
      | Some signature ->
        List.exists
          (fun h ->
            is_useful (specialize h matrix)
              (wildcards (head_arity h) @ rest_row)
              (sub_types ty h @ rest_types))
          signature
      | None -> is_useful (default_matrix matrix) rest_row rest_types))
  | _, [] -> false

let warn fmt =
  Printf.eprintf "Warning: ";
  Printf.kfprintf (fun oc -> output_char oc '\n') stderr fmt

let check info cases =
  let ty = info.scrutinee_type in
  let rec scan seen = function
    | [] -> ()
    | case :: rest ->
      if not (is_useful seen [ case.pat ] [ ty ]) then
        warn "this match case is unused: %s" (string_of_pattern case.pat);
      scan (seen @ [ [ case.pat ] ]) rest
  in
  scan [] cases;
  let matrix = List.map (fun case -> [ case.pat ]) cases in
  match find_missing matrix [ ty ] with
  | Some [ witness ] ->
    warn "this match is not exhaustive; no case matches %s"
      (string_of_pattern witness)
  | _ -> ()
