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
   pass aware of register pressure.  That is the thing this does not do. *)

module M = Mach

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

let block (b : M.block) =
  let code = Array.of_list (List.rev b.M.code) in
  let n = Array.length code in
  if n > 1 then begin
    let rw = Array.map reads_writes code in
    let deps = Array.make n [] in
    (* j depends on i, for i < j, if any of the four kinds holds. *)
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
    (* The height: the longest path from here to the end, in latencies.  One
       backwards pass, because a dependence only ever points at a lower index. *)
    let height = Array.make n 0 in
    for i = n - 1 downto 0 do
      height.(i) <- latency code.(i);
      for j = i + 1 to n - 1 do
        if List.mem i deps.(j) then height.(i) <- max height.(i) (latency code.(i) + height.(j))
      done
    done;
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
