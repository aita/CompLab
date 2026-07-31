(* Instruction scheduling, one basic block at a time.

   Two instructions can be swapped unless one depends on the other.  Collect the
   dependences into a graph, and the block becomes a partial order rather than a
   sequence; scheduling is choosing a linear order out of it, and a good one puts
   an instruction as far as possible from the one whose result it needs.

   List scheduling is the standard way and is what this is.  Walk forward through
   a virtual clock; at each step, of the instructions whose predecessors have all
   issued, pick the one on the longest remaining path to the end of the block.
   The longest path -- the *height* -- is computed once, backwards, and is the
   whole of the heuristic: an instruction that many others are waiting behind
   should go first.

   Four kinds of dependence, and getting any of them wrong produces code that is
   wrong rather than slow:

     true      i writes a register, j reads it
     anti      i reads a register, j writes it
     output    both write the same register
     memory    both touch the heap, or either one is a call

   And a fifth that is easy to forget, because it is a register nobody names:
   the **flags**.  A `cmp` sets them and the block's terminator reads them, so
   every instruction that writes flags has to stay in order relative to every
   other one.  A call clobbers them too.

   This runs *after* register allocation, and that was measured rather than
   assumed.  Scheduling on virtual registers, before allocation, is where there is
   the most freedom -- and it made things worse: holding values live longer pushed
   the allocator into spilling, and the spill references in the examples nearly
   doubled.  After allocation the anti-dependences run through the real registers
   and there is much less room, but the frame is already fixed, so the scheduler
   cannot cost anything.  What it can still do is move a load away from the
   instruction that needs it, including a spill reload -- which is the case worth
   having, since that is the longest latency in the block.

   The textbook answer is to schedule twice, once on each side, with the first
   pass aware of register pressure (Goodman and Hsu).  That pass is `pre` below.
   It is written, it is measured, and it is *off*: on this corpus it buys nothing
   and costs a little, so it is behind an environment variable rather than in the
   pipeline ([17章](../doc/17-loops.md)). *)

module M = Mach
module IS = Regalloc.IS

let flags_written = function
  | M.Alu _ | M.Sar _ | M.Shl _ | M.Neg _ | M.Cmp _ | M.Setcc _ | M.Idiv _ | M.Cqo | M.Call _
  | M.CallReg _ | M.Syscall ->
      true
  | _ -> false

let touches_memory = function
  | M.Mov (M.Mem _, _) | M.Mov (_, M.Mem _) -> true
  | M.Alu (_, M.Mem _, _) | M.Alu (_, _, M.Mem _) -> true
  | M.Loadb (_, M.Mem _) | M.Storeb (M.Mem _, _) -> true
  | M.Call _ | M.CallReg _ | M.Syscall | M.RepMovsb -> true
  | M.Push _ | M.Pop _ -> true
  | _ -> false

(* Deliberately more conservative than the allocator's version.  A call is given
   every caller-saved register as both a read and a write, so that the moves that
   set up its arguments cannot drift past it and the move that takes its result
   cannot drift before it.  The allocator does not need that -- it does not
   reorder anything -- and giving it the same reads would extend live ranges for
   nothing. *)
let regs_in : M.operand -> M.reg list = function
  | M.Reg r -> [ r ]
  | M.Imm _ -> []
  | M.Mem { base; index; _ } ->
      (match base with Some b -> [ b ] | None -> [])
      @ match index with Some i -> [ i ] | None -> []

let call_regs = List.map (fun i -> M.R i) M.caller_saved

let reads_writes (i : M.instr) =
  let dst_w = function M.Reg r -> [ r ] | _ -> [] in
  let dst_r = function M.Reg _ -> [] | o -> regs_in o in
  match i with
  | M.Mov (d, s) -> (dst_r d @ regs_in s, dst_w d)
  | M.Lea (d, s) -> (regs_in s, [ d ])
  | M.Alu (_, d, s) -> (regs_in d @ regs_in s, dst_w d)
  | M.Sar (d, _) | M.Shl (d, _) | M.Neg d -> (regs_in d, dst_w d)
  | M.Cmp (a, b) -> (regs_in a @ regs_in b, [])
  | M.Setcc (_, d) -> ([], [ d ])
  | M.Idiv r -> ([ r; M.R M.rax; M.R M.rdx ], [ M.R M.rax; M.R M.rdx ])
  | M.Cqo -> ([ M.R M.rax ], [ M.R M.rdx ])
  | M.Call _ -> (call_regs, call_regs)
  | M.CallReg r -> (r :: call_regs, call_regs)
  | M.Push o -> (regs_in o, [])
  | M.Pop d -> ([], dst_w d)
  | M.Loadb (d, s) -> (regs_in s, [ d ])
  | M.Storeb (d, s) -> (regs_in d @ [ s ], [])
  | M.RepMovsb -> ([ M.R M.rdi; M.R M.rsi; M.R M.rcx ], [ M.R M.rdi; M.R M.rsi; M.R M.rcx ])
  | M.Syscall -> (call_regs, call_regs)
  | M.Comment _ -> ([], [])

