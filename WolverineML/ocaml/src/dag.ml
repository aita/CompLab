(* The data-flow DAG of one basic block.

   Instruction selection wants to see a block as expressions, not as a list:
   [a + (i lsl 3)] is one ARM instruction and [a + b*c] is another, and neither is
   visible while the operands are separate lines with names in between.  So each
   block is read into a graph — a node per instruction, an edge per operand — and
   the selector covers that graph with instructions.

   It is a graph and not a tree because a value can be read twice.  That is what
   [users] counts, and it is what decides whether a node may be folded into the
   instruction that reads it or has to become an instruction of its own: a node
   read twice would otherwise be computed twice.  A value that leaves the block
   counts as read as well, and so does one a phi in a successor names.

   Only pure nodes are ever folded, and only into a reader whose instruction
   really absorbs them.  Both halves matter.  Folding moves a computation to where
   it is read, which is fine for arithmetic and not fine for a load, because a
   store in between would change what it reads; and folding a chain of nodes that
   nothing absorbs would move a whole expression to its last line, leaving every
   value it read alive until then.  So the selector plans first — it asks, of each
   node with one reader, whether that reader has a tile that takes it — and
   everything else is computed where it was written. *)

open Ir

(* What an operand holds when the value came from outside the block. *)
let no_node = -1

type node = {
  index : int;
  instr : instr;
  operands : int list;
  mutable users : int;
  (* The only node that reads it, when there is one; else [no_node]. *)
  mutable reader : int;
  (* Read after the block ends, or by a phi in a successor. *)
  mutable escapes : bool;
}

type t = { nodes : node array }

let of_index d index = if index = no_node then None else Some d.nodes.(index)

let operand n at = try List.nth n.operands at with _ -> no_node

(* Read exactly once, inside the block, and computable where read. *)
let alone n =
  n.users = 1 && (not n.escapes) && match n.instr with Bin _ -> true | _ -> false

(* A constant, which costs nothing to repeat and is often not an instruction at
   all once it has become an immediate operand. *)
let rematerialisable d index =
  match of_index d index with
  | Some n when (not n.escapes) && (match n.instr with Const _ -> true | _ -> false) -> Some n
  | _ -> None

(* The value at [index], if it is a constant — however many read it.  Even one
   that has to exist in a register for somebody else can be an immediate here, so
   this asks less than folding does. *)
let constant d index =
  match of_index d index with
  | Some { instr = Const c; _ } -> Some c.value
  | _ -> None

(* Read a block into a graph.  [live_out] includes what the phis will read. *)
let build b live_out =
  let all = instrs b in
  let by_value = Hashtbl.create 32 in
  let nodes =
    List.mapi
      (fun at instr ->
        let operands =
          List.map
            (fun r -> match Hashtbl.find_opt by_value r with Some i -> i | None -> no_node)
            (uses instr)
        in
        let d = defs instr in
        if d <> no_reg then Hashtbl.replace by_value d at;
        { index = at; instr; operands; users = 0; reader = no_node; escapes = false })
      all
  in
  let nodes = Array.of_list nodes in
  Array.iter
    (fun n ->
      List.iter
        (fun operand ->
          if operand <> no_node then begin
            let read = nodes.(operand) in
            read.users <- read.users + 1;
            read.reader <- (if read.users = 1 then n.index else no_node)
          end)
        n.operands)
    nodes;
  Array.iter
    (fun n ->
      let v = defs n.instr in
      if v <> no_reg && IntSet.mem v live_out then n.escapes <- true)
    nodes;
  { nodes }

let plain r = Printf.sprintf "%%%d" r

let pad_right width text =
  if String.length text >= width then text
  else text ^ String.make (width - String.length text) ' '

let pad_left width text =
  if String.length text >= width then text
  else String.make (width - String.length text) ' ' ^ text

let show d =
  String.concat "\n"
    (Array.to_list
       (Array.map
          (fun n ->
            let reads =
              String.concat ", "
                (List.map (fun o -> if o = no_node then "-" else string_of_int o) n.operands)
            in
            let marks =
              (if n.escapes then "*" else "") ^ if has_effect n.instr then "!" else ""
            in
            Printf.sprintf "  %s%s %s reads [%s]  users %d"
              (pad_left 3 (string_of_int n.index))
              (pad_right 2 marks)
              (pad_right 38 (show_instr plain n.instr))
              reads n.users)
          d.nodes))
