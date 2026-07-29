(* The `linear` system: substructural types, and session types on top of them.

   Every type carries a qualifier.  An `un` value may be used any number of
   times, including none; a `lin` value must be used exactly once.  That is
   Walker's presentation in Advanced Topics in Types and Programming Languages,
   chapter 1, and the two rules that follow from it are the whole system:

     * The context is *split*, not shared.  Checking a subterm returns what is
       left of the context, and the next subterm starts from that, so a linear
       binding cannot be used twice because the second use cannot find it.
     * An `un` value may not contain a `lin` one.  A closure that captures a
       linear variable is therefore itself linear, which is why the qualifier of
       a lambda is not written but discovered: it is `lin` exactly when the body
       consumed something linear from outside.

   Session types are then almost free.  A channel endpoint is linear -- there is
   no other way to keep two peers in step -- and its type is the protocol that
   remains:

       chan (!int ; ?bool ; stop)

   `fork` creates the two ends of a channel and gives each side the *dual*
   protocol, so what one end sends the other receives.  Duality is the only
   session-specific idea in the checker; the linearity that makes it sound is
   the same linearity as everywhere else. *)

type qual = Lin | Un

type ty =
  | TBase of qual * string (* int, bool, unit *)
  | TFun of qual * ty * ty
  | TPair of qual * ty * ty
  | TChan of session (* always linear *)

and session =
  | SSend of ty * session (* !T ; S *)
  | SRecv of ty * session (* ?T ; S *)
  | SSelect of (string * session) list (* +{ `l : S } -- we choose *)
  | SBranch of (string * session) list (* &{ `l : S } -- they choose *)
  | SStop

let qual_of = function
  | TBase (q, _) | TFun (q, _, _) | TPair (q, _, _) -> q
  | TChan _ -> Lin

let is_lin t = qual_of t = Lin

let rec dual = function
  | SSend (t, s) -> SRecv (t, dual s)
  | SRecv (t, s) -> SSend (t, dual s)
  | SSelect ls -> SBranch (List.map (fun (l, s) -> (l, dual s)) ls)
  | SBranch ls -> SSelect (List.map (fun (l, s) -> (l, dual s)) ls)
  | SStop -> SStop

let rec show ?(prec = 0) t =
  let paren p s = if prec > p then "(" ^ s ^ ")" else s in
  let q s = function Lin -> "lin " ^ s | Un -> s in
  match t with
  | TBase (Un, name) -> name
  | TBase (Lin, name) -> "lin " ^ name
  | TFun (Lin, a, b) ->
      paren 1 (Printf.sprintf "%s -o %s" (show ~prec:2 a) (show ~prec:1 b))
  | TFun (Un, a, b) ->
      paren 1 (Printf.sprintf "%s -> %s" (show ~prec:2 a) (show ~prec:1 b))
  | TPair (qu, a, b) ->
      let s = Printf.sprintf "%s * %s" (show ~prec:4 a) (show ~prec:4 b) in
      if qu = Lin then paren 2 (q s Lin) else paren 3 s
  | TChan s -> Printf.sprintf "chan (%s)" (show_session s)

and show_session = function
  | SStop -> "stop"
  | SSend (t, s) -> Printf.sprintf "!%s ; %s" (show ~prec:5 t) (show_session s)
  | SRecv (t, s) -> Printf.sprintf "?%s ; %s" (show ~prec:5 t) (show_session s)
  | SSelect ls -> Printf.sprintf "+{ %s }" (show_choices ls)
  | SBranch ls -> Printf.sprintf "&{ %s }" (show_choices ls)

and show_choices ls =
  String.concat ", "
    (List.map (fun (l, s) -> Printf.sprintf "`%s : %s" l (show_session s)) ls)

let rec equal a b =
  match (a, b) with
  | TBase (q1, n1), TBase (q2, n2) -> q1 = q2 && n1 = n2
  | TFun (q1, a1, b1), TFun (q2, a2, b2) -> q1 = q2 && equal a1 a2 && equal b1 b2
  | TPair (q1, a1, b1), TPair (q2, a2, b2) -> q1 = q2 && equal a1 a2 && equal b1 b2
  | TChan s1, TChan s2 -> equal_session s1 s2
  | _ -> false