(* How long before the result is usable.  Rough, and only the relative sizes
   matter: a load is worth waiting for, a call much more so, everything else is
   one. *)
let latency = function
  | M.Call _ | M.CallReg _ | M.Syscall -> 8
  | M.Mov (_, M.Mem _) | M.Loadb _ -> 4
  | M.Alu (_, _, M.Mem _) -> 4
  | M.RepMovsb -> 8
  | _ -> 1

(* j depends on i, for i < j, if any of the four kinds holds. *)
let dependences code rw =
  let n = Array.length code in
  let deps = Array.make n [] in
  for j = 0 to n - 1 do
    let rj, wj = rw.(j) in
    for i = 0 to j - 1 do
      let ri, wi = rw.(i) in
      let shares a b = List.exists (fun x -> List.mem x b) a in
      let dep =
        shares wi rj (* true *) || shares ri wj (* anti *) || shares wi wj (* output *)
        || (touches_memory code.(i) && touches_memory code.(j))
        || (flags_written code.(i) && flags_written code.(j))
      in
      if dep then deps.(j) <- i :: deps.(j)
    done
  done;
  deps

(* The height: the longest path from here to the end, in latencies.  One
   backwards pass, because a dependence only ever points at a lower index. *)
let heights code deps =
  let n = Array.length code in
  let height = Array.make n 0 in
  for i = n - 1 downto 0 do
    height.(i) <- latency code.(i);
    for j = i + 1 to n - 1 do
      if List.mem i deps.(j) then height.(i) <- max height.(i) (latency code.(i) + height.(j))
    done
  done;
  height

let block (b : M.block) =
  let code = Array.of_list (List.rev b.M.code) in
  let n = Array.length code in
  if n > 1 then begin
    let rw = Array.map reads_writes code in
    let deps = dependences code rw in
    let height = heights code deps in
    let issued = Array.make n false in
    let ready_at = Array.make n 0 in
    let out = ref [] in
    let clock = ref 0 in
    for _ = 1 to n do
      (* Everything whose dependences have issued.  Among those, the one that has
         waited long enough and is on the longest path; if nothing is ready yet,
         the clock moves on. *)
      let candidates = ref [] in
      for i = 0 to n - 1 do
        if (not issued.(i)) && List.for_all (fun d -> issued.(d)) deps.(i) then
          candidates := i :: !candidates
      done;
      let ok = List.filter (fun i -> ready_at.(i) <= !clock) !candidates in
      let pool = if ok = [] then !candidates else ok in
      let pick =
        List.fold_left
          (fun best i ->
            if height.(i) > height.(best) || (height.(i) = height.(best) && i < best) then i
            else best)
          (List.hd pool) pool
      in
      if ready_at.(pick) > !clock then clock := ready_at.(pick);
      issued.(pick) <- true;
      out := code.(pick) :: !out;
      clock := !clock + 1;
      for j = 0 to n - 1 do
        if List.mem pick deps.(j) then
          ready_at.(j) <- max ready_at.(j) (!clock - 1 + latency code.(pick))
      done
    done;
    (* [code] is kept reversed, which is what [out] already is. *)
    b.M.code <- !out
  end

let func (f : M.func) = List.iter block f.M.blocks
let program (p : M.prog) = List.iter func p.M.funcs

(* ---- the pass on the other side: scheduling that watches the pressure ----- *)

(* Goodman and Hsu.  The pass above runs after allocation, where the frame is
   already fixed and no schedule can cost anything; this one runs before it, on
   virtual registers, where there is far more room and every extra instruction
   between a definition and its last use is a value the allocator has to keep
   somewhere.

   So the priority is switched rather than fixed.  While few values are live,
   pick by height, exactly as above -- latency is the thing worth chasing and
   there are colours to spare.  Once the number of live values crosses a
   threshold, stop chasing latency and pick the instruction that *reduces* the
   live count most: the one whose operands die here and whose result nobody
   wants.  Below the threshold the schedule is as good as it can be; above it,
   it is as small as it can be.

   Whether a use kills its value is the only new question, and it is answered by
   counting: for each register, how many instructions that have not issued yet
   still read it.  When that reaches zero and the register is not live out of the
   block, the value is gone.  The count is kept as the schedule is built rather
   than read off the original order, because the order is exactly what is being
   changed.

   The pressure model reads the *allocator's* table and not `reads_writes`
   above.  The one above is deliberately conservative -- a call reads and writes
   every caller-saved register so that nothing drifts across it -- and that is
   right for dependences and quite wrong for pressure: a call does not really
   make nine values live. *)

