(* The logic the refinement system talks in, and the shape of a verification
   condition.

   A verification condition is one implication: given these variables and
   these hypotheses, does the goal hold?  Nothing here knows how to decide
   that -- solver.ml decides what it can and smt.ml can hand the rest to a
   real solver -- so this file is only the language and its printers. *)

type sort = Int | Bool

type expr =
  | Var of string
  | Lit of int
  | True
  | False
  | Arith of string * expr * expr (* + - * / % *)
  | Neg of expr
  | Not of expr
  | And of expr * expr
  | Or of expr * expr
  | Imp of expr * expr
  | Cmp of string * expr * expr (* == != < <= > >= *)
  | Ite of expr * expr * expr

type binding = { name : string; sort : sort }

type vc = {
  vars : binding list; (* universally quantified, oldest first *)
  hyps : expr list;
  goal : expr;
  loc : Loc.t;
  note : string; (* what the checker was doing when it needed this *)
}

let tt = True
let is_true = function True -> true | _ -> false

let conj a b =
  match (a, b) with True, x | x, True -> x | _ -> And (a, b)

let rec subst x s e =
  match e with
  | Var y when y = x -> s
  | Var _ | Lit _ | True | False -> e
  | Arith (op, a, b) -> Arith (op, subst x s a, subst x s b)
  | Neg a -> Neg (subst x s a)
  | Not a -> Not (subst x s a)
  | And (a, b) -> And (subst x s a, subst x s b)
  | Or (a, b) -> Or (subst x s a, subst x s b)
  | Imp (a, b) -> Imp (subst x s a, subst x s b)
  | Cmp (op, a, b) -> Cmp (op, subst x s a, subst x s b)
  | Ite (c, a, b) -> Ite (subst x s c, subst x s a, subst x s b)

let rec vars_of e acc =
  match e with
  | Var x -> if List.mem x acc then acc else x :: acc
  | Lit _ | True | False -> acc
  | Neg a | Not a -> vars_of a acc
  | Arith (_, a, b) | And (a, b) | Or (a, b) | Imp (a, b) | Cmp (_, a, b) ->
      vars_of b (vars_of a acc)
  | Ite (c, a, b) -> vars_of b (vars_of a (vars_of c acc))

(* Printing in the source language's own syntax, so that an unproved goal in a
   message reads like something the programmer wrote. *)
let rec show ?(prec = 0) e =
  let paren p s = if prec > p then "(" ^ s ^ ")" else s in
  match e with
  | Var x -> x
  | Lit n -> string_of_int n
  | True -> "true"
  | False -> "false"
  | Neg a -> "-" ^ show ~prec:9 a
  | Not a -> "not " ^ show ~prec:9 a
  | Arith (op, a, b) ->
      let p = match op with "+" | "-" -> 6 | _ -> 7 in
      (* Printed the way the source spells it: `div`, `mod` and `<>` rather than
         the names the checker uses inside. *)
      let name = match op with "/" -> "div" | "%" -> "mod" | op -> op in
      paren p (Printf.sprintf "%s %s %s" (show ~prec:p a) name (show ~prec:(p + 1) b))
  | Cmp (op, a, b) ->
      let name = if op = "!=" then "<>" else op in
      paren 5 (Printf.sprintf "%s %s %s" (show ~prec:6 a) name (show ~prec:6 b))
  | And (a, b) ->
      paren 4 (Printf.sprintf "%s andalso %s" (show ~prec:5 a) (show ~prec:5 b))
  | Or (a, b) ->
      paren 3 (Printf.sprintf "%s orelse %s" (show ~prec:4 a) (show ~prec:4 b))
  | Imp (a, b) -> paren 2 (Printf.sprintf "%s ==> %s" (show ~prec:3 a) (show ~prec:2 b))
  | Ite (c, a, b) ->
      paren 1
        (Printf.sprintf "if %s then %s else %s" (show ~prec:2 c) (show ~prec:2 a)
           (show ~prec:2 b))

let show_vc vc =
  let hyps = List.filter (fun h -> not (is_true h)) vc.hyps in
  let lhs =
    match hyps with
    | [] -> ""
    | hs -> String.concat " && " (List.map (show ~prec:5) hs) ^ " ==> "
  in
  lhs ^ show vc.goal

(* SMT-LIB 2, for `--dump-vc` and for handing the problem to a real solver.
   The query is the negation: a goal is valid exactly when its negation is
   unsatisfiable, which is the question an SMT solver answers. *)
let smtlib vc =
  let b = Buffer.create 256 in
  let sort = function Int -> "Int" | Bool -> "Bool" in
  let rec go e =
    match e with
    | Var x -> x
    | Lit n -> if n < 0 then Printf.sprintf "(- %d)" (-n) else string_of_int n
    | True -> "true"
    | False -> "false"
    | Neg a -> Printf.sprintf "(- %s)" (go a)
    | Not a -> Printf.sprintf "(not %s)" (go a)
    | And (a, b) -> Printf.sprintf "(and %s %s)" (go a) (go b)
    | Or (a, b) -> Printf.sprintf "(or %s %s)" (go a) (go b)
    | Imp (a, b) -> Printf.sprintf "(=> %s %s)" (go a) (go b)
    | Ite (c, a, b) -> Printf.sprintf "(ite %s %s %s)" (go c) (go a) (go b)
    | Arith ("%", a, b) -> Printf.sprintf "(mod %s %s)" (go a) (go b)
    | Arith ("/", a, b) -> Printf.sprintf "(div %s %s)" (go a) (go b)
    | Arith (op, a, b) -> Printf.sprintf "(%s %s %s)" op (go a) (go b)
    | Cmp ("==", a, b) -> Printf.sprintf "(= %s %s)" (go a) (go b)
    | Cmp ("!=", a, b) -> Printf.sprintf "(not (= %s %s))" (go a) (go b)
    | Cmp (op, a, b) -> Printf.sprintf "(%s %s %s)" op (go a) (go b)
  in
  Buffer.add_string b "(set-logic QF_LIA)\n";
  List.iter
    (fun v ->
      Buffer.add_string b
        (Printf.sprintf "(declare-const %s %s)\n" v.name (sort v.sort)))
    vc.vars;
  List.iter
    (fun h ->
      if not (is_true h) then
        Buffer.add_string b (Printf.sprintf "(assert %s)\n" (go h)))
    vc.hyps;
  Buffer.add_string b (Printf.sprintf "(assert (not %s))\n" (go vc.goal));
  Buffer.add_string b "(check-sat)\n";
  Buffer.contents b
