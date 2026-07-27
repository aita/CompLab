(* A set of integers drawn from a known, dense range, as one bit each.

   The allocator asks its sets the same few questions, millions of times, about
   elements that are indices into a dense range: is this in you, what is your
   smallest member, iterate over you, what is the union.  A balanced tree
   answers each in O(log n) and allocates a fresh spine on every update.  A bit
   per element answers them with word operations and, once the set exists,
   allocates nothing at all.

   The cost is that every operation is O(capacity / 63) whatever the set holds,
   so this is the right representation for the sets that are whole-graph sized
   and constantly updated, and the wrong one for a set of two things drawn from
   a range of a million.  See regalloc.ml, which uses it for both the worklists
   and the adjacency, and the note there about what that costs in memory.

   Iteration is in increasing order, like Set.Make(Int), which the allocator
   relies on: it decides which node to simplify or spill by taking the smallest
   of a set, so the order fixes the code that comes out. *)

(* An OCaml int is 63 bits wide on a 64-bit machine.  Only logical operations
   are used below, so the top bit carries a member like any other.

   Not Int64, which would give the other bit.  `float array` is the only array
   OCaml stores unboxed; an Int64.t is a custom block, so an `int64 array` is a
   row of pointers to three-word blocks -- and writing to one allocates.
   Measured here on 5.4.1 without flambda, a million distinct words:

     int array     8 bytes each    union of two of them   1.2 ms
     int64 array  32 bytes each                          31.6 ms
     Bytes         8 bytes each                           2.5 ms

   (`Array.make n 0L` looks like 8 bytes each only because every slot shares
   the one box; the first write ends that.)  Bytes with get/set_int64_ne ties
   on memory and gives the 64th bit, but the intermediate Int64 stays boxed
   without flambda.  The price of the int array is one bit per word, which is
   1.6% more words. *)
let width = 63

type t = { words : int array; capacity : int }

let create capacity =
  { words = Array.make ((capacity + width - 1) / width) 0; capacity }

let capacity t = t.capacity
let clear t = Array.fill t.words 0 (Array.length t.words) 0

let mem t i = t.words.(i / width) land (1 lsl (i mod width)) <> 0

let add t i =
  let w = i / width in
  t.words.(w) <- t.words.(w) lor (1 lsl (i mod width))

let remove t i =
  let w = i / width in
  t.words.(w) <- t.words.(w) land lnot (1 lsl (i mod width))

let is_empty t =
  let n = Array.length t.words in
  let rec go i = i >= n || (t.words.(i) = 0 && go (i + 1)) in
  go 0

(* The smallest member.  Raises Not_found on an empty set, like Set.min_elt. *)
let min_elt t =
  let n = Array.length t.words in
  let rec word i =
    if i >= n then raise Not_found
    else if t.words.(i) = 0 then word (i + 1)
    else
      let rec bit b w = if w land 1 <> 0 then (i * width) + b else bit (b + 1) (w lsr 1) in
      bit 0 t.words.(i)
  in
  word 0

let iter f t =
  let n = Array.length t.words in
  for i = 0 to n - 1 do
    let w = ref t.words.(i) in
    if !w <> 0 then begin
      let base = i * width and bit = ref 0 in
      while !w <> 0 do
        if !w land 1 <> 0 then f (base + !bit);
        w := !w lsr 1;
        incr bit
      done
    end
  done

let fold f t init =
  let acc = ref init in
  iter (fun i -> acc := f i !acc) t;
  !acc

let exists p t =
  let n = Array.length t.words in
  let rec word i =
    if i >= n then false
    else if t.words.(i) = 0 then word (i + 1)
    else
      let base = i * width in
      let rec bit b w =
        if w = 0 then word (i + 1)
        else if w land 1 <> 0 && p (base + b) then true
        else bit (b + 1) (w lsr 1)
      in
      bit 0 t.words.(i)
  in
  word 0

let for_all p t = not (exists (fun i -> not (p i)) t)

let count p t = fold (fun i acc -> if p i then acc + 1 else acc) t 0

(* dst <- dst ∪ src.  The two must have the same capacity. *)
let union_into dst src =
  for i = 0 to Array.length dst.words - 1 do
    dst.words.(i) <- dst.words.(i) lor src.words.(i)
  done

let copy_into dst src = Array.blit src.words 0 dst.words 0 (Array.length dst.words)

let of_list capacity xs =
  let t = create capacity in
  List.iter (add t) xs;
  t
