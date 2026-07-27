(* Local rewrites on the machine code, after register allocation.

   Everything here follows from facts that hold within one basic block: which
   registers are known to hold the same value, which constants are already
   materialized, and what was last written to a memory slot.

   Running after allocation is the point.  Spill code stores a value and, if the
   use is close by, loads it straight back; the moves the allocator could not
   coalesce sometimes copy a register onto itself under another name.  Neither
   is visible before registers are assigned. *)

type facts = {
  mutable equal : (Riscv.reg * Riscv.reg) list; (* pairs holding the same value *)
  mutable consts : (Riscv.reg * int) list;
  mutable labels : (Riscv.reg * Ident.label) list;
  mutable memory : ((Riscv.reg * int) * Riscv.reg) list; (* slot -> what is in it *)
  (* Arithmetic already done, and the register still holding the answer.  Every
     operation in this instruction set is pure -- RISC-V division by zero
     produces a value rather than trapping -- so a repeat is always redundant. *)
  mutable computed : ((Riscv.binop * Riscv.reg * Riscv.reg) * Riscv.reg) list;
  mutable computed_imm : ((Riscv.binop * Riscv.reg * int) * Riscv.reg) list;
}

let no_facts () =
  { equal = []; consts = []; labels = []; memory = []; computed = []; computed_imm = [] }

(* Byte accesses take part in none of this.  The memory facts assume every
   slot is a whole aligned word, which is what lets two different offsets from
   one base be treated as disjoint; a byte load overlaps a word and would break
   that reasoning, so it is neither consulted nor recorded. *)

(* Anything said about [r] stops being true once [r] is written. *)
let forget facts r =
  facts.equal <- List.filter (fun (a, b) -> a <> r && b <> r) facts.equal;
  facts.consts <- List.remove_assoc r facts.consts;
  facts.labels <- List.remove_assoc r facts.labels;
  facts.memory <- List.filter (fun ((base, _), v) -> base <> r && v <> r) facts.memory;
  facts.computed <-
    List.filter (fun ((_, a, b), d) -> a <> r && b <> r && d <> r) facts.computed;
  facts.computed_imm <-
    List.filter (fun ((_, a, _), d) -> a <> r && d <> r) facts.computed_imm

(* Not transitive: `mv b, a` then `mv c, b` does not record that c and a agree.
   Chains that long do not survive coalescing anyway. *)
let same facts a b =
  a = b || List.exists (fun (x, y) -> (x = a && y = b) || (x = b && y = a)) facts.equal

let destinations = function
  | Riscv.Li (d, _)
  | Riscv.La (d, _)
  | Riscv.Move (d, _)
  | Riscv.Arith (_, d, _, _)
  | Riscv.Arith_imm (_, d, _, _)
  | Riscv.Load (d, _, _)
  | Riscv.Load_byte (d, _, _) ->
    [ d ]
  | Riscv.Store _ | Riscv.Call _ -> []