(* Where "low pressure" stops.  The natural value is the number of colours --
   below it the allocator has room, at it something is about to be pushed out --
   and on these programs the natural value never fires: a block here rarely
   holds fourteen live values, so a threshold of K leaves the pass picking by
   height from beginning to end, which is the thing 17.6 already rejected.  Four
   is where the sweep in 17.6 bottomed out. *)
let pressure_limit = ref 4

let pre_block live_in live_out (b : M.block) =
  let code = Array.of_list (List.rev b.M.code) in
  let n = Array.length code in
  if n > 1 then begin
    let rw = Array.map reads_writes code in
    let deps = dependences code rw in
    let height = heights code deps in
    let du =
      Array.map
        (fun i ->
          let d, u = Regalloc.defs_uses i in
          (List.sort_uniq compare (Regalloc.nodes d), List.sort_uniq compare (Regalloc.nodes u)))
        code
    in
    (* How many instructions that have not issued yet still read this value. *)
    let remaining = Hashtbl.create 32 in
    let left r = try Hashtbl.find remaining r with Not_found -> 0 in
    Array.iter (fun (_, u) -> List.iter (fun r -> Hashtbl.replace remaining r (left r + 1)) u) du;
    let live = ref live_in in
    (* What issuing i would do to the live set: the values whose last reader it
       is, and the values it starts.  A definition nobody reads and that is not
       live out never becomes live at all -- which is what keeps the nine
       registers a call writes from looking like nine values. *)
    let shift i =
      let d, u = du.(i) in
      let after r = left r - if List.mem r u then 1 else 0 in
      let dead r = after r = 0 && not (IS.mem r live_out) in
      let gone =
        List.filter (fun r -> dead r && IS.mem r !live) (List.sort_uniq compare (u @ d))
      in
      let born = List.filter (fun r -> (not (dead r)) && not (IS.mem r !live)) d in
      (gone, born)
    in
    let issued = Array.make n false in
    let ready_at = Array.make n 0 in
    let out = ref [] in
    let clock = ref 0 in
    for _ = 1 to n do
      let candidates = ref [] in
      for i = 0 to n - 1 do
        if (not issued.(i)) && List.for_all (fun d -> issued.(d)) deps.(i) then
          candidates := i :: !candidates
      done;
      let tight = IS.cardinal !live >= !pressure_limit in
      (* Under pressure the clock is not worth obeying: waiting for a latency is
         waiting with everything still live. *)
      let pool =
        if tight then !candidates
        else
          match List.filter (fun i -> ready_at.(i) <= !clock) !candidates with
          | [] -> !candidates
          | ok -> ok
      in
      let delta i =
        let gone, born = shift i in
        List.length born - List.length gone
      in
      let better i best =
        if tight then delta i < delta best || (delta i = delta best && i < best)
        else height.(i) > height.(best) || (height.(i) = height.(best) && i < best)
      in
      let pick =
        List.fold_left (fun best i -> if better i best then i else best) (List.hd pool) pool
      in
      let gone, born = shift pick in
      List.iter (fun r -> Hashtbl.replace remaining r (left r - 1)) (snd du.(pick));
      live := List.fold_left (fun s r -> IS.remove r s) !live gone;
      live := List.fold_left (fun s r -> IS.add r s) !live born;
      if ready_at.(pick) > !clock then clock := ready_at.(pick);
      issued.(pick) <- true;
      out := code.(pick) :: !out;
      clock := !clock + 1;
      for j = 0 to n - 1 do
        if List.mem pick deps.(j) then
          ready_at.(j) <- max ready_at.(j) (!clock - 1 + latency code.(pick))
      done
    done;
    (* At this point the live set is exactly the block's live-out again, which is
       the one check this model has on itself. *)
    b.M.code <- !out
  end

let pre_func (f : M.func) =
  let live_in, live_out = Regalloc.liveness f in
  List.iter
    (fun (b : M.block) ->
      pre_block (Hashtbl.find live_in b.M.id) (Hashtbl.find live_out b.M.id) b)
    f.M.blocks

(* Off unless asked for, because it did not pay: see 17.6.  The threshold is a
   parameter because that is how the table there was made -- sweeping it is the
   measurement, and every setting lost. *)
let pre ?threshold (p : M.prog) =
  (match threshold with Some n when n > 1 -> pressure_limit := n | _ -> ());
  List.iter pre_func p.M.funcs
