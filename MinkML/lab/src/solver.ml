(* A decision procedure, in about the smallest honest form there is.

   The question is always the same: is `hypotheses => goal` valid?  The answer
   is found by refuting its negation, in two layers.

     * The boolean layer splits on atoms.  Every comparison and every boolean
       variable is an atom; the search assigns them true and false in turn and
       prunes a branch as soon as the formula is already false under the
       partial assignment.  It is DPLL without the clever parts, which is
       enough for formulas with a handful of atoms.

     * The arithmetic layer takes the comparisons that survived one branch and
       eliminates variables by Fourier-Motzkin.  That decides satisfiability
       over the rationals, and this is where the honesty comes in: the
       variables are integers, and rational satisfiability does not imply
       integer satisfiability.  It goes the other way -- rational
       *un*satisfiability does imply integer unsatisfiability -- so a proof
       found here is a real proof, and a failure to find one is reported as
       "could not prove" rather than "false".

   Integer strengthening recovers most of what that loses: over the integers
   `e < 0` is `e + 1 <= 0`, and applying that when the constraints are built
   makes the rational relaxation tight enough for the arithmetic a refinement
   type usually needs.  Multiplication of two unknowns, division and modulo are
   abstracted as opaque values, which is again sound and again incomplete. *)

open Logic

(* Rationals.  The numbers in a verification condition are small; the point of
   the fractions is Fourier-Motzkin's combinations, not the input. *)
type q = { num : int; den : int } (* den > 0, gcd 1 *)

let rec gcd a b = if b = 0 then abs a else gcd b (a mod b)

let q n d =
  let s = if d < 0 then -1 else 1 in
  let n = n * s and d = d * s in
  let g = gcd n d in
  if g = 0 then { num = 0; den = 1 } else { num = n / g; den = d / g }

let qi n = { num = n; den = 1 }
let qzero = qi 0
let qadd a b = q ((a.num * b.den) + (b.num * a.den)) (a.den * b.den)
let qmul a b = q (a.num * b.num) (a.den * b.den)
let qneg a = { a with num = -a.num }
let qsign a = compare a.num 0

(* A linear form: coefficients for named quantities, plus a constant.  The
   names are ordinary variables, and also the abstractions standing for
   nonlinear terms. *)
type lin = { coeffs : (string * q) list; konst : q }

let lin_const k = { coeffs = []; konst = k }
let lin_var x = { coeffs = [ (x, qi 1) ]; konst = qzero }

let lin_add a b =
  let merged =
    List.fold_left
      (fun acc (x, c) ->
        match List.assoc_opt x acc with
        | Some c' -> (x, qadd c c') :: List.remove_assoc x acc
        | None -> (x, c) :: acc)
      a.coeffs b.coeffs
  in
  { coeffs = List.filter (fun (_, c) -> qsign c <> 0) merged;
    konst = qadd a.konst b.konst }

let lin_scale s a =
  { coeffs = List.filter_map
      (fun (x, c) ->
        let c = qmul s c in
        if qsign c = 0 then None else Some (x, c))
      a.coeffs;
    konst = qmul s a.konst }

let lin_sub a b = lin_add a (lin_scale (qi (-1)) b)

(* Anything not linear becomes an opaque name.  The same term always gets the
   same name, so `x * y == x * y` is still provable; nothing else about it is. *)
let opaque = Hashtbl.create 8

let opaque_name e =
  let key = Logic.show e in
  match Hashtbl.find_opt opaque key with
  | Some n -> n
  | None ->
      let n = Printf.sprintf "#%d" (Hashtbl.length opaque) in
      Hashtbl.add opaque key n;
      n

let rec linear e =
  match e with
  | Lit n -> lin_const (qi n)
  | Var x -> lin_var x
  | Neg a -> lin_scale (qi (-1)) (linear a)
  | Arith ("+", a, b) -> lin_add (linear a) (linear b)
  | Arith ("-", a, b) -> lin_sub (linear a) (linear b)
  | Arith ("*", Lit n, b) -> lin_scale (qi n) (linear b)
  | Arith ("*", a, Lit n) -> lin_scale (qi n) (linear a)
  | _ -> lin_var (opaque_name e)

(* Constraints are all `lin <= 0`; that uniformity is what keeps elimination
   short. *)
type constr = lin

let le a b = lin_sub a b (* a - b <= 0 *)

(* `a < b` over the integers is `a - b + 1 <= 0`. *)
let lt a b = lin_add (lin_sub a b) (lin_const (qi 1))

let cap = 4000

exception Too_big

let eliminate v cs =
  let zero, rest = List.partition (fun c -> not (List.mem_assoc v c.coeffs)) cs in
  let pos, neg =
    List.partition (fun c -> qsign (List.assoc v c.coeffs) > 0) rest
  in
  let combos =
    List.concat_map
      (fun p ->
        let cp = List.assoc v p.coeffs in
        List.map
          (fun n ->
            let cn = List.assoc v n.coeffs in
            lin_add (lin_scale (qneg cn) p) (lin_scale cp n))
          neg)
      pos
  in
  let out = zero @ combos in
  if List.length out > cap then raise Too_big else out

(* Satisfiable over the rationals? *)
let satisfiable (cs : constr list) =
  let vars =
    List.sort_uniq compare (List.concat_map (fun c -> List.map fst c.coeffs) cs)
  in
  try
    let cs = List.fold_left (fun cs v -> eliminate v cs) cs vars in
    (* Only constants are left: every one of them must be <= 0. *)
    Some (List.for_all (fun c -> qsign c.konst <= 0) cs)
  with Too_big -> None

(* The boolean layer. *)

