(* SSA construction, the textbook way.

   Dominators by the iterative algorithm of Cooper, Harvey and Kennedy, dominance
   frontiers from those, phis at the frontiers of every definition, and then one
   walk of the dominator tree renaming as it goes.  This is minimal SSA and
   nothing cleverer: a phi is placed wherever the frontier says, whether or not
   the variable is live there, and the dead ones leave in [Opt.dead_code].

   Only registers written more than once take part.  Everything lowering produced
   once — a temporary — is already in SSA and is left with the name it has. *)

open Ir

type dominance = {
  idom : string StrMap.t;
  children : string list StrMap.t;
  frontier : StrSet.t StrMap.t;
  order : string list;
}

let rec dominates dom a b =
  if a = b then true
  else
    let parent = StrMap.find b dom.idom in
    if parent = b then false else dominates dom a parent

let dominance f =
  let order = rpo f in
  (* Both of these are hash tables and not association lists: [intersect] runs
     inside the fix-point's inner loop, so a linear lookup here is what turns
     construction cubic in the number of blocks. *)
  let rank = Hashtbl.create (List.length order) in
  List.iteri (fun i label -> Hashtbl.replace rank label i) order;
  let rank_of label = Hashtbl.find rank label in
  let idom = Hashtbl.create (List.length order) in
  Hashtbl.replace idom f.entry f.entry;

  let intersect a b =
    let a = ref a and b = ref b in
    while !a <> !b do
      while rank_of !a > rank_of !b do
        a := Hashtbl.find idom !a
      done;
      while rank_of !b > rank_of !a do
        b := Hashtbl.find idom !b
      done
    done;
    !a
  in

  let changed = ref true in
  while !changed do
    changed := false;
    List.iter
      (fun label ->
        let preds = List.filter (fun p -> Hashtbl.mem idom p) (block f label).preds in
        match preds with
        | [] -> ()
        | first :: rest ->
            let next = List.fold_left (fun acc p -> intersect p acc) first rest in
            if Hashtbl.find_opt idom label <> Some next then begin
              Hashtbl.replace idom label next;
              changed := true
            end)
      (List.tl order)
  done;
  let idom = Hashtbl.fold StrMap.add idom StrMap.empty in

  let children = ref (List.fold_left (fun m l -> StrMap.add l [] m) StrMap.empty order) in
  List.iter
    (fun label ->
      let parent = StrMap.find label idom in
      if parent <> label then
        children := StrMap.add parent (StrMap.find parent !children @ [ label ]) !children)
    order;

  let frontier =
    ref (List.fold_left (fun m l -> StrMap.add l StrSet.empty m) StrMap.empty order)
  in
  List.iter
    (fun label ->
      let b = block f label in
      if List.length b.preds >= 2 then
        List.iter
          (fun pred ->
            let runner = ref pred in
            let go = ref true in
            while !go && !runner <> StrMap.find label idom do
              if not (StrMap.mem !runner idom) then go := false
              else begin
                frontier :=
                  StrMap.add !runner (StrSet.add label (StrMap.find !runner !frontier)) !frontier;
                runner := StrMap.find !runner idom
              end
            done)
          b.preds)
    order;
  { idom; children = !children; frontier = !frontier; order }

(* Where each register is written, and how often.

   A register written twice in one block is as much a variable as one written in
   two blocks, so the count is what decides, and the blocks are what the frontier
   walk needs. *)
type defs = { mutable sites : StrSet.t IntMap.t; mutable count : int IntMap.t }

let record d r label =
  let at = match IntMap.find_opt r d.sites with Some s -> s | None -> StrSet.empty in
  d.sites <- IntMap.add r (StrSet.add label at) d.sites;
  d.count <- IntMap.add r (1 + Option.value (IntMap.find_opt r d.count) ~default:0) d.count

(* The registers written more than once, in ascending order. *)
let variables d =
  IntMap.fold (fun r n acc -> if n > 1 then IntSet.add r acc else acc) d.count IntSet.empty

let definitions f =
  let d = { sites = IntMap.empty; count = IntMap.empty } in
  iter_blocks f (fun b ->
      iter_instrs b (fun instr ->
          let r = defs instr in
          if r <> no_reg then record d r b.label));
  Dynarray.iter (fun r -> record d r f.entry) f.params;
  d

(* Put a phi for [v] at every dominance frontier of a block defining it. *)
let place_phis f dom d =
  let phi_vars = Hashtbl.create 32 in
  Hashtbl.iter (fun label _ -> Hashtbl.replace phi_vars label (Dynarray.create ())) f.blocks;
  IntSet.iter
    (fun v ->
      let sites = IntMap.find v d.sites in
      let placed = ref StrSet.empty in
      (* A stack whose initial contents are the defining blocks in ascending
         order, taken from the top. *)
      let work = ref (List.rev (StrSet.elements sites)) in
      while !work <> [] do
        let b = List.hd !work in
        work := List.tl !work;
        StrSet.iter
          (fun target ->
            if not (StrSet.mem target !placed) then begin
              placed := StrSet.add target !placed;
              Dynarray.add_last (Hashtbl.find phi_vars target) v;
              let target_block = block f target in
              let phi =
                { phi_dst = v; args = List.map (fun pred -> { pred; arg = v }) target_block.preds }
              in
              target_block.phis <- target_block.phis @ [ phi ];
              if not (StrSet.mem target sites) then work := target :: !work
            end)
          (StrMap.find b dom.frontier)
      done)
    (variables d);
  phi_vars

type renamer = {
  fn : func;
  dom : dominance;
  phi_vars : (string, reg Dynarray.t) Hashtbl.t;
  vars : IntSet.t;
  mutable stacks : reg list IntMap.t;
  mutable undefined : reg IntMap.t;
  mutable undef_order : reg list;
}

