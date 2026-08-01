(* What the allocator and the emitter both have to agree about: the registers.

   x16 and x17 are the ABI's intra-procedure-call scratch registers, which a
   linker veneer may clobber at a [bl].  Nothing of ours is ever live across a
   call in a caller-saved register, so x16 is allocatable like any other; x17 is
   the one register kept back, for an address the emitter has to compute after
   allocation is over.  x18 is the platform register, x29 the frame pointer, x30
   the link register. *)

let caller_saved = [ 9; 10; 11; 12; 13; 14; 15; 16; 0; 1; 2; 3; 4; 5; 6; 7; 8 ]
let callee_saved = [ 19; 20; 21; 22; 23; 24; 25; 26; 27; 28 ]
let argument_regs = [ 0; 1; 2; 3; 4; 5; 6; 7 ]
let scratch = [ 17 ]

(* The machine the allocator is colouring for. *)
type t = { caller : int list; callee : int list }

let all = { caller = caller_saved; callee = callee_saved }
let anywhere m = m.caller @ m.callee
let count m = List.length m.caller + List.length m.callee

(* A smaller machine, so that the spiller can be tested on small programs.
   [CCList.take] stops at the end of the list, the way Python's slice does, so
   asking for more registers than this machine has is capped rather than fatal. *)
let limited max_regs =
  let callee = CCList.take (max 2 (max_regs / 2)) callee_saved in
  let caller = CCList.take (max 1 (max_regs - List.length callee)) caller_saved in
  { caller; callee }

let is_callee_saved colour = List.mem colour callee_saved