let rec sort_of vars = function
  | True | False | Not _ | And _ | Or _ | Imp _ | Cmp _ -> Bool
  | Lit _ | Neg _ | Arith _ -> Int
  | Var x -> (
      match List.find_opt (fun b -> b.name = x) vars with
      | Some b -> b.sort
      | None -> Int)
  | Ite (_, a, b) -> ( match sort_of vars a with Bool -> Bool | Int -> sort_of vars b)

(* Equality between booleans is not arithmetic; rewrite it into the boolean
   structure it is, so that the atoms below are all genuinely arithmetic. *)
let rec normalise vars e =
  let iff a b = Or (And (a, b), And (Not a, Not b))
  and xor a b = Or (And (a, Not b), And (Not a, b)) in
  match e with
  | Cmp ("==", a, b) when sort_of vars a = Bool && sort_of vars b = Bool ->
      iff (normalise vars a) (normalise vars b)
  | Cmp ("!=", a, b) when sort_of vars a = Bool && sort_of vars b = Bool ->
      xor (normalise vars a) (normalise vars b)
  | Not a -> Not (normalise vars a)
  | And (a, b) -> And (normalise vars a, normalise vars b)
  | Or (a, b) -> Or (normalise vars a, normalise vars b)
  | Imp (a, b) -> Imp (normalise vars a, normalise vars b)
  | e -> e

(* The atoms of a formula: comparisons, and variables that stand for a
   boolean.  Each one is remembered by how it prints, which is enough because
   the same expression always prints the same way. *)
let atoms vars e =
  let seen = ref [] in
  let add a =
    let key = Logic.show a in
    if not (List.mem_assoc key !seen) then seen := (key, a) :: !seen
  in
  let rec go e =
    match e with
    | True | False | Lit _ -> ()
    | Var x -> if sort_of vars (Var x) = Bool then add (Var x)
    | Cmp _ -> add e
    | Not a -> go a
    | And (a, b) | Or (a, b) | Imp (a, b) ->
        go a;
        go b
    | Neg a -> go a
    | Arith (_, a, b) ->
        go a;
        go b
    | Ite (c, a, b) ->
        go c;
        go a;
        go b
  in
  go e;
  List.rev_map snd !seen

let three_and a b =
  match (a, b) with
  | Some false, _ | _, Some false -> Some false
  | Some true, Some true -> Some true
  | _ -> None

let three_or a b =
  match (a, b) with
  | Some true, _ | _, Some true -> Some true
  | Some false, Some false -> Some false
  | _ -> None

let rec eval asg e =
  match e with
  | True -> Some true
  | False -> Some false
  | Var _ | Cmp _ -> List.assoc_opt (Logic.show e) asg
  | Not a -> Option.map not (eval asg a)
  | And (a, b) -> three_and (eval asg a) (eval asg b)
  | Or (a, b) -> three_or (eval asg a) (eval asg b)
  | Imp (a, b) -> three_or (Option.map not (eval asg a)) (eval asg b)
  | _ -> None

(* The constraints a decided atom contributes.  A disequality is a disjunction,
   so this returns a list of alternatives, each of which is a list of
   constraints. *)
let constraints_of atom truth =
  let both a b = [ [ le a b; le b a ] ] in
  match atom with
  | Cmp (op, x, y) -> (
      let a = linear x and b = linear y in
      match (op, truth) with
      | "<=", true | ">", false -> [ [ le a b ] ]
      | "<", true | ">=", false -> [ [ lt a b ] ]
      | ">=", true | "<", false -> [ [ le b a ] ]
      | ">", true | "<=", false -> [ [ lt b a ] ]
      | "==", true | "!=", false -> both a b
      | "!=", true | "==", false -> [ [ lt a b ]; [ lt b a ] ]
      | _ -> [ [] ])
  | _ -> [ [] ] (* a boolean variable says nothing about arithmetic *)

type answer = Proved | Unproved of string | Gave_up of string

let check (vc : vc) : answer =
  Hashtbl.reset opaque;
  let f =
    normalise vc.vars
      (List.fold_left (fun acc h -> conj acc h) tt vc.hyps)
  in
  let goal = normalise vc.vars vc.goal in
  let formula = conj f (Not goal) in
  let all = atoms vc.vars formula in
  let gave_up = ref None in
  (* A model of the negation is a reason the goal was not proved. *)
  let rec search atoms asg =
    match eval asg formula with
    | Some false -> None
    | v -> (
        match atoms with
        | [] -> if v = Some true then arith asg else None
        | a :: rest -> (
            let key = Logic.show a in
            match search rest ((key, true) :: asg) with
            | Some m -> Some m
            | None -> search rest ((key, false) :: asg)))
  and arith asg =
    (* Every decided atom contributes constraints; disequalities branch. *)
    let rec go decided acc =
      match decided with
      | [] -> (
          match satisfiable acc with
          | None ->
              gave_up := Some "the elimination grew too large";
              None
          | Some true -> Some (describe asg)
          | Some false -> None)
      | (key, truth) :: rest -> (
          let atom = List.find (fun a -> Logic.show a = key) all in
          let alternatives = constraints_of atom truth in
          let rec try_alts = function
            | [] -> None
            | cs :: more -> (
                match go rest (cs @ acc) with
                | Some m -> Some m
                | None -> try_alts more)
          in
          try_alts alternatives)
    in
    go asg []
  and describe asg =
    let parts =
      List.filter_map
        (fun (key, truth) ->
          if truth then Some key else Some ("not (" ^ key ^ ")"))
        asg
    in
    String.concat " && " (List.rev parts)
  in
  match search all [] with
  | None -> (
      match !gave_up with Some why -> Gave_up why | None -> Proved)
  | Some model -> Unproved model
