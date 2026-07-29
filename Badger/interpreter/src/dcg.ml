(* Definite clause grammars.

   `-->` is not a control construct but a source transformation, applied once
   when a clause is read.  Every nonterminal gains two arguments, the list of
   tokens before it and the list after, and threading those two through a body
   is the whole translation:

     greeting --> [hello], name.

   becomes

     greeting(S0, S) :- S0 = [hello|S1], name(S1, S).

   A terminal consumes; `{}/1` and `!` consume nothing and say so by unifying
   the two lists. *)

let who = "-->/2"

let add_args t extra =
  match Term.deref t with
  | Term.Atom name -> Term.struct_ name extra
  | Term.Struct (name, args) -> Term.Struct (name, Array.append args extra)
  | Term.Var _ -> Term.instantiation_error who
  | t -> Term.type_error "callable" t who

let conj a b = Term.Struct (",", [| a; b |])
let eq a b = Term.Struct ("=", [| a; b |])

(* [a,b,c] with S at the end, so that S0 = [a,b,c|S] consumes three tokens. *)
let rec with_tail t tail =
  match Term.deref t with
  | Term.Atom "[]" -> tail
  | Term.Struct (".", [| h; rest |]) -> Term.cons h (with_tail rest tail)
  | t -> Term.type_error "list" t who

let rec body t s0 s =
  match Term.deref t with
  | Term.Struct (",", [| x; y |]) ->
      let mid = Term.fresh_var () in
      conj (body x s0 mid) (body y mid s)
  | Term.Struct ((";" | "|"), [| x; y |]) -> Term.Struct (";", [| body x s0 s; body y s0 s |])
  | Term.Struct ("->", [| x; y |]) ->
      let mid = Term.fresh_var () in
      Term.Struct ("->", [| body x s0 mid; body y mid s |])
  | Term.Struct ("\\+", [| x |]) ->
      conj (Term.Struct ("\\+", [| body x s0 (Term.fresh_var ()) |])) (eq s0 s)
  | Term.Atom "!" -> conj (Term.Atom "!") (eq s0 s)
  | Term.Atom "[]" -> eq s0 s
  | Term.Struct ("{}", [| goal |]) -> conj goal (eq s0 s)
  | Term.Struct ("call", args) -> Term.Struct ("call", Array.append args [| s0; s |])
  | (Term.Struct (".", [| _; _ |]) as list) -> eq s0 (with_tail list s)
  | nonterminal -> add_args nonterminal [| s0; s |]

(* Some for a --> clause, None for anything else. *)
let translate t =
  match Term.deref t with
  | Term.Struct ("-->", [| head; rule_body |]) ->
      let s0 = Term.fresh_var () and s = Term.fresh_var () in
      let head =
        match Term.deref head with
        | Term.Struct (",", [| _; _ |]) ->
            Term.domain_error "dcg_head" head "pushback lists are not supported"
        | head -> add_args head [| s0; s |]
      in
      Some (Term.Struct (":-", [| head; body rule_body s0 s |]))
  | _ -> None
