(* The `row` system: Hindley-Milner inference over row types, with extensible
   records and variants.

   Rows follow Daan Leijen's "Extensible Records with Scoped Labels" (2005).
   The choice worth knowing about is that a label may appear twice in a row:
   `{ x = 1, ..{ x = true } }` has type `{ x : int, x : bool }`, selection finds
   the outermost `x`, and removing it uncovers the one underneath.  The
   alternative -- Remy-style rows with absence constraints -- rules duplicates
   out, at the price of carrying a constraint on every row variable.  Scoped
   labels need no constraints at all: the only new operation is "rewrite this
   row so that label l is at the front", and unification is otherwise the
   usual thing.

   Generalisation is by levels, in the standard way: every unification
   variable remembers the `let` depth at which it was created, and a variable
   that survives a `let` at a deeper level than its own cannot be generalised
   because something outside still refers to it. *)

type ty =
  | TCon of string (* int, bool, unit, and rigid variables from annotations *)
  | TArrow of ty * ty
  | TPair of ty * ty
  | TRecord of row
  | TVariant of row
  | TVar of tvar ref

and tvar = TUnbound of int * int (* id, level *) | TLink of ty

and row =
  | REmpty
  | RExtend of string * ty * row
  | RCon of string (* a rigid row variable from an annotation *)
  | RVar of rvar ref

and rvar = RUnbound of int * int | RLink of row

(* Bindings in the environment are schemes; a scheme is a type in which some
   variables sit at the generic level and are copied at every use. *)
let generic = max_int
let level = ref 0
let ids = ref 0

let next_id () =
  incr ids;
  !ids

let fresh_var () = TVar (ref (TUnbound (next_id (), !level)))
let fresh_row () = RVar (ref (RUnbound (next_id (), !level)))

let rec force t =
  match t with TVar { contents = TLink t } -> force t | t -> t

let rec force_row r =
  match r with RVar { contents = RLink r } -> force_row r | r -> r

(* Printing.  Variables are numbered by the order they are met, so the same
   type always prints the same way. *)
