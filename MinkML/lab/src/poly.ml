(* The `poly` system: predicative higher-rank polymorphism, checked
   bidirectionally.

   This is Dunfield and Krishnaswami's algorithm ("Complete and Easy
   Bidirectional Typechecking for Higher-Rank Polymorphism", ICFP 2013) with
   three additions that make it a language rather than a calculus: integers and
   booleans, pairs, and generalisation at `let`.

   Two things carry the whole algorithm.  First, the context is *ordered*: a
   list in which a type variable, a term variable, an unsolved existential or
   a solved one all appear in the order they were introduced, so "is this type
   allowed to mention that variable" is answered by looking at what stands to
   the left.  Second, every judgement threads the context through and returns
   it, because solving an existential is how information flows.  There is no
   mutable state and no separate substitution pass: [apply] reads the answers
   out of the context. *)

type ty =
  | TUnit
  | TInt
  | TBool
  | TVar of string (* a universal variable, bound by a forall *)
  | TEx of int (* an existential: "some monotype, not yet known" *)
  | TArrow of ty * ty
  | TPair of ty * ty
  | TForall of string * ty

type entry =
  | EVar of string
  | ETerm of string * ty
  | EEx of int
  | ESolved of int * ty
  | EMark of int

(* The head of the list is the *newest* entry, so "to the left of" in the
   paper is "further down the list" here. *)
type ctx = entry list

let counter = ref 0

let fresh_ex () =
  incr counter;
  !counter

let fresh_name base =
  incr counter;
  Printf.sprintf "%s%d" base !counter

(* Printing.  Existentials print as `?n` so that a leftover one in a message is
   recognisable as "the checker never found out". *)
let rec show ?(prec = 0) t =
  let paren p s = if prec > p then "(" ^ s ^ ")" else s in
  match t with
  | TUnit -> "unit"
  | TInt -> "int"
  | TBool -> "bool"
  | TVar a -> a
  | TEx n -> Printf.sprintf "?%d" n
  | TArrow (a, b) ->
      paren 1 (Printf.sprintf "%s -> %s" (show ~prec:2 a) (show ~prec:1 b))
  | TPair (a, b) ->
      paren 3 (Printf.sprintf "%s * %s" (show ~prec:4 a) (show ~prec:4 b))
  | TForall _ ->
      (* A run of quantifiers prints as one: `forall 'a 'b. ...`. *)
      let rec strip acc = function
        | TForall (a, b) -> strip (a :: acc) b
        | body -> (List.rev acc, body)
      in
      let vars, body = strip [] t in
      paren 0
        (Printf.sprintf "forall %s. %s" (String.concat " " vars) (show ~prec:0 body))

let rec subst a s t =
  match t with
  | TVar b when b = a -> s
  | TArrow (x, y) -> TArrow (subst a s x, subst a s y)
  | TPair (x, y) -> TPair (subst a s x, subst a s y)
  | TForall (b, _) when b = a -> t
  | TForall (b, body) -> TForall (b, subst a s body)
  | t -> t

let rec is_mono = function
  | TForall _ -> false
  | TArrow (a, b) | TPair (a, b) -> is_mono a && is_mono b
  | _ -> true

(* Reading the answers out of the context. *)
let rec apply ctx t =
  match t with
  | TEx n -> (
      match
        List.find_map (function ESolved (m, s) when m = n -> Some s | _ -> None) ctx
      with
      | Some s -> apply ctx s
      | None -> t)
  | TArrow (a, b) -> TArrow (apply ctx a, apply ctx b)
  | TPair (a, b) -> TPair (apply ctx a, apply ctx b)
  | TForall (a, b) -> TForall (a, apply ctx b)
  | t -> t

let rec occurs n = function
  | TEx m -> m = n
  | TArrow (a, b) | TPair (a, b) -> occurs n a || occurs n b
  | TForall (_, b) -> occurs n b
  | _ -> false

let lookup_term ctx x =
  List.find_map (function ETerm (y, t) when y = x -> Some t | _ -> None) ctx

let has_ex ctx n =
  List.exists (function EEx m | ESolved (m, _) -> m = n | _ -> false) ctx

let has_var ctx a = List.exists (function EVar b -> b = a | _ -> false) ctx

