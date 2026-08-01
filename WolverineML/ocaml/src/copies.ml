(* Doing several copies at once, one at a time.

   Every argument of a call is read before any of them is written, and so is every
   parameter at the top of a function.  Once the allocator has given both ends
   real registers that is a permutation, and putting a permutation into a sequence
   of instructions is this file.

   Copies whose destination nobody else has still to read can go first.  When only
   cycles are left, something has to be got out of the way, and there are two ways
   to do it: a register the function never used can hold a value for one step, and
   if there is no such register the two ends of the cycle swap.  A swap is three
   [eor]s and needs nothing to borrow, which is why no register is reserved for
   this anywhere in the compiler. *)

type step = Mov of int * int | Swap of int * int

(* [sequentialize] orders the `(destination, source)` pairs so that nothing is
   lost on the way.  [borrowed] of [-1] means there is nothing free to hold a
   value for a step.

   [pending] keeps the order it was given in, because which copy is picked when
   only cycles are left has to be the same every run. *)
let sequentialize moves borrowed =
  let pending = ref (List.filter (fun (dst, src) -> dst <> src) moves) in
  let seen = Hashtbl.create 16 in
  List.iter
    (fun (dst, _) ->
      if Hashtbl.mem seen dst then failwith "a parallel copy writes a register twice";
      Hashtbl.replace seen dst ())
    !pending;

  (* The value that was in [was] is in [now]; whoever wanted it looks there. *)
  let moved was now =
    pending :=
      List.filter_map
        (fun (dst, src) ->
          if src <> was then Some (dst, src)
          else if dst = now then None (* the swap already put it where it belongs *)
          else Some (dst, now))
        !pending
  in

  let done_ = ref [] in
  while !pending <> [] do
    let sources = List.map snd !pending in
    let ready = List.filter (fun (dst, _) -> not (List.mem dst sources)) !pending in
    if ready <> [] then
      List.iter
        (fun (dst, src) ->
          done_ := Mov (dst, src) :: !done_;
          pending := List.filter (fun (d, _) -> d <> dst) !pending)
        ready
    else begin
      let stuck, other = List.hd !pending in
      if borrowed >= 0 then begin
        done_ := Mov (borrowed, stuck) :: !done_;
        moved stuck borrowed
      end
      else begin
        (* Swapping satisfies [stuck] outright and leaves its old value where the
           other end was, so everything still to read it reads there instead. *)
        pending := List.filter (fun (d, _) -> d <> stuck) !pending;
        done_ := Swap (stuck, other) :: !done_;
        moved stuck other
      end
    end
  done;
  List.rev !done_
