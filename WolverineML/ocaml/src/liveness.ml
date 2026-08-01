(* Liveness.

   The only subtlety is the phi.  A phi does not read its arguments where it
   stands; it reads them on the edges, so an argument is live at the end of the
   predecessor it is paired with and not anywhere inside the block that holds the
   phi.  Getting that wrong is what makes phi-related values interfere when they
   should not. *)

open Ir

type t = { live_in : IntSet.t StrMap.t; live_out : IntSet.t StrMap.t }

let live_in t label = StrMap.find label t.live_in
let live_out t label = StrMap.find label t.live_out

let of_list rs = List.fold_left (fun s r -> IntSet.add r s) IntSet.empty rs

let analyse f =
  let upward = ref StrMap.empty and killed = ref StrMap.empty in
  iter_blocks f (fun b ->
      let use = ref IntSet.empty and kill = ref IntSet.empty in
      List.iter (fun phi -> kill := IntSet.add phi.phi_dst !kill) b.phis;
      iter_instrs b (fun instr ->
          List.iter (fun r -> if not (IntSet.mem r !kill) then use := IntSet.add r !use)
            (uses instr);
          Option.iter (fun d -> kill := IntSet.add d !kill) (defs instr));
      upward := StrMap.add b.label !use !upward;
      killed := StrMap.add b.label !kill !killed);

  let live_in = ref StrMap.empty and live_out = ref StrMap.empty in
  Hashtbl.iter
    (fun label _ ->
      live_in := StrMap.add label IntSet.empty !live_in;
      live_out := StrMap.add label IntSet.empty !live_out)
    f.blocks;

  let order = List.rev (rpo f) in
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter
      (fun label ->
        let b = block f label in
        let out =
          List.fold_left
            (fun acc succ ->
              let acc = IntSet.union acc (StrMap.find succ !live_in) in
              List.fold_left
                (fun acc phi ->
                  match phi_arg phi label with
                  | Some a -> IntSet.add a.arg acc
                  | None -> acc)
                acc (block f succ).phis)
            IntSet.empty (succs b)
        in
        let new_in =
          IntSet.union (StrMap.find label !upward)
            (IntSet.diff out (StrMap.find label !killed))
        in
        if
          (not (IntSet.equal out (StrMap.find label !live_out)))
          || not (IntSet.equal new_in (StrMap.find label !live_in))
        then begin
          live_out := StrMap.add label out !live_out;
          live_in := StrMap.add label new_in !live_in;
          changed := true
        end)
      order
  done;
  { live_in = !live_in; live_out = !live_out }

(* The values live across a call, and so unable to sit in a scratch register. *)
let across_calls f live =
  let out = ref IntSet.empty in
  List.iter
    (fun b ->
      let after = ref (live_out live b.label) in
      List.iter
        (fun instr ->
          Option.iter (fun d -> after := IntSet.remove d !after) (defs instr);
          (match instr with Call _ -> out := IntSet.union !out !after | _ -> ());
          after := IntSet.union !after (of_list (uses instr)))
        (List.rev (instrs b)))
    (walk f);
  !out

(* The most values live at any one point — the registers the function wants. *)
let pressure f live =
  let most = ref 0 in
  List.iter
    (fun b ->
      let after = ref (live_out live b.label) in
      most := max !most (IntSet.cardinal !after);
      List.iter
        (fun instr ->
          Option.iter (fun d -> after := IntSet.remove d !after) (defs instr);
          after := IntSet.union !after (of_list (uses instr));
          most := max !most (IntSet.cardinal !after))
        (List.rev (instrs b));
      let entry =
        List.fold_left (fun acc phi -> IntSet.add phi.phi_dst acc) (live_in live b.label) b.phis
      in
      most := max !most (IntSet.cardinal entry))
    (walk f);
  !most
