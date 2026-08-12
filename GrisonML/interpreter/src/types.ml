(* Types, unification and generalization.

   Levels do the generalizing, in Remy's way: a variable created while type
   checking a right-hand side gets the level of that right-hand side, unifying
   two variables lowers the level of the younger, and what is left above the
   current level when the right-hand side is finished is exactly what does not
   appear in the environment and so can be quantified.

   The grammar has no class or overload declaration, and yet + is written for
   both int and real and < for both int and string.  A variable therefore
   carries a class -- Num for {int, real}, Ord for {int, real, char, string} --
   which unification narrows and which generalization keeps: the scheme of

     fun compare (a, b) = if a < b then 0 - 1 else if a == b then 0 else 1

   is 'a[ord] * 'a[ord] -> int, and it can be used at int and at string both.
   Standard ML defaults such a variable to int instead, because it compiles
   the primitive and has to know which one; here the primitive dispatches on
   the value it is given, so a quantified class costs nothing and the type is
   the more useful of the two.

   There is no ref and no assignment anywhere in the language, so the value
   restriction has nothing to protect and generalization is unrestricted.

   A record type is a row rather than a list of fields, in Remy's way again:
   the row of {x : int, y : bool} ends in TRowNil and is that record and no
   other, while the row of a projection ends in a variable and is every record
   that has the field.  So r.x asks only that r have an x,

     fun originX r = r.x                 originX : {x : 'a | 'b} -> 'a

   and the same variable carries the labels it may not gain, which is what
   keeps a row from being given the same field twice. *)

type cls =
  | NoCls
  | Num
  | Ord
  | Row of string list  (* the labels this row variable may not gain *)

type ty =
  | TVar of tv ref
  | TApp of tycon * ty list
  | TArrow of ty * ty
  | TTup of ty list
  | TRecord of ty                 (* its row *)
  | TRowNil
  | TRowCons of string * ty * ty  (* label, its type, the rest of the row *)

and tv =
  | Unbound of int * int * cls  (* id, level, class *)
  | Link of ty
  (* a parameter, or a skolem during matching; it carries its class because a
     row variable stays a row variable through a scheme *)
  | Rigid of string * cls

and tycon = {
  tc_id : int;
  tc_name : string;
  tc_params : tv ref list;      (* Rigid, one per parameter *)
  mutable tc_def : tdef;
}

and tdef =
  | Abstract
  | Alias of ty
  | Variant of (string * ty option) list

type scheme = { s_vars : tv ref list; s_body : ty }

type con = { con_tycon : tycon; con_arg : ty option }

let counter = ref 0

let next () =
  incr counter;
  !counter

let level = ref 0
let enter () = incr level
let leave () = decr level

let newvar ?(cls = NoCls) () = TVar (ref (Unbound (next (), !level, cls)))
let newrow lacks = TVar (ref (Unbound (next (), !level, Row lacks)))
let newrigid ?(cls = NoCls) name = ref (Rigid (name, cls))
let arity tc = List.length tc.tc_params

let tycon name params def = { tc_id = next (); tc_name = name; tc_params = params; tc_def = def }

let tc_int = tycon "int" [] Abstract
let tc_real = tycon "real" [] Abstract
let tc_char = tycon "char" [] Abstract
let tc_string = tycon "string" [] Abstract
let tc_bool = tycon "bool" [] Abstract
let tc_unit = tycon "unit" [] Abstract

let tc_list =
  let a = newrigid "a" in
  tycon "list" [ a ] Abstract

let t_int = TApp (tc_int, [])
let t_real = TApp (tc_real, [])
let t_char = TApp (tc_char, [])
let t_string = TApp (tc_string, [])
let t_bool = TApp (tc_bool, [])
let t_unit = TApp (tc_unit, [])
let t_list t = TApp (tc_list, [ t ])

let rec row_of_fields fs rest =
  match fs with [] -> rest | (l, t) :: more -> TRowCons (l, t, row_of_fields more rest)

let record fs = TRecord (row_of_fields fs TRowNil)

let () =
  let a = TVar (List.hd tc_list.tc_params) in
  tc_list.tc_def <- Variant [ ("[]", None); ("::", Some (TTup [ a; t_list a ])) ]

