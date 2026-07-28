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
   row of pointers to three-word blocks -- and writing to one allocates.  The
   two ways to get 64 real bits are Bytes with get/set_int64_ne and a Bigarray
   of int64; both keep the storage flat and hand back a boxed Int64 at each
   access, which flambda would remove and this build does not have.

   Union of two million-word sets, best of seven, 5.4.1 without flambda:

     int array, 63 bits/word                    1.15 ms     8 bytes/word
     Bigarray int64, unsafe_get/set              1.51 ms     8, off-heap
     Bytes, get/set_int64_ne                     2.50 ms     8
     int64 array                                31.69 ms    32

   (`Array.make n 0L` looks like 8 bytes a word only because every slot shares
   the one box; the first write ends that.)  Bigarray is the near miss: 1.3x
   for the 64th bit, a dependency, and unsafe accessors to get even that.  The
   int array costs one bit per word instead, which is 1.6% more words. *)
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
