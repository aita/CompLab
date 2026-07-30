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
  | Ttuple of ty list (* the empty tuple is `unit` *)
  | Trecord of (string * ty) list (* sorted by label *)

and tv =
  | Link of ty
  | Unbound of { id : int; level : int; must : (string * ty) list }

and tycon = {
  tid : int;
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

let newvar_with must =
  incr var_counter;
  Tvar (ref (Unbound { id = !var_counter; level = !current_level; must }))

let newvar () = newvar_with []

(* Every type constructor ever made, newest first.  A functor has to know
   which type constructors its body brought into existence, so that each
   application can be given its own: that is what makes a functor generative.
   [mark] and [since] delimit the ones a stretch of elaboration created. *)
let created : tycon list ref = ref []

let newtycon ?(params = []) name =
  incr con_counter;
  let tc = { tid = !con_counter; tname = name; tparams = params; tcons = [] } in
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

(* The built-in types.  `unit` is `Ttuple []` and not a constructor of its own,
   as in SML, where it is the empty record. *)

let int_tc = newtycon "int"
let bool_tc = newtycon "bool"
let string_tc = newtycon "string"
let list_tc = newtycon "list"
let array_tc = newtycon "array"
let tint = Tcon (int_tc, [])
let tbool = Tcon (bool_tc, [])
let tstring = Tcon (string_tc, [])
let tunit = Ttuple []
let tlist t = Tcon (list_tc, [ t ])
let tarray t = Tcon (array_tc, [ t ])

let () =
  let a = ref (Unbound { id = 0; level = 0; must = [] }) in
  list_tc.tparams <- [ a ];
  list_tc.tcons <-
    [
      { cname = "nil"; cidx = 0; carg = None; cres = list_tc };
      {
        cname = "::";
        cidx = 1;
        carg = Some (Ttuple [ Tvar a; Tcon (list_tc, [ Tvar a ]) ]);
        cres = list_tc;
      };
    ];
  let b = ref (Unbound { id = 0; level = 0; must = [] }) in
  array_tc.tparams <- [ b ];
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
  | Ttuple ts -> Ttuple (List.map (copy rw) ts)
  | Trecord fs -> Trecord (List.map (fun (l, t) -> (l, copy rw t)) fs)

let realise rcons t = if rcons = [] then t else copy { no_rewrite with rcons } t

let instantiate (s : scheme) =
  match s.qvars with
  | [] -> s.sbody
  | vs -> copy { no_rewrite with rvars = List.map (fun v -> (v, newvar ())) vs } s.sbody

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
  | Ttuple ts -> List.iter (occurs loc r level) ts
  | Trecord fs -> List.iter (fun (_, t) -> occurs loc r level t) fs

let rec show ?(prec = 0) t =
  let paren p s = if prec > p then "(" ^ s ^ ")" else s in
  match repr t with
  | Tvar { contents = Unbound u } ->
      let base = Printf.sprintf "'_%d" u.id in
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
  | Ttuple [] -> "unit"
  | Ttuple ts -> paren 2 (String.concat " * " (List.map (show ~prec:3) ts))
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
        (match u.must with
        | [] -> ()
        | must -> require_fields loc must t);
        r := Link t
    | Tcon (c1, a1), Tcon (c2, a2) when c1.tid = c2.tid -> List.iter2 (unify loc) a1 a2
    | Tarrow (a1, b1), Tarrow (a2, b2) ->
        unify loc a1 a2;
        unify loc b1 b2
    | Ttuple ts1, Ttuple ts2 when List.length ts1 = List.length ts2 ->
        List.iter2 (unify loc) ts1 ts2
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
    | Ttuple ts -> List.iter walk ts
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
        let n =
          if i < 26 then Printf.sprintf "'%c" (Char.chr (Char.code 'a' + i))
          else Printf.sprintf "'t%d" i
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
        else (match !r with Unbound u -> Printf.sprintf "'_%d" u.id | Link _ -> assert false)
    | Tcon (tc, []) -> tc.tname
    | Tcon (tc, [ a ]) -> paren 3 (Printf.sprintf "%s %s" (go ~prec:3 a) tc.tname)
    | Tcon (tc, args) ->
        Printf.sprintf "(%s) %s" (String.concat ", " (map_lr (go ~prec:0) args)) tc.tname
    | Tarrow (a, b) ->
        let dom = go ~prec:2 a in
        let cod = go ~prec:1 b in
        paren 1 (Printf.sprintf "%s -> %s" dom cod)
    | Ttuple [] -> "unit"
    | Ttuple ts -> paren 2 (String.concat " * " (map_lr (go ~prec:3) ts))
    | Trecord fs ->
        Printf.sprintf "{ %s }"
          (String.concat ", "
             (map_lr (fun (l, t) -> Printf.sprintf "%s : %s" l (go t)) fs))
  in
  go s.sbody

(* Record fields are kept sorted so that `{ y = 1, x = 2 }` and
   `{ x = 2, y = 1 }` are the same type and the same value. *)
let sort_fields fs = List.sort (fun (a, _) (b, _) -> compare a b) fs

let dup_label fs =
  let rec go = function
    | (a, _) :: ((b, _) :: _ as rest) -> if a = b then Some a else go rest
    | _ -> None
  in
  go (sort_fields fs)
