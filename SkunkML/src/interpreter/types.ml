(* Types, and unification over them.

   The representation is the one an implementation uses rather than the one a
   paper writes down: a unification variable is a mutable cell, unification
   links cells destructively, and generalisation compares a *level* instead of
   scanning the environment.  A variable's level is the depth of `let` at which
   it was created; a variable created inside the right-hand side of a `let` and
   never leaked into the environment has a level deeper than the binding, and
   that is exactly the test for "may be generalised".  Rémy's trick, and the
   reason inference here is linear where Algorithm W is quadratic.

   Two things in this file are not in the textbook presentation:

     * A type constructor has an *identity* ([tid]) separate from its name.
       Two `type t` components of two different signatures are two different
       types even though both print as `t`, and a functor application has to
       be able to replace one identity by a type.  Names cannot do that.
     * An unbound variable may carry a list of fields it *must* have.  That is
       what `#lab` needs: `#name r` says "r is a record with a `name` field"
       without saying what the other fields are.  Unlike a row variable this
       one has to be resolved before generalisation -- which is why SML rejects
       `fun getName r = #name r`, and so does this. *)

type ty =
  | Tvar of tv ref
  | Tcon of tycon * ty list
  | Tarrow of ty * ty
  (* A tuple is a record whose labels are 1, 2, ... n, as in the Definition,
     and `unit` is the record with no fields at all.  So there is one product
     here rather than two, `#1` works on a pair, and a tuple pattern is a
     record pattern the decision-tree compiler never has to tell apart. *)
  | Trecord of (string * ty) list (* sorted by [label_compare] *)

and tv =
  | Link of ty
  (* A variable carries what is demanded of it.  [must] is the fields `#lab`
     needs, [eq] is what `=` needs, [ord] is what `<` needs.  All three are
     resolved by unification or, failing that, at generalisation: [must] is an
     error, [ord] defaults to `int`, and [eq] becomes an equality type
     variable, written `''a`. *)
  | Unbound of {
      id : int;
      level : int;
      must : (string * ty) list;
      eq : bool;
      ord : bool;
    }