let show ty =
  let names = Hashtbl.create 8 in
  let supply = [| "'a"; "'b"; "'c"; "'d"; "'e"; "'f"; "'g"; "'h" |] in
  let name_of id =
    match Hashtbl.find_opt names id with
    | Some n -> n
    | None ->
        let i = Hashtbl.length names in
        let n =
          if i < Array.length supply then supply.(i)
          else Printf.sprintf "'t%d" i
        in
        Hashtbl.add names id n;
        n
  in
  let rec go prec t =
    let paren p s = if prec > p then "(" ^ s ^ ")" else s in
    match force t with
    | TCon c -> c
    | TVar { contents = TUnbound (id, _) } -> name_of id
    | TVar _ -> assert false
    (* The parts are named in order, left to right: OCaml evaluates the
       arguments of an application right to left, so the printer would
       otherwise call the first variable it prints 'b. *)
    | TArrow (a, b) ->
        let l = go 2 a in
        let r = go 1 b in
        paren 1 (Printf.sprintf "%s -> %s" l r)
    | TPair (a, b) ->
        let l = go 4 a in
        let r = go 4 b in
        paren 3 (Printf.sprintf "%s * %s" l r)
    | TRecord r -> Printf.sprintf "{ %s }" (row_str "" r)
    | TVariant r -> Printf.sprintf "[ %s ]" (row_str "`" r)
  and row_str tick r =
    let rec fields r =
      match force_row r with
      | REmpty -> ([], None)
      | RExtend (l, t, rest) ->
          let fs, tail = fields rest in
          ((l, t) :: fs, tail)
      | RCon c -> ([], Some c)
      | RVar { contents = RUnbound (id, _) } -> ([], Some (name_of id))
      | RVar _ -> assert false
    in
    let fs, tail = fields r in
    let parts =
      List.map
        (fun (l, t) ->
          let shown = go 0 t in
          Printf.sprintf "%s%s : %s" tick l shown)
        fs
    in
    let parts = parts @ (match tail with None -> [] | Some n -> [ ".." ^ n ]) in
    String.concat ", " parts
  in
  go 0 ty

(* Levels.  Linking a variable to a type may bring that type into a shallower
   scope, so every variable it mentions has to be pulled up with it. *)
let rec update_level loc lvl t =
  match force t with
  | TCon _ -> ()
  | TVar ({ contents = TUnbound (id, l) } as r) ->
      if l = generic then Loc.type_error loc "a generic variable escaped"
      else if l > lvl then r := TUnbound (id, lvl)
  | TVar _ -> ()
  | TArrow (a, b) | TPair (a, b) ->
      update_level loc lvl a;
      update_level loc lvl b
  | TRecord r | TVariant r -> update_level_row loc lvl r

and update_level_row loc lvl r =
  match force_row r with
  | REmpty | RCon _ -> ()
  | RExtend (_, t, rest) ->
      update_level loc lvl t;
      update_level_row loc lvl rest
  | RVar ({ contents = RUnbound (id, l) } as ref_) ->
      if l > lvl then ref_ := RUnbound (id, lvl)
  | RVar _ -> ()

let rec occurs_ty r t =
  match force t with
  | TVar r' -> r == r'
  | TArrow (a, b) | TPair (a, b) -> occurs_ty r a || occurs_ty r b
  | TRecord row | TVariant row -> occurs_row_in_ty r row
  | TCon _ -> false

and occurs_row_in_ty r row =
  match force_row row with
  | RExtend (_, t, rest) -> occurs_ty r t || occurs_row_in_ty r rest
  | _ -> false

let rec occurs_rvar rv row =
  match force_row row with
  | RVar r -> r == rv
  | RExtend (_, t, rest) -> occurs_rvar_ty rv t || occurs_rvar rv rest
  | REmpty | RCon _ -> false

and occurs_rvar_ty rv t =
  match force t with
  | TArrow (a, b) | TPair (a, b) -> occurs_rvar_ty rv a || occurs_rvar_ty rv b
  | TRecord r | TVariant r -> occurs_rvar rv r
  | _ -> false

let rec unify loc a b =
  let a = force a and b = force b in
  if a == b then ()
  else
    match (a, b) with
    | TCon x, TCon y when x = y -> ()
    | TVar ({ contents = TUnbound (_, l) } as r), t
    | t, TVar ({ contents = TUnbound (_, l) } as r) ->
        if occurs_ty r t then
          Loc.type_error loc "this type would contain itself: %s" (show t);
        update_level loc l t;
        r := TLink t
    | TArrow (a1, a2), TArrow (b1, b2) | TPair (a1, a2), TPair (b1, b2) ->
        unify loc a1 b1;
        unify loc a2 b2
    | TRecord r1, TRecord r2 -> unify_row loc r1 r2
    | TVariant r1, TVariant r2 -> unify_row loc r1 r2
    | _ -> Loc.type_error loc "cannot unify %s with %s" (show a) (show b)

(* Row unification.  The interesting case is an extension against anything
   else: rewrite the other row so that the same label is at the front, then
   carry on with the tails.  [rewrite] is where a fresh row variable gets
   split into "the label we want, and the rest". *)
and unify_row loc r1 r2 =
  let r1 = force_row r1 and r2 = force_row r2 in
  match (r1, r2) with
  | REmpty, REmpty -> ()
  | RCon a, RCon b when a = b -> ()
  | RVar ({ contents = RUnbound (_, l) } as r), other
  | other, RVar ({ contents = RUnbound (_, l) } as r) ->
      if occurs_rvar r other then
        Loc.type_error loc "this row would contain itself: { %s }" (show (TRecord other));
      update_level_row loc l other;
      r := RLink other
  | RExtend (l, t, rest), other ->
      let t', rest' = rewrite loc other l in
      unify loc t t';
      unify_row loc rest rest'
  | _, RExtend _ -> unify_row loc r2 r1
  | _ ->
      Loc.type_error loc "cannot unify the rows { %s } and { %s }"
        (show (TRecord r1)) (show (TRecord r2))

and rewrite loc row l =
  match force_row row with
  | REmpty -> Loc.type_error loc "there is no field %s here" l
  | RExtend (l', t, rest) when l' = l -> (t, rest)
  | RExtend (l', t, rest) ->
      let t', rest' = rewrite loc rest l in
      (t', RExtend (l', t, rest'))
  | RVar ({ contents = RUnbound (_, lvl) } as r) ->
      (* The row is not known yet, so decide that it has l, and leave a new
         variable for whatever else it has. *)
      let t = TVar (ref (TUnbound (next_id (), lvl))) in
      let rest = RVar (ref (RUnbound (next_id (), lvl))) in
      r := RLink (RExtend (l, t, rest));
      (t, rest)
  | RCon c ->
      Loc.type_error loc "the row variable %s is fixed, so it cannot be given a field %s" c l
  | RVar _ -> assert false

(* Generalisation and instantiation. *)
let rec generalize t =
  match force t with
  | TVar ({ contents = TUnbound (id, l) } as r) when l > !level ->
      r := TUnbound (id, generic)
  | TArrow (a, b) | TPair (a, b) ->
      generalize a;
      generalize b
  | TRecord r | TVariant r -> generalize_row r
  | _ -> ()

and generalize_row r =
  match force_row r with
  | RExtend (_, t, rest) ->
      generalize t;
      generalize_row rest
  | RVar ({ contents = RUnbound (id, l) } as ref_) when l > !level ->
      ref_ := RUnbound (id, generic)
  | _ -> ()

let instantiate t =
  let seen = Hashtbl.create 8 in
  let rec go t =
    match force t with
    | TVar { contents = TUnbound (id, l) } when l = generic -> (
        match Hashtbl.find_opt seen id with
        | Some v -> v
        | None ->
            let v = fresh_var () in
            Hashtbl.add seen id v;
            v)
    | TArrow (a, b) -> TArrow (go a, go b)
    | TPair (a, b) -> TPair (go a, go b)
    | TRecord r -> TRecord (go_row r)
    | TVariant r -> TVariant (go_row r)
    | t -> t
  and go_row r =
    match force_row r with
    | RExtend (l, t, rest) -> RExtend (l, go t, go_row rest)
    | RVar { contents = RUnbound (id, l) } when l = generic -> (
        match Hashtbl.find_opt seen (-id) with
        | Some (TRecord v) -> v
        | _ ->
            let v = fresh_row () in
            Hashtbl.add seen (-id) (TRecord v);
            v)
    | r -> r
  in
  go t

(* Reading a type out of an annotation.  Names that are not the built-in
   constants become rigid: `forall a. a -> a` is checked against a body that
   may not assume anything about `a`, which is what makes an annotation a
   promise rather than a wish. *)
type state = {
  aliases : (string, string list * Ast.t) Hashtbl.t;
  (* The rigid names this declaration's annotations introduced, so that they
     can be quantified again once the body has been checked against them. *)
  mutable rtys : string list;
  mutable rrows : string list;
}

let rigid_ty st name =
  if not (List.mem name st.rtys) then st.rtys <- name :: st.rtys;
  TCon name

let rigid_row st name =
  if not (List.mem name st.rrows) then st.rrows <- name :: st.rrows;
  RCon name

let rec read_ty (st : state) (e : Ast.t) : ty =
  match e.it with
  | Ast.Var "int" -> TCon "int"
  | Ast.Var "bool" -> TCon "bool"
  | Ast.Var "unit" -> TCon "unit"
  | Ast.Var x -> (
      match Hashtbl.find_opt st.aliases x with
      | Some ([], body) -> read_ty st body
      | Some (ps, _) ->
          Loc.type_error e.loc "the alias %s takes %d argument(s)" x (List.length ps)
      | None -> rigid_ty st x)
  | Ast.App _ -> (
      let head, args = Anf.spine e [] in
      match head.it with
      | Ast.Var name -> (
          match Hashtbl.find_opt st.aliases name with
          | Some (ps, body) when List.length ps = List.length args ->
              let sub = List.combine ps args in
              read_ty st (substitute sub body)
          | Some (ps, _) ->
              Loc.type_error e.loc "the alias %s takes %d argument(s)" name
                (List.length ps)
          | None -> Loc.type_error e.loc "%s is not a type alias" name)
      | _ -> Loc.type_error e.loc "this is not a type")
  | Ast.Arrow (Ast.Many, None, a, b) -> TArrow (read_ty st a, read_ty st b)
  | Ast.Arrow (Ast.One, _, _, _) ->
      Loc.type_error e.loc "`-o` is a linear arrow; try #system linear"
  | Ast.Arrow (_, Some _, _, _) ->
      Loc.type_error e.loc "a named argument needs #system refine or #system dep"
  | Ast.Bin ("*", a, b) -> TPair (read_ty st a, read_ty st b)
  | Ast.Forall (_, body) -> read_ty st body
  | Ast.Rec (Ast.Colon, fields, tail) -> TRecord (read_row st fields tail)
  | Ast.Rec (Ast.Eq, [], None) -> TRecord REmpty
  | Ast.VariantTy (fields, tail) -> TVariant (read_row st fields tail)
  | Ast.Refine _ -> Loc.type_error e.loc "refinement types belong to #system refine"
  | Ast.Prod _ -> Loc.type_error e.loc "dependent pairs belong to #system dep"
  | Ast.Choice _ | Ast.Uop (("!" | "?"), _) ->
      Loc.type_error e.loc "session types belong to #system linear"
  | _ -> Loc.type_error e.loc "this is not a type"

and read_row st fields tail =
  let tl =
    match tail with
    | None -> REmpty
    | Some { it = Ast.Var r; _ } -> rigid_row st r
    | Some t -> Loc.type_error t.Ast.loc "a row tail must be a variable"
  in
  List.fold_right
    (fun (f : Ast.field) rest -> RExtend (f.flabel, read_ty st f.fbody, rest))
    fields tl

(* Substituting a type argument into an alias body, syntactically. *)
and substitute sub (e : Ast.t) : Ast.t =
  let rec go (e : Ast.t) =
    let it =
      match e.Ast.it with
      | Ast.Var x -> (
          match List.assoc_opt x sub with Some r -> r.Ast.it | None -> Ast.Var x)
      | Ast.Arrow (m, n, a, b) -> Ast.Arrow (m, n, go a, go b)
      | Ast.Bin (op, a, b) -> Ast.Bin (op, go a, go b)
      | Ast.App (a, b) -> Ast.App (go a, go b)
      | Ast.Rec (s, fs, t) ->
          Ast.Rec
            ( s,
              List.map (fun (f : Ast.field) -> { f with fbody = go f.fbody }) fs,
              Option.map go t )
      | Ast.VariantTy (fs, t) ->
          Ast.VariantTy
            ( List.map (fun (f : Ast.field) -> { f with fbody = go f.fbody }) fs,
              Option.map go t )
      | Ast.Forall (vs, b) -> Ast.Forall (vs, go b)
      | it -> it
    in
    { e with Ast.it }
  in
  go e

(* An annotation is a promise: while the body is checked, the names it binds
   are rigid constants, so `let f : a -> a = fun x -> x + 1` is rejected rather
   than quietly specialised.  Once the body has been checked they are turned
   back into quantified variables, which is what makes the annotated binding
   polymorphic at its use sites. *)
let quantify_rigids st t =
  let tmap =
    List.map (fun n -> (n, TVar (ref (TUnbound (next_id (), generic))))) st.rtys
  in
  let rmap =
    List.map (fun n -> (n, RVar (ref (RUnbound (next_id (), generic))))) st.rrows
  in
  let rec go t =
    match force t with
    | TCon c -> ( match List.assoc_opt c tmap with Some v -> v | None -> TCon c)
    | TArrow (a, b) -> TArrow (go a, go b)
    | TPair (a, b) -> TPair (go a, go b)
    | TRecord r -> TRecord (go_row r)
    | TVariant r -> TVariant (go_row r)
    | t -> t
  and go_row r =
    match force_row r with
    | RExtend (l, t, rest) -> RExtend (l, go t, go_row rest)
    | RCon c -> ( match List.assoc_opt c rmap with Some v -> v | None -> RCon c)
    | r -> r
  in
  go t

type env = (string * ty) list

let arith = [ "+"; "-"; "*"; "/"; "%" ]
let comparisons = [ "=="; "!="; "<"; "<="; ">"; ">=" ]

let initial_env () =
  let a = TVar (ref (TUnbound (next_id (), generic))) in
  let b = TVar (ref (TUnbound (next_id (), generic))) in
  [
    ("not", TArrow (TCon "bool", TCon "bool"));
    ("print", TArrow (a, TCon "unit"));
    ("fst", TArrow (TPair (a, b), a));
    ("snd", TArrow (TPair (a, b), b));
  ]

let rec infer (st : state) (env : env) (e : Ast.t) : ty =
  match e.it with
  | Ast.Int _ -> TCon "int"
  | Ast.Bool _ -> TCon "bool"
  | Ast.Unit -> TCon "unit"
  | Ast.Var x -> (
      match List.assoc_opt x env with
      | Some t -> instantiate t
      | None -> Loc.type_error e.loc "unbound variable %s" x)
  | Ast.Ann (body, ann) ->
      let t = read_ty st ann in
      let inferred = infer st env body in
      unify e.loc inferred t;
      t
  | Ast.Lam (bs, body) ->
      let env, doms =
        List.fold_left
          (fun (env, doms) (b : Ast.binder) ->
            let t =
              match b.bann with None -> fresh_var () | Some a -> read_ty st a
            in
            ((b.bname, t) :: env, t :: doms))
          (env, []) bs
      in
      let res = infer st env body in
      List.fold_left (fun acc d -> TArrow (d, acc)) res doms
  | Ast.App (f, a) ->
      let tf = infer st env f in
      let ta = infer st env a in
      let res = fresh_var () in
      unify e.loc tf (TArrow (ta, res));
      res
  | Ast.LetIn (d, body) ->
      let env = bind_decl st env d in
      infer st env body
  | Ast.If (c, t, f) ->
      unify c.loc (infer st env c) (TCon "bool");
      let tt = infer st env t in
      unify f.loc (infer st env f) tt;
      tt
  | Ast.Bin (";", a, b) ->
      ignore (infer st env a);
      infer st env b
  | Ast.Bin (op, a, b) when List.mem op arith ->
      unify a.loc (infer st env a) (TCon "int");
      unify b.loc (infer st env b) (TCon "int");
      TCon "int"
  | Ast.Bin (("&&" | "||" | "==>"), a, b) ->
      unify a.loc (infer st env a) (TCon "bool");
      unify b.loc (infer st env b) (TCon "bool");
      TCon "bool"
  | Ast.Bin (op, a, b) when List.mem op comparisons ->
      let ta = infer st env a in
      unify b.loc (infer st env b) ta;
      TCon "bool"
  | Ast.Uop ("-", a) ->
      unify a.loc (infer st env a) (TCon "int");
      TCon "int"
  | Ast.Uop ("not", a) ->
      unify a.loc (infer st env a) (TCon "bool");
      TCon "bool"
  | Ast.Pair (a, b) -> TPair (infer st env a, infer st env b)
  (* A record literal is an extension of the empty record; `{ l = e, ..r }` is
     an extension of whatever r is. *)
  | Ast.Rec (Ast.Eq, fields, tail) ->
      let base =
        match tail with
        | None -> REmpty
        | Some t ->
            let tt = infer st env t in
            let r = fresh_row () in
            unify t.loc tt (TRecord r);
            r
      in
      TRecord
        (List.fold_right
           (fun (f : Ast.field) rest -> RExtend (f.flabel, infer st env f.fbody, rest))
           fields base)
  | Ast.Proj (r, l) ->
      let field = fresh_var () and rest = fresh_row () in
      unify r.loc (infer st env r) (TRecord (RExtend (l, field, rest)));
      field
  | Ast.Restrict (r, l) ->
      let field = fresh_var () and rest = fresh_row () in
      unify r.loc (infer st env r) (TRecord (RExtend (l, field, rest)));
      TRecord rest
  | Ast.Inject (l, payload) ->
      let t =
        match payload with None -> TCon "unit" | Some p -> infer st env p
      in
      TVariant (RExtend (l, t, fresh_row ()))
  | Ast.Match (scrut, cases) -> infer_match st env e.loc scrut cases
  | Ast.Rec (Ast.Colon, _, _) | Ast.VariantTy _ | Ast.Arrow _ | Ast.Forall _
  | Ast.Refine _ | Ast.Prod _ | Ast.Choice _ ->
      Loc.type_error e.loc "a type cannot be used as a term"
  | Ast.Select _ | Ast.Branch _ ->
      Loc.type_error e.loc "channels belong to #system linear"
  | Ast.Uop (op, _) | Ast.Bin (op, _, _) ->
      Loc.type_error e.loc "no operator %s here" op

(* Matching a variant.  Every arm contributes one field to the scrutinee's
   row; a final catch-all arm gets a variant of whatever is left, which is
   what makes a match on an open variant possible at all. *)
and infer_match st env loc scrut cases =
  let result = fresh_var () in
  let variant_arms =
    List.filter_map
      (function Ast.PInject (l, p), body -> Some (l, p, body) | _ -> None)
      cases
  in
  let default =
    List.find_map
      (function
        | Ast.PVar x, body -> Some (Some x, body)
        | Ast.PWild, body -> Some (None, body)
        | _ -> None)
      cases
  in
  if variant_arms = [] then
    (* Not a variant match at all: one structural pattern. *)
    match cases with
    | [ (p, body) ] ->
        let t = infer st env scrut in
        let env = bind_pat st env loc p t in
        infer st env body
    | _ -> Loc.type_error loc "a match on something other than a variant takes one case"
  else begin
    let tail = match default with None -> REmpty | Some _ -> fresh_row () in
    let row =
      List.fold_right
        (fun (l, _, _) rest -> RExtend (l, fresh_var (), rest))
        variant_arms tail
    in
    let tscrut = infer st env scrut in
    unify scrut.Ast.loc tscrut (TVariant row);
    List.iter
      (fun (l, p, body) ->
        let payload, _ = rewrite loc row l in
        let env =
          match p with
          | None -> env
          | Some p -> bind_pat st env loc p payload
        in
        unify body.Ast.loc (infer st env body) result)
      variant_arms;
    (match default with
    | None -> ()
    | Some (x, body) ->
        let env =
          match x with None -> env | Some x -> (x, TVariant tail) :: env
        in
        unify body.Ast.loc (infer st env body) result);
    result
  end

and bind_pat st env loc p t =
  match p with
  | Ast.PWild -> env
  | Ast.PVar x -> (x, t) :: env
  | Ast.PUnit ->
      unify loc t (TCon "unit");
      env
  | Ast.PPair (a, b) ->
      let ta = fresh_var () and tb = fresh_var () in
      unify loc t (TPair (ta, tb));
      bind_pat st (bind_pat st env loc a ta) loc b tb
  | Ast.PInject _ ->
      Loc.type_error loc "a variant pattern may only appear at the top of a case"

(* `let`, in either position.  The level is raised while the right-hand side is
   inferred, so that variables created inside it -- and only those -- can be
   generalised afterwards. *)
and bind_decl st env (d : Ast.decl) : env =
  let body = Ast.decl_body d in
  st.rtys <- [];
  st.rrows <- [];
  incr level;
  let t =
    if d.Ast.drec then begin
      let name =
        match d.Ast.dpat with
        | Ast.DName x -> x
        | _ -> Loc.type_error d.Ast.dloc "`let rec` binds one name"
      in
      let self = fresh_var () in
      let t = infer st ((name, self) :: env) body in
      unify d.Ast.dloc t self;
      t
    end
    else infer st env body
  in
  decr level;
  let t = if st.rtys = [] && st.rrows = [] then t else quantify_rigids st t in
  generalize t;
  match d.Ast.dpat with
  | Ast.DName x -> (x, t) :: env
  | Ast.DUnit -> env
  | Ast.DPair (x, y) ->
      let a = fresh_var () and b = fresh_var () in
      unify d.Ast.dloc t (TPair (a, b));
      generalize a;
      generalize b;
      (x, a) :: (y, b) :: env

let check_program (items : Ast.toplevel list) =
  let st = { aliases = Hashtbl.create 8; rtys = []; rrows = [] } in
  let env = ref (initial_env ()) in
  level := 0;
  List.filter_map
    (function
      | Ast.TType { tname; tparams; tbody; _ } ->
          Hashtbl.replace st.aliases tname (tparams, tbody);
          None
      | Ast.TLet d ->
          env := bind_decl st !env d;
          let name =
            match d.Ast.dpat with
            | Ast.DName x -> x
            | Ast.DUnit -> "()"
            | Ast.DPair (x, y) -> Printf.sprintf "(%s, %s)" x y
          in
          let t =
            match d.Ast.dpat with
            | Ast.DName x -> List.assoc x !env
            | Ast.DUnit -> TCon "unit"
            | Ast.DPair (x, y) ->
                TPair (List.assoc x !env, List.assoc y !env)
          in
          Some { System.rname = name; rtype = show t; rvalue = None })
    items

let system : System.t =
  {
    name = "row";
    blurb = "row polymorphism: extensible records and variants with scoped labels";
    check = check_program;
    runs = true;
  }
