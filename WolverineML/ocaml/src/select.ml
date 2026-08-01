(* Instruction selection: cover the DAG with ARM instructions.

   Every node that has to become a register of its own is tiled, largest tile
   first, pulling its foldable operands into the tile as it goes.  The tiles are
   the things ARM can do in one instruction that the IR needs several nodes to
   say:

   {v
   a + b * c            madd
   a - b * c            msub
   a + (b lsl k)        add with a shifted operand
   a + 4095             add with an immediate
   a * 8                lsl
   [a + 24]             a load with the addition as its displacement
   a < b, then branch   cmp, and a branch on the flags
   v}

   What comes out is still the same CFG, and still in SSA — a tile defines one new
   register — so liveness, the allocator and the verifier carry on as before.
   What has gone is the guesswork the emitter used to do with its peepholes: an
   instruction is now chosen where the whole expression is visible, rather than by
   looking at the line before. *)

open Ir

(* What [add], [sub] and [cmp] take as an immediate operand. *)
let immediate_max = 4095L

let logical_form = [ ("and", "and"); ("or", "orr"); ("xor", "eor") ]
let shift_form = [ ("shl", "lsl"); ("shr", "asr") ]

type selector = {
  graph : Dag.t;
  mutable out : instr list; (* reversed while it is built *)
  mutable done_ : IntSet.t;
  mutable absorbed : IntSet.t;
}

let put s m = s.out <- Machine m :: s.out

let mach ?(dst = no_reg) ?(srcs = []) ?(imm = 0L) ?(symbol = "") ?(effectful = false) form =
  { form; m_dst = dst; srcs; imm; symbol; effectful }

(* Where the one set bit of a power of two is. *)
let log2 value =
  let amount = ref 0L and left = ref value in
  while Int64.shift_right_logical !left 1 <> 0L do
    left := Int64.shift_right_logical !left 1;
    amount := Int64.add !amount 1L
  done;
  !amount

let is_bin (n : Dag.node) op = match n.instr with Bin b -> b.op = op | _ -> false

(* A [x lsl k] that can be folded, however it was written: [* 8] says it too.
   This decides nothing and emits nothing, so the plan and the tiles can both ask
   it and get the same answer. *)
let as_shift s index =
  match Dag.of_index s.graph index with
  | Some n when Dag.alone n -> (
      match n.instr with
      | Bin b -> (
          match Dag.constant s.graph (Dag.operand n 1) with
          | None -> None
          | Some amount ->
              let amount =
                if b.op = "*" then
                  if amount <= 0L || Int64.logand amount (Int64.sub amount 1L) <> 0L then -1L
                  else log2 amount
                else if b.op = "shl" then amount
                else -1L
              in
              if amount < 0L || amount >= 64L then None else Some (n, amount))
      | _ -> None)
  | _ -> None

(* [displaces] is `[pointer + 24]`, when what is added to the pointer is a
   constant. *)
let displaces s (n : Dag.node) offset =
  if not (is_bin n "+") then None
  else
    match Dag.constant s.graph (Dag.operand n 1) with
    | None -> None
    | Some value ->
        let total = Int64.add (Int64.of_int offset) value in
        if total >= 0L && total <= 32760L && Int64.rem total (Int64.of_int word) = 0L then
          Some total
        else if total >= -256L && total <= 255L then Some total
        else None

(* Whether the instruction chosen for [reader] has room for [node]. *)
let swallows s (reader : Dag.node) (node : Dag.node) =
  match reader.instr with
  | Bin b ->
      if b.op <> "+" && b.op <> "-" then false
      else if Dag.operand reader 1 <> node.index then false
      else as_shift s node.index <> None || is_bin node "*"
  | Load l -> Dag.operand reader 0 = node.index && displaces s node l.offset <> None
  | Store st -> Dag.operand reader 0 = node.index && displaces s node st.offset <> None
  | _ -> false

(* [plan] decides which nodes a tile is going to swallow, before emitting any.

   Nothing may be deferred on the chance that its reader takes it.  A node left
   out of the order and then not absorbed would be computed at its reader instead,
   and a chain of those — [a + b + c + ...], where every term has one reader —
   would move the whole sum to its last line and keep every term alive until
   then. *)
let plan s =
  Array.iter
    (fun (n : Dag.node) ->
      if Dag.alone n && n.reader <> Dag.no_node then
        if swallows s s.graph.nodes.(n.reader) n then s.absorbed <- IntSet.add n.index s.absorbed)
    s.graph.nodes