and tycon = {
  tid : int;
  (* Does this type admit equality on its own terms?  `int` and `string` do
     because the machine can compare them; `array` and `ref` do because they
     are compared by identity.  A datatype's answer is computed from its
     constructors instead, and an abstract type's answer is no. *)
  mutable teq : bool;
  (* Only ever printed.  A structure renames the type constructors it created
     to `X.t` once it is bound, so that two abstract types that were both
     written `t` do not both print as `t`. *)
  mutable tname : string;
  (* The parameter variables the constructor argument types are written in
     terms of.  `Tcon (tc, args)` lines up positionally with these. *)
  mutable tparams : tv ref list;
  mutable tcons : constr list; (* empty unless this is a datatype *)
}

and constr = {
  cname : string;
  cidx : int; (* which arm: what a decision tree switches on *)
  carg : ty option; (* written in terms of [cres.tparams] *)
  cres : tycon;
}

(* A scheme keeps the variables it quantifies as themselves.  Instantiation
   copies the body, mapping those cells to fresh ones; every other cell is
   shared, which is what makes a scheme with free variables mean what it
   should. *)
type scheme = { qvars : tv ref list; sbody : ty }

let mono t = { qvars = []; sbody = t }

(* Fresh names.  The counters are global and reset per run so that dumps are
   reproducible. *)
let var_counter = ref 0
let con_counter = ref 0
let current_level = ref 0

(* The type constructor counter is *not* reset: an identity handed out once
   must never be handed out again, or two unrelated abstract types would
   become one. *)
let reset () =
  var_counter := 0;
  current_level := 0

(* Between compilation units the variable numbers start again, so that what
   `--dump-core` prints for a program does not move when the prelude does. *)
let renumber () = var_counter := 0

let enter_level () = incr current_level
let leave_level () = decr current_level

let newvar_gen ?(must = []) ?(eq = false) ?(ord = false) () =
  incr var_counter;
  Tvar (ref (Unbound { id = !var_counter; level = !current_level; must; eq; ord }))

let newvar () = newvar_gen ()
let newvar_with must = newvar_gen ~must ()

(* A type constructor's parameter: a placeholder that is only ever substituted
   for, never unified. *)
(* `''a` is a type variable that admits equality; `'a` is any variable. *)
let eq_tyvar name = String.length name >= 2 && name.[0] = '\'' && name.[1] = '\''

let param_var () = ref (Unbound { id = 0; level = 0; must = []; eq = false; ord = false })

(* Every type constructor ever made, newest first.  A functor has to know
   which type constructors its body brought into existence, so that each
   application can be given its own: that is what makes a functor generative.
   [mark] and [since] delimit the ones a stretch of elaboration created. *)
let created : tycon list ref = ref []

let newtycon ?(params = []) name =
  incr con_counter;
  let tc = { tid = !con_counter; tname = name; teq = false; tparams = params; tcons = [] } in
  created := tc :: !created;
  tc

let mark () = !created

let since m =
  let rec go acc l =
    if l == m then List.rev acc
    else match l with [] -> List.rev acc | x :: rest -> go (x :: acc) rest
  in
  go [] !created

(* Follow links, compressing the path as we go. *)
let rec repr t =
  match t with
  | Tvar ({ contents = Link t' } as r) ->
      let t'' = repr t' in
      r := Link t'';
      t''
  | _ -> t

(* Labels.  A numeric label sorts by its value and before any alphabetic one,
   so `{ 1 : int, 2 : bool }` -- which is what `int * bool` is -- keeps its
   components in order even past ten. *)
let is_numeric l =
  l <> "" && String.for_all (fun c -> c >= '0' && c <= '9') l

let label_compare a b =
  match (is_numeric a, is_numeric b) with
  | true, true -> compare (int_of_string a) (int_of_string b)
  | true, false -> -1
  | false, true -> 1
  | false, false -> compare a b

let sort_fields fs = List.sort (fun (a, _) (b, _) -> label_compare a b) fs

(* Are these the labels of a tuple?  Only then is the type printed `a * b` and
   the value printed `(1, true)`. *)
let tuple_shaped fs =
  List.length fs >= 2
  && List.for_all (fun (i, (l, _)) -> l = string_of_int (i + 1)) (List.mapi (fun i f -> (i, f)) fs)

let tuple_labels n = List.init n (fun i -> string_of_int (i + 1))
let tuple_fields xs = List.mapi (fun i x -> (string_of_int (i + 1), x)) xs

(* The built-in types.  `unit` is the empty record and not a constructor of its
   own, as in SML. *)

let int_tc = newtycon "int"
let bool_tc = newtycon "bool"
let string_tc = newtycon "string"
let list_tc = newtycon "list"
let array_tc = newtycon "array"
let ref_tc = newtycon "ref"
let tint = Tcon (int_tc, [])
let tbool = Tcon (bool_tc, [])
let tstring = Tcon (string_tc, [])
let tunit = Trecord []
let tlist t = Tcon (list_tc, [ t ])
let ttuple ts = Trecord (tuple_fields ts)
let tarray t = Tcon (array_tc, [ t ])
let tref t = Tcon (ref_tc, [ t ])

let () =
  List.iter (fun tc -> tc.teq <- true) [ int_tc; bool_tc; string_tc; array_tc; ref_tc ];
  let a = param_var () in
  list_tc.tparams <- [ a ];
  list_tc.tcons <-
    [
      { cname = "nil"; cidx = 0; carg = None; cres = list_tc };
      {
        cname = "::";
        cidx = 1;
        carg = Some (Trecord (tuple_fields [ Tvar a; Tcon (list_tc, [ Tvar a ]) ]));
        cres = list_tc;
      };
    ];
  let b = param_var () in
  array_tc.tparams <- [ b ];
  (* `ref` is a datatype with one constructor, exactly as in SML, which is why
     `ref x` is a pattern and not only an expression.  What makes it a cell is
     the machine: the constructor allocates in the store. *)
  let c = param_var () in
  ref_tc.tparams <- [ c ];
  ref_tc.tcons <- [ { cname = "ref"; cidx = 0; carg = Some (Tvar c); cres = ref_tc } ];
  bool_tc.tcons <-
    [
      { cname = "false"; cidx = 0; carg = None; cres = bool_tc };
      { cname = "true"; cidx = 1; carg = None; cres = bool_tc };
    ]

(* Copying, which is instantiation, signature refreshing and the realisation a
   functor application performs -- all three are "rewrite these cells and these
   type constructors, share everything else". *)

type rewrite = {
  rvars : (tv ref * ty) list;
  rcons : (int * (tv ref list * ty)) list; (* tid -> a type function *)
}

let no_rewrite = { rvars = []; rcons = [] }

let rec assq_ref r = function
  | [] -> None
  | (k, v) :: rest -> if k == r then Some v else assq_ref r rest

let rec copy (rw : rewrite) t =
  match repr t with
  | Tvar r as t -> (
      match assq_ref r rw.rvars with
      | Some t' -> t'
      (* Everything not named by the rewrite is shared, not copied.  A
         variable with unresolved field demands is never quantified -- that is
         an error -- so it is never one of the cells being rewritten. *)
      | None -> t)
  | Tcon (tc, args) -> (
      let args = List.map (copy rw) args in
      match List.assoc_opt tc.tid rw.rcons with
      | None -> Tcon (tc, args)
      | Some (params, body) ->
          copy { rw with rvars = List.combine params args @ rw.rvars } body)
  | Tarrow (a, b) -> Tarrow (copy rw a, copy rw b)
  | Trecord fs -> Trecord (List.map (fun (l, t) -> (l, copy rw t)) fs)

let realise rcons t = if rcons = [] then t else copy { no_rewrite with rcons } t

(* Instantiating keeps what was demanded of a variable: an `''a` becomes a
   fresh variable that still insists on equality. *)
let instantiate (s : scheme) =
  match s.qvars with
  | [] -> s.sbody
  | vs ->
      let fresh v =
        match !v with
        | Unbound u -> (v, newvar_gen ~eq:u.eq ~ord:u.ord ())
        | Link _ -> (v, newvar ())
      in
      copy { no_rewrite with rvars = List.map fresh vs } s.sbody

(* A constructor's argument type at a given instance of its datatype. *)
let con_arg (c : constr) (args : ty list) =
  match c.carg with
  | None -> None
  | Some t -> Some (copy { no_rewrite with rvars = List.combine c.cres.tparams args } t)

(* Unification. *)

let rec occurs loc r level t =
  match repr t with
  | Tvar r' ->
      if r' == r then Loc.type_error loc "this type would contain itself";
      (match !r' with
      | Unbound u ->
          List.iter (fun (_, t) -> occurs loc r level t) u.must;
          (* Lowering the level of everything reachable is what keeps a
             variable that escapes into an outer scope from being generalised
             there. *)
          if u.level > level then r' := Unbound { u with level }
      | Link _ -> ())
  | Tcon (_, args) -> List.iter (occurs loc r level) args
  | Tarrow (a, b) ->
      occurs loc r level a;
      occurs loc r level b
  | Trecord fs -> List.iter (fun (_, t) -> occurs loc r level t) fs

let rec show ?(prec = 0) t =
  let paren p s = if prec > p then "(" ^ s ^ ")" else s in
  match repr t with
  | Tvar { contents = Unbound u } ->
      let base = Printf.sprintf "%s_%d" (if u.eq then "''" else "'") u.id in
      if u.must = [] then base
      else
        Printf.sprintf "{ %s, ... }"
          (String.concat ", "
             (List.map (fun (l, t) -> Printf.sprintf "%s : %s" l (show t)) u.must))
  | Tvar _ -> assert false
  | Tcon (tc, []) -> tc.tname
  | Tcon (tc, [ a ]) -> paren 3 (Printf.sprintf "%s %s" (show ~prec:3 a) tc.tname)
  | Tcon (tc, args) ->
      Printf.sprintf "(%s) %s" (String.concat ", " (List.map (show ~prec:0) args)) tc.tname
  | Tarrow (a, b) ->
      paren 1 (Printf.sprintf "%s -> %s" (show ~prec:2 a) (show ~prec:1 b))
  | Trecord [] -> "unit"
  | Trecord fs when tuple_shaped fs ->
      paren 2 (String.concat " * " (List.map (fun (_, t) -> show ~prec:3 t) fs))
  | Trecord fs ->
      Printf.sprintf "{ %s }"
        (String.concat ", "
           (List.map (fun (l, t) -> Printf.sprintf "%s : %s" l (show t)) fs))

(* A type variable written in an annotation is read as a rigid type
   constructor whose name still starts with a quote, so it can say what it
   is. *)
let is_written_var c = String.length c.tname > 0 && c.tname.[0] = '\''

let written_var loc c other =
  Loc.type_error loc
    "%s was written in an annotation, so it has to work for every type, and \
     this needs it to be %s"
    c.tname (show other)

let rec unify loc t1 t2 =
  let t1 = repr t1 and t2 = repr t2 in
  if t1 == t2 then ()
  else
    match (t1, t2) with
    | Tvar r1, Tvar r2 when r1 == r2 -> ()
    | Tvar ({ contents = Unbound u } as r), t | t, Tvar ({ contents = Unbound u } as r) ->
        occurs loc r u.level t;
        (match u.must with [] -> () | must -> require_fields loc must t);
        if u.eq then require_eq loc [] t;
        if u.ord then require_ord loc t;
        r := Link t
    | Tcon (c1, a1), Tcon (c2, a2) when c1.tid = c2.tid -> List.iter2 (unify loc) a1 a2
    | Tarrow (a1, b1), Tarrow (a2, b2) ->
        unify loc a1 a2;
        unify loc b1 b2
    | Trecord f1, Trecord f2 when List.map fst f1 = List.map fst f2 ->
        List.iter2 (fun (_, a) (_, b) -> unify loc a b) f1 f2
    (* Two type constructors can print the same and still be different: a
       sealed structure and a second application of the same functor both make
       a `t` of their own.  Saying so is more use than saying `t` twice. *)
    | Tcon (c1, _), Tcon (c2, _) when c1.tname = c2.tname && c1.tid <> c2.tid ->
        Loc.type_error loc
          "these are two different types both called %s: one abstract type is \
           not another"
          c1.tname
    | Tcon (c, _), other when is_written_var c -> written_var loc c other
    | other, Tcon (c, _) when is_written_var c -> written_var loc c other
    | _ -> Loc.type_error loc "cannot unify %s with %s" (show t1) (show t2)

(* Equality.  `int` and `string` the machine can compare; `array` and `ref` are
   compared by identity; a record admits equality when all its fields do; a
   datatype when all its constructors' arguments do -- and while that is being
   decided the datatype itself is assumed to, which is what [seen] is for and
   what makes `int list` an equality type.  A function never does, and neither
   does an abstract type, because nothing is known about it. *)
and require_eq loc seen t =
  match repr t with
  | Tvar ({ contents = Unbound u } as r) -> r := Unbound { u with eq = true }
  | Tvar _ -> assert false
  | Trecord fs -> List.iter (fun (_, t) -> require_eq loc seen t) fs
  | Tarrow _ ->
      Loc.type_error loc "a function cannot be compared: %s does not admit equality"
        (show t)
  | Tcon (tc, args) ->
      if tc.teq || List.mem tc.tid seen then ()
      else if tc.tcons = [] then
        Loc.type_error loc "%s is abstract, so it does not admit equality" tc.tname
      else
        List.iter
          (fun c ->
            match con_arg c args with
            | None -> ()
            | Some at -> require_eq loc (tc.tid :: seen) at)
          tc.tcons

(* Order.  Only two types, as in SML minus `char` and `real`; an unresolved
   demand defaults to `int` at generalisation. *)
and require_ord loc t =
  match repr t with
  | Tvar ({ contents = Unbound u } as r) -> r := Unbound { u with ord = true }
  | Tcon (tc, _) when tc.tid = int_tc.tid || tc.tid = string_tc.tid -> ()
  | other ->
      Loc.type_error loc "%s cannot be ordered: only int and string can" (show other)

(* The fields an unbound variable demanded have to be found in whatever it is
   linked to.  Against another variable the demands merge; against a record the
   record decides, and a missing field is an error here rather than later. *)
and require_fields loc must t =
  match repr t with
  | Tvar ({ contents = Unbound u } as r) ->
      let merged =
        List.fold_left
          (fun acc (l, ty) ->
            match List.assoc_opt l acc with
            | Some ty' ->
                unify loc ty ty';
                acc
            | None -> acc @ [ (l, ty) ])
          u.must must
      in
      r := Unbound { u with must = merged }
  | Trecord fs ->
      List.iter
        (fun (l, ty) ->
          match List.assoc_opt l fs with
          | Some ty' -> unify loc ty ty'
          | None ->
              Loc.type_error loc "this record has no field %s: it is %s" l
                (show (Trecord fs)))
        must
  | other ->
      Loc.type_error loc "expected a record with %s, but this is %s"
        (String.concat " and " (List.map (fun (l, _) -> "a field " ^ l) must))
        (show other)

(* Generalisation.  Everything created deeper than the current level, and
   therefore not reachable from the environment, is quantified. *)
(* Overloading is resolved where the declaration ends: a `<` whose operands
   are still unknown is about integers.  SML does the same. *)
let rec default_ord t =
  match repr t with
  | Tvar { contents = Unbound u } when u.ord -> unify Loc.unknown t tint
  | Tvar _ -> ()
  | Tcon (_, args) -> List.iter default_ord args
  | Tarrow (a, b) ->
      default_ord a;
      default_ord b
  | Trecord fs -> List.iter (fun (_, t) -> default_ord t) fs

let generalise loc t =
  let acc = ref [] in
  let rec walk t =
    match repr t with
    | Tvar ({ contents = Unbound u } as r) ->
        if u.level > !current_level then begin
          if u.must <> [] then
            Loc.type_error loc
              "this record's type is not determined here: %s. Write the type \
               out, as SML makes you"
              (show t);
          if not (List.memq r !acc) then acc := r :: !acc
        end
    | Tvar _ -> ()
    | Tcon (_, args) -> List.iter walk args
    | Tarrow (a, b) ->
        walk a;
        walk b
    | Trecord fs -> List.iter (fun (_, t) -> walk t) fs
  in
  walk t;
  { qvars = List.rev !acc; sbody = t }

(* Printing a scheme renames its quantified variables 'a, 'b, ... in the order
   they appear, so the same type always prints the same way whatever the
   counter happens to be. *)
let show_scheme (s : scheme) =
  let names = ref [] and next = ref 0 in
  let name_of r =
    match assq_ref r !names with
    | Some n -> n
    | None ->
        let i = !next in
        incr next;
        (* An equality type variable wears the extra quote SML gives it. *)
        let tick = match !r with Unbound u when u.eq -> "''" | _ -> "'" in
        let n =
          if i < 26 then Printf.sprintf "%s%c" tick (Char.chr (Char.code 'a' + i))
          else Printf.sprintf "%st%d" tick i
        in
        names := (r, n) :: !names;
        n
  in
  (* The names are handed out as the type is walked, so they have to be handed
     out left to right -- which [List.map] and the argument order of a
     [Printf.sprintf] do not promise. *)
  let map_lr f xs = List.rev (List.rev_map f xs) in
  let rec go ?(prec = 0) t =
    let paren p s = if prec > p then "(" ^ s ^ ")" else s in
    match repr t with
    | Tvar r ->
        if List.memq r s.qvars then name_of r
        else (
          match !r with
          | Unbound u -> Printf.sprintf "%s_%d" (if u.eq then "''" else "'") u.id
          | Link _ -> assert false)
    | Tcon (tc, []) -> tc.tname
    | Tcon (tc, [ a ]) -> paren 3 (Printf.sprintf "%s %s" (go ~prec:3 a) tc.tname)
    | Tcon (tc, args) ->
        Printf.sprintf "(%s) %s" (String.concat ", " (map_lr (go ~prec:0) args)) tc.tname
    | Tarrow (a, b) ->
        let dom = go ~prec:2 a in
        let cod = go ~prec:1 b in
        paren 1 (Printf.sprintf "%s -> %s" dom cod)
    | Trecord [] -> "unit"
    | Trecord fs when tuple_shaped fs ->
        paren 2 (String.concat " * " (map_lr (fun (_, t) -> go ~prec:3 t) fs))
    | Trecord fs ->
        Printf.sprintf "{ %s }"
          (String.concat ", "
             (map_lr (fun (l, t) -> Printf.sprintf "%s : %s" l (go t)) fs))
  in
  go s.sbody

(* Record fields are kept sorted so that `{ y = 1, x = 2 }` and
   `{ x = 2, y = 1 }` are the same type and the same value. *)
let dup_label fs =
  let rec go = function
    | (a, _) :: ((b, _) :: _ as rest) -> if a = b then Some a else go rest
    | _ -> None
  in
  go (sort_fields fs)
