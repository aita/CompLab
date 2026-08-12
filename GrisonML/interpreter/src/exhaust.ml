(* Whether a match covers its type, and whether any of its rules cannot be
   reached: Maranget's usefulness relation, over patterns that have already
   been type checked and so already know, at every constructor, what the whole
   set of constructors there is.

   A rule with a guard is left out of the matrix, because it cannot be counted
   on to match; that makes it neither a cover for what follows it nor
   something that can make what follows it unreachable. *)

type head = {
  h_name : string;
  h_arity : int;
  (* every constructor of the type, or None where there are too many to name:
     int, real, char and string *)
  h_all : (string * int) list option;
  h_fields : string list option; (* a record, and its field names *)
}

type pat =
  | SWild
  | SCon of head * pat list

let tuple_head n = { h_name = "#tuple"; h_arity = n; h_all = Some [ ("#tuple", n) ]; h_fields = None }

let record_head fs =
  { h_name = "#record";
    h_arity = List.length fs;
    h_all = Some [ ("#record", List.length fs) ];
    h_fields = Some fs }

let atom name = { h_name = name; h_arity = 0; h_all = None; h_fields = None }
let closed name arity all = { h_name = name; h_arity = arity; h_all = Some all; h_fields = None }
let bool_head b = closed (if b then "true" else "false") 0 [ ("true", 0); ("false", 0) ]
let unit_head = closed "()" 0 [ ("()", 0) ]

(* ------------------------------------------------------------------
 * The two matrix operations
 * ------------------------------------------------------------------ *)

let wilds n = List.init n (fun _ -> SWild)

let specialize name arity rows =
  List.filter_map
    (fun row ->
      match row with
      | SCon (h, args) :: rest -> if String.equal h.h_name name then Some (args @ rest) else None
      | SWild :: rest -> Some (wilds arity @ rest)
      | [] -> None)
    rows

let defaulted rows =
  List.filter_map (fun row -> match row with SWild :: rest -> Some rest | _ -> None) rows

(* The distinct head constructors of the first column, in the order they
   appear.  Almost every match has a handful of rules, and for those the scan
   of what has been collected costs less than the table it would take to avoid
   it; a column long enough for that to turn around gets the table. *)
let heads_of rows =
  if List.compare_length_with rows 32 <= 0 then begin
    let acc = ref [] in
    List.iter
      (fun row ->
        match row with
        | SCon (h, _) :: _ when not (List.mem_assoc h.h_name !acc) ->
          acc := (h.h_name, h) :: !acc
        | _ -> ())
      rows;
    List.rev !acc
  end
  else begin
    let seen = Hashtbl.create 64 in
    let acc = ref [] in
    List.iter
      (fun row ->
        match row with
        | SCon (h, _) :: _ when not (Hashtbl.mem seen h.h_name) ->
          Hashtbl.add seen h.h_name ();
          acc := (h.h_name, h) :: !acc
        | _ -> ())
      rows;
    List.rev !acc
  end

type coverage =
  | Empty
  | Infinite
  | Complete of (string * int) list
  | Missing of (string * int) list

let coverage rows =
  match heads_of rows with
  | [] -> Empty
  | (_, h) :: _ as hs -> (
    match h.h_all with
    | None -> Infinite
    | Some all ->
      let absent = List.filter (fun (n, _) -> not (List.mem_assoc n hs)) all in
      if absent = [] then Complete all else Missing absent)

(* ------------------------------------------------------------------
 * Usefulness, and the value no rule matches
 * ------------------------------------------------------------------ *)

let rec useful rows q =
  match q with
  | [] -> ( match rows with [] -> true | _ -> false)
  | SCon (h, args) :: qs -> useful (specialize h.h_name h.h_arity rows) (args @ qs)
  | SWild :: qs -> (
    match coverage rows with
    | Complete all ->
      List.exists (fun (n, a) -> useful (specialize n a rows) (wilds a @ qs)) all
    | _ -> useful (defaulted rows) qs)

(* The head to print for a constructor: the one the matrix already shows,
   where it shows one, so that a record keeps its field names. *)
let head_named rows name arity =
  match List.assoc_opt name (heads_of rows) with
  | Some h -> h
  | None -> { h_name = name; h_arity = arity; h_all = None; h_fields = None }

