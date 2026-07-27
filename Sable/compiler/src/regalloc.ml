(* Register allocation by graph colouring, with iterated coalescing.

   The idea is Chaitin's: build a graph whose nodes are registers and whose
   edges join values that are live at the same time, then colour it with as
   many colours as the machine has registers.  Two values joined by an edge
   cannot share a register; two values that are not joined can.

   Colouring a graph is hard in general, but Kempe's observation makes it
   practical: a node with fewer than K neighbours can always be coloured, no
   matter what happens to the rest of the graph.  So repeatedly remove such a
   node and push it on a stack; when the graph is empty, pop the stack and give
   each node a colour its neighbours have not taken.  If at some point every
   remaining node has K or more neighbours, pick one, guess that it will not get
   a colour, and carry on -- if the guess was wrong the value is rewritten to
   live in memory and the whole thing runs again.

   On top of that sits coalescing, which is what earns this allocator its keep
   here.  Instruction selection emits a `mv` for every argument, every result
   and every callee-saved register; coalescing merges the two ends of such a
   move when doing so is safe, and the move disappears.  Merging aggressively
   can make a graph uncolourable, so a merge only happens when Briggs' or
   George's test proves it cannot: hence "iterated" coalescing, which
   interleaves simplification, coalescing and freezing (giving up on a move so
   that its nodes can be simplified) until nothing is left.

   The formulation followed here is Appel's, in Modern Compiler Implementation,
   chapter 11.  Physical registers are pre-coloured nodes of infinite degree,
   which is what makes the calling convention fall out of the same machinery:
   the argument registers, the caller-saved registers a call destroys, and the
   callee-saved registers a function must preserve are all just edges. *)

module RegSet = Liveness.RegSet

type report = {
  mutable rounds : int;
  mutable moves_total : int;
  mutable moves_coalesced : int;
  mutable spill_slots : int;
  mutable spilled : string list;
}

let no_report () =
  { rounds = 0; moves_total = 0; moves_coalesced = 0; spill_slots = 0; spilled = [] }

let pick set = Bitset.min_elt set

