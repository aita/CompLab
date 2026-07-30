(* Environments, semantic signatures, and what it takes to match one against
   the other.

   A `signature` in the source is a piece of syntax; a signature *here* is a
   semantic object -- lists of type components, constructors, value schemes and
   sub-structures.  The distance between the two is the whole module system,
   and it comes down to one question: when a signature says `type t`, what is
   `t`?

   The answer is: a fresh type constructor with an identity of its own, a
   *hole*.  Matching a structure against the signature fills the holes in --
   that map from identity to type is a **realisation** -- and what happens to
   the realisation afterwards is the difference between the two ascriptions:

     str :  S   keeps it, so `X.t` is the type the structure really used
     str :> S   throws it away, so `X.t` is the hole and nothing outside can
                see through it

   A functor is the same idea one level up.  Its parameter signature's holes
   are its type parameters; the body is elaborated *once*, against those holes;
   and an application matches the argument, gets a realisation, and pushes it
   through the body's signature.  Types the body itself created are given fresh
   identities at every application, which is what "generative" means: two
   applications of the same functor make two different types.

   A named signature is stored as syntax and elaborated again at every use, so
   that its holes are fresh each time without any refreshing machinery.  The
   one place that machinery is unavoidable is functor application, and it is at
   the bottom of this file. *)

open Types

(* Where a value lives at run time.  A structure is a record, so a component of
   a structure is a field of a record -- possibly of a record inside a record.
   [root] is a Core variable and [path] is the fields to walk. *)
type access = { root : string; path : string list }

let sub_access a f = { a with path = a.path @ [ f ] }

(* A type component: either a type constructor with an identity, or an
   abbreviation, which has none. *)
type tyfun = TyName of tycon | TyAlias of tv ref list * ty

let tyfun_arity = function
  | TyName tc -> List.length tc.tparams
  | TyAlias (ps, _) -> List.length ps

let apply_tyfun tf args =
  match tf with
  | TyName tc -> Tcon (tc, args)
  | TyAlias (ps, body) ->
      copy { no_rewrite with rvars = List.combine ps args } body

type sg = {
  sg_tys : (string * tyfun) list;
  sg_cons : (string * constr) list;
  sg_vals : (string * scheme) list;
  sg_strs : (string * sg) list;
}

let empty_sg = { sg_tys = []; sg_cons = []; sg_vals = []; sg_strs = [] }

