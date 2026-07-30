(* Leaving SSA: phis become copies.

   A phi is not an instruction.  It says "whichever way control arrived, this
   register holds the value that arrived with it", and the way to make that true
   on a machine is to put a copy at the end of each predecessor.  Two things have
   to be got right, and both of them are why this is a pass and not a line of
   code in the emitter.

   *Critical edges.*  A copy placed at the end of a predecessor runs whenever
   that predecessor runs -- including on the way to a different successor.  If
   the predecessor has more than one successor and the target has more than one
   predecessor, there is nowhere on that edge to put anything, so a block is
   inserted to make somewhere.

   *Simultaneity.*  All the phis in a block happen at once, so

     a = phi [b], b = phi [a]

   is a swap, and doing the copies one after another loses a value.  The copies
   for one edge are therefore a *parallel* copy, and sequentialising it means
   emitting the ones whose destination nobody else needs first, and breaking any
   remaining cycle with a temporary.  A cycle can only be a permutation, so one
   temporary per cycle is enough. *)

module M = Mach

let succs (b : M.block) =
  match b.M.term with
  | M.Jmp t -> [ t ]
  | M.Jcc (_, t, e) -> [ t; e ]
  | M.Ret _ | M.TailCall | M.Halt _ -> []

let retarget (b : M.block) ~from_ ~to_ =
  b.M.term <-
    (match b.M.term with
    | M.Jmp t -> M.Jmp (if t = from_ then to_ else t)
    | M.Jcc (c, t, e) ->
        M.Jcc (c, (if t = from_ then to_ else t), if e = from_ then to_ else e)
    | t -> t)

(* Every edge into a block with phis, from a block with more than one exit, gets
   a block of its own to hold that edge's copies. *)
let split_critical (f : M.func) =
  let next = ref (List.fold_left (fun m (b : M.block) -> max m b.M.id) 0 f.M.blocks + 1) in
  let by_id = Hashtbl.create 32 in
  List.iter (fun (b : M.block) -> Hashtbl.replace by_id b.M.id b) f.M.blocks;
  let extra = ref [] in
  List.iter
    (fun (b : M.block) ->
      if b.M.phis <> [] && List.length b.M.preds > 1 then
        b.M.preds <-
          List.map
            (fun p ->
              let pb = Hashtbl.find by_id p in
              if List.length (succs pb) <= 1 then p
              else begin
                let id = !next in
                incr next;
                retarget pb ~from_:b.M.id ~to_:id;
                extra :=
                  { M.id; phis = []; code = []; term = M.Jmp b.M.id; preds = [ p ] } :: !extra;
                (* The phis name their predecessors, so they have to hear about
                   the new one. *)
                b.M.phis <-
                  List.map
                    (fun (d, srcs) ->
                      (d, List.map (fun (q, o) -> if q = p then (id, o) else (q, o)) srcs))
                    b.M.phis;
                id
              end)
            b.M.preds)
    f.M.blocks;
  (* The new blocks go just before their target, which keeps the order readable
     and lets the emitter still fall through most jumps. *)
  if !extra <> [] then
    f.M.blocks <-
      List.concat_map
        (fun (b : M.block) ->
          List.filter (fun (e : M.block) -> e.M.term = M.Jmp b.M.id) !extra @ [ b ])
        f.M.blocks

(* One edge's worth of copies, in an order that does not lose anything. *)
let sequentialise ~fresh (copies : (M.reg * M.operand) list) =
  let copies = List.filter (fun (d, s) -> M.Reg d <> s) copies in
  let pending = ref copies and out = ref [] in
  let reads (d : M.reg) =
    List.exists (fun (_, s) -> match s with M.Reg r -> r = d | _ -> false) !pending
  in
  let progress = ref true in
  while !pending <> [] && !progress do
    progress := false;
    let ready, blocked = List.partition (fun (d, _) -> not (reads d)) !pending in
    if ready <> [] then begin
      progress := true;
      pending := blocked;
      List.iter (fun (d, s) -> out := M.Mov (M.Reg d, s) :: !out) ready
    end
  done;
  (* What is left is a permutation: every destination is still somebody's
     source.  Break one link with a temporary and the rest unravels. *)
  while !pending <> [] do
    match !pending with
    | (d, s) :: rest ->
        let t = fresh () in
        out := M.Mov (M.Reg t, M.Reg d) :: !out;
        pending :=
          List.map (fun (d', s') -> (d', if s' = M.Reg d then M.Reg t else s')) rest;
        out := M.Mov (M.Reg d, s) :: !out;
        let ready, blocked =
          List.partition
            (fun (d', _) ->
              not
                (List.exists
                   (fun (_, s') -> match s' with M.Reg r -> r = d' | _ -> false)
                   !pending))
            !pending
        in
        pending := blocked;
        List.iter (fun (d', s') -> out := M.Mov (M.Reg d', s') :: !out) ready
    | [] -> ()
  done;
  List.rev !out

let func (f : M.func) =
  split_critical f;
  let fresh () =
    let r = M.V f.M.nvreg in
    f.M.nvreg <- f.M.nvreg + 1;
    r
  in
  let by_id = Hashtbl.create 32 in
  List.iter (fun (b : M.block) -> Hashtbl.replace by_id b.M.id b) f.M.blocks;
  List.iter
    (fun (b : M.block) ->
      if b.M.phis <> [] then begin
        List.iter
          (fun p ->
            let copies =
              List.filter_map
                (fun (d, srcs) -> Option.map (fun s -> (d, s)) (List.assoc_opt p srcs))
                b.M.phis
            in
            let pb = Hashtbl.find by_id p in
            (* [code] is reversed, so the copies go on the front. *)
            pb.M.code <- List.rev (sequentialise ~fresh copies) @ pb.M.code)
          b.M.preds;
        b.M.phis <- []
      end)
    f.M.blocks

(* The pressure-aware scheduling pass runs here rather than from the driver,
   because "before out-of-SSA" is the whole of where it goes: it wants the phis
   still standing, so that the copies this pass is about to invent are not
   instructions it can move ([17章](../doc/17-loops.md)).  It is off unless the
   environment turns it on. *)
let program (p : M.prog) =
  Sched.pre p;
  List.iter func p.M.funcs
