(* Compiling pattern matching to a decision tree.

   The input is a `case` with source patterns: nested, overlapping, possibly
   not covering everything.  The output tests each part of the value at most
   once, in an order it chooses, and jumps to the arm that won.

   The algorithm is Maranget's matrix one.  State is a matrix of patterns and a
   vector of *occurrences* -- the sub-values of the scrutinee the columns are
   about.  At every step:

     - no rows left            the match can fail here
     - the first row is all _  that row wins; jump to its arm
     - otherwise               pick a column, look at the constructors in it,
                               and build one branch per constructor, each with
                               a smaller matrix

   Two facts about the language decide the shape of the code.  A tuple or a
   record has exactly one shape, so its column is *expanded* into one column
   per component and no test is emitted.  A datatype's column becomes a switch,
   and whether it needs a default depends on whether every constructor is
   there -- which is a question the type answers, and the reason this pass runs
   on typed Core rather than after the types are thrown away.

   The output is where join points come from.  A decision tree reaches the same
   arm from several leaves -- `case xs of (_, []) => e | ([], _) => e | ...`
   duplicates paths, not by accident but because that is what sharing tests
   costs.  An arm reached more than once becomes a join point and the leaves
   jump to it; an arm reached once is inlined, so a dump shows a `join` exactly
   where something is shared.

   Exhaustiveness and redundancy fall out of the tree and need no separate
   analysis: a reachable failure means the match is not exhaustive, and an arm
   with no leaf at all is an arm nothing can reach. *)

open Types
module C = Core

type row = {
  rpats : C.pat list;
  rbind : (string * C.atom * ty) list;
  rarm : int;
}

type tree =
  | TFail
  | TLeaf of int * (string * C.atom * ty) list
  | TBind of string * ty * C.rhs * tree
  | TSwitch of C.atom * (C.key * tree) list * tree option

(* The variables a pattern binds, in the order the elaborator made them.  The
   join point's parameters are in this order and so are a leaf's arguments. *)
let rec binders (p : C.pat) =
  match p with
  | C.PAny None | C.PInt _ | C.PStr _ | C.PCon (_, None) -> []
  | C.PAny (Some x) -> [ x ]
  | C.PAs (x, q) -> x :: binders q
  | C.PCon (_, Some q) -> binders q
  | C.PTup ps -> List.concat_map binders ps
  | C.PRec fs -> List.concat_map (fun (_, q) -> binders q) fs

(* ... and their types, read off the type of the value they match against. *)
let rec binder_types ty (p : C.pat) =
  match p with
  | C.PAny None | C.PInt _ | C.PStr _ | C.PCon (_, None) -> []
  | C.PAny (Some x) -> [ (x, ty) ]
  | C.PAs (x, q) -> (x, ty) :: binder_types ty q
  | C.PCon (c, Some q) -> (
      match repr ty with
      | Tcon (_, args) -> (
          match con_arg c args with Some at -> binder_types at q | None -> [])
      | _ -> [])
  | C.PTup ps -> (
      match repr ty with
      | Ttuple ts -> List.concat (List.map2 binder_types ts ps)
      | _ -> [])
  | C.PRec fs -> (
      match repr ty with
      | Trecord tfs ->
          List.concat_map
            (fun (l, q) ->
              match List.assoc_opt l tfs with
              | Some t -> binder_types t q
              | None -> [])
            fs
      | _ -> [])

(* Move variable and `as` patterns out of the matrix: they always match, and
   what they contribute is a binding. *)
let rec strip occ ty p binds =
  match p with
  | C.PAny (Some x) -> (C.PAny None, (x, occ, ty) :: binds)
  | C.PAs (x, q) -> strip occ ty q ((x, occ, ty) :: binds)
  | _ -> (p, binds)

let simplify occs row =
  let binds = ref row.rbind in
  let pats =
    List.map2
      (fun (occ, ty) p ->
        let p, b = strip occ ty p !binds in
        binds := b;
        p)
      occs row.rpats
  in
  { row with rpats = pats; rbind = !binds }

let is_wild = function C.PAny None -> true | _ -> false

let swap i xs =
  if i = 0 then xs
  else
    let a = List.nth xs 0 and b = List.nth xs i in
    List.mapi (fun j x -> if j = 0 then b else if j = i then a else x) xs

let key_of = function
  | C.PCon (c, _) -> Some (C.Ktag c)
  | C.PInt n -> Some (C.Kint n)
  | C.PStr s -> Some (C.Kstr s)
  | _ -> None