and equal_session a b =
  match (a, b) with
  | SStop, SStop -> true
  | SSend (t1, s1), SSend (t2, s2) | SRecv (t1, s1), SRecv (t2, s2) ->
      equal t1 t2 && equal_session s1 s2
  | SSelect l1, SSelect l2 | SBranch l1, SBranch l2 ->
      List.length l1 = List.length l2
      && List.for_all2
           (fun (a, s1) (b, s2) -> a = b && equal_session s1 s2)
           (List.sort compare l1) (List.sort compare l2)
  | _ -> false

(* An unrestricted value may be used where a linear one is wanted: promising to
   use something exactly once is a promise anything can keep.  The other
   direction is what must not happen, so the promotion is allowed only at the
   top of a type, where the obligation is being taken on. *)
let set_qual q = function
  | TBase (_, n) -> TBase (q, n)
  | TFun (_, a, b) -> TFun (q, a, b)
  | TPair (_, a, b) -> TPair (q, a, b)
  | TChan s -> TChan s

let compatible got want =
  equal got want || (qual_of got = Un && equal (set_qual Lin got) want)

(* Reading a type.  A base type is unrestricted unless `lin` says otherwise; an
   arrow written `-o` is linear, and one written `->` is not. *)
let rec read_ty (e : Ast.t) : ty =
  match e.it with
  | Ast.Var (("int" | "bool" | "unit") as n) -> TBase (Un, n)
  | Ast.Unit -> TBase (Un, "unit")
  | Ast.App ({ it = Ast.Var "lin"; _ }, t) -> with_qual e.loc Lin (read_ty t)
  | Ast.App ({ it = Ast.Var "un"; _ }, t) -> with_qual e.loc Un (read_ty t)
  | Ast.App ({ it = Ast.Var "chan"; _ }, s) -> TChan (read_session s)
  | Ast.Arrow (Ast.One, None, a, b) -> TFun (Lin, read_ty a, read_ty b)
  | Ast.Arrow (Ast.Many, None, a, b) -> TFun (Un, read_ty a, read_ty b)
  | Ast.Arrow (_, Some _, _, _) ->
      Loc.type_error e.loc "a named argument needs #system refine or #system dep"
  | Ast.Bin ("*", a, b) ->
      let a = read_ty a and b = read_ty b in
      TPair ((if is_lin a || is_lin b then Lin else Un), a, b)
  | Ast.Forall _ ->
      Loc.type_error e.loc "the `linear` system is monomorphic; try #system poly"
  | Ast.Rec _ | Ast.VariantTy _ ->
      Loc.type_error e.loc "records and variants belong to #system row"
  | Ast.Refine _ -> Loc.type_error e.loc "refinement types belong to #system refine"
  | Ast.Prod _ -> Loc.type_error e.loc "dependent pairs belong to #system dep"
  | Ast.Var x -> Loc.type_error e.loc "unknown type %s" x
  | _ -> Loc.type_error e.loc "this is not a type"

(* `un (T * U)` is only a type if T and U are themselves unrestricted: an
   unrestricted value that contained a linear one could be copied, and the
   linear one with it. *)
and with_qual loc q t =
  match (t, q) with
  | TChan _, _ -> Loc.type_error loc "a channel is linear; it cannot be qualified"
  | TBase (_, n), _ -> TBase (q, n)
  | TFun (_, a, b), _ -> TFun (q, a, b)
  | TPair (_, a, b), Un when is_lin a || is_lin b ->
      Loc.type_error loc
        "`un (%s * %s)` would let a linear value be copied with the pair that \
         holds it"
        (show a) (show b)
  | TPair (_, a, b), _ -> TPair (q, a, b)