(* A variable read on a path that never wrote it reads zero. *)
let undef r v =
  match IntMap.find_opt v r.undefined with
  | Some fresh -> fresh
  | None ->
      let fresh = new_reg r.fn in
      r.undefined <- IntMap.add v fresh r.undefined;
      r.undef_order <- v :: r.undef_order;
      fresh

let top r v =
  match IntMap.find_opt v r.stacks with
  | Some (x :: _) -> x
  | _ -> undef r v

let rename r v =
  let fresh = new_reg r.fn in
  let stack = Option.value (IntMap.find_opt v r.stacks) ~default:[] in
  r.stacks <- IntMap.add v (fresh :: stack) r.stacks;
  fresh

let pop_name r v =
  match IntMap.find_opt v r.stacks with
  | Some (_ :: rest) -> r.stacks <- IntMap.add v rest r.stacks
  | _ -> ()

let use r reg = if IntSet.mem reg r.vars then top r reg else reg

let rename_block r label =
  let b = block r.fn label in
  let mine = ref [] in
  List.iteri
    (fun at phi ->
      let v = Dynarray.get (Hashtbl.find r.phi_vars label) at in
      phi.phi_dst <- rename r v;
      mine := v :: !mine)
    b.phis;
  List.iter
    (fun instr ->
      map_uses (use r) instr;
      let d = defs instr in
      if d <> no_reg && IntSet.mem d r.vars then begin
        set_def instr (rename r d);
        mine := d :: !mine
      end)
    (instrs b);
  List.iter
    (fun succ ->
      let target = block r.fn succ in
      List.iteri
        (fun at phi -> set_arg phi label (top r (Dynarray.get (Hashtbl.find r.phi_vars succ) at)))
        target.phis)
    (succs b);
  (* Prepended and reversed once; every name here is popped exactly once, so the
     order only has to be a permutation, but keeping it the walk's order is what
     makes this readable next to the other three trees. *)
  List.rev !mine

let rec walk_dominators r label =
  let mine = rename_block r label in
  List.iter (walk_dominators r) (StrMap.find label r.dom.children);
  List.iter (pop_name r) mine

let plant_undefined r =
  let entry = block r.fn r.fn.entry in
  List.iter
    (fun v ->
      let fresh = IntMap.find v r.undefined in
      set_instrs entry (Const { dst = fresh; value = 0L } :: instrs entry))
    (List.rev r.undef_order)

(* Rewrite one function into SSA, in place. *)
let construct f =
  recompute_preds f;
  let dom = dominance f in
  let d = definitions f in
  let phi_vars = place_phis f dom d in
  let vars = variables d in
  let r =
    { fn = f; dom; phi_vars; vars; stacks = IntMap.empty; undefined = IntMap.empty;
      undef_order = [] }
  in
  Dynarray.iteri
    (fun at p -> if IntSet.mem p vars then Dynarray.set f.params at (rename r p))
    f.params;
  walk_dominators r f.entry;
  plant_undefined r

let construct_module m = List.iter construct m.funcs

(* Give every phi a place to put its copy in.

   An edge from a block with several successors into a block with several
   predecessors has nowhere to hold the copies a phi turns into, so it gets a
   block of its own.  The same goes for any edge into a block that still has a
   phi, so that the emitter only ever has to put copies before a [jmp]. *)
let split_critical_edges f =
  List.iter
    (fun label ->
      let b = block f label in
      if List.length (succs b) >= 2 then
        List.iter
          (fun succ ->
            let target = block f succ in
            if List.length target.preds >= 2 || target.phis <> [] then begin
              let split = add_block f (label ^ "." ^ succ) in
              emit split (Jmp { target = succ });
              rename_target (terminator b) succ split.label;
              List.iter
                (fun phi ->
                  match remove_arg phi label with
                  | Some arg -> set_arg phi split.label arg
                  | None -> ())
                target.phis
            end)
          (succs b))
    (order_list f);
  recompute_preds f

(* Check what SSA promises: one definition per register, and it dominates. *)
let verify f =
  let dom = dominance f in
  let definition = Hashtbl.create 64 in
  let claim r label =
    if Hashtbl.mem definition r then
      failwith (Printf.sprintf "%%%d defined twice" r);
    Hashtbl.replace definition r label
  in
  List.iter
    (fun b ->
      List.iter (fun phi -> claim phi.phi_dst b.label) b.phis;
      List.iter
        (fun instr ->
          let d = defs instr in
          if d <> no_reg then claim d b.label)
        (instrs b))
    (walk f);
  Dynarray.iter (fun p -> if not (Hashtbl.mem definition p) then Hashtbl.replace definition p f.entry) f.params;
  let where r =
    match Hashtbl.find_opt definition r with
    | Some label -> label
    | None -> failwith (Printf.sprintf "%%%d is never defined" r)
  in
  List.iter
    (fun b ->
      List.iter
        (fun phi ->
          let named = StrSet.of_list (phi_preds phi) in
          let preds = StrSet.of_list b.preds in
          if not (StrSet.equal named preds) then
            failwith
              (Printf.sprintf "phi in %s names %s, preds are %s" b.label
                 (String.concat "," (StrSet.elements named))
                 (String.concat "," (StrSet.elements preds)));
          List.iter
            (fun a ->
              if not (dominates dom (where a.arg) a.pred) then
                failwith
                  (Printf.sprintf "%%%d does not reach %s through %s" a.arg b.label a.pred))
            phi.args)
        b.phis;
      List.iter
        (fun instr ->
          List.iter
            (fun r ->
              if not (dominates dom (where r) b.label) then
                failwith (Printf.sprintf "%%%d does not dominate its use in %s" r b.label))
            (uses instr))
        (instrs b))
    (walk f)
