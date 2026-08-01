(* Types, and the two operations that make Hindley-Milner work: unification, and
   the levels that decide what may be generalised.

   A type variable is a mutable cell.  Unifying two of them writes a [Link] into
   one, so a type that has been solved is a chain of links to the answer, and
   [repr] follows it.  A variable also remembers the *level* at which it was
   created: how many `let`s deep the expression was.  A variable created inside a
   binding and still unbound when the binding finishes cannot appear in the
   environment outside, so it may be quantified.  That is the whole of the "which
   variables can I generalise" question, and it costs one integer.

   Nothing below this file cares about types.  The compiler is untyped: values
   are one word each, an `int` and a closure are told apart by the constructor
   the machine already has, and the only reason the types are computed at all is
   to reject bad programs and to print the top level. *)

type t =
  | Int
  | Bool
  | Unit
  | Tuple of t list
  | Arrow of t list * t
  | Var of var ref
  | Qvar of int (* a quantified variable of a scheme *)

and var = Unbound of { id : int; level : int } | Link of t

let counter = ref 0
let reset () = counter := 0

let fresh level =
  incr counter;
  Var (ref (Unbound { id = !counter; level }))

(* Follow the links.  Path compression is not worth it at this size, but
   shortening by one step as we go is free. *)
let rec repr t =
  match t with
  | Var ({ contents = Link inner } as cell) ->
      let answer = repr inner in
      cell := Link answer;
      answer
  | _ -> t

exception Mismatch of t * t
exception Occurs of t * t

(* Binding a variable to a type does two things: it checks the variable does not
   occur in it (`'a = 'a -> 'a` has no finite solution), and it lowers the level
   of every variable inside to the variable's own, because those variables are
   now reachable from wherever this one was. *)
let rec occurs_and_adjust cell level t =
  match repr t with
  | Var inner when inner == cell -> raise Exit
  | Var ({ contents = Unbound v } as inner) ->
      if v.level > level then inner := Unbound { v with level }
  | Tuple ts -> List.iter (occurs_and_adjust cell level) ts
  | Arrow (ps, r) ->
      List.iter (occurs_and_adjust cell level) ps;
      occurs_and_adjust cell level r
  | Int | Bool | Unit | Qvar _ | Var _ -> ()

let rec unify a b =
  let a = repr a and b = repr b in
  if a == b then ()
  else
    match (a, b) with
    | Int, Int | Bool, Bool | Unit, Unit -> ()
    | Tuple xs, Tuple ys when List.length xs = List.length ys ->
        List.iter2 unify xs ys
    | Arrow (ps, r), Arrow (qs, s) when List.length ps = List.length qs ->
        List.iter2 unify ps qs;
        unify r s
    | Var ({ contents = Unbound { level; _ } } as cell), other
    | other, Var ({ contents = Unbound { level; _ } } as cell) ->
        (try occurs_and_adjust cell level other
         with Exit -> raise (Occurs (a, b)));
        cell := Link other
    | _ -> raise (Mismatch (a, b))

(* Generalisation replaces the variables born inside the binding with quantified
   ones.  The variables themselves are left unbound: nothing else can reach
   them, since that is exactly what the level test established. *)
let rec generalize level t =
  match repr t with
  | Var { contents = Unbound v } when v.level > level -> Qvar v.id
  | Tuple ts -> Tuple (List.map (generalize level) ts)
  | Arrow (ps, r) -> Arrow (List.map (generalize level) ps, generalize level r)
  | other -> other

let instantiate level scheme =
  let seen = Hashtbl.create 8 in
  let rec go t =
    match repr t with
    | Qvar id -> (
        match Hashtbl.find_opt seen id with
        | Some v -> v
        | None ->
            let v = fresh level in
            Hashtbl.add seen id v;
            v)
    | Tuple ts -> Tuple (List.map go ts)
    | Arrow (ps, r) -> Arrow (List.map go ps, go r)
    | other -> other
  in
  go scheme

(* Printing.  Quantified and still-unbound variables both come out as `'a`,
   `'b`, ... in the order they are met, so the same type always prints the same
   way however many programs were checked before it.  [show_many] shares one
   naming across several types, which is what an error message about two of them
   needs: `'a` in the first has to mean `'a` in the second. *)
let show_many ts =
  let names = Hashtbl.create 8 in
  let next = ref 0 in
  let name_of id =
    match Hashtbl.find_opt names id with
    | Some s -> s
    | None ->
        let n = !next in
        incr next;
        let s =
          if n < 26 then Printf.sprintf "'%c" (Char.chr (Char.code 'a' + n))
          else Printf.sprintf "'%c%d" (Char.chr (Char.code 'a' + (n mod 26))) (n / 26)
        in
        Hashtbl.add names id s;
        s
  in
  (* [level] is 0 at the top, 1 under an arrow's left side or inside a product,
     2 where only an atom may stand. *)
  let rec go level t =
    let parens needed s = if needed then "(" ^ s ^ ")" else s in
    match repr t with
    | Int -> "int"
    | Bool -> "bool"
    | Unit -> "unit"
    | Var { contents = Unbound { id; _ } } -> name_of id
    | Qvar id -> name_of id
    | Tuple ts -> parens (level >= 2) (String.concat " * " (List.map (go 2) ts))
    | Arrow (ps, r) ->
        let left =
          match ps with
          | [ one ] -> go 1 one
          | many -> "(" ^ String.concat ", " (List.map (go 0) many) ^ ")"
        in
        parens (level >= 1) (left ^ " -> " ^ go 0 r)
    | Var _ -> assert false
  in
  List.map (go 0) ts

let show t = List.hd (show_many [ t ])

let show_two a b =
  match show_many [ a; b ] with [ x; y ] -> (x, y) | _ -> assert false