and read_session (e : Ast.t) : session =
  match e.it with
  | Ast.Var "stop" -> SStop
  | Ast.Bin (";", { it = Ast.Uop ("!", t); _ }, rest) ->
      SSend (read_ty t, read_session rest)
  | Ast.Bin (";", { it = Ast.Uop ("?", t); _ }, rest) ->
      SRecv (read_ty t, read_session rest)
  | Ast.Uop ("!", t) -> SSend (read_ty t, SStop)
  | Ast.Uop ("?", t) -> SRecv (read_ty t, SStop)
  | Ast.Choice ("+", fields) -> SSelect (read_choices fields)
  | Ast.Choice (_, fields) -> SBranch (read_choices fields)
  | Ast.Bin (";", _, _) ->
      Loc.type_error e.loc
        "a session step is `!t`, `?t`, `+{...}`, `&{...}` or `stop`"
  | _ ->
      Loc.type_error e.loc
        "a session type looks like `!int ; ?bool ; stop`; this does not"

and read_choices fields =
  List.map
    (fun (f : Ast.field) -> (f.flabel, read_session f.fbody))
    fields

(* The context.  Checking returns what is left of it, and that is the whole
   accounting: a name that is still there was not used. *)
type ctx = (string * ty) list

(* Linear names that have been used already, kept only so that the second use
   can be told what happened to the first. *)
let spent : (string * ty) list ref = ref []

let lookup loc (ctx : ctx) x =
  match List.assoc_opt x ctx with
  | Some t -> t
  | None -> (
      match List.assoc_opt x !spent with
      | Some t ->
          Loc.type_error loc
            "%s has linear type %s and has already been used: a linear value \
             is used exactly once"
            x (show t)
      | None -> Loc.type_error loc "unbound variable %s" x)

(* Using a name: an unrestricted one stays, a linear one is taken away. *)
let use loc ctx x =
  let t = lookup loc ctx x in
  if is_lin t then (
    spent := (x, t) :: !spent;
    (t, List.remove_assoc x ctx))
  else (t, ctx)

let linear_names (ctx : ctx) =
  List.filter_map (fun (x, t) -> if is_lin t then Some x else None) ctx

(* Two branches must leave the same context behind, or the program's behaviour
   would depend on which one ran. *)
let same_leftovers loc a b =
  let la = List.sort compare (linear_names a)
  and lb = List.sort compare (linear_names b) in
  if la <> lb then
    let only l1 l2 = List.filter (fun x -> not (List.mem x l2)) l1 in
    let missing = only la lb @ only lb la in
    Loc.type_error loc
      "the branches disagree about %s: a linear value must be used in every \
       branch or in none"
      (String.concat ", " missing)

let prims = [ "send"; "recv"; "close"; "fork" ]

let initial_ctx () =
  [
    ("not", TFun (Un, TBase (Un, "bool"), TBase (Un, "bool")));
    ("print", TFun (Un, TBase (Un, "int"), TBase (Un, "unit")));
  ]

