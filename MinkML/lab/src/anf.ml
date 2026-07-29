(* Normalisation: the syntax tree to A-normal form.

   The translation is the textbook one -- a term is converted with respect to
   a destination, which is either "you are in tail position" or "here is what
   to do with your value".  Naming every intermediate result is what the
   destination does.

   The one interesting case is a conditional in a non-tail position.  Plain
   ANF cannot write `let x = if c then a else b in rest`, and copying `rest`
   into both branches would double the program at every nesting.  So the
   continuation is reified as a local function and each branch tail-calls it:
   that function is what a compiler with join points would keep as a label
   instead of a closure. *)

open Ast
module C = Core

type dest =
  | Tail
  | Cont of (C.atom -> C.block)

let ret d a = match d with Tail -> C.Tail (C.Ret a) | Cont k -> k a

let emit r d =
  let x = C.fresh "t" in
  C.Let (x, r, ret d (C.AVar x))

let no_type loc what =
  Loc.fail ~where:"internal error" loc
    "%s cannot be evaluated: it is a type, and types are erased before the \
     machine runs"
    what

(* The primitives the machine implements.  A checker decides what type each
   one has -- and whether it exists at all, since `fst` has no place in the
   linear system -- but their arity and their runtime meaning live here. *)
let prim_arity = function
  | "not" | "neg" | "print" | "fst" | "snd" -> Some 1
  | "recv" | "close" | "fork" -> Some 1
  | "send" -> Some 2
  | _ -> None

let prim_rhs name (args : C.atom list) =
  match (name, args) with
  | "send", [ v; c ] -> C.Send (v, c)
  | "recv", [ c ] -> C.Recv c
  | "close", [ c ] -> C.Close c
  | "fork", [ f ] -> C.Fork f
  | _, _ -> C.Prim (name, args)

(* `f a b c` as a head and its arguments, so that a saturated primitive can be
   recognised before it is turned into a chain of unary calls. *)
let rec spine e acc =
  match e.it with App (f, a) -> spine f (a :: acc) | _ -> (e, acc)

