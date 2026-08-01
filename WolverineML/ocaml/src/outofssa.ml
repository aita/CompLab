(* Leaving SSA before allocation.

   A phi is a copy that happens on an edge, so it becomes copies at the end of
   each predecessor.  Critical edges are already split, so a predecessor of a
   block with phis has nowhere else to go and the copies can simply be appended.

   The copies of one edge happen at once: every argument is read before any
   destination is written.  Usually that needs no care, because a phi's
   destination is defined nowhere else and so is nobody's argument — but a block
   that is its own predecessor can have two phis that swap, and then the copies go
   through temporaries, which is Sreedhar's answer and which coalescing is
   expected to remove again.

   That the copies are a cost to be paid is the point rather than a complaint:
   copies are what coalescing eats, and the allocator earns nearly all of them
   back. *)

open Ir

let copy_in_parallel f b moves =
  let real = List.filter (fun (dst, src) -> dst <> src) moves in
  if real <> [] then begin
    let written = List.map fst real and read = List.map snd real in
    let clash = List.exists (fun dst -> List.mem dst read) written in
    let copies =
      if clash then begin
        let through = List.map (fun (dst, _) -> (dst, new_reg f)) real in
        List.map (fun (dst, src) -> Move { dst = List.assoc dst through; src }) real
        @ List.map (fun (dst, _) -> Move { dst; src = List.assoc dst through }) real
      end
      else List.map (fun (dst, src) -> Move { dst; src }) real
    in
    (* Before the terminator, which is the last instruction of the block. *)
    let all = instrs b in
    let at = List.length all - 1 in
    set_instrs b (CCList.take at all @ copies @ CCList.drop at all)
  end

(* Replace every phi in [f] with copies in its predecessors. *)
let destruct f =
  List.iter
    (fun b ->
      if b.phis <> [] then begin
        List.iter
          (fun pred ->
            let source = block f pred in
            if List.length (succs source) <> 1 then
              failwith (pred ^ " -> " ^ b.label ^ " is a critical edge");
            let moves =
              List.map
                (fun phi ->
                  match phi_arg phi pred with
                  | Some a -> (phi.phi_dst, a.arg)
                  | None -> failwith ("a phi in " ^ b.label ^ " does not name " ^ pred))
                b.phis
            in
            copy_in_parallel f source moves)
          b.preds;
        b.phis <- []
      end)
    (walk f);
  recompute_preds f

let destruct_module m = List.iter destruct m.funcs