let rec infer (ctx : ctx) (e : Ast.t) : ty * ctx =
  match e.it with
  | Ast.Int _ -> (TBase (Un, "int"), ctx)
  | Ast.Bool _ -> (TBase (Un, "bool"), ctx)
  | Ast.Unit -> (TBase (Un, "unit"), ctx)
  | Ast.Var x -> use e.loc ctx x
  | Ast.Ann (body, ann) ->
      let want = read_ty ann in
      let got, ctx = infer ctx body in
      if not (compatible got want) then
        Loc.type_error e.loc "this has type %s, but %s was written" (show got)
          (show want);
      (want, ctx)
  | Ast.Lam (bs, body) -> infer_lam ctx e.loc bs body
  | Ast.App _ -> infer_app ctx e
  | Ast.Pair (a, b) ->
      let ta, ctx = infer ctx a in
      let tb, ctx = infer ctx b in
      (TPair ((if is_lin ta || is_lin tb then Lin else Un), ta, tb), ctx)
  | Ast.If (c, thn, els) ->
      let tc, ctx = infer ctx c in
      expect e.loc tc (TBase (Un, "bool"));
      let t1, ctx1 = infer ctx thn in
      let t2, ctx2 = infer ctx els in
      same_leftovers e.loc ctx1 ctx2;
      if not (equal t1 t2) then
        Loc.type_error e.loc "the branches have types %s and %s" (show t1) (show t2);
      (t1, ctx1)
  | Ast.Bin (";", a, b) ->
      let ta, ctx = infer ctx a in
      if is_lin ta then
        Loc.type_error a.Ast.loc
          "this has linear type %s, so its value cannot be discarded" (show ta);
      infer ctx b
  | Ast.Bin (op, a, b) when List.mem op [ "+"; "-"; "*"; "/"; "%" ] ->
      let ctx = check_base ctx a "int" in
      let ctx = check_base ctx b "int" in
      (TBase (Un, "int"), ctx)
  | Ast.Bin (op, a, b) when List.mem op [ "=="; "!="; "<"; "<="; ">"; ">=" ] ->
      let ta, ctx = infer ctx a in
      let tb, ctx = infer ctx b in
      if is_lin ta || is_lin tb then
        Loc.type_error e.loc "linear values cannot be compared";
      if not (equal ta tb) then
        Loc.type_error e.loc "comparing %s with %s" (show ta) (show tb);
      (TBase (Un, "bool"), ctx)
  | Ast.Bin (("&&" | "||" | "==>"), a, b) ->
      let ctx = check_base ctx a "bool" in
      let ctx = check_base ctx b "bool" in
      (TBase (Un, "bool"), ctx)
  | Ast.Uop ("-", a) ->
      let ctx = check_base ctx a "int" in
      (TBase (Un, "int"), ctx)
  | Ast.LetIn (d, body) ->
      let ctx, introduced = bind_decl ctx d in
      let t, ctx = infer ctx body in
      List.iter
        (fun x ->
          match List.assoc_opt x ctx with
          | Some bt when is_lin bt ->
              Loc.type_error d.Ast.dloc "%s has linear type %s and is never used"
                x (show bt)
          | _ -> ())
        introduced;
      (t, List.fold_left (fun c x -> List.remove_assoc x c) ctx introduced)
  | Ast.Select (l, c) ->
      let t, ctx = infer ctx c in
      let choices =
        match t with
        | TChan (SSelect ls) -> ls
        | TChan s ->
            Loc.type_error e.loc "this channel's protocol is %s, so there is \
                                  nothing to choose" (show_session s)
        | _ -> Loc.type_error e.loc "select needs a channel, not %s" (show t)
      in
      (match List.assoc_opt l choices with
      | Some rest -> (TChan rest, ctx)
      | None ->
          Loc.type_error e.loc "the protocol offers %s, not `%s"
            (show_choices choices) l)
  | Ast.Branch (c, arms) ->
      let t, ctx = infer ctx c in
      let choices =
        match t with
        | TChan (SBranch ls) -> ls
        | TChan s ->
            Loc.type_error e.loc
              "this channel's protocol is %s, so the peer makes no choice here"
              (show_session s)
        | _ -> Loc.type_error e.loc "branch needs a channel, not %s" (show t)
      in
      if List.length arms <> List.length choices then
        Loc.type_error e.loc
          "the protocol offers %s; every branch must be answered"
          (show_choices choices);
      let results =
        List.map
          (fun (l, x, body) ->
            match List.assoc_opt l choices with
            | None ->
                Loc.type_error e.loc "the protocol does not offer `%s" l
            | Some rest ->
                let inner = (x, TChan rest) :: ctx in
                let t, out = infer inner body in
                (match List.assoc_opt x out with
                | Some bt when is_lin bt ->
                    Loc.type_error e.loc
                      "the branch for `%s leaves %s unused, and %s is linear" l x
                      (show bt)
                | _ -> ());
                (t, List.remove_assoc x out))
          arms
      in
      let t0, ctx0 = List.hd results in
      List.iter
        (fun (t, c) ->
          same_leftovers e.loc ctx0 c;
          if not (equal t t0) then
            Loc.type_error e.loc "the branches have types %s and %s" (show t0)
              (show t))
        (List.tl results);
      (t0, ctx0)
  | Ast.Match _ ->
      Loc.type_error e.loc "the `linear` system has no variants to match on"
  | Ast.Proj _ | Ast.Restrict _ | Ast.Inject _ ->
      Loc.type_error e.loc "records and variants belong to #system row"
  | Ast.Arrow _ | Ast.Forall _ | Ast.Refine _ | Ast.Prod _ | Ast.Choice _
  | Ast.Rec _ | Ast.VariantTy _ | Ast.Uop (("!" | "?"), _) ->
      Loc.type_error e.loc "a type cannot be used as a term"
  | _ -> Loc.type_error e.loc "the `linear` system does not know this form"

