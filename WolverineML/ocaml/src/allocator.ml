(* The seam the register allocator is reached through, and what it promises.

   There is one allocator here: leave SSA, build the interference graph, and
   colour it the way Chaitin's algorithm does, with the iterated coalescing that
   eats the copies leaving SSA made.  The Python tree beside this one carries a
   second allocator that colours the SSA itself in dominance order, so that the
   two can be measured against each other; this tree keeps the graph. *)

open Ir

let allocate_module m machine = List.iter (fun f -> Graph.allocate f machine) m.funcs

(* Nothing else live here may hold the colour [written] was just given. *)
let no_clash f alive written where =
  match IntMap.find_opt written f.colours with
  | None -> ()
  | Some colour ->
      IntSet.iter
        (fun other ->
          if other <> written && IntMap.find_opt other f.colours = Some colour then
            failwith
              (Printf.sprintf "x%d holds %%%d and %%%d at once in %s" colour written other
                 where))
        alive

let coloured f r =
  if not (IntMap.mem r f.colours) then failwith (Printf.sprintf "%%%d has no colour" r)

(* No two values that hold different things at once may share a colour.

   The check is made where the interference graph joins values — at each
   definition, and at the top of a block for the phis and the parameters, which
   define several at once.  Looking at a whole live set instead would be wrong,
   not merely slower: both ends of a copy are live after it and hold the same
   value, so they may share a register, and that is the entire point of
   coalescing.  A verifier that rejected it would reject every program the
   coalescer had done its job on.

   Nothing that interferes escapes this, because the later of the two
   definitions that put the values there happens while the other is live. *)
let verify f =
  let live = Liveness.analyse f in
  List.iter
    (fun b ->
      let alive = ref (Liveness.live_out live b.label) in
      List.iter
        (fun instr ->
          (match instr with Move m -> alive := IntSet.remove m.src !alive | _ -> ());
          List.iter (coloured f) (uses instr);
          let d = defs instr in
          if d <> no_reg then begin
            coloured f d;
            alive := IntSet.add d !alive;
            no_clash f !alive d b.label;
            alive := IntSet.remove d !alive
          end;
          alive := IntSet.union !alive (Liveness.of_list (uses instr)))
        (List.rev (instrs b));

      let entering = ref (Liveness.live_in live b.label) in
      List.iter
        (fun phi ->
          coloured f phi.phi_dst;
          entering := IntSet.add phi.phi_dst !entering;
          no_clash f !entering phi.phi_dst b.label)
        b.phis;
      if b.label = f.entry then
        Dynarray.iter
          (fun p ->
            entering := IntSet.add p !entering;
            no_clash f !entering p b.label)
          f.params)
    (walk f)