type fct = {
  f_holes : tycon list; (* the parameter signature's type components *)
  f_param : sg;
  f_gen : tycon list; (* what the body created: fresh at every application *)
  f_body : sg;
  f_access : access;
}

type env = {
  vals : (string * (scheme * access)) list;
  tys : (string * tyfun) list;
  cons : (string * constr) list;
  strs : (string * (sg * access)) list;
  (* A signature keeps its syntax and the environment it was written in, and
     is elaborated again at every use.  Fresh holes come for free. *)
  sigs : (string * (Ast.sigexp * env)) list;
  fcts : (string * fct) list;
}

let empty_env =
  { vals = []; tys = []; cons = []; strs = []; sigs = []; fcts = [] }

let add_val env x sch acc = { env with vals = (x, (sch, acc)) :: env.vals }
let add_ty env x tf = { env with tys = (x, tf) :: env.tys }
let add_con env c = { env with cons = (c.cname, c) :: env.cons }
let add_str env x sg acc = { env with strs = (x, (sg, acc)) :: env.strs }

(* Lookup, along a path.  `A.B.x` walks two structures and then asks for a
   value; every step can fail, and each failure says which step it was. *)

let find_str env loc quals =
  let rec go sg acc = function
    | [] -> (sg, acc)
    | q :: rest -> (
        match List.assoc_opt q sg.sg_strs with
        | Some sg' -> go sg' (sub_access acc q) rest
        | None -> Loc.type_error loc "structure %s has no substructure %s" acc.root q)
  in
  match quals with
  | [] -> None
  | q :: rest -> (
      match List.assoc_opt q env.strs with
      | Some (sg, acc) -> Some (go sg acc rest)
      | None -> Loc.type_error loc "unbound structure %s" q)

let lookup_val env loc (p : Ast.path) =
  match find_str env loc p.quals with
  | None -> (
      match List.assoc_opt p.base env.vals with
      | Some v -> Some v
      | None -> None)
  | Some (sg, acc) -> (
      match List.assoc_opt p.base sg.sg_vals with
      | Some sch -> Some (sch, sub_access acc p.base)
      | None -> None)

let lookup_con env loc (p : Ast.path) =
  match find_str env loc p.quals with
  | None -> List.assoc_opt p.base env.cons
  | Some (sg, _) -> List.assoc_opt p.base sg.sg_cons

let lookup_ty env loc (p : Ast.path) =
  match find_str env loc p.quals with
  | None -> List.assoc_opt p.base env.tys
  | Some (sg, _) -> List.assoc_opt p.base sg.sg_tys

let lookup_str env loc (p : Ast.path) =
  match find_str env loc (p.quals @ [ p.base ]) with
  | Some r -> r
  | None -> assert false

(* Reading a written type.  [tvs] is the table of type variables in scope; a
   name not in it is made by [mk] and added, so `'a -> 'a` means the same `'a`
   twice.  [mk] is what decides whether a written `'a` is a promise or a wish:
   an ordinary variable can be unified with `int`, and a rigid constant
   cannot. *)
let rec read_ty ?(mk = fun (_ : string) -> newvar ()) env
    (tvs : (string * ty) list ref) (t : Ast.ty) : ty =
  let read_ty env tvs t = read_ty ~mk env tvs t in
  match t with
  | Ast.TyVar v -> (
      match List.assoc_opt v !tvs with
      | Some t -> t
      | None ->
          let fresh = mk v in
          tvs := (v, fresh) :: !tvs;
          fresh)
  | Ast.TyArrow (a, b) -> Tarrow (read_ty env tvs a, read_ty env tvs b)
  | Ast.TyTuple ts -> Ttuple (List.map (read_ty env tvs) ts)
  | Ast.TyRecord fs ->
      let fs = List.map (fun (l, t) -> (l, read_ty env tvs t)) fs in
      (match dup_label fs with
      | Some l -> Loc.type_error Loc.unknown "the field %s is written twice" l
      | None -> ());
      Trecord (sort_fields fs)
  | Ast.TyCon (p, args) -> (
      let args = List.map (read_ty env tvs) args in
      match lookup_ty env Loc.unknown p with
      | None -> Loc.type_error Loc.unknown "unbound type %s" (Ast.path_str p)
      | Some tf ->
          let want = tyfun_arity tf in
          if List.length args <> want then
            Loc.type_error Loc.unknown
              "the type %s takes %d argument%s, not %d" (Ast.path_str p) want
              (if want = 1 then "" else "s")
              (List.length args);
          apply_tyfun tf args)

(* A written type, closed over the variables it mentions.  This is how a `val`
   specification in a signature becomes a scheme: `val id : 'a -> 'a` promises
   something about every `'a`, which is what quantifying them says. *)
let read_scheme env (t : Ast.ty) : scheme =
  let tvs = ref [] in
  enter_level ();
  let ty = read_ty env tvs t in
  leave_level ();
  let qvars =
    List.filter_map
      (fun (_, t) -> match repr t with Tvar r -> Some r | _ -> None)
      (List.rev !tvs)
  in
  { qvars; sbody = ty }

(* Declaring datatypes.  The type constructors go into the environment before
   the constructor arguments are read, so a datatype can mention itself and its
   siblings in the same `and` group. *)
let declare_datatypes env (binds : Ast.databind list) =
  let made =
    List.map
      (fun (b : Ast.databind) ->
        let params = List.map (fun _ -> ref (Unbound { id = 0; level = 0; must = [] })) b.dbparams in
        let tc = newtycon ~params b.dbname in
        (b, tc))
      binds
  in
  let env' =
    List.fold_left (fun env (_, tc) -> add_ty env tc.tname (TyName tc)) env made
  in
  let cons = ref [] in
  List.iter
    (fun ((b : Ast.databind), tc) ->
      let tvs =
        ref (List.map2 (fun n r -> (n, Tvar r)) b.dbparams tc.tparams)
      in
      let cs =
        List.mapi
          (fun i (name, arg) ->
            {
              cname = name;
              cidx = i;
              carg = Option.map (read_ty env' tvs) arg;
              cres = tc;
            })
          b.dbcons
      in
      (* Reading the arguments must not have invented type variables: every
         `'a` in a constructor has to be one of the datatype's parameters. *)
      List.iter
        (fun (v, _) ->
          if not (List.mem v b.dbparams) then
            Loc.type_error b.dbloc
              "the type variable %s is not a parameter of %s" v b.dbname)
        !tvs;
      tc.tcons <- cs;
      cons := !cons @ cs)
    made;
  let env'' = List.fold_left add_con env' !cons in
  (env'', List.map snd made, !cons)

(* Elaborating a signature.  The holes it returns are the type components it
   declared -- the things a structure will have to supply. *)
let rec elab_sig env (s : Ast.sigexp) : sg * tycon list =
  match s.s with
  | Ast.SigId name -> (
      match List.assoc_opt name env.sigs with
      | Some (syntax, defenv) -> elab_sig defenv syntax
      | None -> Loc.module_error s.sloc "unbound signature %s" name)
  | Ast.SigBody specs ->
      let sg, holes, _ =
        List.fold_left
          (fun (sg, holes, env) sp -> elab_spec env sg holes sp)
          (empty_sg, [], env) specs
      in
      (sg, holes)
  | Ast.SigWhere (inner, b) ->
      let sg, holes = elab_sig env inner in
      let tc =
        match List.assoc_opt b.Ast.tbname sg.sg_tys with
        | Some (TyName tc) when List.exists (fun h -> h.tid = tc.tid) holes -> tc
        | Some _ ->
            Loc.module_error s.sloc
              "`where type %s` needs %s to be an abstract type of the \
               signature, and it already has a definition"
              b.Ast.tbname b.Ast.tbname
        | None ->
            Loc.module_error s.sloc "this signature has no type %s" b.Ast.tbname
      in
      if List.length b.Ast.tbparams <> List.length tc.tparams then
        Loc.module_error s.sloc "%s takes %d parameter%s here" b.Ast.tbname
          (List.length tc.tparams)
          (if List.length tc.tparams = 1 then "" else "s");
      let tvs =
        ref (List.map2 (fun n r -> (n, Tvar r)) b.Ast.tbparams tc.tparams)
      in
      let body = read_ty env tvs b.Ast.tbody in
      let rw = [ (tc.tid, (tc.tparams, body)) ] in
      ( map_sg (realise rw) { sg with sg_tys = replace_ty sg.sg_tys b.Ast.tbname (TyAlias (tc.tparams, body)) },
        List.filter (fun h -> h.tid <> tc.tid) holes )

and replace_ty tys name tf =
  List.map (fun (n, old) -> if n = name then (n, tf) else (n, old)) tys

and elab_spec env sg holes (sp : Ast.spec) =
  match sp.sp with
  | Ast.SpVal (x, t) ->
      let sch = read_scheme env t in
      ({ sg with sg_vals = sg.sg_vals @ [ (x, sch) ] }, holes, env)
  | Ast.SpType (params, name, None) ->
      let ps = List.map (fun _ -> ref (Unbound { id = 0; level = 0; must = [] })) params in
      let tc = newtycon ~params:ps name in
      ( { sg with sg_tys = sg.sg_tys @ [ (name, TyName tc) ] },
        holes @ [ tc ],
        add_ty env name (TyName tc) )
  | Ast.SpType (params, name, Some body) ->
      let ps = List.map (fun _ -> ref (Unbound { id = 0; level = 0; must = [] })) params in
      let tvs = ref (List.map2 (fun n r -> (n, Tvar r)) params ps) in
      let body = read_ty env tvs body in
      let tf = TyAlias (ps, body) in
      ({ sg with sg_tys = sg.sg_tys @ [ (name, tf) ] }, holes, add_ty env name tf)
  | Ast.SpData binds ->
      let env', tcs, cons = declare_datatypes env binds in
      ( {
          sg with
          sg_tys = sg.sg_tys @ List.map (fun tc -> (tc.tname, TyName tc)) tcs;
          sg_cons = sg.sg_cons @ List.map (fun c -> (c.cname, c)) cons;
        },
        holes @ tcs,
        env' )
  | Ast.SpStruct (name, inner) ->
      let isg, iholes = elab_sig env inner in
      ( { sg with sg_strs = sg.sg_strs @ [ (name, isg) ] },
        holes @ iholes,
        add_str env name isg { root = name; path = [] } )
  | Ast.SpInclude inner ->
      let isg, iholes = elab_sig env inner in
      ( {
          sg_tys = sg.sg_tys @ isg.sg_tys;
          sg_cons = sg.sg_cons @ isg.sg_cons;
          sg_vals = sg.sg_vals @ isg.sg_vals;
          sg_strs = sg.sg_strs @ isg.sg_strs;
        },
        holes @ iholes,
        open_sg env isg { root = "?"; path = [] } )

(* Everything a structure exports, brought into scope unqualified. *)
and open_sg env sg acc =
  let env = List.fold_left (fun e (n, tf) -> add_ty e n tf) env sg.sg_tys in
  let env = List.fold_left (fun e (_, c) -> add_con e c) env sg.sg_cons in
  let env =
    List.fold_left (fun e (n, sch) -> add_val e n sch (sub_access acc n)) env sg.sg_vals
  in
  List.fold_left (fun e (n, s) -> add_str e n s (sub_access acc n)) env sg.sg_strs

(* Rewriting every type in a signature. *)
and map_sg f sg =
  {
    sg_tys =
      List.map
        (fun (n, tf) ->
          ( n,
            match tf with
            | TyName tc -> (
                (* A name may be rewritten into another name, or into a type
                   that is no longer a name at all. *)
                match f (Tcon (tc, List.map (fun r -> Tvar r) tc.tparams)) with
                | Tcon (tc', args)
                  when List.for_all2
                         (fun a r -> match repr a with Tvar r' -> r' == r | _ -> false)
                         args tc.tparams ->
                    TyName tc'
                | other -> TyAlias (tc.tparams, other))
            | TyAlias (ps, body) -> TyAlias (ps, f body) ))
        sg.sg_tys;
    sg_cons =
      List.map
        (fun (n, c) -> (n, { c with carg = Option.map f c.carg }))
        sg.sg_cons;
    sg_vals = List.map (fun (n, s) -> (n, { s with sbody = f s.sbody })) sg.sg_vals;
    sg_strs = List.map (fun (n, s) -> (n, map_sg f s)) sg.sg_strs;
  }

(* Matching.  [target] is what was asked for and [actual] is what there is;
   the result fills in the target's holes. *)
let rec match_sig loc ~what (actual : sg) (target : sg) (holes : tycon list) =
  let rw = ref [] in
  let hole tc = List.exists (fun h -> h.tid = tc.tid) holes in
  (* Types first: a value's type cannot be compared before the types it
     mentions are known. *)
  List.iter
    (fun (name, tf) ->
      let got =
        match List.assoc_opt name actual.sg_tys with
        | Some tf -> tf
        | None -> Loc.module_error loc "%s does not define the type %s" what name
      in
      if tyfun_arity got <> tyfun_arity tf then
        Loc.module_error loc "%s gives %s %d parameter%s, the signature wants %d"
          what name (tyfun_arity got)
          (if tyfun_arity got = 1 then "" else "s")
          (tyfun_arity tf);
      match tf with
      | TyName tc when hole tc ->
          let args = List.map (fun r -> Tvar r) tc.tparams in
          rw := (tc.tid, (tc.tparams, apply_tyfun got args)) :: !rw;
          (* A datatype specification also fixes the constructors. *)
          if tc.tcons <> [] then match_datatype loc ~what name tc got
      | _ ->
          let args = List.map (fun _ -> newvar ()) (List.init (tyfun_arity tf) (fun _ -> ()))in
          let want = realise !rw (apply_tyfun tf args) in
          let have = apply_tyfun got args in
          (try unify loc want have
           with Loc.Error _ ->
             Loc.module_error loc
               "the type %s is %s here, but the signature says %s" name
               (show have) (show want)))
    target.sg_tys;
  (* Then values. *)
  List.iter
    (fun (name, want) ->
      match List.assoc_opt name actual.sg_vals with
      | None -> Loc.module_error loc "%s does not define %s" what name
      | Some have ->
          let want = { want with sbody = realise !rw want.sbody } in
          if not (more_general have want) then
            Loc.module_error loc
              "%s is %s here, but the signature asks for %s" name
              (show_scheme have) (show_scheme want))
    target.sg_vals;
  (* Then substructures, whose holes were collected into the same list. *)
  List.iter
    (fun (name, want) ->
      match List.assoc_opt name actual.sg_strs with
      | None -> Loc.module_error loc "%s does not define the structure %s" what name
      | Some have ->
          let inner = match_sig loc ~what:(what ^ "." ^ name) have want holes in
          rw := inner @ !rw)
    target.sg_strs;
  !rw

and match_datatype loc ~what name (spec : tycon) (got : tyfun) =
  let actual =
    match got with
    | TyName tc when tc.tcons <> [] -> tc.tcons
    | _ ->
        Loc.module_error loc
          "the signature declares %s as a datatype, but %s does not define it \
           as one"
          name what
  in
  let names cs = List.map (fun c -> c.cname) cs in
  if names actual <> names spec.tcons then
    Loc.module_error loc
      "the constructors of %s are %s here, and the signature lists %s -- they \
       have to be the same, in the same order"
      name
      (String.concat " | " (names actual))
      (String.concat " | " (names spec.tcons))

(* Is [have] at least as general as [want]?  Make the wanted scheme's variables
   rigid -- they are what the signature promised for *every* type -- instantiate
   the one we have with unknowns, and see whether they can be made equal. *)
and more_general (have : scheme) (want : scheme) =
  let skolems =
    List.map (fun _ -> Tcon (newtycon "?rigid", [])) want.qvars
  in
  let target =
    copy { no_rewrite with rvars = List.combine want.qvars skolems } want.sbody
  in
  let source = instantiate have in
  try
    unify Loc.unknown source target;
    true
  with Loc.Error _ -> false

(* Generativity.  Give each of [tcs] a new identity, and rewrite a signature so
   that it talks about the new ones.  The parameters are shared rather than
   copied: they are placeholders that are never unified, only substituted for. *)
let refresh (tcs : tycon list) =
  let pairs =
    List.map
      (fun tc ->
        let tc' = newtycon ~params:tc.tparams tc.tname in
        (tc, tc'))
      tcs
  in
  let rw =
    List.map
      (fun (tc, tc') ->
        (tc.tid, (tc.tparams, Tcon (tc', List.map (fun r -> Tvar r) tc.tparams))))
      pairs
  in
  (pairs, rw)

let instantiate_functor loc (f : fct) (arg : sg) =
  let rw = match_sig loc ~what:"the argument" arg f.f_param f.f_holes in
  let pairs, gen_rw = refresh f.f_gen in
  let all = gen_rw @ rw in
  (* The refreshed datatypes need their constructors rebuilt, since a
     constructor names the type it belongs to. *)
  List.iter
    (fun (tc, tc') ->
      tc'.tcons <-
        List.map
          (fun c -> { c with carg = Option.map (realise all) c.carg; cres = tc' })
          tc.tcons)
    pairs;
  let body = map_sg (realise all) f.f_body in
  (* [map_sg] rewrote the constructor argument types, but the constructors a
     signature exports must be the rebuilt ones, so that a `case` on a value of
     the refreshed datatype finds them. *)
  let rec fix sg =
    {
      sg with
      sg_cons =
        List.map
          (fun (n, c) ->
            match List.find_opt (fun (tc, _) -> tc.tid = c.cres.tid) pairs with
            | Some (_, tc') -> (n, List.nth tc'.tcons c.cidx)
            | None -> (n, c))
          sg.sg_cons;
      sg_strs = List.map (fun (n, s) -> (n, fix s)) sg.sg_strs;
    }
  in
  fix body
