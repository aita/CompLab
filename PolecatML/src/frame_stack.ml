(* Frames, and the stack of them.

   A frame is one call in progress: the closure it is running, where in that
   closure's code it is, its arguments and bindings, and how tall the operand
   stack was when it started.  There is no second notion of an activation record
   — this is it.

   The stack of frames is the machine's continuation.  A call pushes; a return
   pops; a tail call *replaces the top*, which is the whole of proper tail calls:
   the caller's continuation is reused rather than extended, so a loop written as
   recursion runs in constant space here. *)

type frame = {
  closure : Machine.closure;
  mutable pc : int;
  locals : Machine.value array;
  stack_base : int; (* the height of the operand stack when this call began *)
}

(* [high] is the deepest the stack has ever been: the number that says whether
   tail calls are really being made. *)
type t = { mutable data : frame array; mutable size : int; mutable high : int }

let dummy =
  {
    closure = { Machine.function_id = 0; captures = [||] };
    pc = 0;
    locals = [||];
    stack_base = 0;
  }

let create capacity =
  { data = Array.make (max 1 capacity) dummy; size = 0; high = 0 }

let is_empty t = t.size = 0
let depth t = t.size
let deepest t = t.high

exception Empty

let push t frame =
  if t.size = Array.length t.data then (
    let bigger = Array.make (2 * t.size) dummy in
    Array.blit t.data 0 bigger 0 t.size;
    t.data <- bigger);
  t.data.(t.size) <- frame;
  t.size <- t.size + 1;
  if t.size > t.high then t.high <- t.size

let pop t =
  if t.size = 0 then raise Empty;
  t.size <- t.size - 1;
  let frame = t.data.(t.size) in
  t.data.(t.size) <- dummy;
  frame

let top t =
  if t.size = 0 then raise Empty;
  t.data.(t.size - 1)

let replace_top t frame =
  if t.size = 0 then raise Empty;
  t.data.(t.size - 1) <- frame