let rec tile s (n : Dag.node) =
  match n.instr with
  | Const c ->
      put s (mach "const" ~dst:c.dst ~imm:c.value);
      c.dst
  | Str_const c ->
      put s (mach "adr" ~dst:c.dst ~symbol:c.str_symbol);
      c.dst
  | Bin b ->
      arithmetic s n b.dst b.op b.lhs b.rhs;
      b.dst
  | Cmp c ->
      compare_ s n c.lhs c.rhs;
      put s (mach "cset" ~dst:c.dst ~symbol:(Mach.code_of c.op));
      c.dst
  | Load l ->
      let pointer, displacement = address s (Dag.operand n 0) l.base l.offset in
      put s (mach "ldr" ~dst:l.dst ~srcs:[ pointer ] ~imm:displacement);
      l.dst
  | Store st ->
      let value = at s (Dag.operand n 1) st.src in
      let pointer, displacement = address s (Dag.operand n 0) st.base st.offset in
      put s (mach "str" ~srcs:[ pointer; value ] ~imm:displacement ~effectful:true);
      st.src
  | other ->
      (* Moves, calls, slot accesses and the terminator are machine instructions
         already, and a phi is not in this list at all.  None of them folds
         anything, so every operand that was left to be folded has to be computed
         here instead. *)
      List.iter (fun operand -> force s operand) n.operands;
      s.out <- other :: s.out;
      let d = defs other in
      if d <> no_reg then d else 0

(* [at] is the register holding an operand, computing it here if it was deferred.

   Only two kinds of node were left out of the order: a constant, which is tiled
   the first time somebody needs it in a register and read from there afterwards,
   and a node the plan said would be absorbed, which ends up here only if the tile
   that was to absorb it changed its mind. *)
and at s index reg =
  match Dag.of_index s.graph index with
  | None -> reg
  | Some n ->
      if IntSet.mem n.index s.done_ then reg
      else
        let deferred =
          IntSet.mem n.index s.absorbed || Dag.rematerialisable s.graph n.index <> None
        in
        if not deferred then reg
        else begin
          s.done_ <- IntSet.add n.index s.done_;
          tile s n
        end

(* Compute a deferred operand for a reader that has no tile to take it. *)
and force s index =
  match Dag.of_index s.graph index with
  | None -> ()
  | Some n ->
      let v = defs n.instr in
      ignore (at s index (if v <> no_reg then v else 0))

(* Both operands in registers, which is what the plain forms want. *)
and both s n lhs rhs =
  let a = at s (Dag.operand n 0) lhs in
  let b = at s (Dag.operand n 1) rhs in
  [ a; b ]

and arithmetic s n dst op lhs rhs =
  match op with
  | "+" | "-" -> additive s n dst op lhs rhs
  | "*" -> multiply s n dst lhs rhs
  | "/" -> put s (mach "sdiv" ~dst ~srcs:(both s n lhs rhs))
  | "shl" | "shr" -> shift s n dst op lhs rhs
  | "and" | "or" | "xor" -> logical s n dst op lhs rhs
  | _ -> failwith ("no instruction for `" ^ op ^ "`")

(* [add] and [sub], in whichever of their four forms fits. *)
and additive s n dst op lhs rhs =
  (* A shifted operand comes first: [a + b * 8] is one instruction that way and
     two as a multiply-add, because the 8 would need a register. *)
  if not (shift_into s n dst op lhs) then
    if not (multiply_into s n dst op lhs) then begin
      let left = Dag.operand n 0 and right = Dag.operand n 1 in
      match Dag.constant s.graph right with
      | Some value when value >= 0L && value <= immediate_max ->
          put s (mach (if op = "+" then "addi" else "subi") ~dst
                   ~srcs:[ at s left lhs ] ~imm:value)
      | _ -> (
          (* Only addition may take its constant from the other side. *)
          match if op = "+" then Dag.constant s.graph left else None with
          | Some value when value >= 0L && value <= immediate_max ->
              put s (mach "addi" ~dst ~srcs:[ at s right rhs ] ~imm:value)
          | _ ->
              put s (mach (if op = "+" then "add" else "sub") ~dst ~srcs:(both s n lhs rhs)))
    end

and multiply s n dst lhs rhs =
  match Dag.constant s.graph (Dag.operand n 1) with
  | Some value when value > 0L && Int64.logand value (Int64.sub value 1L) = 0L ->
      put s (mach "lsli" ~dst ~srcs:[ at s (Dag.operand n 0) lhs ] ~imm:(log2 value))
  | _ -> put s (mach "mul" ~dst ~srcs:(both s n lhs rhs))

