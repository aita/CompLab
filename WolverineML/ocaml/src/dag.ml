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
  users : int;
  (* The only node that reads it, when there is one; else [no_node]. *)
  reader : int;
  (* Read after the block ends, or by a phi in a successor. *)
  escapes : bool;
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

(* Read a block into a graph.  [live_out] includes what the phis will read.

   A node's facts are settled while the graph is built and never change after, so
   they are fields of a value and not something to be filled in later: the
   operands first, because they are what tells the rest apart, then who reads
   each node, then what leaves the block. *)
let build b live_out =
  let all = Array.of_list (instrs b) in
  let count = Array.length all in

  (* Which node made each value, as far as we have read.  The loop is a [for] and
     not a map because the answer depends on how far it has got. *)
  let by_value = Hashtbl.create 32 in
  let operands = Array.make count [] in
  for at = 0 to count - 1 do
    operands.(at) <-
      List.map
        (fun r -> Option.value (Hashtbl.find_opt by_value r) ~default:no_node)
        (uses all.(at));
    Option.iter (fun d -> Hashtbl.replace by_value d at) (defs all.(at))
  done;

  let users = Array.make count 0 in
  let reader = Array.make count no_node in
  Array.iteri
    (fun at ops ->
      List.iter
        (fun operand ->
          if operand <> no_node then begin
            users.(operand) <- users.(operand) + 1;
            reader.(operand) <- (if users.(operand) = 1 then at else no_node)
          end)
        ops)
    operands;

  let escapes at =
    match defs all.(at) with Some v -> IntSet.mem v live_out | None -> false
  in
  { nodes =
      Array.init count (fun at ->
          { index = at;
            instr = all.(at);
            operands = operands.(at);
            users = users.(at);
            reader = reader.(at);
            escapes = escapes at
          })
  }

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
