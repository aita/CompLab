(* Spilling.

   A spilled value gets a frame slot, a store after every definition of it and a
   reload in front of every use.  The reloads are new registers, live from the
   load to the instruction under it and nowhere else, which is what makes the
   pressure come down.  Nothing here assumes SSA: a value written twice gets two
   stores, and a phi argument is reloaded at the end of the predecessor it comes
   from, so the same rewrite would serve a walk of the dominator tree as well as
   the graph. *)

open Ir

(* Raised when spilling cannot help either. *)
exception Out_of_registers of string

(* How deeply each block is nested in loops, for weighing what a use costs.

   A back edge is an edge into a block that dominates its source; everything that
   can reach the source without leaving the dominated region is in that loop. *)
let loop_depth f =
  let dom = Ssa.dominance f in
  let depth = ref (Hashtbl.fold (fun l _ m -> StrMap.add l 0 m) f.blocks StrMap.empty) in
  List.iter
    (fun b ->
      List.iter
        (fun succ ->
          if Ssa.dominates dom succ b.label then begin
            let body = ref (StrSet.singleton succ) in
            let stack = ref [ b.label ] in
            while !stack <> [] do
              let label = List.hd !stack in
              stack := List.tl !stack;
              if not (StrSet.mem label !body) then begin
                body := StrSet.add label !body;
                stack := (block f label).preds @ !stack
              end
            done;
            StrSet.iter
              (fun label -> depth := StrMap.add label (StrMap.find label !depth + 1) !depth)
              !body
          end)
        (succs b))
    (walk f);
  !depth

(* What spilling a value would cost: its reads and writes, weighed by loops. *)
let costs f =
  let depth = loop_depth f in
  let scale_of label = 10.0 ** float_of_int (min (StrMap.find label depth) 4) in
  let weight = ref IntMap.empty in
  let add r amount =
    weight := IntMap.add r (Option.value (IntMap.find_opt r !weight) ~default:0.0 +. amount) !weight
  in
  List.iter
    (fun b ->
      let scale = scale_of b.label in
      List.iter
        (fun phi ->
          List.iter (fun a -> add a.arg (scale_of a.pred)) phi.args;
          add phi.phi_dst scale)
        b.phis;
      List.iter
        (fun instr ->
          List.iter (fun r -> add r scale) (uses instr);
          Option.iter (fun d -> add d scale) (defs instr))
        (instrs b))
    (walk f);
  !weight

let insert_before_last b instr =
  let all = instrs b in
  let at = List.length all - 1 in
  set_instrs b (CCList.take at all @ (instr :: CCList.drop at all))

(* Give [victim] a frame slot, and answer with the slot and the reloads that
   replaced it.  Where it went is the caller's to remember, because it is part of
   the allocation and not of the program. *)
let spill f victim =
  let slot = new_slot f in
  let is_param = Dynarray.exists (fun p -> p = victim) f.params in
  let reloads = ref IntSet.empty in

  List.iter
    (fun b ->
      if List.exists (fun phi -> phi.phi_dst = victim) b.phis then
        set_instrs b (Store_slot { slot; src = victim } :: instrs b);
      if is_param && b.label = f.entry then
        set_instrs b (Store_slot { slot; src = victim } :: instrs b);

      let rebuilt =
        List.concat_map
          (fun instr ->
            let spill_store =
              match instr with Store_slot s -> s.slot = slot | _ -> false
            in
            let reads = List.mem victim (uses instr) in
            let before, instr =
              if reads && not spill_store then begin
                let fresh = new_reg f in
                reloads := IntSet.add fresh !reloads;
                ( [ Load_slot { dst = fresh; slot } ],
                  map_uses (fun r -> if r = victim then fresh else r) instr )
              end
              else ([], instr)
            in
            let after =
              if defs instr = Some victim then [ Store_slot { slot; src = victim } ] else []
            in
            before @ [ instr ] @ after)
          (instrs b)
      in
      set_instrs b rebuilt)
    (walk f);

  List.iter
    (fun b ->
      map_phis b (fun phi ->
          { phi with
            args =
              Util.map_in_order
                (fun a ->
                  if a.arg <> victim then a
                  else begin
                    let source = block f a.pred in
                    let fresh = new_reg f in
                    reloads := IntSet.add fresh !reloads;
                    insert_before_last source (Load_slot { dst = fresh; slot });
                    { a with arg = fresh }
                  end)
                phi.args
          }))
    (walk f);
  (slot, !reloads)