(* Everything a type mentions must already be in scope.  This is the check
   that keeps the algorithm predicative: an existential may only be solved
   with a type whose variables were introduced before it. *)
let rec well_formed loc ctx t =
  match t with
  | TUnit | TInt | TBool -> ()
  | TVar a ->
      if not (has_var ctx a) then Loc.type_error loc "unbound type variable %s" a
  | TEx n ->
      if not (has_ex ctx n) then
        Loc.type_error loc "the type ?%d escapes the scope it was created in" n
  | TArrow (a, b) | TPair (a, b) ->
      well_formed loc ctx a;
      well_formed loc ctx b
  | TForall (a, b) -> well_formed loc (EVar a :: ctx) b

(* Split a context at an existential: everything newer, and everything older.
   The existential itself is dropped, so the caller says what replaces it. *)
let split_ex loc ctx n =
  (* Both halves come back newest-first, the way contexts are stored, so that
     [newer @ entries @ older] puts [entries] exactly where the existential
     was. *)
  let rec go acc = function
    | [] -> Loc.type_error loc "the type ?%d is not in scope" n
    | EEx m :: older when m = n -> (List.rev acc, older)
    | e :: rest -> go (e :: acc) rest
  in
  go [] ctx

(* Drop everything introduced after a marker, and return it: this is how the
   scope of a forall is closed, and how generalisation finds the existentials
   that were never solved. *)
let split_mark ctx n =
  let rec go acc = function
    | [] -> (List.rev acc, [])
    | EMark m :: older when m = n -> (List.rev acc, older)
    | e :: rest -> go (e :: acc) rest
  in
  go [] ctx

let drop_var ctx a =
  let rec go = function
    | [] -> []
    | EVar b :: older when b = a -> older
    | _ :: rest -> go rest
  in
  go ctx

let drop_term ctx x =
  let rec go = function
    | [] -> []
    | ETerm (y, _) :: older when y = x -> older
    | _ :: rest -> go rest
  in
  go ctx

(* Is n older than m?  Contexts are newest-first, so older means later. *)
let older_than ctx n m =
  let index p =
    let rec go i = function
      | [] -> None
      | e :: rest -> if p e then Some i else go (i + 1) rest
    in
    go 0 ctx
  in
  let is_ex k = function EEx j | ESolved (j, _) -> j = k | _ -> false in
  match (index (is_ex n), index (is_ex m)) with
  | Some i, Some j -> i > j
  | _ -> false