let rewrite_block (block : Riscv.block) =
  let facts = no_facts () in
  let changed = ref false in
  let step instr =
    (* Reading back a slot whose contents are still in a register is a move. *)
    let instr =
      match instr with
      | Riscv.Load (d, base, offset) -> (
        match List.assoc_opt (base, offset) facts.memory with
        | Some source ->
          changed := true;
          Riscv.Move (d, source)
        | None -> instr)
      (* The same arithmetic twice over, with nothing written in between. *)
      | Riscv.Arith (op, d, a, b) -> (
        match List.assoc_opt (op, a, b) facts.computed with
        | Some source ->
          changed := true;
          Riscv.Move (d, source)
        | None -> instr)
      | Riscv.Arith_imm (op, d, a, n) -> (
        match List.assoc_opt (op, a, n) facts.computed_imm with
        | Some source ->
          changed := true;
          Riscv.Move (d, source)
        | None -> instr)
      | _ -> instr
    in
    let redundant =
      match instr with
      | Riscv.Move (d, s) -> same facts d s
      | Riscv.Li (d, n) -> List.assoc_opt d facts.consts = Some n
      | Riscv.La (d, l) -> List.assoc_opt d facts.labels = Some l
      | _ -> false
    in
    if redundant then begin
      changed := true;
      None
    end
    else begin
      (match instr with
       | Riscv.Call _ ->
         (* The callee may write any caller-saved register and any memory. *)
         facts.equal <- [];
         facts.consts <- [];
         facts.labels <- [];
         facts.memory <- [];
         facts.computed <- [];
         facts.computed_imm <- []
       | Riscv.Store (source, base, offset) ->
         (* A store through a different base might alias anything.  Two offsets
            from the same base cannot: every access this compiler emits is an
            aligned 64-bit word at a multiple of 8. *)
         facts.memory <-
           ((base, offset), source)
           :: List.filter (fun ((b, o), _) -> b = base && o <> offset) facts.memory
       | _ ->
         List.iter (forget facts) (destinations instr);
         (match instr with
          | Riscv.Move (d, s) -> facts.equal <- (d, s) :: facts.equal
          | Riscv.Li (d, n) -> facts.consts <- (d, n) :: facts.consts
          | Riscv.La (d, l) -> facts.labels <- (d, l) :: facts.labels
          (* A fact may only be recorded when the destination is not also an
             operand.  `mul t0, t0, t1` would otherwise record that t0 holds
             t0 * t1, which stops being true the instant it is written -- the
             operand in the key now names the result. *)
          | Riscv.Load (d, base, offset) when d <> base ->
            facts.memory <- ((base, offset), d) :: facts.memory
          | Riscv.Arith (op, d, a, b) when d <> a && d <> b ->
            facts.computed <- ((op, a, b), d) :: facts.computed
          | Riscv.Arith_imm (op, d, a, n) when d <> a ->
            facts.computed_imm <- ((op, a, n), d) :: facts.computed_imm
          | _ -> ()));
      Some instr
    end
  in
  block.body <- List.filter_map step block.body;
  !changed

(* A block that does nothing but jump elsewhere can be skipped by whoever
   branches to it, after which it is usually unreachable. *)
let thread_jumps (func : Riscv.func) =
  let entry = match func.blocks with b :: _ -> b.Riscv.label | [] -> "" in
  let shortcut = Hashtbl.create 8 in
  List.iter
    (fun (b : Riscv.block) ->
      match (b.body, b.terminator) with
      | [], Riscv.Jump target when b.label <> entry ->
        Hashtbl.replace shortcut b.label target
      | _ -> ())
    func.blocks;
  let rec resolve seen label =
    match Hashtbl.find_opt shortcut label with
    | Some target when not (List.mem label seen) -> resolve (label :: seen) target
    | _ -> label
  in
  let target label = resolve [] label in
  let changed = ref false in
  List.iter
    (fun (b : Riscv.block) ->
      let updated =
        match b.terminator with
        | Riscv.Jump l -> Riscv.Jump (target l)
        | Riscv.Branch (cond, x, y, if_true, if_false) -> (
          match (target if_true, target if_false) with
          (* Both arms ended up in the same place. *)
          | t, f when t = f -> Riscv.Jump t
          | t, f -> Riscv.Branch (cond, x, y, t, f))
        | t -> t
      in
      if updated <> b.terminator then changed := true;
      b.terminator <- updated)
    func.blocks;
  (* Whatever is no longer reachable from the entry can go. *)
  let reachable = Hashtbl.create 8 in
  let rec visit label =
    if not (Hashtbl.mem reachable label) then begin
      Hashtbl.replace reachable label ();
      match List.find_opt (fun (b : Riscv.block) -> b.Riscv.label = label) func.blocks with
      | Some b -> List.iter visit (Riscv.successors b.terminator)
      | None -> ()
    end
  in
  visit entry;
  let kept =
    List.filter (fun (b : Riscv.block) -> Hashtbl.mem reachable b.Riscv.label) func.blocks
  in
  if List.length kept <> List.length func.blocks then changed := true;
  func.blocks <- kept;
  !changed

(* Deleting one instruction can expose the next, so run to a fixed point.  The
   bound is a backstop; two passes is the most anything here has needed. *)
let run (func : Riscv.func) =
  let rec loop rounds =
    if rounds > 0 then begin
      let blocks = List.map rewrite_block func.Riscv.blocks in
      let threaded = thread_jumps func in
      if List.exists Fun.id blocks || threaded then loop (rounds - 1)
    end
  in
  loop 8
