(* Elaboration: the surface tree to typed Core, in one pass.

   Inference and normalisation happen together because they want the same
   traversal.  A term is converted with respect to a *destination*, which is
   either "you are in tail position" or "here is what to do with your value";
   naming every intermediate result is what a destination does.  The type comes
   back out of the conversion, and the type of a compound form is a fresh
   variable allocated before the sub-terms are converted and unified inside the
   continuation -- which is why the code reads as one function and not as an
   inference pass followed by a normaliser.

   Two things worth pointing at:

     * The join point.  A `case` in a non-tail position cannot be written in
       plain A-normal form -- `let x = case ... in rest` is not a block -- and
       copying `rest` into every arm doubles the program at every nesting.  So
       the continuation becomes a *join point*: a label the arms jump to.  A
       compiler without them reifies the continuation as a closure instead,
       which allocates.
     * The value restriction.  `val` generalises only when its right-hand side
       is non-expansive, because this language has arrays.  Without it,
       `val cell = Array.array (1, [])` would be a polymorphic array. *)

open Types
module C = Core
module S = Sem

type dest = Tail | Cont of (C.atom -> ty -> C.block)

let ret d a t = match d with Tail -> C.Tail (C.Ret a) | Cont k -> k a t

let emit ?(base = "t") ty rhs d =
  let x = C.fresh_name base in
  C.Let (x, ty, rhs, ret d (C.AVar x) ty)

(* A `case` (or anything else that branches) whose value is wanted by a
   continuation.  In tail position there is nothing to do; otherwise the
   continuation is named once, as a join point, and every branch jumps to it. *)
let with_join ty d f =
  match d with
  | Tail -> f Tail
  | Cont k ->
      let j = C.fresh_name "k" and v = C.fresh_name "v" in
      C.Join (j, [ (v, ty) ], k (C.AVar v) ty, f (Cont (fun a _ -> C.Tail (C.Jump (j, [ a ])))))

let bool_con name = List.find (fun c -> c.cname = name) bool_tc.tcons
let nil_con = List.find (fun c -> c.cname = "nil") list_tc.tcons
let cons_con = List.find (fun c -> c.cname = "::") list_tc.tcons

(* Reaching a value that lives inside a structure: walk the record. *)
(* Reaching a value inside a structure: walk the record.  Each step needs the
   type of the record it is stepping through, which is why the access carries
   one per component. *)
let atom_of_access (acc : S.access) ty (k : C.atom -> C.block) =
  let rec go a = function
    | [] -> k a
    | [ (f, rty) ] ->
        let x = C.fresh_name f in
        C.Let (x, ty, C.Field (a, f, rty), k (C.AVar x))
    | (f, rty) :: rest ->
        let x = C.fresh_name f in
        C.Let (x, newvar (), C.Field (a, f, rty), go (C.AVar x) rest)
  in
  go (C.AVar acc.S.root) acc.S.path

(* The primitives that are spelled as operators.  Their types live here and
   their meaning lives in the machine. *)
let binop_type loc op =
  match op with
  (* `+` `-` `*` overload over int and real, so their type is one variable
     demanding arithmetic and used three times: both operands and the result
     are the same type, whichever of the two it turns out to be.  `div` and
     `mod` stay int-only and `/` is real-only, which is why those three are not
     overloaded at all -- SML spells the two divisions differently precisely so
     that neither has to be. *)
  | "+" | "-" | "*" ->
      let a = newvar_gen ~num:true () in
      (a, a, a)
  | "/" -> (treal, treal, treal)
  | "div" | "mod" -> (tint, tint, tint)
  | "^" -> (tstring, tstring, tstring)
  | "<" | "<=" | ">" | ">=" ->
      let a = newvar_gen ~ord:true () in
      (a, a, tbool)
  (* `=` demands a type that can be compared, `<` one that can be ordered.
     Both are recorded on a fresh variable and settled by unification -- or,
     for `<`, by defaulting to int when nothing settles it. *)
  | "=" | "<>" ->
      let a = newvar_gen ~eq:true () in
      (a, a, tbool)
  | "@" ->
      let a = tlist (newvar ()) in
      (a, a, a)
  | ":=" ->
      let a = newvar () in
      (tref a, a, tunit)
  | _ -> Loc.type_error loc "no operator %s" op

(* Non-expansive: safe to generalise.  Anything that can allocate -- which here
   means anything that can call a function -- is expansive. *)
let rec non_expansive (e : Ast.exp) =
  match e.Ast.e with
  | Ast.EVar _ | Ast.EInt _ | Ast.EReal _ | Ast.EStr _ | Ast.ESelect _ | Ast.EFn _ ->
      true
  | Ast.ETuple es | Ast.EList es -> List.for_all non_expansive es
  | Ast.ERecord fs -> List.for_all (fun (_, e) -> non_expansive e) fs
  | Ast.EAnn (e, _) -> non_expansive e
  | Ast.EBin ("::", a, b) -> non_expansive a && non_expansive b
  | _ -> false

(* What a declaration brought into scope.  A `struct` turns these into the
   fields of a record and the components of a signature; a `let` throws them
   away; the top level makes one reported binding out of each. *)