let allocate ?(report = no_report ()) (func : Riscv.func) =
  let num_colors = Riscv.num_colors () in
  let colours = !Riscv.allocatable in
  (* Temporaries introduced to hold a spilled value are never spilled again:
     their live range is a single instruction, and spilling them would not
     terminate. *)
  let never_spill = Hashtbl.create 16 in
  let fresh_reg () =
    let r = func.Riscv.num_regs in
    func.Riscv.num_regs <- r + 1;
    Hashtbl.replace never_spill r ();
    r
  in

  let rec round () =
    report.rounds <- report.rounds + 1;
    if report.rounds > 32 then
      failwith "Regalloc: allocation failed to converge (this is a compiler bug)";
    let n = func.Riscv.num_regs in
    let precoloured r = r < Riscv.num_physical in

    (* ------------------------------------------------------- the graph *)
    (* One row of bits per node, holding that node's neighbours.  The row is
       filled in both directions whatever the nodes are, so it answers "do
       these two interfere?" as well as "who are your neighbours?" -- the
       adjacency used to be a separate Hashtbl keyed on the pair.  Only the
       rows of nodes that get simplified are ever iterated, so the rows
       belonging to machine registers cost their bits and nothing else.

       This is n * n bits: 184 kB for the largest function in the examples,
       and quadratic in the size of a function.  A hash table of the edges
       would be smaller on a sparse graph, but these graphs are not sparse --
       a value live across a call interferes with every caller-saved register
       at once -- and it was slower on every function measured. *)
    let interfere = Array.init n (fun _ -> Bitset.create n) in
    let degree = Array.make n 0 in
    let alias = Array.init n (fun i -> i) in
    let colour = Array.make n (-1) in
    let uses_and_defs = Array.make n 0 in
    Array.iter
      (fun r ->
        colour.(r) <- r;
        degree.(r) <- max_int)
      colours;

    let interferes u v = Bitset.mem interfere.(u) v in
    let add_edge u v =
      if u <> v && not (interferes u v) then begin
        Bitset.add interfere.(u) v;
        Bitset.add interfere.(v) u;
        if not (precoloured u) then degree.(u) <- degree.(u) + 1;
        if not (precoloured v) then degree.(v) <- degree.(v) + 1
      end
    in

    (* --------------------------------------------------- the worklists *)
    (* How many moves there will be, so that the sets of them can be sized
       before the walk that finds them. *)
    let move_capacity =
      List.fold_left
        (fun acc (b : Riscv.block) ->
          List.fold_left
            (fun acc i -> if Riscv.move_pair i <> None then acc + 1 else acc)
            acc b.body)
        0 func.Riscv.blocks
    in
    let moves = ref [] and num_moves = ref 0 in
    let move_list = Array.init n (fun _ -> Bitset.create move_capacity) in
    let simplify_worklist = Bitset.create n in
    let freeze_worklist = Bitset.create n in
    let spill_worklist = Bitset.create n in
    let spilled_nodes = Bitset.create n in
    (* These three are only ever asked "is this node in you?", so they are
       plain boolean arrays: a bitset would answer the same question with more
       arithmetic and no fewer cache misses. *)
    let coalesced = Array.make n false in
    let coloured = Array.make n false in
    let stacked = Array.make n false in
    let select_stack = ref [] in
    (* Appel keeps a move in exactly one of five sets, which makes the
       invariant easy to state.  Only two of them are ever consulted here --
       node_moves asks whether a move is still live, and a move is live exactly
       when it is waiting or merely paused -- so the other three would be state
       nothing reads.  What became of a move is recorded as a count instead. *)
    let worklist_moves = Bitset.create move_capacity in
    let active_moves = Bitset.create move_capacity in
    let coalesced_count = ref 0 in

    let record_move dst src =
      let m = !num_moves in
      incr num_moves;
      moves := (dst, src) :: !moves;
      Bitset.add move_list.(dst) m;
      Bitset.add move_list.(src) m;
      Bitset.add worklist_moves m
    in

    (* Walk each block backwards from its live-out set, adding an edge between
       every register being defined and everything live at that point.  A move
       is the one exception: `mv d, s` does not make d and s interfere, which is
       precisely what leaves them free to be coalesced. *)
    let live_out = Liveness.analyze func in
    let live = Bitset.create n in
    List.iter
      (fun (b : Riscv.block) ->
        Bitset.clear live;
        RegSet.iter (Bitset.add live) (Hashtbl.find live_out b.label);
        List.iter (Bitset.add live) (Riscv.terminator_uses b.terminator);
        List.iter
          (fun instr ->
            (match Riscv.move_pair instr with
             | Some (dst, src) ->
               Bitset.remove live src;
               record_move dst src
             | None -> ());
            let defs = Riscv.defines instr and uses = Riscv.uses instr in
            List.iter (Bitset.add live) defs;
            List.iter (fun d -> Bitset.iter (fun l -> add_edge l d) live) defs;
            List.iter (Bitset.remove live) defs;
            List.iter (Bitset.add live) uses;
            List.iter (fun r -> uses_and_defs.(r) <- uses_and_defs.(r) + 1) (defs @ uses))
          (List.rev b.body))
      func.Riscv.blocks;
    let moves = Array.of_list (List.rev !moves) in

    (* ------------------------------------------------------- primitives *)
    (* The neighbours still in the graph, and the moves still live.  Both used
       to build a set and hand it back; now they walk the row and skip, which
       is the same order and allocates nothing.  Nothing below mutates the row
       it is walking: add_edge only ever touches the two nodes named, and
       neither is the one being iterated. *)
    let iter_adjacent node f =
      Bitset.iter (fun r -> if not (stacked.(r) || coalesced.(r)) then f r) interfere.(node)
    in
    let iter_node_moves node f =
      Bitset.iter
        (fun m -> if Bitset.mem active_moves m || Bitset.mem worklist_moves m then f m)
        move_list.(node)
    in
    let move_related node =
      Bitset.exists
        (fun m -> Bitset.mem active_moves m || Bitset.mem worklist_moves m)
        move_list.(node)
    in
    let rec alias_of node = if coalesced.(node) then alias_of alias.(node) else node in
    let enable_move node =
      iter_node_moves node (fun m ->
          if Bitset.mem active_moves m then begin
            Bitset.remove active_moves m;
            Bitset.add worklist_moves m
          end)
    in
    let decrement_degree node =
      if not (precoloured node) then begin
        let d = degree.(node) in
        degree.(node) <- d - 1;
        if d = num_colors then begin
          (* The node just became trivially colourable, so moves involving it
             are worth reconsidering. *)
          enable_move node;
          iter_adjacent node enable_move;
          Bitset.remove spill_worklist node;
          if move_related node then Bitset.add freeze_worklist node
          else Bitset.add simplify_worklist node
        end
      end
    in
    let make_worklists () =
      for node = Riscv.num_physical to n - 1 do
        if degree.(node) >= num_colors then Bitset.add spill_worklist node
        else if move_related node then Bitset.add freeze_worklist node
        else Bitset.add simplify_worklist node
      done
    in

    let simplify () =
      let node = pick simplify_worklist in
      Bitset.remove simplify_worklist node;
      select_stack := node :: !select_stack;
      stacked.(node) <- true;
      iter_adjacent node decrement_degree
    in

    let add_to_worklist node =
      if (not (precoloured node)) && (not (move_related node))
         && degree.(node) < num_colors
      then begin
        Bitset.remove freeze_worklist node;
        Bitset.add simplify_worklist node
      end
    in
    (* George: merging into the pre-coloured [r] is safe if every neighbour of
       the other node already interferes with r or is insignificant. *)
    let george r node =
      not
        (Bitset.exists
           (fun t ->
             (not (stacked.(t) || coalesced.(t)))
             && not (degree.(t) < num_colors || precoloured t || interferes t r))
           interfere.(node))
    in
    (* Briggs: merging is safe if the merged node has fewer than K neighbours
       of significant degree.  The union is built in a scratch row that is
       reused, so the test costs no allocation. *)
    let scratch = Bitset.create n in
    let briggs u v =
      Bitset.clear scratch;
      iter_adjacent u (Bitset.add scratch);
      iter_adjacent v (Bitset.add scratch);
      Bitset.count (fun t -> degree.(t) >= num_colors) scratch < num_colors
    in
    let combine u v =
      if Bitset.mem freeze_worklist v then Bitset.remove freeze_worklist v
      else Bitset.remove spill_worklist v;
      coalesced.(v) <- true;
      alias.(v) <- u;
      Bitset.union_into move_list.(u) move_list.(v);
      enable_move v;
      iter_adjacent v (fun t ->
          add_edge t u;
          decrement_degree t);
      if degree.(u) >= num_colors && Bitset.mem freeze_worklist u then begin
        Bitset.remove freeze_worklist u;
        Bitset.add spill_worklist u
      end
    in
    let coalesce () =
      let m = pick worklist_moves in
      Bitset.remove worklist_moves m;
      let dst, src = moves.(m) in
      let x = alias_of dst and y = alias_of src in
      let u, v = if precoloured y then (y, x) else (x, y) in
      if u = v then begin
        incr coalesced_count;
        add_to_worklist u
      end
      else if precoloured v || interferes u v then begin
        (* The two ends are live at the same time, or both are machine
           registers: this move has to stay. *)
        add_to_worklist u;
        add_to_worklist v
      end
      else if
        (precoloured u && george u v) || ((not (precoloured u)) && briggs u v)
      then begin
        incr coalesced_count;
        combine u v;
        add_to_worklist u
      end
      else Bitset.add active_moves m
    in

    let freeze_moves u =
      iter_node_moves u (fun m ->
          let dst, src = moves.(m) in
          let v = if alias_of src = alias_of u then alias_of dst else alias_of src in
          (* Dropping it from both sets is what freezing a move amounts to:
             node_moves stops seeing it, so its ends are ordinary again. *)
          Bitset.remove active_moves m;
          if (not (move_related v)) && degree.(v) < num_colors then begin
            Bitset.remove freeze_worklist v;
            Bitset.add simplify_worklist v
          end)
    in
    let freeze () =
      let node = pick freeze_worklist in
      Bitset.remove freeze_worklist node;
      Bitset.add simplify_worklist node;
      freeze_moves node
    in

    (* Spill the value that is used least and interferes most: it occupies a
       register for a long time without earning it.  Every basic block weighs
       the same here, which is exact for these graphs -- they are acyclic, so
       there is no loop nesting to account for. *)
    let select_spill () =
      let cost node =
        if Hashtbl.mem never_spill node then infinity
        else float_of_int uses_and_defs.(node) /. float_of_int (max 1 degree.(node))
      in
      let node =
        Bitset.fold
          (fun candidate best ->
            match best with
            | Some b when cost b <= cost candidate -> best
            | _ -> Some candidate)
          spill_worklist None
        |> Option.get
      in
      Bitset.remove spill_worklist node;
      Bitset.add simplify_worklist node;
      freeze_moves node
    in

    let assign_colours () =
      (* There are at most 25 colours, so the set of the ones still free is a
         row of its own rather than anything cleverer. *)
      let available = Bitset.create Riscv.num_physical in
      List.iter
        (fun node ->
          Bitset.clear available;
          Array.iter (Bitset.add available) colours;
          Bitset.iter
            (fun w ->
              let w = alias_of w in
              if coloured.(w) || precoloured w then Bitset.remove available colour.(w))
            interfere.(node);
          if Bitset.is_empty available then Bitset.add spilled_nodes node
          else begin
            coloured.(node) <- true;
            colour.(node) <- pick available
          end)
        !select_stack;
      for node = 0 to n - 1 do
        if coalesced.(node) then colour.(node) <- colour.(alias_of node)
      done
    in

    make_worklists ();
    let rec work () =
      if not (Bitset.is_empty simplify_worklist) then (simplify (); work ())
      else if not (Bitset.is_empty worklist_moves) then (coalesce (); work ())
      else if not (Bitset.is_empty freeze_worklist) then (freeze (); work ())
      else if not (Bitset.is_empty spill_worklist) then (select_spill (); work ())
    in
    work ();
    assign_colours ();

    if Bitset.is_empty spilled_nodes then begin
      (* Only the round that succeeded describes the code that came out; the
         earlier rounds were thrown away along with their moves. *)
      report.moves_total <- Array.length moves;
      report.moves_coalesced <- !coalesced_count;
      apply_colours colour
    end
    else begin
      rewrite spilled_nodes;
      round ()
    end

  (* Give every spilled value a stack slot, and reduce its live range to the
     single instruction that touches it by loading just before and storing just
     after.  The new temporaries are trivial to colour, so the next round is
     strictly closer to done. *)
  and rewrite spilled =
    let slots = Hashtbl.create 8 in
    Bitset.iter
      (fun r ->
        Hashtbl.replace slots r func.Riscv.num_spill_slots;
        func.Riscv.num_spill_slots <- func.Riscv.num_spill_slots + 1;
        report.spilled <- Riscv.name_of_reg r :: report.spilled)
      spilled;
    let offset r = Hashtbl.find slots r * 8 in
    let touched regs =
      List.sort_uniq compare (List.filter (fun r -> Bitset.mem spilled r) regs)
    in
    (* One temporary per spilled register per instruction, whether the
       instruction reads it, writes it, or both. *)
    let temps_for reads writes =
      let table = Hashtbl.create 4 in
      List.iter
        (fun r -> if not (Hashtbl.mem table r) then Hashtbl.replace table r (fresh_reg ()))
        (reads @ writes);
      table
    in
    List.iter
      (fun (b : Riscv.block) ->
        let body =
          List.concat_map
            (fun instr ->
              let reads = touched (Riscv.uses instr) in
              let writes = touched (Riscv.defines instr) in
              if reads = [] && writes = [] then [ instr ]
              else begin
                let temps = temps_for reads writes in
                let substitute r =
                  match Hashtbl.find_opt temps r with Some t -> t | None -> r
                in
                let loads =
                  List.map (fun r -> Riscv.Load (substitute r, Riscv.sp, offset r)) reads
                in
                let stores =
                  List.map (fun r -> Riscv.Store (substitute r, Riscv.sp, offset r)) writes
                in
                loads
                @ [ Riscv.map_regs ~use:substitute ~def:substitute instr ]
                @ stores
              end)
            b.body
        in
        let reads = touched (Riscv.terminator_uses b.terminator) in
        let temps = temps_for reads [] in
        let substitute r =
          match Hashtbl.find_opt temps r with Some t -> t | None -> r
        in
        b.terminator <- Riscv.map_terminator_regs ~use:substitute b.terminator;
        b.body <-
          body @ List.map (fun r -> Riscv.Load (substitute r, Riscv.sp, offset r)) reads)
      func.Riscv.blocks

  (* Replace every virtual register by the machine register it was given, and
     drop the moves that have become `mv x, x`. *)
  and apply_colours colour =
    let recolour r = if Riscv.is_virtual r then colour.(r) else r in
    List.iter
      (fun (b : Riscv.block) ->
        b.body <-
          List.filter_map
            (fun instr ->
              let instr = Riscv.map_regs ~use:recolour ~def:recolour instr in
              match instr with
              | Riscv.Move (d, s) when d = s -> None
              | _ -> Some instr)
            b.body;
        b.terminator <- Riscv.map_terminator_regs ~use:recolour b.terminator)
      func.Riscv.blocks
  in
  round ();
  report.spill_slots <- report.spill_slots + func.Riscv.num_spill_slots;
  report

let print_report out name report =
  Printf.fprintf out "%s: %d round(s), %d/%d moves coalesced, %d spill slot(s)%s\n" name
    report.rounds report.moves_coalesced report.moves_total report.spill_slots
    (if report.spilled = [] then ""
     else " [spilled " ^ String.concat " " (List.rev report.spilled) ^ "]")