and expect loc got want =
  if not (equal got want) then
    Loc.type_error loc "this has type %s, but %s was expected" (show got) (show want)

and check_base ctx e name =
  let t, ctx = infer ctx e in
  expect e.Ast.loc t (TBase (Un, name));
  ctx

(* A lambda's qualifier is discovered rather than written: if checking the body
   took a linear binding out of the enclosing context, the closure holds it, and
   the closure is linear too. *)
and infer_lam ctx loc bs body =
  match bs with
  | [] -> infer ctx body
  | b :: rest ->
      let dom =
        match b.Ast.bann with
        | Some ann -> read_ty ann
        | None ->
            Loc.type_error loc
              "the `linear` system needs a type for the parameter %s" b.Ast.bname
      in
      let before = linear_names ctx in
      let inner = (b.Ast.bname, dom) :: ctx in
      let cod, out =
        match rest with
        | [] -> infer inner body
        | _ -> infer_lam inner loc rest body
      in
      (match List.assoc_opt b.Ast.bname out with
      | Some t when is_lin t ->
          Loc.type_error loc "the parameter %s has linear type %s and is never used"
            b.Ast.bname (show t)
      | _ -> ());
      let out = List.remove_assoc b.Ast.bname out in
      let captured = List.exists (fun x -> not (List.mem_assoc x out)) before in
      (TFun ((if captured then Lin else Un), dom, cod), out)

(* Applications, including the session primitives.  They are not entries in the
   context because their types are not fixed: `send` works for any payload and
   any continuation. *)
and infer_app ctx (e : Ast.t) =
  let head, args = Anf.spine e [] in
  match (head.Ast.it, args) with
  | Ast.Var "send", [ v; c ] ->
      let tv, ctx = infer ctx v in
      let tc, ctx = infer ctx c in
      let payload, rest =
        match tc with
        | TChan (SSend (t, s)) -> (t, s)
        | TChan s ->
            Loc.type_error e.loc
              "this channel's protocol is %s, so it is not ready to send"
              (show_session s)
        | _ -> Loc.type_error e.loc "send needs a channel, not %s" (show tc)
      in
      if not (compatible tv payload) then
        Loc.type_error e.loc "the protocol sends %s, but this is %s" (show payload)
          (show tv);
      (TChan rest, ctx)
  | Ast.Var "recv", [ c ] ->
      let tc, ctx = infer ctx c in
      let payload, rest =
        match tc with
        | TChan (SRecv (t, s)) -> (t, s)
        | TChan s ->
            Loc.type_error e.loc
              "this channel's protocol is %s, so nothing is coming"
              (show_session s)
        | _ -> Loc.type_error e.loc "recv needs a channel, not %s" (show tc)
      in
      (TPair (Lin, payload, TChan rest), ctx)
  | Ast.Var "close", [ c ] ->
      let tc, ctx = infer ctx c in
      (match tc with
      | TChan SStop -> ()
      | TChan s ->
          Loc.type_error e.loc "this channel still has %s to do" (show_session s)
      | _ -> Loc.type_error e.loc "close needs a channel, not %s" (show tc));
      (TBase (Un, "unit"), ctx)
  | Ast.Var "fork", [ f ] ->
      let tf, ctx = infer ctx f in
      (match tf with
      | TFun (_, TChan s, TBase (Un, "unit")) -> (TChan (dual s), ctx)
      | TFun (_, TChan _, res) ->
          Loc.type_error e.loc "a forked process must end in unit, not %s"
            (show res)
      | _ ->
          Loc.type_error e.loc
            "fork needs a function from a channel to unit, not %s" (show tf))
  | Ast.Var p, _ when List.mem p prims ->
      Loc.type_error e.loc "%s is applied to the wrong number of arguments" p
  | _ ->
      List.fold_left
        (fun (t, ctx) arg ->
          match t with
          | TFun (_, dom, cod) ->
              let ta, ctx = infer ctx arg in
              if not (compatible ta dom) then
                Loc.type_error arg.Ast.loc "this has type %s, but %s was expected"
                  (show ta) (show dom);
              (cod, ctx)
          | _ ->
              Loc.type_error e.loc "this is applied to an argument but has type %s"
                (show t))
        (infer ctx head) args

