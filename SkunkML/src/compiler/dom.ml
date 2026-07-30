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

(* The dominance frontier of [b]: the blocks b reaches but does not dominate.
   Cytron's rule is one loop -- for every block j with more than one
   predecessor, walk up from each predecessor to j's immediate dominator,
   adding j on the way, because those are exactly the blocks that reach j
   without owning it.

   We do not use it for what it is for.  Cytron et al. place a phi-function for
   a variable at the iterated frontier of the blocks that define it; here the
   phi-functions arrived with the join points.  What it is used for is checking
   that claim: `frontier_ok` asks whether every block that has phis is in the
   frontier of each of its predecessors, which is where the algorithm would
   have put them. *)
let frontier t (f : S.func) =
  let df = Hashtbl.create 16 in
  let addf b j =
    let old = try Hashtbl.find df b.S.bid with Not_found -> [] in
    if not (List.exists (fun (x : S.block) -> x.S.bid = j.S.bid) old) then
      Hashtbl.replace df b.S.bid (old @ [ j ])
  in
  List.iter
    (fun (j : S.block) ->
      if List.length j.S.preds > 1 then
        List.iter
          (fun (p : S.block) ->
            let stop = Hashtbl.find_opt t.idom j.S.bid in
            let rec up (r : S.block) =
              match stop with
              | Some d when r.S.bid = d.S.bid -> ()
              | _ ->
                  addf r j;
                  (match Hashtbl.find_opt t.idom r.S.bid with
                  | Some parent when parent.S.bid <> r.S.bid -> up parent
                  | _ -> ())
            in
            up p)
          j.S.preds)
    f.S.blocks;
  df

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

(* Every block that carries phi-functions should be in the dominance frontier
   of each of its predecessors: that is where Cytron's algorithm would have put
   them, and the join points put them there without being asked. *)
(* Cytron's rule places a phi at j when j is in the dominance frontier of a block
   that *defines* the variable.  For a join point every predecessor defines it, so
   the claim can be made about each one separately, and that is the strong form
   worth checking: a join point puts its phis exactly where the algorithm would.

   A loop header is the other case.  Its two definitions are the one before the
   loop and the one on the back edge, and the header is in the frontier of the
   latch but not of the block before the loop -- pre-headers dominate their
   headers.  So for a header the honest claim is the weaker one: some predecessor
   justifies it. *)
let frontier_ok (f : S.func) =
  let t = build f in
  let df = frontier t f in
  let bad = ref [] in
  let in_frontier (p : S.block) (b : S.block) =
    let fr = try Hashtbl.find df p.S.bid with Not_found -> [] in
    List.exists (fun (x : S.block) -> x.S.bid = b.S.bid) fr
  in
  List.iter
    (fun (b : S.block) ->
      if b.S.phis <> [] then
        if List.exists (fun (p : S.block) -> dominates t b p) b.S.preds then begin
          (* A loop header. *)
          if not (List.exists (fun p -> in_frontier p b) b.S.preds) then
            bad :=
              !bad
              @ [ Printf.sprintf "b%d has phis but is in no predecessor's frontier" b.S.bid ]
        end
        else
          List.iter
            (fun (p : S.block) ->
              if not (in_frontier p b) then
                bad :=
                  !bad
                  @ [ Printf.sprintf "b%d has phis but is not in the frontier of b%d" b.S.bid
                        p.S.bid ])
            b.S.preds)
    f.S.blocks;
  !bad

(* What `--dump-dom` prints. *)
let to_string (f : S.func) =
  let t = build f in
  let df = frontier t f in
  let out = Buffer.create 256 in
  let add = Buffer.add_string in
  add out (Printf.sprintf "func %s:\n" f.S.fn);
  add out
    (Printf.sprintf "  reverse postorder  %s\n"
       (String.concat " " (List.map (fun (b : S.block) -> Printf.sprintf "b%d" b.S.bid) t.rpo)));
  List.iter
    (fun (b : S.block) ->
      let idom =
        match Hashtbl.find_opt t.idom b.S.bid with
        | Some d when d.S.bid <> b.S.bid -> Printf.sprintf "b%d" d.S.bid
        | _ -> "-"
      in
      let fr = try Hashtbl.find df b.S.bid with Not_found -> [] in
      add out
        (Printf.sprintf "  b%-4s idom %-5s frontier { %s }%s\n"
           (Printf.sprintf "%d" b.S.bid)
           idom
           (String.concat " " (List.map (fun (x : S.block) -> Printf.sprintf "b%d" x.S.bid) fr))
           (if b.S.phis = [] then "" else Printf.sprintf "   %d phi" (List.length b.S.phis))))
    t.rpo;
  Buffer.contents out

let all_funcs (p : S.prog) =
  p.S.funcs @ List.filter_map (fun (i : S.item) -> i.S.ibody) p.S.items

let check_prog (p : S.prog) =
  List.concat_map
    (fun (f : S.func) ->
      List.map (fun m -> f.S.fn ^ ": " ^ m) (check f @ frontier_ok f))
    (all_funcs p)
