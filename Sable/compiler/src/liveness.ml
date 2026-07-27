(* Liveness analysis over the control-flow graph.

   A register is live at a point if some path from there reads it before
   writing it.  Everything the allocator does rests on this: two values
   interfere exactly when one is live where the other is defined.

   Control flow inside a function is acyclic here -- a loop in the source is a
   recursive call, which leaves the function -- so the backwards fixed point
   converges in a single pass over the blocks in reverse.  The loop is written
   as a general fixed point anyway, since nothing else in the back end depends
   on the graph being acyclic. *)

module RegSet = Set.Make (Int)

let set_of_list = List.fold_left (fun acc r -> RegSet.add r acc) RegSet.empty

(* Registers live just before [block], given those live just after it. *)
let live_in_of_block (block : Ir.block) live_out =
  let live = ref (RegSet.union live_out (set_of_list (Ir.terminator_uses block.terminator))) in
  List.iter
    (fun instr ->
      live :=
        RegSet.union
          (RegSet.diff !live (set_of_list (Ir.defines instr)))
          (set_of_list (Ir.uses instr)))
    (List.rev block.body);
  !live

(* Live-out sets for every block, keyed by label. *)
let analyze (func : Ir.func) =
  let live_out = Hashtbl.create 16 in
  let live_in = Hashtbl.create 16 in
  List.iter
    (fun (b : Ir.block) ->
      Hashtbl.replace live_out b.label RegSet.empty;
      Hashtbl.replace live_in b.label RegSet.empty)
    func.blocks;
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter
      (fun (b : Ir.block) ->
        let out =
          List.fold_left
            (fun acc succ ->
              match Hashtbl.find_opt live_in succ with
              | Some s -> RegSet.union acc s
              | None -> acc)
            RegSet.empty
            (Ir.successors b.terminator)
        in
        let inn = live_in_of_block b out in
        if not (RegSet.equal out (Hashtbl.find live_out b.label)) then changed := true;
        if not (RegSet.equal inn (Hashtbl.find live_in b.label)) then changed := true;
        Hashtbl.replace live_out b.label out;
        Hashtbl.replace live_in b.label inn)
      (List.rev func.blocks)
  done;
  live_out

(* An instruction can be dropped when it only writes a register nothing reads.
   Note the test is on the instruction's actual destination, not on what the
   allocator tracks: `mv t6, x` writes a reserved register and has to stay. *)
let writes_dead_register live = function
  | Ir.Li (d, _)
  | Ir.La (d, _)
  | Ir.Move (d, _)
  | Ir.Arith (_, d, _, _)
  | Ir.Arith_imm (_, d, _, _)
  | Ir.Load (d, _, _) ->
    Ir.is_tracked d && not (RegSet.mem d live)
  | Ir.Store _ | Ir.Call _ -> false

let eliminate_dead_code (func : Ir.func) =
  let live_out = analyze func in
  List.iter
    (fun (b : Ir.block) ->
      let live =
        ref
          (RegSet.union
             (Hashtbl.find live_out b.label)
             (set_of_list (Ir.terminator_uses b.terminator)))
      in
      let kept =
        List.fold_left
          (fun kept instr ->
            if writes_dead_register !live instr then kept
            else begin
              live :=
                RegSet.union
                  (RegSet.diff !live (set_of_list (Ir.defines instr)))
                  (set_of_list (Ir.uses instr));
              instr :: kept
            end)
          [] (List.rev b.body)
      in
      b.body <- kept)
    func.blocks
