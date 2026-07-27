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

let set_of_list = Liveness.set_of_list
let pick set = RegSet.min_elt set

let allocate ?(report = no_report ()) (func : Ir.func) =
  let num_colors = Ir.num_colors () in
  let colours = !Ir.allocatable in
  (* Temporaries introduced to hold a spilled value are never spilled again:
     their live range is a single instruction, and spilling them would not
     terminate. *)
  let never_spill = Hashtbl.create 16 in
  let fresh_reg () =
    let r = func.Ir.num_regs in
    func.Ir.num_regs <- r + 1;
    Hashtbl.replace never_spill r ();
    r
  in

  let rec round () =
    report.rounds <- report.rounds + 1;
    if report.rounds > 32 then
      failwith "Regalloc: allocation failed to converge (this is a compiler bug)";
    let n = func.Ir.num_regs in
    let precoloured r = r < Ir.num_physical in

    (* ------------------------------------------------------- the graph *)
    let adjacency = Hashtbl.create 1024 in
    let neighbours = Array.make n RegSet.empty in
    let degree = Array.make n 0 in
    let move_list = Array.make n RegSet.empty in
    let alias = Array.init n (fun i -> i) in
    let colour = Array.make n (-1) in
    let uses_and_defs = Array.make n 0 in
    Array.iter
      (fun r ->
        colour.(r) <- r;
        degree.(r) <- max_int)
      colours;

    let edge u v = if u < v then (u * n) + v else (v * n) + u in
    let interferes u v = Hashtbl.mem adjacency (edge u v) in
    let add_edge u v =
      if u <> v && not (interferes u v) then begin
        Hashtbl.replace adjacency (edge u v) ();
        if not (precoloured u) then begin
          neighbours.(u) <- RegSet.add v neighbours.(u);
          degree.(u) <- degree.(u) + 1
        end;
        if not (precoloured v) then begin
          neighbours.(v) <- RegSet.add u neighbours.(v);
          degree.(v) <- degree.(v) + 1
        end
      end
    in

    (* --------------------------------------------------- the worklists *)
    let moves = ref [] and num_moves = ref 0 in
    let simplify_worklist = ref RegSet.empty in
    let freeze_worklist = ref RegSet.empty in
    let spill_worklist = ref RegSet.empty in
    let spilled_nodes = ref RegSet.empty in
    let coalesced_nodes = ref RegSet.empty in
    let coloured_nodes = ref RegSet.empty in
    let select_stack = ref [] in
    let on_select_stack = ref RegSet.empty in
    let worklist_moves = ref RegSet.empty in
    let active_moves = ref RegSet.empty in
    let frozen_moves = ref RegSet.empty in
    let coalesced_moves = ref RegSet.empty in
    let constrained_moves = ref RegSet.empty in

    let record_move dst src =
      let m = !num_moves in
      incr num_moves;
      moves := (dst, src) :: !moves;
      move_list.(dst) <- RegSet.add m move_list.(dst);
      move_list.(src) <- RegSet.add m move_list.(src);
      worklist_moves := RegSet.add m !worklist_moves
    in

    (* Walk each block backwards from its live-out set, adding an edge between
       every register being defined and everything live at that point.  A move
       is the one exception: `mv d, s` does not make d and s interfere, which is
       precisely what leaves them free to be coalesced. *)
    let live_out = Liveness.analyze func in
    List.iter
      (fun (b : Ir.block) ->
        let live =
          ref
            (RegSet.union
               (Hashtbl.find live_out b.label)
               (set_of_list (Ir.terminator_uses b.terminator)))
        in
        List.iter
          (fun instr ->
            (match Ir.move_pair instr with
             | Some (dst, src) ->
               live := RegSet.remove src !live;
               record_move dst src
             | None -> ());
            let defs = Ir.defines instr and uses = Ir.uses instr in
            live := List.fold_left (fun acc d -> RegSet.add d acc) !live defs;
            List.iter (fun d -> RegSet.iter (fun l -> add_edge l d) !live) defs;
            live :=
              RegSet.union (RegSet.diff !live (set_of_list defs)) (set_of_list uses);
            List.iter (fun r -> uses_and_defs.(r) <- uses_and_defs.(r) + 1) (defs @ uses))
          (List.rev b.body))
      func.Ir.blocks;
    let moves = Array.of_list (List.rev !moves) in
    report.moves_total <- report.moves_total + Array.length moves;

    (* ------------------------------------------------------- primitives *)
    let adjacent node =
      RegSet.diff neighbours.(node) (RegSet.union !on_select_stack !coalesced_nodes)
    in
    let node_moves node =
      RegSet.inter move_list.(node) (RegSet.union !active_moves !worklist_moves)
    in
    let move_related node = not (RegSet.is_empty (node_moves node)) in
    let rec alias_of node =
      if RegSet.mem node !coalesced_nodes then alias_of alias.(node) else node
    in
    let enable_moves nodes =
      RegSet.iter
        (fun node ->
          RegSet.iter
            (fun m ->
              if RegSet.mem m !active_moves then begin
                active_moves := RegSet.remove m !active_moves;
                worklist_moves := RegSet.add m !worklist_moves
              end)
            (node_moves node))
        nodes
    in
    let decrement_degree node =
      if not (precoloured node) then begin
        let d = degree.(node) in
        degree.(node) <- d - 1;
        if d = num_colors then begin
          (* The node just became trivially colourable, so moves involving it
             are worth reconsidering. *)
          enable_moves (RegSet.add node (adjacent node));
          spill_worklist := RegSet.remove node !spill_worklist;
          if move_related node then freeze_worklist := RegSet.add node !freeze_worklist
          else simplify_worklist := RegSet.add node !simplify_worklist
        end
      end
    in
    let make_worklists () =
      for node = Ir.num_physical to n - 1 do
        if degree.(node) >= num_colors then
          spill_worklist := RegSet.add node !spill_worklist
        else if move_related node then freeze_worklist := RegSet.add node !freeze_worklist
        else simplify_worklist := RegSet.add node !simplify_worklist
      done
    in

    let simplify () =
      let node = pick !simplify_worklist in
      simplify_worklist := RegSet.remove node !simplify_worklist;
      select_stack := node :: !select_stack;
      on_select_stack := RegSet.add node !on_select_stack;
      RegSet.iter decrement_degree (adjacent node)
    in

    let add_to_worklist node =
      if (not (precoloured node)) && (not (move_related node))
         && degree.(node) < num_colors
      then begin
        freeze_worklist := RegSet.remove node !freeze_worklist;
        simplify_worklist := RegSet.add node !simplify_worklist
      end
    in
    (* George: merging into the pre-coloured [r] is safe if every neighbour of
       the other node already interferes with r or is insignificant. *)
    let george neighbour r =
      degree.(neighbour) < num_colors || precoloured neighbour
      || interferes neighbour r
    in
    (* Briggs: merging is safe if the merged node has fewer than K neighbours
       of significant degree. *)
    let briggs nodes =
      RegSet.cardinal (RegSet.filter (fun t -> degree.(t) >= num_colors) nodes)
      < num_colors
    in
    let combine u v =
      if RegSet.mem v !freeze_worklist then
        freeze_worklist := RegSet.remove v !freeze_worklist
      else spill_worklist := RegSet.remove v !spill_worklist;
      coalesced_nodes := RegSet.add v !coalesced_nodes;
      alias.(v) <- u;
      move_list.(u) <- RegSet.union move_list.(u) move_list.(v);
      enable_moves (RegSet.singleton v);
      RegSet.iter
        (fun t ->
          add_edge t u;
          decrement_degree t)
        (adjacent v);
      if degree.(u) >= num_colors && RegSet.mem u !freeze_worklist then begin
        freeze_worklist := RegSet.remove u !freeze_worklist;
        spill_worklist := RegSet.add u !spill_worklist
      end
    in
    let coalesce () =
      let m = pick !worklist_moves in
      worklist_moves := RegSet.remove m !worklist_moves;
      let dst, src = moves.(m) in
      let x = alias_of dst and y = alias_of src in
      let u, v = if precoloured y then (y, x) else (x, y) in
      if u = v then begin
        coalesced_moves := RegSet.add m !coalesced_moves;
        add_to_worklist u
      end
      else if precoloured v || interferes u v then begin
        (* The two ends are live at the same time, or both are machine
           registers: this move has to stay. *)
        constrained_moves := RegSet.add m !constrained_moves;
        add_to_worklist u;
        add_to_worklist v
      end
      else if
        (precoloured u && RegSet.for_all (fun t -> george t u) (adjacent v))
        || ((not (precoloured u)) && briggs (RegSet.union (adjacent u) (adjacent v)))
      then begin
        coalesced_moves := RegSet.add m !coalesced_moves;
        combine u v;
        add_to_worklist u
      end
      else active_moves := RegSet.add m !active_moves
    in

    let freeze_moves u =
      RegSet.iter
        (fun m ->
          let dst, src = moves.(m) in
          let v = if alias_of src = alias_of u then alias_of dst else alias_of src in
          active_moves := RegSet.remove m !active_moves;
          frozen_moves := RegSet.add m !frozen_moves;
          if (not (move_related v)) && degree.(v) < num_colors then begin
            freeze_worklist := RegSet.remove v !freeze_worklist;
            simplify_worklist := RegSet.add v !simplify_worklist
          end)
        (node_moves u)
    in
    let freeze () =
      let node = pick !freeze_worklist in
      freeze_worklist := RegSet.remove node !freeze_worklist;
      simplify_worklist := RegSet.add node !simplify_worklist;
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
        RegSet.fold
          (fun candidate best ->
            match best with
            | Some b when cost b <= cost candidate -> best
            | _ -> Some candidate)
          !spill_worklist None
        |> Option.get
      in
      spill_worklist := RegSet.remove node !spill_worklist;
      simplify_worklist := RegSet.add node !simplify_worklist;
      freeze_moves node
    in

    let assign_colours () =
      List.iter
        (fun node ->
          let available =
            Array.fold_left (fun acc c -> RegSet.add c acc) RegSet.empty colours
          in
          let available =
            RegSet.fold
              (fun w acc ->
                let w = alias_of w in
                if RegSet.mem w !coloured_nodes || precoloured w then
                  RegSet.remove colour.(w) acc
                else acc)
              neighbours.(node) available
          in
          if RegSet.is_empty available then
            spilled_nodes := RegSet.add node !spilled_nodes
          else begin
            coloured_nodes := RegSet.add node !coloured_nodes;
            colour.(node) <- pick available
          end)
        !select_stack;
      RegSet.iter (fun node -> colour.(node) <- colour.(alias_of node)) !coalesced_nodes
    in

    make_worklists ();
    let rec work () =
      if not (RegSet.is_empty !simplify_worklist) then (simplify (); work ())
      else if not (RegSet.is_empty !worklist_moves) then (coalesce (); work ())
      else if not (RegSet.is_empty !freeze_worklist) then (freeze (); work ())
      else if not (RegSet.is_empty !spill_worklist) then (select_spill (); work ())
    in
    work ();
    assign_colours ();

    if RegSet.is_empty !spilled_nodes then begin
      report.moves_coalesced <- report.moves_coalesced + RegSet.cardinal !coalesced_moves;
      apply_colours colour
    end
    else begin
      rewrite !spilled_nodes;
      round ()
    end

  (* Give every spilled value a stack slot, and reduce its live range to the
     single instruction that touches it by loading just before and storing just
     after.  The new temporaries are trivial to colour, so the next round is
     strictly closer to done. *)
  and rewrite spilled =
    let slots = Hashtbl.create 8 in
    RegSet.iter
      (fun r ->
        Hashtbl.replace slots r func.Ir.num_spill_slots;
        func.Ir.num_spill_slots <- func.Ir.num_spill_slots + 1;
        report.spilled <- Ir.name_of_reg r :: report.spilled)
      spilled;
    let offset r = Hashtbl.find slots r * 8 in
    let touched regs = List.sort_uniq compare (List.filter (fun r -> RegSet.mem r spilled) regs) in
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
      (fun (b : Ir.block) ->
        let body =
          List.concat_map
            (fun instr ->
              let reads = touched (Ir.uses instr) in
              let writes = touched (Ir.defines instr) in
              if reads = [] && writes = [] then [ instr ]
              else begin
                let temps = temps_for reads writes in
                let substitute r =
                  match Hashtbl.find_opt temps r with Some t -> t | None -> r
                in
                let loads =
                  List.map (fun r -> Ir.Load (substitute r, Ir.sp, offset r)) reads
                in
                let stores =
                  List.map (fun r -> Ir.Store (substitute r, Ir.sp, offset r)) writes
                in
                loads
                @ [ Ir.map_regs ~use:substitute ~def:substitute instr ]
                @ stores
              end)
            b.body
        in
        let reads = touched (Ir.terminator_uses b.terminator) in
        let temps = temps_for reads [] in
        let substitute r =
          match Hashtbl.find_opt temps r with Some t -> t | None -> r
        in
        b.terminator <- Ir.map_terminator_regs ~use:substitute b.terminator;
        b.body <-
          body @ List.map (fun r -> Ir.Load (substitute r, Ir.sp, offset r)) reads)
      func.Ir.blocks

  (* Replace every virtual register by the machine register it was given, and
     drop the moves that have become `mv x, x`. *)
  and apply_colours colour =
    let recolour r = if Ir.is_virtual r then colour.(r) else r in
    List.iter
      (fun (b : Ir.block) ->
        b.body <-
          List.filter_map
            (fun instr ->
              let instr = Ir.map_regs ~use:recolour ~def:recolour instr in
              match instr with
              | Ir.Move (d, s) when d = s -> None
              | _ -> Some instr)
            b.body;
        b.terminator <- Ir.map_terminator_regs ~use:recolour b.terminator)
      func.Ir.blocks
  in
  round ();
  report.spill_slots <- report.spill_slots + func.Ir.num_spill_slots;
  report

let print_report out name report =
  Printf.fprintf out "%s: %d round(s), %d/%d moves coalesced, %d spill slot(s)%s\n" name
    report.rounds report.moves_coalesced report.moves_total report.spill_slots
    (if report.spilled = [] then ""
     else " [spilled " ^ String.concat " " (List.rev report.spilled) ^ "]")
