(* Dominators, and the check that the SSA really is SSA.

   A block d *dominates* a block b when every path from the entry to b goes
   through d.  The immediate dominator of b is the closest such d other than b
   itself, and those form a tree rooted at the entry.

   The algorithm is the iterative one -- walk the blocks in reverse postorder,
   intersect the predecessors' dominators, repeat until nothing changes.  It is
   not the asymptotically fastest (Lengauer-Tarjan is), but it is a page of
   code, it is fast in practice, and it is the one written to be understood
   (Cooper, Harvey and Kennedy, "A Simple, Fast Dominance Algorithm").

   The famous *use* of dominators is not here.  Cytron et al. place
   phi-functions on dominance frontiers; we never compute a frontier, because
   the phi-functions arrived already placed -- they were the parameters of join
   points.  What the tree is for here is the two things underneath:

     * verification.  Every use of a value has to be dominated by its
       definition.  That is the invariant that makes SSA worth having, and
       since we claim to get it for free, it should be checked rather than
       asserted.
     * register allocation, later: colouring an SSA interference graph walks
       the dominator tree. *)

module S = Ssa

type t = {
  rpo : S.block list; (* reverse postorder: a block after all its dominators *)
  num : (int, int) Hashtbl.t; (* block id -> its position in [rpo] *)
  idom : (int, S.block) Hashtbl.t;
}

let build (f : S.func) =
  let rpo = S.reverse_postorder f in
  let num = Hashtbl.create 16 in
  List.iteri (fun i b -> Hashtbl.replace num b.S.bid i) rpo;
  let idom = Hashtbl.create 16 in
  Hashtbl.replace idom f.S.entry.S.bid f.S.entry;
  let n b = Hashtbl.find num b.S.bid in
  (* Walk up the two chains until they meet.  A block's immediate dominator is
     always earlier in reverse postorder, so "earlier" is the direction of
     progress. *)
  let rec intersect a b =
    if a.S.bid = b.S.bid then a
    else if n a > n b then intersect (Hashtbl.find idom a.S.bid) b
    else intersect a (Hashtbl.find idom b.S.bid)
  in
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter
      (fun b ->
        if b.S.bid <> f.S.entry.S.bid then begin
          let known =
            List.filter
              (fun p -> Hashtbl.mem num p.S.bid && Hashtbl.mem idom p.S.bid)
              b.S.preds
          in
          match known with
          | [] -> ()
          | first :: rest ->
              let d = List.fold_left intersect first rest in
              let old = Hashtbl.find_opt idom b.S.bid in
              if old = None || (Option.get old).S.bid <> d.S.bid then begin
                Hashtbl.replace idom b.S.bid d;
                changed := true
              end
        end)
      rpo
  done;
  { rpo; num; idom }

(* Does [a] dominate [b]?  Walk b up the tree until the entry. *)
let dominates t (a : S.block) (b : S.block) =
  let rec up (x : S.block) =
    if x.S.bid = a.S.bid then true
    else
      match Hashtbl.find_opt t.idom x.S.bid with
      | None -> false
      | Some p -> if p.S.bid = x.S.bid then false else up p
  in
  up b

(* Every use dominated by its definition, and every phi with one argument per
   predecessor.  Returns the complaints; an empty list means the claim in
   ssa.ml holds for this function. *)
let check (f : S.func) =
  let t = build f in
  let bad = ref [] in
  let say fmt = Printf.ksprintf (fun s -> bad := !bad @ [ s ]) fmt in
  (* Where each value sits inside its block, so that a use in the same block
     can be told from a use before the definition. *)
  let pos = Hashtbl.create 64 in
  List.iter
    (fun (b : S.block) ->
      List.iteri (fun i v -> Hashtbl.replace pos v.S.vid (b.S.bid, i)) (b.S.phis @ b.S.values))
    f.S.blocks;
  let ok_at (user : S.block) (at : int) (v : S.value) =
    match Hashtbl.find_opt pos v.S.vid with
    | None -> false
    | Some (db, di) -> if db = user.S.bid then di < at else dominates t v.S.home user
  in
  List.iter
    (fun (b : S.block) ->
      if List.length b.S.preds > 1 || b.S.phis <> [] then
        List.iter
          (fun (p : S.value) ->
            if List.length p.S.args <> List.length b.S.preds then
              say "b%d: phi v%d has %d arguments and the block has %d predecessors"
                b.S.bid p.S.vid (List.length p.S.args) (List.length b.S.preds))
          b.S.phis;
      (* A phi's argument has to reach the end of the matching predecessor, not
         the top of this block. *)
      List.iter
        (fun (p : S.value) ->
          List.iter2
            (fun (pred : S.block) (a : S.value) ->
              if not (ok_at pred max_int a) then
                say "b%d: phi v%d takes v%d from b%d, which does not reach it"
                  b.S.bid p.S.vid a.S.vid pred.S.bid)
            (if List.length p.S.args = List.length b.S.preds then b.S.preds else [])
            (if List.length p.S.args = List.length b.S.preds then p.S.args else []))
        b.S.phis;
      List.iteri
        (fun i (v : S.value) ->
          List.iter
            (fun (a : S.value) ->
              if not (ok_at b (List.length b.S.phis + i) a) then
                say "b%d: v%d uses v%d, which does not dominate it" b.S.bid v.S.vid a.S.vid)
            v.S.args)
        b.S.values;
      let term_uses =
        match b.S.term with
        | S.Ret v | S.Switch (v, _, _) -> [ v ]
        | S.TailCall (x, y) -> [ x; y ]
        | S.Jump _ | S.Fail _ -> []
      in
      List.iter
        (fun (a : S.value) ->
          if not (ok_at b max_int a) then
            say "b%d: the terminator uses v%d, which does not dominate it" b.S.bid a.S.vid)
        term_uses)
    f.S.blocks;
  !bad

let check_prog (p : S.prog) =
  List.concat_map
    (fun (f : S.func) -> List.map (fun m -> f.S.fn ^ ": " ^ m) (check f))
    (p.S.funcs @ List.filter_map (fun (i : S.item) -> i.S.ibody) p.S.items)
