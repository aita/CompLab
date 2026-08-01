(* Register allocation by graph colouring, with iterated coalescing.

   The idea is Chaitin's: build a graph whose nodes are values and whose edges
   join values that are live at the same time, then colour it with as many colours
   as the machine has registers.  Colouring a graph is hard in general, but
   Kempe's observation makes it practical: a node with fewer than K neighbours can
   always be coloured whatever happens to the rest of the graph.  So remove such
   nodes one at a time and push them on a stack; when the graph is empty, pop the
   stack and give each node a colour its neighbours have not taken.  If every
   remaining node has K or more neighbours, guess that one of them will not get a
   colour and carry on — if the guess was wrong the value is rewritten to live in
   memory and the whole thing runs again (Briggs' optimistic colouring).

   On top of that sits coalescing, which is why leaving SSA first costs nothing.
   Leaving SSA fills the predecessors of every join with copies; coalescing merges
   the two ends of a copy so that it disappears.  Merging aggressively can make a
   graph uncolourable, so a merge only happens when Briggs' test proves it cannot:
   the merged node must have fewer than K neighbours of significant degree.  That
   test is only exact enough to be useful if degrees are up to date, and
   simplifying lowers degrees while merging raises them — so the two run
   interleaved, with freezing (giving up on a copy so its nodes can be simplified)
   as the way out when neither applies.  Hence "iterated" (George and Appel, 1996).

   This machine has no fixed registers to colour against, so the calling
   convention is carried as a set of colours each node may not take: a value live
   across a call may not take a caller-saved one.  A node with [f] forbidden
   colours and [d] neighbours needs [d + f < K] to be trivially colourable, so that
   sum is what stands in for the degree everywhere below.

   Every set here is an [IntSet], so "the least element" and "in order" are what
   the structure already gives; the Python has to say [sorted] at each of these
   places and the Go has to sort by hand. *)

open Ir

type move = { m_dst : reg; m_src : reg }

type colouring = {
  fn : func;
  machine : Registers.t;
  (* Values a previous round produced by reloading something.  Their live ranges
     are a load and its one use, so spilling one again would only make another of
     the same, and the rewriting would never end. *)
  protected : IntSet.t;
  mutable adjacent : IntSet.t IntMap.t;
  mutable degree : int IntMap.t;
  mutable forbidden : IntSet.t IntMap.t;
  mutable preferred : int IntMap.t;
  mutable moves : move array;
  mutable moves_of : IntSet.t IntMap.t;
  mutable worklist_moves : IntSet.t;
  mutable active_moves : IntSet.t;
  mutable simplify_worklist : IntSet.t;
  mutable freeze_worklist : IntSet.t;
  mutable spill_worklist : IntSet.t;
  mutable select_stack : reg list;
  mutable on_stack : IntSet.t;
  mutable coalesced : IntSet.t;
  mutable alias : reg IntMap.t;
  mutable colour : int IntMap.t;
}

let k c = Registers.count c.machine
let adjacent c r = Option.value (IntMap.find_opt r c.adjacent) ~default:IntSet.empty
let degree c r = Option.value (IntMap.find_opt r c.degree) ~default:0
let forbidden c r = Option.value (IntMap.find_opt r c.forbidden) ~default:IntSet.empty

(* The degree, counting a forbidden colour as a neighbour holding it. *)
let weight c r = degree c r + IntSet.cardinal (forbidden c r)

let node c r =
  if not (IntMap.mem r c.adjacent) then begin
    c.adjacent <- IntMap.add r IntSet.empty c.adjacent;
    c.degree <- IntMap.add r 0 c.degree;
    c.forbidden <- IntMap.add r IntSet.empty c.forbidden
  end

let add_edge c a b =
  if a <> b && not (IntSet.mem b (adjacent c a)) then begin
    c.adjacent <- IntMap.add a (IntSet.add b (adjacent c a)) c.adjacent;
    c.adjacent <- IntMap.add b (IntSet.add a (adjacent c b)) c.adjacent;
    c.degree <- IntMap.add a (degree c a + 1) c.degree;
    c.degree <- IntMap.add b (degree c b + 1) c.degree
  end

let note_move c r index =
  let at = Option.value (IntMap.find_opt r c.moves_of) ~default:IntSet.empty in
  c.moves_of <- IntMap.add r (IntSet.add index at) c.moves_of

(* Parameters arrive together, so they interfere with each other. *)
let entry_edges c alive =
  let params = Dynarray.to_list c.fn.params in
  List.iteri
    (fun at param ->
      IntSet.iter (fun other -> add_edge c param other) alive;
      List.iteri (fun other_at another -> if other_at > at then add_edge c param another) params)
    params

let build c =
  c.preferred <- Hints.preferences c.fn;
  let live = Liveness.analyse c.fn in
  let caller = IntSet.of_list c.machine.Registers.caller in
  iter_blocks c.fn (fun b ->
      iter_instrs b (fun instr ->
          List.iter (node c) (uses instr);
          let d = defs instr in
          if d <> no_reg then node c d));
  Dynarray.iter (node c) c.fn.params;

  let all_moves = Dynarray.create () in
  List.iter
    (fun b ->
      let alive = ref (Liveness.live_out live b.label) in
      List.iter
        (fun instr ->
          (match instr with
          | Move m ->
              alive := IntSet.remove m.src !alive;
              let index = Dynarray.length all_moves in
              Dynarray.add_last all_moves { m_dst = m.dst; m_src = m.src };
              note_move c m.dst index;
              note_move c m.src index;
              c.worklist_moves <- IntSet.add index c.worklist_moves
          | _ -> ());
          let defined = defs instr in
          if defined <> no_reg then begin
            alive := IntSet.add defined !alive;
            IntSet.iter (fun other -> add_edge c defined other) !alive
          end;
          (match instr with
          | Call _ ->
              IntSet.iter
                (fun r ->
                  if r <> defined then
                    c.forbidden <- IntMap.add r (IntSet.union (forbidden c r) caller) c.forbidden)
                !alive
          | _ -> ());
          if defined <> no_reg then alive := IntSet.remove defined !alive;
          alive := IntSet.union !alive (Liveness.of_list (uses instr)))
        (List.rev (instrs b));
      if b.label = c.fn.entry then entry_edges c !alive)
    (walk c.fn);
  c.moves <- Dynarray.to_array all_moves

(* -- the worklists ---------------------------------------------------------- *)

let node_moves c r =
  IntSet.inter
    (Option.value (IntMap.find_opt r c.moves_of) ~default:IntSet.empty)
    (IntSet.union c.active_moves c.worklist_moves)

let move_related c r = not (IntSet.is_empty (node_moves c r))

let neighbours c r = IntSet.diff (IntSet.diff (adjacent c r) c.on_stack) c.coalesced

let make_worklists c =
  IntMap.iter
    (fun r _ ->
      if weight c r >= k c then c.spill_worklist <- IntSet.add r c.spill_worklist
      else if move_related c r then c.freeze_worklist <- IntSet.add r c.freeze_worklist
      else c.simplify_worklist <- IntSet.add r c.simplify_worklist)
    c.adjacent

let enable_moves c nodes =
  IntSet.iter
    (fun r ->
      IntSet.iter
        (fun index ->
          if IntSet.mem index c.active_moves then begin
            c.active_moves <- IntSet.remove index c.active_moves;
            c.worklist_moves <- IntSet.add index c.worklist_moves
          end)
        (node_moves c r))
    nodes

let decrement_degree c r =
  let was = weight c r in
  c.degree <- IntMap.add r (degree c r - 1) c.degree;
  if was = k c then begin
    (* It has just become trivially colourable, so the copies around it may have
       become safe to merge as well. *)
    enable_moves c (IntSet.add r (neighbours c r));
    c.spill_worklist <- IntSet.remove r c.spill_worklist;
    if move_related c r then c.freeze_worklist <- IntSet.add r c.freeze_worklist
    else c.simplify_worklist <- IntSet.add r c.simplify_worklist
  end

let simplify c =
  let r = IntSet.min_elt c.simplify_worklist in
  c.simplify_worklist <- IntSet.remove r c.simplify_worklist;
  c.select_stack <- r :: c.select_stack;
  c.on_stack <- IntSet.add r c.on_stack;
  IntSet.iter (decrement_degree c) (neighbours c r)

(* -- coalescing ------------------------------------------------------------- *)

let rec get_alias c r = if IntSet.mem r c.coalesced then get_alias c (IntMap.find r c.alias) else r

let add_to_worklist c r =
  if weight c r < k c && not (move_related c r) then begin
    c.freeze_worklist <- IntSet.remove r c.freeze_worklist;
    c.simplify_worklist <- IntSet.add r c.simplify_worklist
  end

(* Briggs' test: the merged node must have fewer than K significant neighbours.
   The colours the two ends may not take add up as well, and a colour the merged
   node is barred from is one more thing standing in its way. *)
let conservative c u v =
  let together = IntSet.union (neighbours c u) (neighbours c v) in
  let barred = IntSet.cardinal (IntSet.union (forbidden c u) (forbidden c v)) in
  let significant = IntSet.fold (fun r n -> if weight c r >= k c then n + 1 else n) together 0 in
  significant + barred < k c

let combine c u v =
  c.freeze_worklist <- IntSet.remove v c.freeze_worklist;
  c.spill_worklist <- IntSet.remove v c.spill_worklist;
  c.coalesced <- IntSet.add v c.coalesced;
  c.alias <- IntMap.add v u c.alias;
  let of_u = Option.value (IntMap.find_opt u c.moves_of) ~default:IntSet.empty in
  let of_v = Option.value (IntMap.find_opt v c.moves_of) ~default:IntSet.empty in
  c.moves_of <- IntMap.add u (IntSet.union of_u of_v) c.moves_of;
  c.forbidden <- IntMap.add u (IntSet.union (forbidden c u) (forbidden c v)) c.forbidden;
  (match (IntMap.find_opt v c.preferred, IntMap.find_opt u c.preferred) with
  | Some want, None -> c.preferred <- IntMap.add u want c.preferred
  | _ -> ());
  enable_moves c (IntSet.singleton v);
  IntSet.iter
    (fun other ->
      add_edge c other u;
      decrement_degree c other)
    (neighbours c v);
  if weight c u >= k c && IntSet.mem u c.freeze_worklist then begin
    c.freeze_worklist <- IntSet.remove u c.freeze_worklist;
    c.spill_worklist <- IntSet.add u c.spill_worklist
  end

let coalesce c =
  let index = IntSet.min_elt c.worklist_moves in
  let m = c.moves.(index) in
  c.worklist_moves <- IntSet.remove index c.worklist_moves;
  let u = get_alias c m.m_dst and v = get_alias c m.m_src in
  if u = v then add_to_worklist c u
  else if IntSet.mem v (adjacent c u) then begin
    add_to_worklist c u;
    add_to_worklist c v
  end
  else if conservative c u v then begin
    combine c u v;
    add_to_worklist c u
  end
  else c.active_moves <- IntSet.add index c.active_moves

(* -- freezing and spilling --------------------------------------------------- *)

let freeze_moves c r =
  IntSet.iter
    (fun index ->
      let m = c.moves.(index) in
      c.active_moves <- IntSet.remove index c.active_moves;
      c.worklist_moves <- IntSet.remove index c.worklist_moves;
      let end_ = if get_alias c m.m_dst = get_alias c r then m.m_src else m.m_dst in
      let other = get_alias c end_ in
      if (not (move_related c other)) && weight c other < k c then begin
        c.freeze_worklist <- IntSet.remove other c.freeze_worklist;
        c.simplify_worklist <- IntSet.add other c.simplify_worklist
      end)
    (node_moves c r)

let freeze c =
  let r = IntSet.min_elt c.freeze_worklist in
  c.freeze_worklist <- IntSet.remove r c.freeze_worklist;
  c.simplify_worklist <- IntSet.add r c.simplify_worklist;
  freeze_moves c r

(* Guess that the value with the most neighbours per use will not fit.

   Never a reload, though: those are cheap by that measure precisely because they
   were made cheap, and choosing one would undo the last round's work instead of
   the pressure. *)
let select_spill c =
  let weights = Spill.costs c.fn in
  let among = IntSet.diff c.spill_worklist c.protected in
  let among = if IntSet.is_empty among then c.spill_worklist else among in
  let score r =
    float_of_int (weight c r) /. (Option.value (IntMap.find_opt r weights) ~default:0.0 +. 1.0)
  in
  let chosen =
    IntSet.fold
      (fun r best -> match best with None -> Some r | Some b -> if score r > score b then Some r else best)
      among None
    |> Option.get
  in
  c.spill_worklist <- IntSet.remove chosen c.spill_worklist;
  c.simplify_worklist <- IntSet.add chosen c.simplify_worklist;
  freeze_moves c chosen

(* -- handing out the colours ------------------------------------------------- *)

let assign_colours c =
  let spilled = ref IntSet.empty in
  while c.select_stack <> [] do
    let r = List.hd c.select_stack in
    c.select_stack <- List.tl c.select_stack;
    c.on_stack <- IntSet.remove r c.on_stack;
    let taken =
      IntSet.fold
        (fun other acc ->
          match IntMap.find_opt (get_alias c other) c.colour with
          | Some colour -> IntSet.add colour acc
          | None -> acc)
        (adjacent c r) IntSet.empty
    in
    let free =
      List.filter
        (fun colour -> (not (IntSet.mem colour taken)) && not (IntSet.mem colour (forbidden c r)))
        (Registers.anywhere c.machine)
    in
    match free with
    | [] -> spilled := IntSet.add r !spilled
    | first :: _ ->
        let chosen =
          match IntMap.find_opt r c.preferred with
          | Some want when List.mem want free -> want
          | _ -> first
        in
        c.colour <- IntMap.add r chosen c.colour
  done;
  IntSet.iter
    (fun r ->
      let colour =
        match IntMap.find_opt (get_alias c r) c.colour with
        | Some colour -> colour
        | None -> List.hd (Registers.anywhere c.machine)
      in
      c.colour <- IntMap.add r colour c.colour)
    c.coalesced;
  !spilled

let run c =
  build c;
  make_worklists c;
  let going = ref true in
  while !going do
    if not (IntSet.is_empty c.simplify_worklist) then simplify c
    else if not (IntSet.is_empty c.worklist_moves) then coalesce c
    else if not (IntSet.is_empty c.freeze_worklist) then freeze c
    else if not (IntSet.is_empty c.spill_worklist) then select_spill c
    else going := false
  done;
  assign_colours c

let new_colouring f machine protected =
  {
    fn = f; machine; protected;
    adjacent = IntMap.empty; degree = IntMap.empty; forbidden = IntMap.empty;
    preferred = IntMap.empty; moves = [||]; moves_of = IntMap.empty;
    worklist_moves = IntSet.empty; active_moves = IntSet.empty;
    simplify_worklist = IntSet.empty; freeze_worklist = IntSet.empty;
    spill_worklist = IntSet.empty; select_stack = []; on_stack = IntSet.empty;
    coalesced = IntSet.empty; alias = IntMap.empty; colour = IntMap.empty;
  }

(* Colour [f], rewriting and starting again for as long as it spills. *)
let allocate f machine =
  let protected = ref IntSet.empty in
  let going = ref true in
  while !going do
    recompute_preds f;
    let c = new_colouring f machine !protected in
    let spilled = run c in
    if IntSet.is_empty spilled then begin
      f.colours <- c.colour;
      f.saved <-
        IntSet.elements
          (IntMap.fold
             (fun _ colour acc ->
               if Registers.is_callee_saved colour then IntSet.add colour acc else acc)
             c.colour IntSet.empty);
      going := false
    end
    else
      IntSet.iter
        (fun victim ->
          if IntSet.mem victim !protected then
            raise
              (Spill.Out_of_registers
                 (Printf.sprintf "`%s` needs more registers at once than the machine has" f.fname));
          protected := IntSet.union !protected (Spill.spill f victim))
        spilled
  done
