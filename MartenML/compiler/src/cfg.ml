(* The graph, for either of the two control-flow graphs this compiler has.

   `Linear.func` and `Riscv.func` are both a list of blocks, each ending in a
   terminator that names its successors, so neither of them needs a graph built
   for it -- what they need is what walking one takes: which block a label is,
   who jumps to whom, which blocks the entry can reach, and an order to visit
   them in.  That is the same work for both, so this module asks for the two
   things it cannot know rather than committing to a block type:

     [label]       the label of a block
     [successors]  the labels its terminator names

   Nothing here mentions Linear or Riscv, which is what keeps the
   machine-independent half of the compiler from depending on the machine.

   Two things rest on the same walk.  Liveness is a backwards analysis, so it
   wants to see a block after everything it can reach; that is depth-first
   postorder.  And the same depth-first walk finds a back edge if there is one,
   which is how `is_acyclic` answers -- a claim the rest of the back end leans
   on, so it is worth checking rather than assuming.  See doc/regalloc.md §11. *)

type 'b t = {
  blocks : 'b array; (* by index, in the function's own order *)
  index : (Ident.label, int) Hashtbl.t;
  successors : int list array;
  predecessors : int list array;
  reachable : bool array;
  postorder : int list; (* successors first; entry last *)
  acyclic : bool;
}

let entry = 0

let build ~label ~successors blocks =
  let blocks = Array.of_list blocks in
  let n = Array.length blocks in
  let index = Hashtbl.create (max 1 n) in
  Array.iteri (fun i b -> Hashtbl.replace index (label b) i) blocks;
  let succs =
    Array.map (fun b -> List.filter_map (Hashtbl.find_opt index) (successors b)) blocks
  in
  let predecessors = Array.make n [] in
  Array.iteri
    (fun i ss -> List.iter (fun s -> predecessors.(s) <- i :: predecessors.(s)) ss)
    succs;
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
      (fun s -> if on_stack.(s) then acyclic := false else if not reachable.(s) then visit s)
      succs.(i);
    on_stack.(i) <- false;
    postorder := i :: !postorder
  in
  if n > 0 then visit entry;
  {
    blocks;
    index;
    successors = succs;
    predecessors = Array.map List.rev predecessors;
    reachable;
    postorder = List.rev !postorder;
    acyclic = !acyclic;
  }

let is_acyclic t = t.acyclic
let block t i = t.blocks.(i)

(* ------------------------------------------------------------------ layout *)

(* Order the blocks so that as many terminators as possible fall through to the
   block after them.  `emit.ml` drops a `Jump` whose target is next and inverts
   a `Branch` whose false arm is next, so every edge that becomes an adjacency
   is a jump instruction that never gets printed.

   [preferred] is the third thing this module cannot know: the successors a
   terminator could fall through to, best first.  A `Jump` has one candidate; a
   `Branch` can fall through to either arm.

   Greedy traces: from a block, follow an edge to a successor nothing has
   claimed yet, preferring the one the terminator can fall through to for free.
   When the trace runs out, start another at the earliest block still left, so
   that the result does not depend on hash order.

   On the code this compiler generates today it changes nothing: the assembly
   for all 42 test files is identical with and without it, because selection
   already emits blocks in the order a trace would pick them.  Following the
   arms greedily instead, without the sole-predecessor rule below, is worse --
   20 unconditional jumps across those files becomes 28.  What this buys is
   that the fall-through quality stops depending on the order selection happens
   to emit in. *)
let layout ~preferred t =
  let n = Array.length t.blocks in
  let placed = Array.make n false in
  let order = ref [] in
  let candidates i = List.filter_map (Hashtbl.find_opt t.index) (preferred t.blocks.(i)) in
  (* Only extend a trace into a block this one is the sole way into.  A join
     block has several predecessors, and dragging it along behind one of them
     leaves the others jumping to it. *)
  let rec trace i =
    placed.(i) <- true;
    order := i :: !order;
    match
      List.find_opt
        (fun s -> (not placed.(s)) && List.length t.predecessors.(s) = 1)
        (candidates i)
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