let base_types = [ tc_int; tc_real; tc_char; tc_string; tc_bool; tc_unit; tc_list ]

(* ------------------------------------------------------------------
 * Walking types
 * ------------------------------------------------------------------ *)

let rec repr t =
  match t with
  | TVar ({ contents = Link t' } as r) ->
    let t'' = repr t' in
    r := Link t'';
    t''
  | t -> t

(* The fields a row shows, and what it ends in: TRowNil if it is that record
   and nothing else, a variable if it is every record that has them. *)
let rec row_parts t =
  match repr t with
  | TRowCons (l, ft, rest) ->
    let fs, tail = row_parts rest in
    ((l, ft) :: fs, tail)
  | t -> ([], t)

(* Replace the parameters of a tycon, by physical identity of their refs. *)
let rec subst map t =
  match t with
  | TVar r -> (
    match List.assq_opt r map with
    | Some t -> t
    | None -> ( match !r with Link t -> subst map t | _ -> t))
  | TApp (tc, args) -> TApp (tc, List.map (subst map) args)
  | TArrow (a, b) -> TArrow (subst map a, subst map b)
  | TTup ts -> TTup (List.map (subst map) ts)
  | TRecord row -> TRecord (subst map row)
  | TRowNil -> TRowNil
  | TRowCons (l, t, rest) -> TRowCons (l, subst map t, subst map rest)

(* An alias keeps its name: it is expanded only where a comparison needs it,
   so that a type prints as "point -> int" rather than as its record. *)
let apply_tycon tc args = TApp (tc, args)

(* One step of alias expansion, or None. *)
let unalias t =
  match repr t with
  | TApp (tc, args) -> (
    match tc.tc_def with
    | Alias body -> Some (subst (List.combine tc.tc_params args) body)
    | _ -> None)
  | _ -> None

let rec head t = match unalias t with Some t -> head t | None -> repr t

(* ------------------------------------------------------------------
 * Printing
 * ------------------------------------------------------------------ *)

let show ty =
  let names = Hashtbl.create 8 in
  let n = ref 0 in
  let name_of id =
    match Hashtbl.find_opt names id with
    | Some s -> s
    | None ->
      let s =
        "'"
        ^ String.make 1 (Char.chr (Char.code 'a' + (!n mod 26)))
        ^ (if !n >= 26 then string_of_int (!n / 26) else "")
      in
      incr n;
      Hashtbl.add names id s;
      s
  in
  (* prec: 0 arrow, 1 tuple, 2 application, 3 atom *)
  let rec go prec t =
    let paren p s = if prec > p then "(" ^ s ^ ")" else s in
    match repr t with
    | TVar { contents = Unbound (id, _, c) } ->
      let s = name_of id in
      (match c with Num -> s ^ "[num]" | Ord -> s ^ "[ord]" | NoCls | Row _ -> s)
    | TVar { contents = Rigid (s, _) } -> "'" ^ s
    | TVar { contents = Link _ } -> assert false
    | TApp (tc, []) -> tc.tc_name
    | TApp (tc, [ a ]) ->
      let a = go 2 a in
      paren 2 (a ^ " " ^ tc.tc_name)
    | TApp (tc, args) ->
      let args = List.map (go 0) args in
      "(" ^ String.concat ", " args ^ ") " ^ tc.tc_name
    | TArrow (a, b) ->
      (* the names are handed out in the order the type reads, so the two
         sides have to be rendered in that order too *)
      let a = go 1 a in
      let b = go 0 b in
      paren 0 (a ^ " -> " ^ b)
    | TTup ts -> paren 1 (String.concat " * " (List.map (go 2) ts))
    | TRecord row -> go_row row
    | TRowNil -> "{}"
    | TRowCons _ -> go_row t
  (* an open row prints the way it is written: {x : int | 'a} *)
  and go_row row =
    let fs, tail = row_parts row in
    let fs = List.map (fun (f, t) -> f ^ " : " ^ go 0 t) fs in
    let body = String.concat ", " fs in
    match repr tail with
    | TRowNil -> "{" ^ body ^ "}"
    | t ->
      let t = go 0 t in
      "{" ^ (if fs = [] then "" else body ^ " ") ^ "| " ^ t ^ "}"
  in
  go 0 ty

(* ------------------------------------------------------------------
 * Unification
 * ------------------------------------------------------------------ *)

exception Clash of string

let clash fmt = Printf.ksprintf (fun m -> raise (Clash m)) fmt
let clash_cls () = clash "a row cannot be a type, and a type cannot be a row"

let admits c t =
  match c with
  | NoCls -> true
  | Num -> t == tc_int || t == tc_real
  | Ord -> t == tc_int || t == tc_real || t == tc_char || t == tc_string
  | Row _ -> false

let cls_name = function
  | Num -> "arithmetic"
  | Ord -> "comparison"
  | Row _ -> "a record row"
  | NoCls -> ""

let merge_cls a b =
  match (a, b) with
  | NoCls, c | c, NoCls -> c
  | Row x, Row y -> Row (List.sort_uniq String.compare (x @ y))
  | Row _, _ | _, Row _ -> clash_cls ()
  | Num, _ | _, Num -> Num
  | Ord, Ord -> Ord

(* Lower the level of every variable in [t] to [lv], and refuse [r] itself. *)
let rec occurs r lv t =
  match repr t with
  | TVar r' ->
    if r == r' then clash "this type would contain itself";
    (match !r' with
     | Unbound (id, l, c) -> if l > lv then r' := Unbound (id, lv, c)
     | _ -> ())
  | TApp (_, args) -> List.iter (occurs r lv) args
  | TArrow (a, b) -> occurs r lv a; occurs r lv b
  | TTup ts -> List.iter (occurs r lv) ts
  | TRecord row -> occurs r lv row
  | TRowNil -> ()
  | TRowCons (_, t, rest) -> occurs r lv t; occurs r lv rest

let rec unify a b =
  let a = repr a and b = repr b in
  if a == b then ()
  else
    match (a, b) with
    | TVar r1, TVar r2 when r1 == r2 -> ()
    (* rows have their own equality, and a row variable is never anything but
       a row, so both go to unify_row before the ordinary cases *)
    | TRecord r1, TRecord r2 -> unify_row r1 r2
    | (TRowNil | TRowCons _), _
    | _, (TRowNil | TRowCons _)
    | TVar { contents = Unbound (_, _, Row _) }, _
    | _, TVar { contents = Unbound (_, _, Row _) } ->
      unify_row a b
    | TVar ({ contents = Unbound (_, lv, c) } as r), t
    | t, TVar ({ contents = Unbound (_, lv, c) } as r) -> (
      match repr t with
      | TVar ({ contents = Unbound (id', lv', c') } as r') when r != r' ->
        let c'' = merge_cls c c' in
        r' := Unbound (id', min lv lv', c'');
        r := Link (TVar r')
      | _ ->
        occurs r lv t;
        (if c <> NoCls then
           match head t with
           | TApp (tc, []) when admits c tc -> ()
           | _ -> clash "%s is not admitted by %s" (show t) (cls_name c));
        r := Link t)
    (* an alias is compared by what it stands for, not by its arguments *)
    | TApp (tc1, a1), TApp (tc2, a2)
      when tc1 == tc2
           && (match tc1.tc_def with Alias _ -> false | _ -> true)
           && List.length a1 = List.length a2 ->
      List.iter2 unify a1 a2
    | TArrow (a1, b1), TArrow (a2, b2) -> unify a1 a2; unify b1 b2
    | TTup t1, TTup t2 when List.length t1 = List.length t2 -> List.iter2 unify t1 t2
    | _ -> (
      match (unalias a, unalias b) with
      | Some a', _ -> unify a' b
      | _, Some b' -> unify a b'
      | None, None ->
        let sa = show a and sb = show b in
        (* two types can print the same and still differ: a sealing, or an
           application of a functor, makes a type constructor nobody else
           has, and its name says nothing about which one it is *)
        if String.equal sa sb then
          clash "these are two different types, both called %s" sa
        else clash "%s and %s do not match" sa sb)

(* Two rows are the same row when each field of one is somewhere in the other
   and what is left over agrees.  A field is looked for by [rewrite], which
   also lets a row that ends in a variable grow the field it is asked for. *)
and unify_row a b =
  let a = repr a and b = repr b in
  if a == b then ()
  else
    match (a, b) with
    | TVar r1, TVar r2 when r1 == r2 -> ()
    | TVar ({ contents = Unbound (_, lv, Row lacks) } as r), t
    | t, TVar ({ contents = Unbound (_, lv, Row lacks) } as r) -> (
      match repr t with
      | TVar ({ contents = Unbound (id', lv', c') } as r') when r != r' ->
        r' := Unbound (id', min lv lv', merge_cls (Row lacks) c');
        r := Link (TVar r')
      | t ->
        let fields, _ = row_parts t in
        List.iter
          (fun (l, _) ->
            if List.mem l lacks then clash "this record is given the field %s twice" l)
          fields;
        occurs r lv t;
        r := Link t)
    | TRowNil, TRowNil -> ()
    | TRowCons (l, t, rest), TRowCons _ ->
      let rest' = rewrite l t b in
      unify_row rest rest'
    | TRowCons (l, _, _), TRowNil | TRowNil, TRowCons (l, _, _) ->
      clash "there is no field %s" l
    (* a rigid row is every record that has the fields already agreed, and a
       row that ends anywhere else is not *)
    | TVar { contents = Rigid _ }, _ | _, TVar { contents = Rigid _ } ->
      clash "one of these records is open where the other is not"
    | _ -> clash "%s and %s do not match" (show a) (show b)

(* Find [l] in [row], agreeing its type with [t], and give back the row
   without it; a row that ends in a variable gains the field instead. *)
and rewrite l t row =
  match repr row with
  | TRowCons (l', t', rest) when String.equal l l' ->
    unify t t';
    rest
  | TRowCons (l', t', rest) -> TRowCons (l', t', rewrite l t rest)
  | TVar ({ contents = Unbound (_, lv, Row lacks) } as r) ->
    if List.mem l lacks then clash "this record is given the field %s twice" l;
    occurs r lv t;
    let rest = TVar (ref (Unbound (next (), lv, Row (l :: lacks)))) in
    r := Link (TRowCons (l, t, rest));
    rest
  | TRowNil -> clash "there is no field %s" l
  | other -> clash "%s is not a record row" (show other)

(* ------------------------------------------------------------------
 * Schemes
 * ------------------------------------------------------------------ *)

let mono t = { s_vars = []; s_body = t }

let class_of r = match !r with Unbound (_, _, c) | Rigid (_, c) -> c | Link _ -> NoCls

let instantiate s =
  match s.s_vars with
  | [] -> s.s_body
  | vars -> subst (List.map (fun r -> (r, newvar ~cls:(class_of r) ())) vars) s.s_body

(* Instantiate with fresh Rigid variables: the "for all" of a signature's
   specification, as seen by the check that a structure is at least as
   general. *)
let skolemize s =
  match s.s_vars with
  | [] -> s.s_body
  | vars ->
    let map =
      List.mapi
        (fun i r ->
          let name = String.make 1 (Char.chr (Char.code 'a' + (i mod 26))) in
          (r, TVar (newrigid ~cls:(class_of r) name)))
        vars
    in
    subst map s.s_body

(* The variables above the current level, in the order they are met.  A type
   written by hand has a handful, so the scan for duplicates is a list; the
   quadratic case is a type large enough that walking it dominates anyway. *)
let free_vars t =
  let acc = ref [] in
  let rec go t =
    match repr t with
    | TVar r -> (
      match !r with
      | Unbound (_, l, _) when l > !level ->
        if not (List.memq r !acc) then acc := r :: !acc
      | _ -> ())
    | TApp (_, args) -> List.iter go args
    | TArrow (a, b) -> go a; go b
    | TTup ts -> List.iter go ts
    | TRecord row -> go row
    | TRowNil -> ()
    | TRowCons (_, t, rest) -> go t; go rest
  in
  go t;
  List.rev !acc