and shift s n dst op lhs rhs =
  match Dag.constant s.graph (Dag.operand n 1) with
  | Some value when value >= 0L && value < 64L ->
      put s (mach (List.assoc op shift_form ^ "i") ~dst
               ~srcs:[ at s (Dag.operand n 0) lhs ] ~imm:value)
  | _ -> put s (mach (List.assoc op shift_form) ~dst ~srcs:(both s n lhs rhs))

and logical s n dst op lhs rhs =
  match Dag.constant s.graph (Dag.operand n 1) with
  | Some 1L when op = "xor" ->
      (* Which is how [not] arrives. *)
      put s (mach "eori" ~dst ~srcs:[ at s (Dag.operand n 0) lhs ] ~imm:1L)
  | _ -> put s (mach (List.assoc op logical_form) ~dst ~srcs:(both s n lhs rhs))

(* [a + b * c] and [a - b * c] are one instruction each. *)
and multiply_into s n dst op lhs =
  match Dag.of_index s.graph (Dag.operand n 1) with
  | Some product when Dag.alone product && is_bin product "*" -> (
      match product.instr with
      | Bin inner ->
          let x = at s (Dag.operand product 0) inner.lhs in
          let y = at s (Dag.operand product 1) inner.rhs in
          let z = at s (Dag.operand n 0) lhs in
          put s (mach (if op = "+" then "madd" else "msub") ~dst ~srcs:[ x; y; z ]);
          true
      | _ -> false)
  | _ -> false

(* The second operand of an [add] may be shifted on the way in. *)
and shift_into s n dst op lhs =
  match as_shift s (Dag.operand n 1) with
  | None -> false
  | Some (shifted, amount) -> (
      match shifted.instr with
      | Bin inner ->
          let a = at s (Dag.operand n 0) lhs in
          let b = at s (Dag.operand shifted 0) inner.lhs in
          put s (mach (if op = "+" then "adds" else "subs") ~dst ~srcs:[ a; b ] ~imm:amount);
          true
      | _ -> false)

(* A pointer and a displacement, taking in an addition if there is one. *)
and address s index base offset =
  match Dag.of_index s.graph index with
  | Some n when Dag.alone n -> (
      match displaces s n offset with
      | Some displaced -> (
          match n.instr with
          | Bin inner -> (at s (Dag.operand n 0) inner.lhs, displaced)
          | _ -> (at s index base, Int64.of_int offset))
      | None -> (at s index base, Int64.of_int offset))
  | _ -> (at s index base, Int64.of_int offset)

and compare_ s n lhs rhs =
  let left = Dag.operand n 0 and right = Dag.operand n 1 in
  match Dag.constant s.graph right with
  | Some value when value >= 0L && value <= immediate_max ->
      put s (mach "cmpi" ~srcs:[ at s left lhs ] ~imm:value)
  | _ ->
      let a = at s left lhs in
      let b = at s right rhs in
      put s (mach "cmp" ~srcs:[ a; b ])

(* A comparison the branch below it is the only reader of sets the flags. *)
let fuse_comparison s index =
  let nodes = s.graph.nodes in
  let n = nodes.(index) in
  match n.instr with
  | Cmp c when index + 1 = Array.length nodes - 1 -> (
      match nodes.(Array.length nodes - 1).instr with
      | Cbr branch when branch.cond = c.dst && n.users = 1 && not n.escapes ->
          compare_ s n c.lhs c.rhs;
          branch.code <- Mach.code_of c.op;
          true
      | _ -> false)
  | _ -> false

let run s =
  plan s;
  Array.iteri
    (fun at_ (n : Dag.node) ->
      if IntSet.mem at_ s.absorbed then () (* part of the tile that reads it *)
      else if Dag.rematerialisable s.graph at_ <> None then
        () (* a constant, computed only where a register wants it *)
      else if fuse_comparison s at_ then ()
      else begin
        s.done_ <- IntSet.add at_ s.done_;
        ignore (tile s n)
      end)
    s.graph.nodes;
  List.rev s.out

let select f =
  let live = Liveness.analyse f in
  List.iter
    (fun b ->
      let s =
        { graph = Dag.build b (Liveness.live_out live b.label); out = [];
          done_ = IntSet.empty; absorbed = IntSet.empty }
      in
      set_instrs b (run s))
    (walk f)

let select_module m = List.iter select m.funcs

(* The DAGs a selection would work on, for [wolv emit -s dag]. *)
let graphs f =
  let live = Liveness.analyse f in
  List.map (fun b -> (b.label, Dag.build b (Liveness.live_out live b.label))) (walk f)
