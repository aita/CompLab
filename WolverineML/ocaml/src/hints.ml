(* Which colour a value would like, which is the calling convention asking.

   The allocator does not have to satisfy these — a preference is dropped the
   moment it clashes with something the colouring actually requires — but taking
   one when it is free is what stops the emitter having to move a value into [x2]
   on the way into a call, or out of [x0] on the way back from one. *)

open Ir

(* The register each value is about to be wanted in, where there is one. *)
let preferences f =
  let wanted = ref IntMap.empty in
  Dynarray.iteri
    (fun at param ->
      if at < List.length Registers.argument_regs then
        wanted := IntMap.add param (List.nth Registers.argument_regs at) !wanted)
    f.params;
  List.iter
    (fun b ->
      List.iter
        (fun instr ->
          match instr with
          | Call c ->
              List.iteri
                (fun at arg ->
                  if at < List.length Registers.argument_regs then
                    wanted := IntMap.add arg (List.nth Registers.argument_regs at) !wanted)
                c.args;
              if c.dst <> no_reg then
                wanted := IntMap.add c.dst (List.hd Registers.argument_regs) !wanted
          | Ret r ->
              if r.value <> no_reg then
                wanted := IntMap.add r.value (List.hd Registers.argument_regs) !wanted
          | _ -> ())
        (instrs b))
    (walk f);
  !wanted