and bind_decl ctx (d : Ast.decl) : ctx * string list =
  let body = Ast.decl_body d in
  match d.Ast.dpat with
  | Ast.DName name ->
      if d.Ast.drec then
        (* A recursive function has to be in scope for its own body, so its type
           must be written; and it must be unrestricted, or the recursive call
           would be a second use. *)
        let t =
          match (d.Ast.dparams, d.Ast.dret) with
          | ps, Some ret when List.for_all (fun (b : Ast.binder) -> b.bann <> None) ps ->
              List.fold_right
                (fun (b : Ast.binder) acc ->
                  TFun (Un, read_ty (Option.get b.bann), acc))
                ps (read_ty ret)
          | _ ->
              Loc.type_error d.Ast.dloc
                "`fun %s` is recursive, so the `linear` system needs its \
                 parameter and result types written out"
                name
        in
        let inner = (name, t) :: ctx in
        let got, out = infer inner body in
        if not (compatible got t) then
          Loc.type_error d.Ast.dloc "%s is declared %s but defined as %s" name
            (show t) (show got);
        ((name, t) :: List.remove_assoc name out, [ name ])
      else
        let t, ctx = infer ctx body in
        ((name, t) :: ctx, [ name ])
  | Ast.DUnit ->
      let t, ctx = infer ctx body in
      if is_lin t then
        Loc.type_error d.Ast.dloc "this has linear type %s and cannot be dropped"
          (show t);
      (ctx, [])
  | Ast.DPair (x, y) ->
      let t, ctx = infer ctx body in
      (match t with
      | TPair (_, a, b) -> ((x, a) :: (y, b) :: ctx, [ x; y ])
      | _ ->
          Loc.type_error d.Ast.dloc "this is not a pair but %s" (show t))

let check_program (items : Ast.toplevel list) =
  let ctx = ref (initial_ctx ()) in
  spent := [];
  let results =
    List.filter_map
      (function
        | Ast.TType { tloc; _ } ->
            Loc.type_error tloc "the `linear` system has no type aliases yet"
        | Ast.TLet d ->
            let c, _ = bind_decl !ctx d in
            ctx := c;
            let name =
              match d.Ast.dpat with
              | Ast.DName x -> x
              | Ast.DUnit -> "()"
              | Ast.DPair (x, y) -> Printf.sprintf "(%s, %s)" x y
            in
            let t =
              match d.Ast.dpat with
              | Ast.DName x -> List.assoc x !ctx
              | Ast.DUnit -> TBase (Un, "unit")
              | Ast.DPair (x, y) ->
                  TPair (Lin, List.assoc x !ctx, List.assoc y !ctx)
            in
            Some { System.rname = name; rtype = show t; rvalue = None })
      items
  in
  (* Nothing linear may be left over at the end of the program either: an
     endpoint nobody talked to is a protocol nobody finished. *)
  List.iter
    (fun (x, t) ->
      if is_lin t then
        Loc.type_error Loc.unknown
          "%s has linear type %s and is never used" x (show t))
    !ctx;
  results

let system : System.t =
  {
    name = "linear";
    blurb = "linear types and session-typed channels: use exactly once, in order";
    check = check_program;
    runs = true;
  }