let same_key a b =
  match (a, b) with
  | C.Ktag c1, C.Ktag c2 -> c1.cidx = c2.cidx && c1.cres.tid = c2.cres.tid
  | C.Kint a, C.Kint b -> a = b
  | C.Kstr a, C.Kstr b -> a = b
  | _ -> false

let rec build (occs : (C.atom * ty) list) (rows : row list) : tree =
  let rows = List.map (simplify occs) rows in
  match rows with
  | [] -> TFail
  | row0 :: _ when List.for_all is_wild row0.rpats -> TLeaf (row0.rarm, row0.rbind)
  | row0 :: _ ->
      (* The leftmost column the first row actually tests.  Choosing it means
         the first row is one step closer to winning, so the recursion ends. *)
      let i =
        let rec find j = function
          | [] -> 0
          | p :: rest -> if is_wild p then find (j + 1) rest else j
        in
        find 0 row0.rpats
      in
      let occs = swap i occs and rows = List.map (fun r -> { r with rpats = swap i r.rpats }) rows in
      let occ, oty = List.hd occs and rest_occs = List.tl occs in
      let head = List.hd (List.hd rows).rpats in
      let tails r = List.tl r.rpats in
      (match head with
      | C.PTup ps ->
          (* One shape, so no test: bind the components and widen the matrix. *)
          let n = List.length ps in
          let tys = match repr oty with Ttuple ts -> ts | _ -> List.map (fun _ -> newvar ()) ps in
          let names = List.map (fun _ -> C.fresh_name "p") ps in
          let subs = List.map2 (fun x t -> (C.AVar x, t)) names tys in
          let rows' =
            List.map
              (fun r ->
                let cols =
                  match List.hd r.rpats with
                  | C.PTup qs -> qs
                  | C.PAny None -> List.init n (fun _ -> C.PAny None)
                  | _ -> assert false
                in
                { r with rpats = cols @ tails r })
              rows
          in
          let inner = build (subs @ rest_occs) rows' in
          List.fold_right2
            (fun x (i, t) acc -> TBind (x, t, C.Proj (occ, i), acc))
            names
            (List.mapi (fun i t -> (i, t)) tys)
            inner
      | C.PRec fs ->
          let labels = List.map fst fs in
          let tys =
            List.map
              (fun l ->
                match repr oty with
                | Trecord tfs -> ( match List.assoc_opt l tfs with Some t -> t | None -> newvar ())
                | _ -> newvar ())
              labels
          in
          let names = List.map (fun l -> C.fresh_name l) labels in
          let subs = List.map2 (fun x t -> (C.AVar x, t)) names tys in
          let rows' =
            List.map
              (fun r ->
                let cols =
                  match List.hd r.rpats with
                  | C.PRec qs -> List.map snd qs
                  | C.PAny None -> List.map (fun _ -> C.PAny None) labels
                  | _ -> assert false
                in
                { r with rpats = cols @ tails r })
              rows
          in
          let inner = build (subs @ rest_occs) rows' in
          List.fold_right2
            (fun x (l, t) acc -> TBind (x, t, C.Field (occ, l), acc))
            names
            (List.map2 (fun l t -> (l, t)) labels tys)
            inner
      | _ ->
          (* A real test.  The keys are taken in the order they first appear,
             so the switch reads like the source. *)
          let keys = ref [] in
          List.iter
            (fun r ->
              match key_of (List.hd r.rpats) with
              | Some k when not (List.exists (same_key k) !keys) -> keys := !keys @ [ k ]
              | _ -> ())
            rows;
          let branch k =
            let rows' =
              List.filter_map
                (fun r ->
                  match List.hd r.rpats with
                  | C.PAny None -> Some (None, r)
                  | p when (match key_of p with Some k' -> same_key k k' | None -> false) ->
                      Some ((match p with C.PCon (_, sub) -> sub | _ -> None), r)
                  | _ -> None)
                rows
            in
            match k with
            | C.Ktag c -> (
                match con_arg c (match repr oty with Tcon (_, args) -> args | _ -> []) with
                | None ->
                    (k, build rest_occs (List.map (fun (_, r) -> { r with rpats = tails r }) rows'))
                | Some at ->
                    let x = C.fresh_name "arg" in
                    let rows'' =
                      List.map
                        (fun (sub, r) ->
                          let col = match sub with Some p -> p | None -> C.PAny None in
                          { r with rpats = col :: tails r })
                        rows'
                    in
                    ( k,
                      TBind
                        ( x,
                          at,
                          C.Payload occ,
                          build ((C.AVar x, at) :: rest_occs) rows'' ) ))
            | _ -> (k, build rest_occs (List.map (fun (_, r) -> { r with rpats = tails r }) rows'))
          in
          let branches = List.map branch !keys in
          (* Is every case covered?  Only a datatype can answer yes. *)
          let complete =
            match (head, repr oty) with
            | C.PCon _, Tcon (tc, _) ->
                tc.tcons <> [] && List.length !keys = List.length tc.tcons
            | _ -> false
          in
          let default =
            if complete then None
            else
              Some
                (build rest_occs
                   (List.filter_map
                      (fun r ->
                        if is_wild (List.hd r.rpats) then Some { r with rpats = tails r }
                        else None)
                      rows))
          in
          TSwitch (occ, branches, default))

(* Counting what the tree reaches, so that an arm used twice becomes a label
   and an arm used once is written where it is needed. *)
let rec count uses = function
  | TFail -> ()
  | TLeaf (k, _) -> uses.(k) <- uses.(k) + 1
  | TBind (_, _, _, t) -> count uses t
  | TSwitch (_, bs, d) ->
      List.iter (fun (_, t) -> count uses t) bs;
      Option.iter (count uses) d

let rec reaches_fail = function
  | TFail -> true
  | TLeaf _ -> false
  | TBind (_, _, _, t) -> reaches_fail t
  | TSwitch (_, bs, d) ->
      List.exists (fun (_, t) -> reaches_fail t) bs
      || (match d with Some t -> reaches_fail t | None -> false)

let rec compile_block (b : C.block) : C.block =
  match b with
  | C.Let (x, t, rhs, rest) -> C.Let (x, t, compile_rhs rhs, compile_block rest)
  | C.Fix (defs, rest) ->
      C.Fix
        ( List.map (fun (x, t, r) -> (x, t, compile_rhs r)) defs,
          compile_block rest )
  | C.Join (j, ps, body, rest) -> C.Join (j, ps, compile_block body, compile_block rest)
  | C.Tail t -> compile_tail t

and compile_rhs = function
  | C.Lam (x, t, body) -> C.Lam (x, t, compile_block body)
  | r -> r

and compile_tail = function
  | C.Case (a, ty, arms, loc) ->
      let arms = List.map (fun arm -> { arm with C.abody = compile_block arm.C.abody }) arms in
      compile_case a ty arms loc
  | t -> C.Tail t

and compile_case scrut ty arms loc =
  let rows =
    List.mapi (fun k arm -> { rpats = [ arm.C.apat ]; rbind = []; rarm = k }) arms
  in
  let tree = build [ (scrut, ty) ] rows in
  let n = List.length arms in
  let uses = Array.make n 0 in
  count uses tree;
  List.iteri
    (fun k arm ->
      if uses.(k) = 0 then
        Loc.warn loc "this pattern can never match: %s" (C.pat_str arm.C.apat))
    arms;
  if reaches_fail tree then
    Loc.warn loc "this match does not cover every case";
  (* An arm reached more than once gets a label; the others are written out. *)
  let joins =
    List.mapi
      (fun k arm ->
        if uses.(k) > 1 then
          Some (k, C.fresh_name "arm", binder_types ty arm.C.apat, arm.C.abody)
        else None)
      arms
    |> List.filter_map Fun.id
  in
  let arm_binders = List.map (fun arm -> binders arm.C.apat) arms in
  let rec emit = function
    | TFail -> C.Tail (C.Fail (loc, "no pattern matched"))
    | TBind (x, t, rhs, rest) -> C.Let (x, t, rhs, emit rest)
    | TSwitch (a, bs, d) ->
        C.Tail
          (C.Switch (a, List.map (fun (k, t) -> (k, emit t)) bs, Option.map emit d))
    | TLeaf (k, binds) -> (
        let names = List.nth arm_binders k in
        let arg name =
          match List.find_opt (fun (n, _, _) -> n = name) binds with
          | Some (_, a, t) -> (a, t)
          | None -> assert false
        in
        match List.find_opt (fun (k', _, _, _) -> k' = k) joins with
        | Some (_, j, _, _) -> C.Tail (C.Jump (j, List.map (fun n -> fst (arg n)) names))
        | None ->
            let body = (List.nth arms k).C.abody in
            List.fold_right
              (fun n rest ->
                let a, t = arg n in
                C.Let (n, t, C.Atom a, rest))
              names body)
  in
  List.fold_left
    (fun rest (_, j, ps, body) -> C.Join (j, ps, body, rest))
    (emit tree) (List.rev joins)

let program (items : C.item list) =
  List.map
    (fun (i : C.item) -> { i with C.ibody = Option.map compile_block i.C.ibody })
    items
