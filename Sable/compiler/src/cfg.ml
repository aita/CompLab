(* The control-flow graph of one function, as the passes after selection want
   to look at it.

   `Riscv.func` already is a control-flow graph -- a list of blocks, each
   ending in a terminator that names its successors -- so this module adds only
   what walking it needs: which block a label is, who jumps to whom, which
   blocks the entry can reach, and an order to visit them in.

   Two things here rest on the same walk.  Liveness is a backwards analysis, so
   it wants to see a block after everything it can reach; that is depth-first
   postorder.  And the same depth-first walk finds a back edge if there is one,
   which is how `is_acyclic` answers -- a claim the rest of the back end leans
   on, so it is worth checking rather than assuming.  See doc/regalloc.md §10. *)

type t = {
  blocks : Riscv.block array; (* by index, in the function's own order *)
  index : (Ident.label, int) Hashtbl.t;
  successors : int list array;
  predecessors : int list array;
  reachable : bool array;
  postorder : int list; (* successors first; entry last *)
  acyclic : bool;
}

let entry = 0

let build (func : Riscv.func) =
  let blocks = Array.of_list func.Riscv.blocks in
  let n = Array.length blocks in
  let index = Hashtbl.create (max 1 n) in
  Array.iteri (fun i (b : Riscv.block) -> Hashtbl.replace index b.label i) blocks;
  let successors =
    Array.map
      (fun (b : Riscv.block) ->
        List.filter_map (Hashtbl.find_opt index) (Riscv.successors b.terminator))
      blocks
  in
  let predecessors = Array.make n [] in
  Array.iteri
    (fun i succs -> List.iter (fun s -> predecessors.(s) <- i :: predecessors.(s)) succs)
    successors;
  (* One depth-first walk gives the postorder, what the entry can reach, and
     whether any edge goes back to a block still on the stack. *)
  let reachable = Array.make n false in
  let on_stack = Array.make n false in
  let acyclic = ref true in
  let postorder = ref [] in
  let rec visit i =
    reachable.(i) <- true;
    on_stack.(i) <- true;
    List.iter
      (fun s ->
        if on_stack.(s) then acyclic := false else if not reachable.(s) then visit s)
      successors.(i);
    on_stack.(i) <- false;
    postorder := i :: !postorder
  in
  if n > 0 then visit entry;
  {
    blocks;
    index;
    successors;
    predecessors = Array.map List.rev predecessors;
    reachable;
    postorder = List.rev !postorder;
    acyclic = !acyclic;
  }

let is_acyclic t = t.acyclic
let block t i = t.blocks.(i)
let label t i = t.blocks.(i).Riscv.label

(* Blocks the entry cannot reach, in the function's own order.  Peephole's jump
   threading is what usually strands one. *)
let unreachable t =
  let out = ref [] in
  Array.iteri (fun i r -> if not r then out := i :: !out) t.reachable;
  List.rev !out

(* ------------------------------------------------------------------ layout *)

(* Order the blocks so that as many terminators as possible fall through to the
   block after them.  `emit.ml` drops a `Jump` whose target is next and inverts
   a `Branch` whose false arm is next, so every edge that becomes an adjacency
   is a jump instruction that never gets printed.

   Greedy traces: from a block, follow an edge to a successor nothing has
   claimed yet, preferring the one the terminator can fall through to for free.
   When the trace runs out, start another at the earliest block still left, so
   that the result does not depend on hash order.

   On the code this compiler generates today it changes nothing: the assembly
   for all 42 test files is identical with and without it, because selection
   already emits blocks in the order a trace would pick them.  Following the
   arms greedily instead, without the sole-predecessor rule below, is worse --
   20 unconditional jumps across those files becomes 26.  What this buys is
   that the fall-through quality stops depending on the order selection happens
   to emit in. *)
let layout t =
  let n = Array.length t.blocks in
  let placed = Array.make n false in
  let order = ref [] in
  let preferred i =
    (* A Jump has one candidate; a Branch falls through on its false arm. *)
    match t.blocks.(i).Riscv.terminator with
    | Riscv.Jump l -> ( match Hashtbl.find_opt t.index l with Some s -> [ s ] | None -> [])
    | Riscv.Branch (_, _, _, if_true, if_false) ->
      List.filter_map (Hashtbl.find_opt t.index) [ if_true; if_false ]
    | Riscv.Return _ | Riscv.Tail_call _ -> []
  in
  (* Only extend a trace into a block this one is the sole way into.  A join
     block has several predecessors, and dragging it along behind one of them
     leaves the others jumping to it. *)
  let rec trace i =
    placed.(i) <- true;
    order := i :: !order;
    match
      List.find_opt
        (fun s -> (not placed.(s)) && List.length t.predecessors.(s) = 1)
        (preferred i)
    with
    | Some s -> trace s
    | None -> ()
  in
  let rec next_start i =
    if i >= n then ()
    else if placed.(i) || not t.reachable.(i) then next_start (i + 1)
    else begin
      trace i;
      next_start 0
    end
  in
  if n > 0 then begin
    trace entry;
    next_start 0
  end;
  List.rev_map (fun i -> t.blocks.(i)) !order

(* Reorder a function's blocks in place, dropping any the entry cannot reach.
   The entry block stays first: the emitter puts the prologue there. *)
let relayout (func : Riscv.func) =
  let t = build func in
  func.Riscv.blocks <- layout t