type bound =
  | BVal of string * scheme * string (* source name, its scheme, its Core name *)
  | BStr of string * S.sg * string
  | BFct of string * S.fct * string
  | BTy of string * S.tyfun
  | BCon of constr

(* Type variables written in an annotation.

   `fun id (x : 'a) : 'a = x + 1` has to be rejected, and it is only rejected
   if the written `'a` refuses to become `int`.  So a written type variable is
   read as a *rigid* type constructor, which unifies with nothing but itself,
   and when the declaration is finished the rigid constants are turned back
   into ordinary variables so that generalisation can quantify them.  The same
   name means the same thing for as long as its declaration lasts, and no
   longer -- which is roughly SML's implicit scoping. *)
let ann_table : (string * ty) list ref = ref []
let ann_rigids : (string * tycon) list ref = ref []

let read_ann env t =
  let mk name =
    let tc = newtycon name in
    tc.teq <- eq_tyvar name;
    ann_rigids := (name, tc) :: !ann_rigids;
    Tcon (tc, [])
  in
  S.read_ty ~mk env ann_table t

(* Everything [ann_rigids] gained since the mark, newest first. *)
let rigids_since mark =
  let rec go acc l =
    if l == mark then acc
    else match l with [] -> acc | x :: rest -> go (x :: acc) rest
  in
  go [] !ann_rigids

(* Open a declaration: remember where the annotation table was.  Closing it
   returns a rewrite that frees this declaration's rigid constants, and puts
   the table back the way it was.  The fresh variables are made *before* the
   level is left, so that generalisation still sees them as local. *)
let close_ann (mark, saved_table) =
  let mine = rigids_since mark in
  let rw =
    List.map (fun (n, tc) -> (tc.tid, ([], newvar_gen ~eq:(eq_tyvar n) ()))) mine
  in
  ann_rigids := mark;
  ann_table := saved_table;
  rw

let open_ann () = (!ann_rigids, !ann_table)

(* Once a structure is bound, the type constructors it made are renamed `X.t`.
   Two applications of one functor really do make two different types, and if
   both print as `set` the report is a riddle.  Only the ones this structure
   created are touched: a transparent ascription can leave `int` as a
   component, and `int` is not this structure's to rename. *)
let rec qualify prefix fresh (sg : S.sg) =
  List.iter
    (fun (n, tf) ->
      match tf with
      | S.TyName tc when List.memq tc fresh && tc.tname = n ->
          tc.tname <- prefix ^ "." ^ n
      | _ -> ())
    sg.S.sg_tys;
  List.iter (fun (n, inner) -> qualify (prefix ^ "." ^ n) fresh inner) sg.S.sg_strs

(* Patterns.  Checking one against a type produces the Core pattern and the
   variables it binds, each renamed to a Core name of its own. *)

type binding = { bsrc : string; bty : ty; bvar : string }

let rec check_pat env (p : Ast.pat) (ty : ty) : binding list * C.pat =
  let loc = p.Ast.ploc in
  match p.Ast.p with
  | Ast.PWild -> ([], C.PAny None)
  | Ast.PInt n ->
      unify loc ty tint;
      ([], C.PInt n)
  | Ast.PStr s ->
      unify loc ty tstring;
      ([], C.PStr s)
  | Ast.PVar x -> (
      (* A bare name is a constructor if the environment says so, and a
         variable otherwise.  `nil` and `true` are ordinary constructors. *)
      match S.lookup_con env loc (Ast.ident x) with
      | Some c -> check_con env loc c None ty
      | None ->
          let v = C.fresh_name x in
          ([ { bsrc = x; bty = ty; bvar = v } ], C.PAny (Some v)))
  | Ast.PCon (path, arg) -> (
      match S.lookup_con env loc path with
      | Some c -> check_con env loc c arg ty
      | None -> Loc.type_error loc "%s is not a constructor" (Ast.path_str path))
  | Ast.PTuple ps ->
      let ts = List.map (fun _ -> newvar ()) ps in
      unify loc ty (ttuple ts);
      let bs, cps = List.split (List.map2 (check_pat env) ps ts) in
      (List.concat bs, C.PRec (tuple_fields cps))
  | Ast.PList ps ->
      let elt = newvar () in
      unify loc ty (tlist elt);
      let rec go = function
        | [] -> ([], C.PCon (nil_con, None))
        | q :: rest ->
            let b1, c1 = check_pat env q elt in
            let b2, c2 = go rest in
            (b1 @ b2, C.PCon (cons_con, Some (C.PRec (tuple_fields [ c1; c2 ]))))
      in
      go ps
  | Ast.PRecord (fs, flex) ->
      (match dup_label fs with
      | Some l -> Loc.type_error loc "the field %s appears twice" l
      | None -> ());
      let typed = List.map (fun (l, q) -> (l, q, newvar ())) fs in
      if flex then
        unify loc ty (newvar_with (sort_fields (List.map (fun (l, _, t) -> (l, t)) typed)))
      else
        unify loc ty (Trecord (sort_fields (List.map (fun (l, _, t) -> (l, t)) typed)));
      let all =
        match repr ty with
        | Trecord fs -> fs
        | _ ->
            Loc.type_error loc
              "this pattern does not say which record type it is; drop the \
               `...` or write the type out"
      in
      (* Every field of the type appears in the Core pattern, in order, so a
         decision tree can treat a record like a tuple. *)
      let bs = ref [] in
      let cps =
        List.map
          (fun (l, fty) ->
            match List.find_opt (fun (l', _, _) -> l' = l) typed with
            | Some (_, q, t) ->
                unify loc t fty;
                let b, cp = check_pat env q fty in
                bs := !bs @ b;
                (l, cp)
            | None -> (l, C.PAny None))
          all
      in
      (!bs, C.PRec cps)
  | Ast.PAs (x, q) ->
      let b, cp = check_pat env q ty in
      let v = C.fresh_name x in
      ({ bsrc = x; bty = ty; bvar = v } :: b, C.PAs (v, cp))
  | Ast.PAnn (q, t) ->
      let want = read_ann env t in
      unify loc ty want;
      check_pat env q ty

and check_con env loc (c : constr) arg ty =
  let args = List.map (fun _ -> newvar ()) c.cres.tparams in
  unify loc ty (Tcon (c.cres, args));
  match (con_arg c args, arg) with
  | None, None -> ([], C.PCon (c, None))
  | Some _, None ->
      Loc.type_error loc "the constructor %s takes an argument" c.cname
  | None, Some _ ->
      Loc.type_error loc "the constructor %s takes no argument" c.cname
  | Some at, Some q ->
      let b, cp = check_pat env q at in
      (b, C.PCon (c, Some cp))

let no_duplicates loc (bs : binding list) =
  let rec go seen = function
    | [] -> ()
    | b :: rest ->
        if List.mem b.bsrc seen then
          Loc.type_error loc "%s is bound twice in this pattern" b.bsrc;
        go (b.bsrc :: seen) rest
  in
  go [] bs

let bind_all env (bs : binding list) =
  List.fold_left
    (fun env b -> S.add_val env b.bsrc (mono b.bty) { S.root = b.bvar; path = [] })
    env bs

(* Expressions. *)

let rec infer env (e : Ast.exp) (d : dest) : ty * C.block =
  let loc = e.Ast.eloc in
  match e.Ast.e with
  | Ast.EInt n -> (tint, ret d (C.AInt n) tint)
  | Ast.EReal r -> (treal, ret d (C.AReal r) treal)
  | Ast.EStr s -> (tstring, ret d (C.AStr s) tstring)
  | Ast.ETuple [] -> (tunit, ret d C.AUnit tunit)
  | Ast.EVar path -> infer_var env loc path d
  | Ast.ETuple es ->
      let ts = List.map (fun _ -> newvar ()) es in
      let ty = ttuple ts in
      ( ty,
        atoms env es ts (fun ats -> emit ty (C.Record (tuple_fields ats)) d) )
  | Ast.ERecord fs ->
      (match dup_label fs with
      | Some l -> Loc.type_error loc "the field %s appears twice" l
      | None -> ());
      (* The fields are evaluated in the order they were written and sorted
         afterwards, so that `{ b = f (), a = g () }` runs `f` first.  Sorting
         before converting would have run them in label order, which is a
         surprise the Definition permits and nobody wants. *)
      let ts = List.map (fun _ -> newvar ()) fs in
      let ty = Trecord (sort_fields (List.map2 (fun (l, _) t -> (l, t)) fs ts)) in
      ( ty,
        atoms env (List.map snd fs) ts (fun ats ->
            emit ty (C.Record (sort_fields (List.map2 (fun (l, _) a -> (l, a)) fs ats))) d) )
  | Ast.EList es ->
      (* `[a, b]` is `a :: b :: nil`, built from the tail forwards. *)
      let elt = newvar () in
      let ty = tlist elt in
      ( ty,
        atoms env es (List.map (fun _ -> elt) es) (fun ats ->
            let rec build ats k =
              match ats with
              | [] ->
                  let n = C.fresh_name "t" in
                  C.Let (n, ty, C.Con (nil_con, None), k (C.AVar n))
              | a :: rest ->
                  build rest (fun tail ->
                      let p = C.fresh_name "t" and c = C.fresh_name "t" in
                      C.Let
                        ( p,
                          ttuple [ elt; ty ],
                          C.Record (tuple_fields [ a; tail ]),
                          C.Let (c, ty, C.Con (cons_con, Some (C.AVar p)), k (C.AVar c)) ))
            in
            build ats (fun a -> ret d a ty)) )
  | Ast.ESelect l ->
      (* `#lab` on its own is a function, and its argument's type has to be
         determined by the time the enclosing declaration generalises. *)
      let fty = newvar () in
      let dom = newvar_with [ (l, fty) ] in
      let v = C.fresh_name "r" in
      let ty = Tarrow (dom, fty) in
      let x = C.fresh_name "t" in
      ( ty,
        emit ty
          (C.Lam
             (v, dom, C.Let (x, fty, C.Field (C.AVar v, l, dom), C.Tail (C.Ret (C.AVar x)))))
          d )
  | Ast.EApp ({ Ast.e = Ast.ESelect l; _ }, arg) ->
      let fty = newvar () in
      let _, blk =
        infer env arg
          (Cont
             (fun a at ->
               unify loc at (newvar_with [ (l, fty) ]);
               emit fty (C.Field (a, l, at)) d))
      in
      (fty, blk)
  | Ast.EApp (f, a) -> infer_app env loc f a d
  | Ast.EBin ("::", a, b) ->
      let elt = newvar () in
      let ty = tlist elt in
      ( ty,
        atoms env [ a; b ] [ elt; ty ] (fun ats ->
            let p = C.fresh_name "t" in
            C.Let
              ( p,
                ttuple [ elt; ty ],
                C.Record (tuple_fields ats),
                emit ty (C.Con (cons_con, Some (C.AVar p))) d )) )
  | Ast.EBin (op, a, b) ->
      let ta, tb, tr = binop_type loc op in
      (tr, atoms env [ a; b ] [ ta; tb ] (fun ats -> emit tr (C.Prim (op, ats)) d))
  (* `~` is overloaded like `+`, over the same two types. *)
  | Ast.ENeg a ->
      let t = newvar_gen ~num:true () in
      (t, atoms env [ a ] [ t ] (fun ats -> emit t (C.Prim ("~", ats)) d))
  | Ast.EAnn (e, t) ->
      let want = read_ann env t in
      let got, blk = infer env e d in
      unify loc got want;
      (want, blk)
  | Ast.ESeq (a, b) ->
      let res = newvar () in
      let _, blk =
        infer env a
          (Cont
             (fun _ _ ->
               let tb, blk = infer env b d in
               unify loc tb res;
               blk))
      in
      (res, blk)
  | Ast.EIf (c, thn, els) ->
      let res = newvar () in
      let _, blk =
        infer env c
          (Cont
             (fun a at ->
               unify c.Ast.eloc at tbool;
               with_join res d (fun d' ->
                   let t1, b1 = infer env thn d' in
                   let t2, b2 = infer env els d' in
                   unify loc t1 res;
                   unify loc t2 res;
                   C.Tail
                     (C.Case
                        ( a,
                          tbool,
                          [
                            { C.apat = C.PCon (bool_con "true", None); abody = b1 };
                            { C.apat = C.PCon (bool_con "false", None); abody = b2 };
                          ],
                          loc )))))
      in
      (res, blk)
  | Ast.EAndalso (a, b) ->
      infer env
        { e with Ast.e = Ast.EIf (a, b, { e with Ast.e = Ast.EVar (Ast.ident "false") }) }
        d
  | Ast.EOrelse (a, b) ->
      infer env
        { e with Ast.e = Ast.EIf (a, { e with Ast.e = Ast.EVar (Ast.ident "true") }, b) }
        d
  | Ast.EFn rules ->
      let dom = newvar () and cod = newvar () in
      let ty = Tarrow (dom, cod) in
      let v = C.fresh_name "x" in
      let arms = match_arms env loc rules dom cod in
      (ty, emit ty (C.Lam (v, dom, C.Tail (C.Case (C.AVar v, dom, arms, loc)))) d)
  | Ast.ECase (scrut, rules) ->
      let res = newvar () in
      let _, blk =
        infer env scrut
          (Cont
             (fun a at ->
               with_join res d (fun d' ->
                   let arms = match_arms_d env loc rules at res d' in
                   C.Tail (C.Case (a, at, arms, loc)))))
      in
      (res, blk)
  | Ast.ELet (decs, body) ->
      let res = newvar () in
      let blk =
        elab_decs env decs (fun env' _ ->
            let t, b = infer env' body d in
            unify loc t res;
            b)
      in
      (res, blk)

and infer_var env loc (path : Ast.path) d =
  match S.lookup_val env loc path with
  | Some (sch, acc) ->
      let ty = instantiate sch in
      (ty, atom_of_access acc ty (fun a -> ret d a ty))
  | None -> (
      match S.lookup_con env loc path with
      | None -> Loc.type_error loc "unbound variable %s" (Ast.path_str path)
      | Some c -> (
          let args = List.map (fun _ -> newvar ()) c.cres.tparams in
          let res = Tcon (c.cres, args) in
          match con_arg c args with
          | None -> (res, emit res (C.Con (c, None)) d)
          | Some at ->
              (* A constructor used as a value is a function. *)
              let v = C.fresh_name "x" in
              let r = C.fresh_name "t" in
              let ty = Tarrow (at, res) in
              ( ty,
                emit ty
                  (C.Lam (v, at, C.Let (r, res, C.Con (c, Some (C.AVar v)), C.Tail (C.Ret (C.AVar r)))))
                  d )))

and infer_app env loc f a d =
  (* A saturated constructor application builds the value directly instead of
     going through the function a bare constructor would become. *)
  let direct =
    match f.Ast.e with
    | Ast.EVar path -> (
        match S.lookup_val env loc path with
        | Some _ -> None
        | None -> S.lookup_con env loc path)
    | _ -> None
  in
  match direct with
  | Some c -> (
      let args = List.map (fun _ -> newvar ()) c.cres.tparams in
      let res = Tcon (c.cres, args) in
      match con_arg c args with
      | None -> Loc.type_error loc "the constructor %s takes no argument" c.cname
      | Some at ->
          let _, blk =
            infer env a
              (Cont
                 (fun x xt ->
                   unify a.Ast.eloc xt at;
                   emit res (C.Con (c, Some x)) d))
          in
          (res, blk))
  | None ->
      let res = newvar () in
      let _, blk =
        infer env f
          (Cont
             (fun fa ft ->
               let _, blk =
                 infer env a
                   (Cont
                      (fun aa at ->
                        unify loc ft (Tarrow (at, res));
                        match d with
                        | Tail -> C.Tail (C.TCall (fa, aa))
                        | Cont _ -> emit res (C.Call (fa, aa)) d))
               in
               blk))
      in
      (res, blk)

(* Convert a list of expressions to atoms, checking each against a type. *)
and atoms env es tys (k : C.atom list -> C.block) =
  let rec go acc es tys =
    match (es, tys) with
    | [], _ -> k (List.rev acc)
    | e :: erest, t :: trest ->
        let _, blk =
          infer env e
            (Cont
               (fun a at ->
                 unify e.Ast.eloc at t;
                 go (a :: acc) erest trest))
        in
        blk
    | _ -> assert false
  in
  go [] es tys

and match_arms env loc rules dom cod =
  match_arms_d env loc rules dom cod Tail

and match_arms_d env _loc rules scrut_ty res d =
  List.map
    (fun (p, body) ->
      let bs, cp = check_pat env p scrut_ty in
      no_duplicates p.Ast.ploc bs;
      let env' = bind_all env bs in
      let t, b = infer env' body d in
      unify body.Ast.eloc t res;
      { C.apat = cp; abody = b })
    rules

(* Declarations.  Each one is given the rest of the block as a continuation,
   which is also what gets put inside the arm of a pattern binding. *)

and elab_decs env decs (k : Sem.env -> bound list -> C.block) =
  let rec go env acc = function
    | [] -> k env (List.rev acc)
    | d :: rest ->
        elab_dec env d (fun env' bs -> go env' (List.rev_append bs acc) rest)
  in
  go env [] decs

and elab_dec env (dc : Ast.dec) (k : Sem.env -> bound list -> C.block) : C.block =
  let loc = dc.Ast.dloc in
  match dc.Ast.d with
  | Ast.DVal (p, e) ->
      let ann = open_ann () in
      enter_level ();
      let _, blk =
        infer env e
          (Cont
             (fun a te ->
               (* The pattern is checked before the annotation table is
                  closed: `val id : 'a -> 'a = ...` writes its `'a` on the
                  pattern, and that `'a` has to be one of this declaration's
                  rigid constants like any other. *)
               let checked =
                 match p.Ast.p with
                 (* The common case: one name, bound to one value. *)
                 | Ast.PVar x when S.lookup_con env loc (Ast.ident x) = None -> None
                 | _ ->
                     let bs, cp = check_pat env p te in
                     no_duplicates loc bs;
                     Some (bs, cp)
               in
               let rw = close_ann ann in
               leave_level ();
               let gen ty =
                 let ty = realise rw ty in
                 default_overload ty;
                 if non_expansive e then generalise loc ty else mono ty
               in
               match (p.Ast.p, checked) with
               | Ast.PVar x, None ->
                   let v = C.fresh_name x in
                   let sch = gen te in
                   C.Let
                     ( v,
                       te,
                       C.Atom a,
                       k (S.add_val env x sch { S.root = v; path = [] })
                         [ BVal (x, sch, v) ] )
               | _, None -> assert false
               | _, Some (bs, cp) ->
                   let env', bounds =
                     List.fold_left
                       (fun (env, acc) b ->
                         let sch = gen b.bty in
                         ( S.add_val env b.bsrc sch { S.root = b.bvar; path = [] },
                           acc @ [ BVal (b.bsrc, sch, b.bvar) ] ))
                       (env, []) bs
                   in
                   C.Tail
                     (C.Case (a, te, [ { C.apat = cp; abody = k env' bounds } ], loc))))
      in
      blk
  | Ast.DFun fs ->
      let ann = open_ann () in
      enter_level ();
      let entries =
        List.map (fun (f : Ast.fundec) -> (f, C.fresh_name f.Ast.fname, newvar ())) fs
      in
      let env_rec =
        List.fold_left
          (fun env ((f : Ast.fundec), v, ty) ->
            S.add_val env f.Ast.fname (mono ty) { S.root = v; path = [] })
          env entries
      in
      let defs =
        List.map
          (fun ((f : Ast.fundec), v, ty) ->
            let param, dom, body = elab_fun env_rec f ty in
            (v, ty, C.Lam (param, dom, body)))
          entries
      in
      let rw = close_ann ann in
      leave_level ();
      let env', bounds =
        List.fold_left
          (fun (env, acc) ((f : Ast.fundec), v, ty) ->
            let ty = realise rw ty in
            default_overload ty;
            let sch = generalise f.Ast.floc ty in
            ( S.add_val env f.Ast.fname sch { S.root = v; path = [] },
              acc @ [ BVal (f.Ast.fname, sch, v) ] ))
          (env, []) entries
      in
      (* Only a group that refers to itself is a [Fix]; the rest are ordinary
         bindings, and the dump says so. *)
      if C.recursive defs then C.Fix (defs, k env' bounds)
      else
        List.fold_right
          (fun (x, t, r) rest -> C.Let (x, t, r, rest))
          defs (k env' bounds)
  | Ast.DType binds ->
      let env', bounds =
        List.fold_left
          (fun (env, acc) (b : Ast.tybind) ->
            let ps =
              List.map (fun _ -> param_var ()) b.Ast.tbparams
            in
            let tvs = ref (List.map2 (fun n r -> (n, Tvar r)) b.Ast.tbparams ps) in
            let body = S.read_ty env tvs b.Ast.tbody in
            let tf = S.TyAlias (ps, body) in
            (S.add_ty env b.Ast.tbname tf, acc @ [ BTy (b.Ast.tbname, tf) ]))
          (env, []) binds
      in
      k env' bounds
  | Ast.DData binds ->
      let env', tcs, cons = S.declare_datatypes env binds in
      k env'
        (List.map (fun tc -> BTy (tc.tname, S.TyName tc)) tcs
        @ List.map (fun c -> BCon c) cons)
  | Ast.DOpen paths ->
      let env' =
        List.fold_left
          (fun env p ->
            let sg, acc = S.lookup_str env loc p in
            S.open_sg env sg acc)
          env paths
      in
      k env' []

(* `fun f p q = e | f r s = e2` becomes `fn a1 => fn a2 => case (a1, a2) of
   (p, q) => e | (r, s) => e2`.  Currying is done here so that the machine can
   have one-argument functions and no arity check. *)
and elab_fun env (f : Ast.fundec) (fty : ty) =
  let loc = f.Ast.floc in
  let arity = match f.Ast.fclauses with (ps, _, _) :: _ -> List.length ps | [] -> 0 in
  let params =
    List.init arity (fun i -> (C.fresh_name (Printf.sprintf "a%d" (i + 1)), newvar ()))
  in
  let res = newvar () in
  unify loc fty (List.fold_right (fun (_, t) acc -> Tarrow (t, acc)) params res);
  let scrut_ty =
    match params with [ (_, t) ] -> t | _ -> ttuple (List.map snd params)
  in
  let arms =
    List.map
      (fun (ps, retann, body) ->
        let bs, cp =
          match (ps, params) with
          | [ p ], [ (_, t) ] -> check_pat env p t
          | _ ->
              let bs, cps =
                List.split (List.map2 (fun p (_, t) -> check_pat env p t) ps params)
              in
              (List.concat bs, C.PRec (tuple_fields cps))
        in
        no_duplicates loc bs;
        let env' = bind_all env bs in
        (match retann with
        | None -> ()
        | Some t -> unify loc res (read_ann env' t));
        let t, b = infer env' body Tail in
        unify body.Ast.eloc t res;
        { C.apat = cp; abody = b })
      f.Ast.fclauses
  in
  let inner =
    match params with
    | [ (v, t) ] -> C.Tail (C.Case (C.AVar v, t, arms, loc))
    | _ ->
        let tup = C.fresh_name "args" in
        C.Let
          ( tup,
            scrut_ty,
            C.Record (tuple_fields (List.map (fun (v, _) -> C.AVar v) params)),
            C.Tail (C.Case (C.AVar tup, scrut_ty, arms, loc)) )
  in
  let rec wrap i =
    if i = arity - 1 then inner
    else
      let v, t = List.nth params (i + 1) in
      let rest = List.filteri (fun j _ -> j > i) params in
      let fty =
        List.fold_right (fun (_, t) acc -> Tarrow (t, acc)) rest res
      in
      let g = C.fresh_name "f" in
      C.Let (g, fty, C.Lam (v, t, wrap (i + 1)), C.Tail (C.Ret (C.AVar g)))
  in
  let name, dom = List.hd params in
  (name, dom, wrap 0)

(* Structures.

   A structure is a record and a functor is a function.  Everything above this
   line -- inference, normalisation, the machine -- is untouched by the module
   language; what modules add is a static discipline over records, and the
   discipline is entirely gone by the time Core is built. *)

and elab_str env (s : Ast.strexp) (k : S.sg -> C.atom -> C.block) : C.block =
  let loc = s.Ast.stloc in
  match s.Ast.st with
  | Ast.StrId p ->
      let sg, acc = S.lookup_str env loc p in
      atom_of_access acc (S.struct_ty sg) (fun a -> k sg a)
  | Ast.StrBody decs ->
      elab_topdecs env decs (fun _ bounds ->
          let sg = sg_of_bounds bounds in
          let fields =
            List.filter_map
              (function
                | BVal (n, _, v) -> Some (n, C.AVar v)
                | BStr (n, _, v) -> Some (n, C.AVar v)
                | _ -> None)
              bounds
          in
          let r = C.fresh_name "struct" in
          C.Let (r, S.struct_ty sg, C.Record (sort_fields fields), k sg (C.AVar r)))
  | Ast.StrApp (fname, arg) -> (
      match List.assoc_opt fname env.S.fcts with
      | None -> Loc.module_error loc "unbound functor %s" fname
      | Some f ->
          elab_str env arg (fun asg aa ->
              let result = S.instantiate_functor loc f asg in
              let r = C.fresh_name "app" in
              atom_of_access f.S.f_access (newvar ()) (fun fa ->
                  C.Let (r, S.struct_ty result, C.Call (fa, aa), k result (C.AVar r)))))
  | Ast.StrAsc (inner, se, opaque) ->
      elab_str env inner (fun asg aa ->
          let target, holes = S.elab_sig env se in
          let rw = S.match_sig loc ~what:"this structure" asg target holes in
          (* Transparent ascription pushes the realisation through, so the
             types stay visible; opaque ascription drops it on the floor, and
             the holes are what is left. *)
          let sg = if opaque then target else S.map_sg (realise rw) target in
          k sg aa)

and sg_of_bounds bounds =
  List.fold_left
    (fun sg b ->
      match b with
      | BVal (n, sch, _) -> { sg with S.sg_vals = sg.S.sg_vals @ [ (n, sch) ] }
      | BStr (n, s, _) -> { sg with S.sg_strs = sg.S.sg_strs @ [ (n, s) ] }
      | BTy (n, tf) -> { sg with S.sg_tys = sg.S.sg_tys @ [ (n, tf) ] }
      | BCon c -> { sg with S.sg_cons = sg.S.sg_cons @ [ (c.cname, c) ] }
      (* A functor inside a structure is bound and usable there, but a
         signature has no way to describe it, so it is not exported. *)
      | BFct _ -> sg)
    S.empty_sg bounds

and elab_topdecs env decs (k : S.env -> bound list -> C.block) : C.block =
  let rec go env acc = function
    | [] -> k env (List.rev acc)
    | d :: rest -> elab_topdec env d (fun env' bs -> go env' (List.rev_append bs acc) rest)
  in
  go env [] decs

and elab_topdec env (td : Ast.topdec) (k : S.env -> bound list -> C.block) : C.block =
  let loc = td.Ast.tloc in
  match td.Ast.t with
  | Ast.TDec d -> elab_dec env d k
  | Ast.TSig (name, se) ->
      (* A signature is kept as syntax and elaborated again at every use, so
         that each use gets holes of its own. *)
      k { env with S.sigs = (name, (se, env)) :: env.S.sigs } []
  | Ast.TStr (name, se) ->
      let before = mark () in
      elab_str env se (fun sg a ->
          qualify name (since before) sg;
          let v = C.fresh_name name in
          C.Let
            ( v,
              S.struct_ty sg,
              C.Atom a,
              k (S.add_str env name sg { S.root = v; path = [] }) [ BStr (name, sg, v) ] ))
  | Ast.TFun (fname, aname, psig, rsig, body) ->
      let param_sg, holes = S.elab_sig env psig in
      let pv = C.fresh_name aname in
      let env_body = S.add_str env aname param_sg { S.root = pv; path = [] } in
      (* Everything the body invents belongs to the body, and every
         application gets its own copy: that is generativity. *)
      let before = mark () in
      let body_sg = ref S.empty_sg in
      let block =
        elab_str env_body body (fun sg a ->
            let sg =
              match rsig with
              | None -> sg
              | Some (rse, opaque) ->
                  let target, rholes = S.elab_sig env_body rse in
                  let rw = S.match_sig loc ~what:"the functor body" sg target rholes in
                  if opaque then target else S.map_sg (realise rw) target
            in
            body_sg := sg;
            C.Tail (C.Ret a))
      in
      let generated =
        List.filter
          (fun tc -> not (List.exists (fun h -> h.tid = tc.tid) holes))
          (since before)
      in
      let v = C.fresh_name fname in
      let f =
        {
          S.f_holes = holes;
          f_param = param_sg;
          f_gen = generated;
          f_body = !body_sg;
          f_access = { S.root = v; path = [] };
        }
      in
      C.Let
        ( v,
          Tarrow (S.struct_ty param_sg, S.struct_ty !body_sg),
          C.Lam (pv, S.struct_ty param_sg, block),
          k { env with S.fcts = (fname, f) :: env.S.fcts } [ BFct (fname, f, v) ] )

(* Printing a datatype back the way it was written, for the report line.  The
   parameters are replaced by nullary constructors called `'a`, `'b`, ... so
   that the ordinary type printer names them consistently across all the
   constructors of the datatype. *)
let datatype_label name (tc : tycon) =
  let names =
    List.mapi (fun i _ -> Printf.sprintf "'%c" (Char.chr (Char.code 'a' + i))) tc.tparams
  in
  let rw =
    { no_rewrite with
      rvars = List.map2 (fun p n -> (p, Tcon (newtycon n, []))) tc.tparams names }
  in
  let head =
    match names with
    | [] -> name
    | [ a ] -> a ^ " " ^ name
    | _ -> Printf.sprintf "(%s) %s" (String.concat ", " names) name
  in
  let con (c : constr) =
    match c.carg with
    | None -> c.cname
    | Some t -> Printf.sprintf "%s of %s" c.cname (show (copy rw t))
  in
  Printf.sprintf "datatype %s = %s" head
    (String.concat " | " (List.map con tc.tcons))

(* The top level.

   Every declaration becomes its own block, so that the driver can run it,
   report what it bound and go on to the next one.  A declaration that binds
   several names returns them in a tuple and each is projected out afterwards,
   which is also how a `fun ... and ...` group survives being split up: the
   closures were made together, inside one block, and only the results are
   handed out. *)

let program (env : S.env) (decs : Ast.topdec list) : S.env * C.item list =
  let env = ref env in
  let items = ref [] in
  let emit_item i = items := i :: !items in
  List.iter
    (fun (td : Ast.topdec) ->
      let out = ref None in
      let block =
        elab_topdec !env td (fun env' bounds ->
            out := Some (env', bounds);
            let runtime =
              List.filter_map
                (function
                  | BVal (_, sch, v) -> Some (sch.sbody, v)
                  | BStr (_, sg, v) -> Some (S.struct_ty sg, v)
                  | BFct (_, _, v) -> Some (newvar (), v)
                  | _ -> None)
                bounds
            in
            match runtime with
            | [] -> C.Tail (C.Ret C.AUnit)
            | [ (_, v) ] -> C.Tail (C.Ret (C.AVar v))
            | many ->
                let t = C.fresh_name "group" in
                C.Let
                  ( t,
                    ttuple (List.map fst many),
                    C.Record (tuple_fields (List.map (fun (_, v) -> C.AVar v) many)),
                    C.Tail (C.Ret (C.AVar t)) ))
      in
      let env', bounds = Option.get !out in
      env := env';
      let label b =
        match b with
        | BVal (n, sch, _) -> Some (lazy (Printf.sprintf "val %s : %s" n (show_scheme sch)))
        | BStr (n, _, _) -> Some (lazy (Printf.sprintf "structure %s" n))
        | BFct (n, _, _) -> Some (lazy (Printf.sprintf "functor %s" n))
        | BTy (n, S.TyName tc) when tc.tcons <> [] -> Some (lazy (datatype_label n tc))
        | BTy (n, _) -> Some (lazy (Printf.sprintf "type %s" n))
        | BCon _ -> None
      in
      let runtime =
        List.filter (function BVal _ | BStr _ | BFct _ -> true | _ -> false) bounds
      in
      match runtime with
      | [] ->
          (match td.Ast.t with
          | Ast.TSig (n, _) ->
              emit_item
                { C.iname = ""; ibody = None; ilabel = Some (lazy (Printf.sprintf "signature %s" n)); ishow = false }
          | _ ->
              (* Nothing is bound, but `val () = print "hi"` still has to run:
                 a declaration is evaluated for its effect even when it keeps
                 nothing. *)
              emit_item { C.iname = ""; ibody = Some block; ilabel = None; ishow = false };
              List.iter
                (fun l ->
                  emit_item { C.iname = ""; ibody = None; ilabel = Some l; ishow = false })
                (List.filter_map label bounds))
      | [ b ] ->
          let name =
            match b with
            | BVal (_, _, v) | BStr (_, _, v) | BFct (_, _, v) -> v
            | _ -> ""
          in
          emit_item
            {
              C.iname = name;
              ibody = Some block;
              ilabel = label b;
              ishow = (match b with BVal _ -> true | _ -> false);
            }
      | many ->
          let g = C.fresh_name "group" in
          emit_item { C.iname = g; ibody = Some block; ilabel = None; ishow = false };
          let slot b =
            match b with
            | BVal (_, sch, v) -> (v, sch.sbody)
            | BStr (_, sg, v) -> (v, S.struct_ty sg)
            | BFct (_, _, v) -> (v, newvar ())
            | _ -> ("", tunit)
          in
          (* The group is one tuple, so the projections need its type. *)
          let group_ty = ttuple (List.map (fun b -> snd (slot b)) many) in
          List.iteri
            (fun i b ->
              let name, ty = slot b in
              let x = C.fresh_name "t" in
              emit_item
                {
                  C.iname = name;
                  ibody =
                    Some
                      (C.Let
                         ( x,
                           ty,
                           C.Field (C.AVar g, string_of_int (i + 1), group_ty),
                           C.Tail (C.Ret (C.AVar x)) ));
                  ilabel = label b;
                  ishow = (match b with BVal _ -> true | _ -> false);
                })
            many;
          (* Types and constructors declared alongside still deserve a line. *)
          List.iter
            (fun b ->
              match b with
              | BTy _ -> (
                  match label b with
                  | Some l ->
                      emit_item { C.iname = ""; ibody = None; ilabel = Some l; ishow = false }
                  | None -> ())
              | _ -> ())
            bounds)
    decs;
  (!env, List.rev !items)