let rec conv (e : Ast.t) (d : dest) : C.block =
  match e.it with
  | Var x -> ret d (C.AVar x)
  | Int n -> ret d (C.AInt n)
  | Bool b -> ret d (C.ABool b)
  | Unit -> ret d C.AUnit
  | Ann (e, _) -> conv e d
  | Lam (bs, body) -> emit (curry bs body) d
  | LetIn (dcl, body) -> conv_let dcl (fun () -> conv body d)
  | App _ ->
      let head, args = spine e [] in
      conv_app e.loc head args d
  | If (c, a, b) ->
      conv c
        (Cont
           (fun ca ->
             with_join d (fun d' -> C.Tail (C.If (ca, conv a d', conv b d')))))
  | Bin (";", a, b) -> conv a (Cont (fun _ -> conv b d))
  | Bin ("&&", a, b) ->
      conv a
        (Cont
           (fun ca ->
             with_join d (fun d' ->
                 C.Tail (C.If (ca, conv b d', ret d' (C.ABool false))))))
  | Bin ("||", a, b) ->
      conv a
        (Cont
           (fun ca ->
             with_join d (fun d' ->
                 C.Tail (C.If (ca, ret d' (C.ABool true), conv b d')))))
  (* Implication is there for refinement predicates; it still has to run, so
     it runs as the disjunction it is. *)
  | Bin ("==>", a, b) ->
      conv a
        (Cont
           (fun ca ->
             with_join d (fun d' ->
                 C.Tail (C.If (ca, conv b d', ret d' (C.ABool true))))))
  | Bin (op, a, b) ->
      conv a (Cont (fun x -> conv b (Cont (fun y -> emit (C.Prim (op, [ x; y ])) d))))
  | Uop ("-", a) -> conv a (Cont (fun x -> emit (C.Prim ("neg", [ x ])) d))
  | Uop (("!" | "?"), _) -> no_type e.loc "a session type"
  | Uop (op, a) -> conv a (Cont (fun x -> emit (C.Prim (op, [ x ])) d))
  | Pair (a, b) ->
      conv a (Cont (fun x -> conv b (Cont (fun y -> emit (C.MkPair (x, y)) d))))
  | Proj (r, l) -> conv r (Cont (fun x -> emit (C.Proj (x, l)) d))
  | Restrict (r, l) -> conv r (Cont (fun x -> emit (C.Restrict (x, l)) d))
  | Inject (l, None) -> emit (C.Inject (l, C.AUnit)) d
  | Inject (l, Some a) -> conv a (Cont (fun x -> emit (C.Inject (l, x)) d))
  | Rec (Eq, fields, tail) ->
      let rec go acc = function
        | [] -> (
            match tail with
            | None -> emit (C.MkRecord (List.rev acc, None)) d
            | Some t ->
                conv t (Cont (fun x -> emit (C.MkRecord (List.rev acc, Some x)) d)))
        | f :: rest ->
            conv f.fbody (Cont (fun x -> go ((f.flabel, x) :: acc) rest))
      in
      go [] fields
  | Match (scrut, cases) ->
      conv scrut
        (Cont (fun a -> with_join d (fun d' -> conv_match e.loc a cases d')))
  | Select (l, c) -> conv c (Cont (fun x -> emit (C.Select (l, x)) d))
  | Branch (c, arms) ->
      conv c
        (Cont
           (fun ca ->
             with_join d (fun d' ->
                 C.Tail
                   (C.Branch
                      ( ca,
                        List.map (fun (l, x, body) -> (l, x, conv body d')) arms )))))
  | Rec (Colon, _, _) -> no_type e.loc "a record type"
  | VariantTy _ -> no_type e.loc "a variant type"
  | Choice _ -> no_type e.loc "a choice"
  | Arrow _ -> no_type e.loc "a function type"
  | Prod _ -> no_type e.loc "a pair type"
  | Forall _ -> no_type e.loc "a polymorphic type"
  | Refine _ -> no_type e.loc "a refinement type"

(* `fun x y -> e` is `fun x -> fun y -> e`: the machine only knows unary
   functions, which is what makes partial application need no machinery. *)
and curry bs body =
  match bs with
  | [] -> assert false
  | [ b ] -> C.Lam (b.bname, conv body Tail)
  | b :: rest ->
      let inner = C.fresh "f" in
      C.Lam
        ( b.bname,
          C.Let (inner, curry rest body, C.Tail (C.Ret (C.AVar inner))) )

and with_join d f =
  match d with
  | Tail -> f Tail
  | Cont k ->
      let j = C.fresh "j" and v = C.fresh "v" in
      C.Let
        ( j,
          C.Lam (v, k (C.AVar v)),
          f (Cont (fun a -> C.Tail (C.TCall (C.AVar j, a)))) )

and conv_app loc head args d =
  match head.it with
  | Var p when prim_arity p <> None ->
      let n = Option.get (prim_arity p) in
      if List.length args < n then
        Loc.type_error loc "%s wants %d argument%s" p n
          (if n = 1 then "" else "s")
      else
        let taken = List.filteri (fun i _ -> i < n) args in
        let left = List.filteri (fun i _ -> i >= n) args in
        bind_all taken (fun ats ->
            match left with
            | [] -> emit (prim_rhs p ats) d
            | _ ->
                let x = C.fresh "t" in
                C.Let (x, prim_rhs p ats, apply (C.AVar x) left d))
  | _ -> conv head (Cont (fun f -> apply f args d))

and apply f args d =
  match args with
  | [] -> ret d f
  | [ a ] -> (
      conv a
        (Cont
           (fun x ->
             match d with
             | Tail -> C.Tail (C.TCall (f, x))
             | Cont _ -> emit (C.Call (f, x)) d)))
  | a :: rest ->
      conv a
        (Cont
           (fun x ->
             let r = C.fresh "t" in
             C.Let (r, C.Call (f, x), apply (C.AVar r) rest d)))

and bind_all es k =
  let rec go acc = function
    | [] -> k (List.rev acc)
    | e :: rest -> conv e (Cont (fun x -> go (x :: acc) rest))
  in
  go [] es

and conv_let (dcl : Ast.decl) (rest : unit -> C.block) =
  let body = Ast.decl_body dcl in
  match (dcl.drec, dcl.dpat) with
  | true, DName f -> (
      match dcl.dparams with
      | [] ->
          Loc.type_error dcl.dloc
            "`let rec %s` must define a function: there is nothing to recur \
             into otherwise"
            f
      | b :: more ->
          let inner_body =
            match more with
            | [] -> (match dcl.dret with
                     | None -> dcl.dbody
                     | Some r -> Ast.mk dcl.dbody.loc (Ann (dcl.dbody, r)))
            | _ ->
                Ast.mk dcl.dloc
                  (Lam (more,
                        match dcl.dret with
                        | None -> dcl.dbody
                        | Some r -> Ast.mk dcl.dbody.loc (Ann (dcl.dbody, r))))
          in
          C.LetRec (f, b.bname, conv inner_body Tail, rest ()))
  | true, _ ->
      Loc.type_error dcl.dloc "`let rec` binds one name, not a pattern"
  | false, DName x -> conv body (Cont (fun a -> C.Let (x, C.Atom a, rest ())))
  | false, DUnit -> conv body (Cont (fun _ -> rest ()))
  | false, DPair (x, y) ->
      conv body
        (Cont
           (fun a ->
             C.Let
               ( x,
                 C.Prim ("fst", [ a ]),
                 C.Let (y, C.Prim ("snd", [ a ]), rest ()) )))

(* Patterns are compiled here rather than in a pass of their own: variants
   become a [Case], everything else becomes projections.  A variant pattern is
   only allowed at the top of a case, which keeps this a dozen lines instead of
   a decision-tree compiler -- MartenML has that, and this is not what Mink is
   for. *)
and conv_match loc scrut cases d =
  let is_variant (p, _) = match p with PInject _ -> true | _ -> false in
  if List.exists is_variant cases then
    let arms = ref [] and dflt = ref None in
    List.iter
      (fun (p, body) ->
        match p with
        | PInject (l, payload) ->
            let binder, wrap =
              match payload with
              | Some (PVar x) -> (x, fun b -> b)
              | None | Some PWild | Some PUnit -> (C.fresh "p", fun b -> b)
              | Some p ->
                  let x = C.fresh "p" in
                  (x, fun b -> bind_pat (C.AVar x) p b)
            in
            arms :=
              { C.alabel = l; abinder = binder; abody = wrap (conv body d) }
              :: !arms
        | PVar x -> if !dflt = None then dflt := Some (x, conv body d)
        | PWild -> if !dflt = None then dflt := Some (C.fresh "p", conv body d)
        | _ ->
            Loc.type_error loc
              "this pattern mixes a variant match with a structural one; bind \
               the payload to a name and match it separately")
      cases;
    C.Tail (C.Case (scrut, List.rev !arms, !dflt))
  else
    match cases with
    | [ (p, body) ] -> bind_pat scrut p (conv body d)
    | _ ->
        Loc.type_error loc
          "a match on something other than a variant takes exactly one case"

and bind_pat a p body =
  match p with
  | PWild | PUnit -> body
  | PVar x -> C.Let (x, C.Atom a, body)
  | PPair (l, r) ->
      let x = C.fresh "p" and y = C.fresh "p" in
      C.Let
        ( x,
          C.Prim ("fst", [ a ]),
          C.Let (y, C.Prim ("snd", [ a ]), bind_pat (C.AVar x) l (bind_pat (C.AVar y) r body)) )
  | PInject _ -> assert false

(* Entry points. *)

let block_of_term e = conv e Tail
let block_of_decl (d : Ast.decl) = conv (Ast.decl_body d) Tail