(* Subtyping: Γ ⊢ A <: B ⊣ Δ.  "A is at least as polymorphic as B". *)
let rec subtype loc ctx a b =
  match (a, b) with
  | TUnit, TUnit | TInt, TInt | TBool, TBool -> ctx
  | TVar x, TVar y when x = y -> ctx
  | TEx n, TEx m when n = m -> ctx
  | TArrow (a1, a2), TArrow (b1, b2) ->
      (* contravariant in the argument, covariant in the result *)
      let ctx = subtype loc ctx b1 a1 in
      subtype loc ctx (apply ctx a2) (apply ctx b2)
  | TPair (a1, a2), TPair (b1, b2) ->
      let ctx = subtype loc ctx a1 b1 in
      subtype loc ctx (apply ctx a2) (apply ctx b2)
  | TForall (x, body), _ ->
      (* The left forall is instantiated with a fresh existential; the marker
         remembers where to cut the context back to. *)
      let n = fresh_ex () in
      let ctx' = EEx n :: EMark n :: ctx in
      let ctx' = subtype loc ctx' (subst x (TEx n) body) b in
      snd (split_mark ctx' n)
  | _, TForall (x, body) ->
      (* The right forall must hold for a variable the left side cannot see. *)
      let a' = fresh_name x in
      let ctx' = subtype loc (EVar a' :: ctx) a (subst x (TVar a') body) in
      drop_var ctx' a'
  | TEx n, _ when not (occurs n b) -> instantiate_l loc ctx n b
  | _, TEx n when not (occurs n a) -> instantiate_r loc ctx a n
  | _ ->
      Loc.type_error loc "cannot make %s a subtype of %s" (show a) (show b)

(* Γ ⊢ â :=< A ⊣ Δ -- solve â so that it is below A. *)
and instantiate_l loc ctx n a =
  let newer, older = split_ex loc ctx n in
  let reassemble entries = newer @ entries @ older in
  match a with
  | _ when is_mono a && (try well_formed loc older a; true with Loc.Error _ -> false) ->
      reassemble [ ESolved (n, a) ]
  | TEx m when older_than ctx n m ->
      (* â was introduced first, so β̂ is the one that gets solved. *)
      let newer', older' = split_ex loc ctx m in
      newer' @ [ ESolved (m, TEx n) ] @ older'
  | TArrow (a1, a2) ->
      let n1 = fresh_ex () and n2 = fresh_ex () in
      let ctx =
        reassemble [ ESolved (n, TArrow (TEx n1, TEx n2)); EEx n1; EEx n2 ]
      in
      let ctx = instantiate_r loc ctx a1 n1 in
      instantiate_l loc ctx n2 (apply ctx a2)
  | TPair (a1, a2) ->
      let n1 = fresh_ex () and n2 = fresh_ex () in
      let ctx =
        reassemble [ ESolved (n, TPair (TEx n1, TEx n2)); EEx n1; EEx n2 ]
      in
      let ctx = instantiate_l loc ctx n1 a1 in
      instantiate_l loc ctx n2 (apply ctx a2)
  | TForall (x, body) ->
      let a' = fresh_name x in
      let ctx = instantiate_l loc (EVar a' :: ctx) n (subst x (TVar a') body) in
      drop_var ctx a'
  | _ -> Loc.type_error loc "cannot instantiate ?%d to %s" n (show a)

(* Γ ⊢ A =<: â ⊣ Δ -- the mirror image, except that the forall case has to
   guess, which is exactly where rank-2 inference stops being possible. *)
and instantiate_r loc ctx a n =
  let newer, older = split_ex loc ctx n in
  let reassemble entries = newer @ entries @ older in
  match a with
  | _ when is_mono a && (try well_formed loc older a; true with Loc.Error _ -> false) ->
      reassemble [ ESolved (n, a) ]
  | TEx m when older_than ctx n m ->
      let newer', older' = split_ex loc ctx m in
      newer' @ [ ESolved (m, TEx n) ] @ older'
  | TArrow (a1, a2) ->
      let n1 = fresh_ex () and n2 = fresh_ex () in
      let ctx =
        reassemble [ ESolved (n, TArrow (TEx n1, TEx n2)); EEx n1; EEx n2 ]
      in
      let ctx = instantiate_l loc ctx n1 a1 in
      instantiate_r loc ctx (apply ctx a2) n2
  | TPair (a1, a2) ->
      let n1 = fresh_ex () and n2 = fresh_ex () in
      let ctx =
        reassemble [ ESolved (n, TPair (TEx n1, TEx n2)); EEx n1; EEx n2 ]
      in
      let ctx = instantiate_r loc ctx a1 n1 in
      instantiate_r loc ctx (apply ctx a2) n2
  | TForall (x, body) ->
      let m = fresh_ex () in
      let ctx = EEx m :: EMark m :: ctx in
      let ctx = instantiate_r loc ctx (subst x (TEx m) body) n in
      snd (split_mark ctx m)
  | _ -> Loc.type_error loc "cannot instantiate ?%d to %s" n (show a)

(* Generalisation invents names like `t17`, which say nothing.  Before a type
   is shown, rename the leading foralls to a, b, c -- skipping any name the
   type already uses, so that a rank-2 annotation's own variables are safe. *)
let pretty t =
  let taken = ref [] in
  let rec collect = function
    | TVar a -> taken := a :: !taken
    | TForall (a, b) ->
        taken := a :: !taken;
        collect b
    | TArrow (a, b) | TPair (a, b) ->
        collect a;
        collect b
    | _ -> ()
  in
  collect t;
  let supply = ref [ "'a"; "'b"; "'c"; "'d"; "'e"; "'f"; "'g"; "'h" ] in
  let rec next () =
    match !supply with
    | [] -> "z"
    | n :: rest ->
        supply := rest;
        if List.mem n !taken then next () else n
  in
  let rec go = function
    | TForall (x, body) ->
        let n = next () in
        TForall (n, go (subst x (TVar n) body))
    | t -> t
  in
  go t

(* Reading a type out of the syntax tree.  The systems differ mostly in what
   they refuse here, and the refusal is the useful part: it says which system
   the program belongs to. *)
let rec read_ty (e : Ast.t) : ty =
  match e.it with
  | Ast.Var "int" -> TInt
  | Ast.Var "bool" -> TBool
  | Ast.Var "unit" -> TUnit
  | Ast.Var x -> TVar x
  | Ast.Arrow (Ast.Many, None, a, b) -> TArrow (read_ty a, read_ty b)
  | Ast.Arrow (Ast.One, _, _, _) ->
      Loc.type_error e.loc
        "`-o` is a linear arrow; the `poly` system has only `->` (try #system \
         linear)"
  | Ast.Arrow (_, Some _, _, _) ->
      Loc.type_error e.loc
        "a function type may not name its argument here (try #system refine or \
         #system dep)"
  | Ast.Forall (vs, body) ->
      List.fold_right (fun v t -> TForall (v, t)) vs (read_ty body)
  | Ast.Bin ("*", a, b) -> TPair (read_ty a, read_ty b)
  | Ast.Refine _ ->
      Loc.type_error e.loc "refinement types belong to #system refine"
  | Ast.Rec _ | Ast.VariantTy _ ->
      Loc.type_error e.loc "records and variants belong to #system row"
  | Ast.Prod _ ->
      Loc.type_error e.loc "dependent pairs belong to #system dep"
  | Ast.Choice _ | Ast.Uop (("!" | "?"), _) ->
      Loc.type_error e.loc "session types belong to #system linear"
  | _ -> Loc.type_error e.loc "this is not a type"

(* The primitives, and the types the paper's calculus does not have to give
   them.  `print` is polymorphic in what it prints, which is a rank-1 use of a
   forall and needs no annotation to apply. *)
let initial_ctx () =
  let a = TVar "a" and b = TVar "b" in
  List.rev
    [
      ETerm ("not", TArrow (TBool, TBool));
      ETerm ("print", TForall ("a", TArrow (a, TUnit)));
      ETerm ("fst", TForall ("a", TForall ("b", TArrow (TPair (a, b), a))));
      ETerm ("snd", TForall ("a", TForall ("b", TArrow (TPair (a, b), b))));
    ]

let arith = [ "+"; "-"; "*"; "/"; "%" ]
let compare_ops = [ "=="; "!="; "<"; "<="; ">"; ">=" ]

(* Γ ⊢ e ⇐ A ⊣ Δ *)
let rec check ctx (e : Ast.t) (t : ty) : ctx =
  match (e.it, t) with
  (* Checking against a forall introduces the variable and checks under it. *)
  | _, TForall (x, body) ->
      let a' = fresh_name x in
      let ctx = check (EVar a' :: ctx) e (subst x (TVar a') body) in
      drop_var ctx a'
  | Ast.Unit, TUnit -> ctx
  | Ast.Int _, TInt -> ctx
  | Ast.Bool _, TBool -> ctx
  | Ast.Lam (bs, body), TArrow _ -> check_lam ctx e.loc bs body t
  | Ast.Pair (l, r), TPair (a, b) ->
      let ctx = check ctx l a in
      check ctx r (apply ctx b)
  | Ast.If (c, thn, els), _ ->
      let ctx = check ctx c TBool in
      let ctx = check ctx thn (apply ctx t) in
      check ctx els (apply ctx t)
  | Ast.LetIn (d, body), _ ->
      let ctx, x = bind_decl ctx d in
      let ctx = check ctx body (apply ctx t) in
      drop_term ctx x
  | Ast.Bin (";", a, b), _ ->
      let ctx, _ = synth ctx a in
      check ctx b (apply ctx t)
  | Ast.Match _, _ ->
      Loc.type_error e.loc "the `poly` system has no variants to match on"
  (* Everything else: synthesise, then check that what came out is at least as
     polymorphic as what was wanted. *)
  | _ ->
      let ctx, s = synth ctx e in
      subtype e.loc ctx (apply ctx s) (apply ctx t)

and check_lam ctx loc bs body t =
  match (bs, t) with
  | [], _ -> check ctx body t
  | b :: rest, TArrow (dom, cod) ->
      (* A parameter may carry its own type even though one is expected from
         outside; then what is passed must be acceptable to what was written.
         The context that comes back is kept: the comparison may have solved
         something. *)
      let ctx =
        match b.Ast.bann with
        | None -> ctx
        | Some ann -> subtype loc ctx dom (read_ty ann)
      in
      let ctx = ETerm (b.Ast.bname, dom) :: ctx in
      let inner =
        match rest with
        | [] -> check ctx body cod
        | _ -> check_lam ctx loc rest body cod
      in
      drop_term inner b.Ast.bname
  | b :: _, _ ->
      Loc.type_error loc "%s is a function, but it is checked against %s"
        b.Ast.bname (show t)

(* Γ ⊢ e ⇒ A ⊣ Δ *)
and synth ctx (e : Ast.t) : ctx * ty =
  match e.it with
  | Ast.Unit -> (ctx, TUnit)
  | Ast.Int _ -> (ctx, TInt)
  | Ast.Bool _ -> (ctx, TBool)
  | Ast.Var x -> (
      match lookup_term ctx x with
      | Some t -> (ctx, t)
      | None -> Loc.type_error e.loc "unbound variable %s" x)
  | Ast.Ann (body, ann) ->
      let t = read_ty ann in
      well_formed e.loc ctx t;
      let ctx = check ctx body t in
      (ctx, t)
  | Ast.Lam (bs, body) ->
      (* Guessing a monotype for an unannotated function: one existential per
         parameter, one for the result, and whatever is left unsolved becomes a
         forall.  This is the rule that makes `fun x -> x` polymorphic without
         an annotation. *)
      let m = fresh_ex () in
      let ctx = ref (EMark m :: ctx) in
      let doms =
        List.map
          (fun b ->
            let n =
              match b.Ast.bann with
              | Some ann ->
                  let t = read_ty ann in
                  well_formed e.loc !ctx t;
                  t
              | None ->
                  let n = fresh_ex () in
                  ctx := EEx n :: !ctx;
                  TEx n
            in
            (b.Ast.bname, n))
          bs
      in
      let res = fresh_ex () in
      ctx := EEx res :: !ctx;
      let inner =
        List.fold_left (fun c (x, t) -> ETerm (x, t) :: c) !ctx doms
      in
      let out = check inner body (TEx res) in
      let out =
        List.fold_left (fun c (x, _) -> drop_term c x) out (List.rev doms)
      in
      let result =
        List.fold_right (fun (_, d) acc -> TArrow (d, acc)) doms (TEx res)
      in
      generalize out m result
  | Ast.App _ ->
      let head, args = Anf.spine e [] in
      let ctx, t = synth ctx head in
      List.fold_left
        (fun (ctx, t) arg -> app_synth arg.Ast.loc ctx (apply ctx t) arg)
        (ctx, t) args
  | Ast.Pair (l, r) ->
      let ctx, a = synth ctx l in
      let ctx, b = synth ctx r in
      (ctx, TPair (apply ctx a, apply ctx b))
  | Ast.If (c, thn, els) ->
      let ctx = check ctx c TBool in
      let ctx, a = synth ctx thn in
      let a = apply ctx a in
      let ctx = check ctx els a in
      (ctx, apply ctx a)
  | Ast.LetIn (d, body) ->
      let ctx, x = bind_decl ctx d in
      let ctx, t = synth ctx body in
      (drop_term ctx x, t)
  | Ast.Bin (";", a, b) ->
      let ctx, _ = synth ctx a in
      synth ctx b
  | Ast.Bin (op, a, b) when List.mem op arith ->
      let ctx = check ctx a TInt in
      let ctx = check ctx b TInt in
      (ctx, TInt)
  | Ast.Bin (("&&" | "||" | "==>"), a, b) ->
      let ctx = check ctx a TBool in
      let ctx = check ctx b TBool in
      (ctx, TBool)
  | Ast.Bin (op, a, b) when List.mem op compare_ops ->
      let ctx, ta = synth ctx a in
      let ctx = check ctx b (apply ctx ta) in
      (ctx, TBool)
  | Ast.Uop ("-", a) ->
      let ctx = check ctx a TInt in
      (ctx, TInt)
  | Ast.Uop ("not", a) ->
      let ctx = check ctx a TBool in
      (ctx, TBool)
  | Ast.Forall _ | Ast.Arrow _ | Ast.Refine _ | Ast.Prod _ ->
      Loc.type_error e.loc "a type cannot be used as a term in this system"
  | _ ->
      Loc.type_error e.loc
        "the `poly` system does not know this form (records, variants, \
         channels and dependent types live in the other systems)"

(* Γ ⊢ A • e ⇒⇒ C ⊣ Δ -- what applying something of type A to e produces. *)
and app_synth loc ctx t arg =
  match t with
  | TForall (x, body) ->
      let n = fresh_ex () in
      app_synth loc (EEx n :: ctx) (subst x (TEx n) body) arg
  | TArrow (dom, cod) ->
      let ctx = check ctx arg dom in
      (ctx, apply ctx cod)
  | TEx n ->
      let newer, older = split_ex loc ctx n in
      let n1 = fresh_ex () and n2 = fresh_ex () in
      let ctx =
        newer @ [ ESolved (n, TArrow (TEx n1, TEx n2)); EEx n1; EEx n2 ] @ older
      in
      let ctx = check ctx arg (TEx n1) in
      (ctx, apply ctx (TEx n2))
  | _ -> Loc.type_error loc "this is applied to an argument but has type %s" (show t)

(* Everything introduced after the marker is dropped; the existentials in the
   result that were never solved become universals.  That is generalisation. *)
and generalize ctx mark t =
  let newer, older = split_mark ctx mark in
  let t = apply newer (apply older t) in
  let unsolved =
    List.filter_map
      (function
        | EEx n when not (List.exists (function ESolved (m, _) -> m = n | _ -> false) newer)
          -> Some n
        | _ -> None)
      newer
  in
  let t, names =
    List.fold_left
      (fun (t, names) n ->
        let name = fresh_name "t" in
        (subst_ex n (TVar name) t, name :: names))
      (t, []) unsolved
  in
  let t = List.fold_left (fun t name -> TForall (name, t)) t names in
  (older, t)

and subst_ex n s t =
  match t with
  | TEx m when m = n -> s
  | TArrow (a, b) -> TArrow (subst_ex n s a, subst_ex n s b)
  | TPair (a, b) -> TPair (subst_ex n s a, subst_ex n s b)
  | TForall (a, b) -> TForall (a, subst_ex n s b)
  | t -> t

(* A `let`, in either position: annotated bindings are checked, unannotated
   ones are synthesised and generalised. *)
and bind_decl ctx (d : Ast.decl) =
  let name = match d.Ast.dpat with
    | Ast.DName x -> x
    | Ast.DUnit -> "_"
    | Ast.DPair _ ->
        Loc.type_error d.Ast.dloc
          "the `poly` system has no pair patterns in `let`; use fst and snd"
  in
  let body = Ast.decl_body d in
  if d.Ast.drec then
    (* Monomorphic recursion: the function gets an existential to be found by
       checking its own body, and is generalised afterwards. *)
    let m = fresh_ex () in
    let n = fresh_ex () in
    let ctx = ETerm (name, TEx n) :: EEx n :: EMark m :: ctx in
    let ctx = check ctx body (TEx n) in
    let ctx = drop_term ctx name in
    let ctx, t = generalize ctx m (TEx n) in
    (ETerm (name, t) :: ctx, name)
  else
    let m = fresh_ex () in
    let ctx, t = synth (EMark m :: ctx) body in
    let ctx, t = generalize ctx m t in
    (ETerm (name, t) :: ctx, name)

(* The whole program: bindings are checked in order and each one's type is
   reported. *)
let check_program (items : Ast.toplevel list) =
  let ctx = ref (initial_ctx ()) in
  List.filter_map
    (function
      | Ast.TType { tloc; _ } ->
          Loc.type_error tloc "the `poly` system has no type aliases"
      | Ast.TLet d ->
          let c, name = bind_decl !ctx d in
          ctx := c;
          let t =
            match lookup_term !ctx name with Some t -> t | None -> TUnit
          in
          Some
            {
              System.rname = name;
              rtype = show (pretty (apply !ctx t));
              rvalue = None;
            })
    items

let system : System.t =
  {
    name = "poly";
    blurb =
      "higher-rank predicative polymorphism, bidirectional (Dunfield & \
       Krishnaswami 2013)";
    check = check_program;
    runs = true;
  }