let rec witness rows n =
  if n = 0 then (match rows with [] -> Some [] | _ -> None)
  else
    match coverage rows with
    | Complete all ->
      List.fold_left
        (fun found (name, arity) ->
          match found with
          | Some _ -> found
          | None -> (
            match witness (specialize name arity rows) (arity + n - 1) with
            | None -> None
            | Some ps ->
              let args = List.filteri (fun i _ -> i < arity) ps in
              let rest = List.filteri (fun i _ -> i >= arity) ps in
              Some (SCon (head_named rows name arity, args) :: rest)))
        None all
    | Missing ((name, arity) :: _) -> (
      match witness (defaulted rows) (n - 1) with
      | None -> None
      | Some rest -> Some (SCon (head_named rows name arity, wilds arity) :: rest))
    | Empty | Infinite | Missing [] -> (
      match witness (defaulted rows) (n - 1) with
      | None -> None
      | Some rest -> Some (SWild :: rest))

(* ------------------------------------------------------------------
 * Printing a witness
 * ------------------------------------------------------------------ *)

let rec show_pat outer p =
  match p with
  | SWild -> "_"
  | SCon (h, args) -> (
    match (h.h_fields, h.h_name, args) with
    | Some fs, _, _ ->
      "{" ^ String.concat ", " (List.map2 (fun f a -> f ^ " = " ^ show_pat false a) fs args) ^ "}"
    | None, "#tuple", _ -> "(" ^ String.concat ", " (List.map (show_pat false) args) ^ ")"
    (* :: is right associative, so only its head ever needs parentheses; and
       a :: whose argument is unknown is a head and a tail both unknown *)
    | None, "::", [ SCon (t, [ h1; t1 ]) ] when String.equal t.h_name "#tuple" ->
      let s = show_pat true h1 ^ " :: " ^ show_pat false t1 in
      if outer then "(" ^ s ^ ")" else s
    | None, "::", [ SWild ] -> if outer then "(_ :: _)" else "_ :: _"
    | None, n, [] -> n
    | None, n, args ->
      let s = n ^ " " ^ String.concat " " (List.map (show_pat true) args) in
      if outer then "(" ^ s ^ ")" else s)

(* ------------------------------------------------------------------
 * What the type checker asks for
 * ------------------------------------------------------------------ *)

(* A value no rule matches, printed, or None if the rules cover the type. *)
let uncovered pats =
  match witness (List.map (fun p -> [ p ]) pats) 1 with
  | Some [ p ] -> Some (show_pat false p)
  | _ -> None

(* ------------------------------------------------------------------
 * Reading the rules of one match, one at a time
 *
 * Asking whether rule i can be reached is asking whether its pattern is
 * useful against the i - 1 rules before it, and doing that from scratch is
 * quadratic in a match with many rules -- which a match on literals easily
 * has.  The rules already read are therefore kept indexed by their head
 * constructor, so that specializing to a head is a lookup rather than a scan.
 * Once a rule matches everything, nothing after it can be reached, and the
 * question stops being asked at all.
 * ------------------------------------------------------------------ *)

type seen = {
  mutable s_all : bool;                       (* some rule matches everything *)
  s_heads : (string, pat list list) Hashtbl.t;
  mutable s_rows : pat list list;             (* only for the wildcard question *)
}

let no_rules () = { s_all = false; s_heads = Hashtbl.create 8; s_rows = [] }

let reachable s p =
  if s.s_all then false
  else
    match p with
    | SWild -> witness s.s_rows 1 <> None
    | SCon (h, args) ->
      (* s_all is false, so no row read so far specializes into this head
         except the rows that already have it *)
      let rows = match Hashtbl.find_opt s.s_heads h.h_name with Some r -> r | None -> [] in
      useful rows args

let remember s p =
  s.s_rows <- [ p ] :: s.s_rows;
  match p with
  | SWild -> s.s_all <- true
  | SCon (h, args) ->
    let rows = match Hashtbl.find_opt s.s_heads h.h_name with Some r -> r | None -> [] in
    Hashtbl.replace s.s_heads h.h_name (args :: rows)
