(* The operand stack: the temporaries of the expression being evaluated, and
   nothing else.

   Arguments and bindings are not here — they are in the frame's locals — so the
   stack only ever holds values that some instruction a few steps further on is
   going to consume.  That is what makes its height a static property, and the
   verifier's height walk possible.

   It grows by doubling.  [truncate] is what a return uses to throw away whatever
   a call left above its own base, so the caller sees exactly the stack it had. *)

type t = { mutable data : Machine.value array; mutable size : int }

let create capacity =
  { data = Array.make (max 1 capacity) Machine.VUnit; size = 0 }

let length t = t.size

let push t value =
  if t.size = Array.length t.data then (
    let bigger = Array.make (2 * t.size) Machine.VUnit in
    Array.blit t.data 0 bigger 0 t.size;
    t.data <- bigger);
  t.data.(t.size) <- value;
  t.size <- t.size + 1

exception Underflow

let pop t =
  if t.size = 0 then raise Underflow;
  t.size <- t.size - 1;
  let value = t.data.(t.size) in
  (* Drop the reference: a popped value must not be kept alive by the stack. *)
  t.data.(t.size) <- Machine.VUnit;
  value

(* [peek t 0] is the top. *)
let peek t depth =
  if depth < 0 || depth >= t.size then raise Underflow;
  t.data.(t.size - 1 - depth)

let truncate t height =
  if height < t.size then (
    Array.fill t.data height (t.size - height) Machine.VUnit;
    t.size <- height)
