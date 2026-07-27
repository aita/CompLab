(* Turning `match` into a decision tree.

   The classical matrix algorithm: pick a column, split the rows by the
   constructor at the head of that column, and recurse.  Each branch binds the
   fields it exposed to fresh names, so a value is loaded from the heap once
   however many rows inspect it.

   A decision tree can reach the same case from several leaves, which would
   duplicate that case's code.  Rather than accept the blow-up, a case reached
   more than once is emitted as a local function taking the variables its
   pattern binds, and the leaves call it.  Every leaf is then a jump, and each
   case's body appears exactly once. *)

open Syntax
module Check = Match_check

type tree =
  | Fail
  | Leaf of int * binding list (* case index, its pattern variables *)
  | Bind of (Ident.t * Types.t) * Syntax.t * tree
  | Test of Syntax.t * tree * tree

and binding = Ident.t * Types.t * Ident.t (* variable, type, occurrence holding it *)

(* A row of the pattern matrix.  [bindings] accumulates the variables whose
   column has already been consumed by a split further up the tree. *)
type row = { pats : pattern list; bindings : binding list; case : int }

type occurrence = Ident.t * Types.t

let bind_of pat occ = match pat with Pvar (x, t) -> [ (x, t, occ) ] | _ -> []
let is_wildcard pat = Check.head_of pat = None

let swap_to_front i xs =
  if i = 0 then xs
  else
    let arr = Array.of_list xs in
    let tmp = arr.(0) in
    arr.(0) <- arr.(i);
    arr.(i) <- tmp;
    Array.to_list arr

(* Rows that survive knowing the first column is [head], with that column
   replaced by the head's arguments.  A row matching by variable keeps its
   binding to the whole value. *)
let specialize_rows head (occ, _) rows =
  let arity = Check.head_arity head in
  List.filter_map
    (fun row ->
      match row.pats with
      | [] -> None
      | p :: rest -> (
        match Check.head_of p with
        | None ->
          Some
            {
              row with
              pats = Check.wildcards arity @ rest;
              bindings = row.bindings @ bind_of p occ;
            }
        | Some h ->
          if Check.head_eq head h then Some { row with pats = Check.sub_patterns p @ rest }
          else None))
    rows

(* Rows that survive knowing the first column is none of the heads tested. *)
let default_rows (occ, _) rows =
  List.filter_map
    (fun row ->
      match row.pats with
      | [] -> None
      | p :: rest ->
        if is_wildcard p then
          Some { row with pats = rest; bindings = row.bindings @ bind_of p occ }
        else None)
    rows

let column_heads rows = Check.column_heads (List.map (fun row -> row.pats) rows)

(* The test that decides whether [occ] starts with [head].  Single-constructor
   heads are never tested: reaching them is already proof. *)
let test_for head (occ, _) =
  match head with
  | Check.Hconstr c -> Cmp (Eq, Field (Var occ, 0, Types.Int), Int c.Datatype.tag)
  (* `[]` and `::` are the tags 0 and 1 of one built-in datatype. *)
  | Check.Hnil -> Cmp (Eq, Field (Var occ, 0, Types.Int), Int 0)
  | Check.Hcons -> Cmp (Eq, Field (Var occ, 0, Types.Int), Int 1)
  | Check.Hint n -> Cmp (Eq, Var occ, Int n)
  | Check.Hbool b -> Cmp (Eq, Var occ, Bool b)
  | Check.Hunit | Check.Htuple _ ->
    failwith "Match_compile: a single-constructor head needs no test"

(* Heads whose test compares against zero, which costs one instruction less. *)
let tests_against_zero = function
  | Check.Hnil -> true
  | Check.Hcons -> false
  | Check.Hconstr c -> c.Datatype.tag = 0
  | Check.Hint n -> n = 0
  | Check.Hbool b -> not b
  | Check.Hunit | Check.Htuple _ -> false

let rec build occs rows =
  match rows with
  | [] -> Fail
  | row :: _ when List.for_all is_wildcard row.pats ->
    let last = List.concat (List.map2 (fun p (occ, _) -> bind_of p occ) row.pats occs) in
    Leaf (row.case, row.bindings @ last)
  | first :: _ ->
    (* Split on the leftmost column the first row actually inspects: matching
       it is necessary, so the work is never wasted. *)
    let col =
      let rec find i = function
        | [] -> failwith "Match_compile: no column to split on"
        | p :: rest -> if is_wildcard p then find (i + 1) rest else i
      in
      find 0 first.pats
    in
    let occs = swap_to_front col occs in
    let rows = List.map (fun row -> { row with pats = swap_to_front col row.pats }) rows in
    let occ = List.hd occs and rest_occs = List.tl occs in
    let _, occ_type = occ in
    let heads = column_heads rows in
    let signature = Check.complete_signature occ_type heads in
    let branch head =
      let field_types = Check.sub_types occ_type head in
      (* A datatype block keeps its tag in word 0, so its fields start at 1;
         a tuple has no tag. *)
      let offset = match head with Check.Hconstr _ | Check.Hcons -> 1 | _ -> 0 in
      let fields = List.map (fun t -> (Ident.fresh "fld", t)) field_types in
      let body = build (fields @ rest_occs) (specialize_rows head occ rows) in
      let rec load i = function
        | [] -> body
        | (x, t) :: rest ->
          Bind ((x, t), Field (Var (fst occ), i + offset, t), load (i + 1) rest)
      in
      load 0 fields
    in
    let fallback =
      if signature = None then build rest_occs (default_rows occ rows) else Fail
    in
    (* When the signature is complete, the head left for last needs no test at
       all.  A tag of zero is the one head whose test would have been free
       anyway -- machines have a register hard-wired to zero -- so it should be
       tested rather than saved for last. *)
    let heads =
      if signature = None then heads
      else
        match List.partition tests_against_zero heads with
        | free :: others, rest -> (free :: others) @ rest
        | [], _ -> heads
    in
    let rec chain = function
      | [] -> fallback
      | [ head ] when signature <> None -> branch head
      | head :: rest -> Test (test_for head occ, branch head, chain rest)
    in
    chain heads

(* ------------------------------------------------------- materialization *)

let rec count_leaves counts = function
  | Fail -> ()
  | Leaf (i, _) -> counts.(i) <- counts.(i) + 1
  | Bind (_, _, t) -> count_leaves counts t
  | Test (_, a, b) ->
    count_leaves counts a;
    count_leaves counts b

let compile_match info scrutinee cases =
  Match_check.check info cases;
  let scrut = Ident.fresh "match" in
  let rows =
    List.mapi (fun i case -> { pats = [ case.pat ]; bindings = []; case = i }) cases
  in
  let tree = build [ (scrut, info.scrutinee_type) ] rows in
  let counts = Array.make (List.length cases) 0 in
  count_leaves counts tree;
  let cases = Array.of_list cases in
  (* Cases reachable from several leaves become local functions. *)
  let join_of = Array.mapi (fun i _ -> if counts.(i) > 1 then Some (Ident.fresh "case") else None) cases in
  let params_of i =
    match pattern_vars cases.(i).pat with
    | [] -> [ (Ident.fresh "novars", Types.Unit) ]
    | vars -> vars
  in
  let leaf i bindings =
    match join_of.(i) with
    | None ->
      List.fold_right
        (fun (x, t, occ) body -> Let ((x, t), Var occ, body))
        bindings cases.(i).action
    | Some join ->
      let args =
        match pattern_vars cases.(i).pat with
        | [] -> [ Unit ]
        | vars ->
          List.map
            (fun (x, _) ->
              match List.find_opt (fun (y, _, _) -> y = x) bindings with
              | Some (_, _, occ) -> Var occ
              | None -> failwith "Match_compile: pattern variable never bound")
            vars
      in
      App (Var join, args)
  in
  let rec to_syntax = function
    | Fail -> Match_failure info.result_type
    | Leaf (i, bindings) -> leaf i bindings
    | Bind ((x, t), e, k) -> Let ((x, t), e, to_syntax k)
    | Test (cond, a, b) -> If (cond, to_syntax a, to_syntax b)
  in
  let body = ref (to_syntax tree) in
  Array.iteri
    (fun i join ->
      match join with
      | None -> ()
      | Some join ->
        let args = params_of i in
        let ty = Types.Fun (List.map snd args, info.result_type) in
        body :=
          Let_rec ([ { name = (join, ty); args; body = cases.(i).action } ], !body))
    join_of;
  Let ((scrut, info.scrutinee_type), scrutinee, !body)

(* --------------------------------------------------------- the whole tree *)

let rec compile exp =
  match exp with
  | Unit | Bool _ | Int _ | Str _ | Var _ | Nil -> exp
  | Not e -> Not (compile e)
  | Neg e -> Neg (compile e)
  | Arith (op, a, b) -> Arith (op, compile a, compile b)
  | Cmp (op, a, b) -> Cmp (op, compile a, compile b)
  | If (c, a, b) ->
    let c = compile c in
    let a = compile a in
    If (c, a, compile b)
  (* The bindings are forced in source order so that the warnings a match
     raises come out in the order the reader expects. *)
  | Let (xt, e1, e2) ->
    let e1 = compile e1 in
    Let (xt, e1, compile e2)
  | Let_rec (fds, e) ->
    let fds = List.map (fun fd -> { fd with body = compile fd.body }) fds in
    Let_rec (fds, compile e)
  | App (f, args) ->
    let f = compile f in
    App (f, List.map compile args)
  | Tuple es -> Tuple (List.map compile es)
  | Let_tuple (xts, e1, e2) -> Let_tuple (xts, compile e1, compile e2)
  | Array (a, b) -> Array (compile a, compile b)
  | Get (a, b) -> Get (compile a, compile b)
  | Put (a, b, c) -> Put (compile a, compile b, compile c)
  | Str_length e -> Str_length (compile e)
  | Str_get (a, b) ->
    let a = compile a in
    Str_get (a, compile b)
  | Cons (head, tail) ->
    let head = compile head in
    Cons (head, compile tail)
  | Constr (name, args) -> Constr (name, List.map compile args)
  | Field (e, i, t) -> Field (compile e, i, t)
  | Match_failure _ -> exp
  | Match (info, scrutinee, cases) ->
    let scrutinee = compile scrutinee in
    let cases = List.map (fun case -> { case with action = compile case.action }) cases in
    compile_match info scrutinee cases
