(* Register allocation by graph colouring.

   Two values can share a register exactly when they are never both live at the
   same time.  Turn that around: build a graph whose nodes are the values and
   whose edges say "these two are live together", and a register assignment is a
   colouring of that graph with as many colours as there are registers.  That is
   Chaitin's observation, and the algorithm here is Chaitin's with Briggs'
   improvement:

     1. liveness, backwards to a fixed point
     2. the interference graph: everything defined interferes with everything
        live at that point
     3. simplify -- repeatedly remove a node with fewer than K neighbours and
        push it on a stack, because whatever the rest gets coloured with, there
        will be a colour left for it
     4. when nothing has fewer than K neighbours, push the node with the most
        neighbours anyway.  Chaitin gave up here and spilled; Briggs noticed
        that a node with K or more neighbours can still have a colour left,
        because its neighbours may share colours, so it is worth trying
     5. pop the stack, giving each node the lowest colour none of its already
        coloured neighbours has.  A node that finds nothing free really is
        spilled
     6. if anything spilled, give it a frame slot, rewrite the code to load
        before each use and store after each definition, and start again.  The
        rewritten code has tiny live ranges where the long one was, so it
        converges

   The physical registers are nodes too, pre-coloured and never removed.  That
   is what makes a call work without a special case: a call defines every
   caller-saved register, so anything live across one interferes with all of
   them and ends up callee-saved or spilled, which is exactly right. *)

module M = Mach

let k = M.nregs

(* ---- what each instruction reads and writes ------------------------------ *)

let regs_in = function
  | M.Reg r -> [ r ]
  | M.Imm _ -> []
  | M.Mem { base; index; _ } ->
      (match base with Some b -> [ b ] | None -> [])
      @ match index with Some i -> [ i ] | None -> []

(* A destination operand that is a register is written; one that is memory is
   read, because the address has to be computed. *)
let dst_defs = function M.Reg r -> [ r ] | o -> ignore o; []
let dst_uses = function M.Reg _ -> [] | o -> regs_in o

let phys = List.map (fun i -> M.R i) M.caller_saved

let defs_uses (i : M.instr) =
  match i with
  | M.Mov (d, s) -> (dst_defs d, dst_uses d @ regs_in s)
  | M.Lea (d, s) -> ([ d ], regs_in s)
  (* An arithmetic destination is read as well as written. *)
  | M.Alu (_, d, s) -> (dst_defs d, regs_in d @ regs_in s)
  | M.Sar (d, _) | M.Shl (d, _) | M.Neg d -> (dst_defs d, regs_in d)
  | M.Cmp (a, b) -> ([], regs_in a @ regs_in b)
  | M.Setcc (_, d) -> ([ d ], [])
  | M.Idiv r -> ([ M.R M.rax; M.R M.rdx ], [ r; M.R M.rax; M.R M.rdx ])
  | M.Cqo -> ([ M.R M.rdx ], [ M.R M.rax ])
  | M.Call _ -> (phys, [])
  | M.CallReg r -> (phys, [ r ])
  | M.Push o -> ([], regs_in o)
  | M.Pop d -> (dst_defs d, [])
  | M.Loadb (d, s) -> ([ d ], regs_in s)
  | M.Storeb (d, s) -> ([], regs_in d @ [ s ])
  | M.RepMovsb -> ([], [])
  | M.Syscall -> (phys, [])
  | M.Comment _ -> ([], [])

let term_uses = function
  | M.Ret o -> regs_in o
  | M.TailCall -> [ M.R M.rdi; M.R M.rsi ]
  | M.Jmp _ | M.Jcc _ | M.Halt _ -> []

let succs (b : M.block) =
  match b.M.term with
  | M.Jmp t -> [ t ]
  | M.Jcc (_, t, e) -> [ t; e ]
  | M.Ret _ | M.TailCall | M.Halt _ -> []

(* ---- nodes --------------------------------------------------------------- *)

(* One numbering for both kinds: the physical registers first, so that a node's
   number is its colour when it has one.  All sixteen of them are numbered, not
   just the thirteen that get handed out, because rsp appears in every spill
   address and must not be mistaken for a virtual register.

   The three that are never handed out are not nodes at all: interfering with
   rsp says nothing, since no colour is rsp. *)
let nphys = Array.length M.reg_name
let node = function M.R i -> i | M.V i -> nphys + i

let nodes rs =
  List.filter_map (fun r -> match r with M.R i when i >= k -> None | r -> Some (node r)) rs

module IS = Set.Make (Int)

let liveness (f : M.func) =
  let live_in = Hashtbl.create 32 and live_out = Hashtbl.create 32 in
  List.iter
    (fun (b : M.block) ->
      Hashtbl.replace live_in b.M.id IS.empty;
      Hashtbl.replace live_out b.M.id IS.empty)
    f.M.blocks;
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter
      (fun (b : M.block) ->
        let out =
          List.fold_left
            (fun acc s -> IS.union acc (Hashtbl.find live_in s))
            IS.empty (succs b)
        in
        let live = ref (IS.union out (IS.of_list (nodes (term_uses b.M.term)))) in
        (* [code] is reversed, so walking it forwards walks the block
           backwards. *)
        List.iter
          (fun i ->
            let d, u = defs_uses i in
            live := IS.diff !live (IS.of_list (nodes d));
            live := IS.union !live (IS.of_list (nodes u)))
          b.M.code;
        if not (IS.equal out (Hashtbl.find live_out b.M.id)) then changed := true;
        if not (IS.equal !live (Hashtbl.find live_in b.M.id)) then changed := true;
        Hashtbl.replace live_out b.M.id out;
        Hashtbl.replace live_in b.M.id !live)
      (List.rev f.M.blocks)
  done;
  (live_in, live_out)

(* ---- the interference graph ---------------------------------------------- *)

let build_graph (f : M.func) live_out =
  let adj = Hashtbl.create 256 in
  let neighbours n = match Hashtbl.find_opt adj n with Some s -> s | None -> IS.empty in
  let edge a b =
    if a <> b then begin
      Hashtbl.replace adj a (IS.add b (neighbours a));
      Hashtbl.replace adj b (IS.add a (neighbours b))
    end
  in
  let touch n = if not (Hashtbl.mem adj n) then Hashtbl.replace adj n IS.empty in
  for i = 0 to k - 1 do
    touch i
  done;
  for i = 0 to f.M.nvreg - 1 do
    touch (nphys + i)
  done;
  List.iter
    (fun (b : M.block) ->
      let live =
        ref
          (IS.union (Hashtbl.find live_out b.M.id)
             (IS.of_list (nodes (term_uses b.M.term))))
      in
      List.iter
        (fun i ->
          let d, u = defs_uses i in
          let ds = nodes d in
          List.iter (fun x -> IS.iter (fun y -> edge x y) !live) ds;
          (* Two things defined by the same instruction interfere too: a call
             writes all the caller-saved registers at once. *)
          List.iter (fun x -> List.iter (fun y -> edge x y) ds) ds;
          live := IS.diff !live (IS.of_list ds);
          live := IS.union !live (IS.of_list (nodes u)))
        b.M.code)
    f.M.blocks;
  (adj, neighbours)

(* ---- colouring ----------------------------------------------------------- *)

exception Spilled of int list

let colour (f : M.func) =
  let _, live_out = liveness f in
  let adj, neighbours = build_graph f live_out in
  (* Simplify, then Briggs' optimistic push.  The degrees are maintained rather
     than recomputed: removing a node decrements its neighbours, and any that
     drops below K becomes trivially colourable, which is what keeps this linear
     in the number of edges instead of cubic in the number of nodes. *)
  let removed = Hashtbl.create 256 in
  let deg = Hashtbl.create 256 in
  Hashtbl.iter (fun n s -> Hashtbl.replace deg n (IS.cardinal s)) adj;
  let vregs = Hashtbl.fold (fun n _ acc -> if n >= nphys then n :: acc else acc) adj [] in
  let stack = ref [] in
  let ready = ref (List.filter (fun n -> Hashtbl.find deg n < k) vregs) in
  let remaining = ref (List.length vregs) in
  let take n =
    Hashtbl.replace removed n ();
    decr remaining;
    stack := n :: !stack;
    IS.iter
      (fun m ->
        if not (Hashtbl.mem removed m) then begin
          let d = Hashtbl.find deg m - 1 in
          Hashtbl.replace deg m d;
          if d = k - 1 && m >= nphys then ready := m :: !ready
        end)
      (neighbours n)
  in
  while !remaining > 0 do
    match List.filter (fun n -> not (Hashtbl.mem removed n)) !ready with
    | n :: rest ->
        ready := rest;
        take n
    | [] ->
        (* Nothing is trivially colourable: push the most constrained node and
           hope its neighbours share colours. *)
        ready := [];
        let live = List.filter (fun n -> not (Hashtbl.mem removed n)) vregs in
        let worst =
          List.fold_left
            (fun best n -> if Hashtbl.find deg n > Hashtbl.find deg best then n else best)
            (List.hd live) live
        in
        take worst
  done;
  let colours = Hashtbl.create 256 in
  for i = 0 to k - 1 do
    Hashtbl.replace colours i i
  done;
  let spills = ref [] in
  List.iter
    (fun n ->
      let taken =
        IS.fold
          (fun m acc -> match Hashtbl.find_opt colours m with Some c -> IS.add c acc | None -> acc)
          (neighbours n) IS.empty
      in
      let rec free c = if c >= k then None else if IS.mem c taken then free (c + 1) else Some c in
      match free 0 with
      | Some c -> Hashtbl.replace colours n c
      | None -> spills := n :: !spills)
    !stack;
  if !spills <> [] then raise (Spilled (List.map (fun n -> n - nphys) !spills));
  colours

(* ---- spilling ------------------------------------------------------------ *)

(* A spilled value gets a frame slot, and every mention of it becomes a fresh
   virtual register with a load before or a store after.  Those live ranges are
   two instructions long, so the next round colours them. *)
let rewrite (f : M.func) (spilled : int list) (slot : int -> int) =
  let is_spilled = function M.V i -> List.mem i spilled | M.R _ -> false in
  let fresh () =
    let r = M.V f.M.nvreg in
    f.M.nvreg <- f.M.nvreg + 1;
    r
  in
  let at r = M.Mem { base = Some (M.R M.rsp); index = None; scale = 1;
                     disp = 8 * slot (match r with M.V i -> i | M.R _ -> assert false);
                     sym = None } in
  let subst_op map o =
    match o with
    | M.Reg r -> ( match List.assoc_opt r map with Some r' -> M.Reg r' | None -> o)
    | M.Imm _ -> o
    | M.Mem { base; index; scale; disp; sym } ->
        let g r = match List.assoc_opt r map with Some r' -> r' | None -> r in
        M.Mem
          { base = Option.map g base; index = Option.map g index; scale; disp; sym }
  in
  let one (i : M.instr) =
    let d, u = defs_uses i in
    let touched = List.sort_uniq compare (List.filter is_spilled (d @ u)) in
    if touched = [] then [ i ]
    else begin
      let map = List.map (fun r -> (r, fresh ())) touched in
      let loads =
        List.filter_map
          (fun r -> if List.mem r u then Some (M.Mov (M.Reg (List.assoc r map), at r)) else None)
          touched
      in
      let stores =
        List.filter_map
          (fun r -> if List.mem r d then Some (M.Mov (at r, M.Reg (List.assoc r map))) else None)
          touched
      in
      let i' =
        match i with
        | M.Mov (a, b) -> M.Mov (subst_op map a, subst_op map b)
        | M.Lea (a, b) ->
            M.Lea ((match List.assoc_opt a map with Some r -> r | None -> a), subst_op map b)
        | M.Alu (op, a, b) -> M.Alu (op, subst_op map a, subst_op map b)
        | M.Sar (a, n) -> M.Sar (subst_op map a, n)
        | M.Shl (a, n) -> M.Shl (subst_op map a, n)
        | M.Neg a -> M.Neg (subst_op map a)
        | M.Cmp (a, b) -> M.Cmp (subst_op map a, subst_op map b)
        | M.Setcc (c, a) -> M.Setcc (c, (match List.assoc_opt a map with Some r -> r | None -> a))
        | M.CallReg a -> M.CallReg (match List.assoc_opt a map with Some r -> r | None -> a)
        | M.Push a -> M.Push (subst_op map a)
        | M.Pop a -> M.Pop (subst_op map a)
        | M.Loadb (a, b) ->
            M.Loadb ((match List.assoc_opt a map with Some r -> r | None -> a), subst_op map b)
        | M.Storeb (a, b) ->
            M.Storeb (subst_op map a, match List.assoc_opt b map with Some r -> r | None -> b)
        | other -> other
      in
      (* [code] is reversed: stores first in the list means after in the code. *)
      stores @ [ i' ] @ loads
    end
  in
  List.iter (fun (b : M.block) -> b.M.code <- List.concat_map one b.M.code) f.M.blocks;
  List.iter
    (fun (b : M.block) ->
      match b.M.term with
      | M.Ret o when List.exists is_spilled (regs_in o) -> (
          match regs_in o with
          | [ r ] ->
              let t = fresh () in
              b.M.code <- M.Mov (M.Reg t, at r) :: b.M.code;
              b.M.term <- M.Ret (M.Reg t)
          | _ -> ())
      | _ -> ())
    f.M.blocks

(* ---- the pass ------------------------------------------------------------ *)

let apply (f : M.func) colours =
  let of_reg r =
    match r with
    | M.R _ -> r
    | M.V i -> (
        match Hashtbl.find_opt colours (nphys + i) with
        | Some c -> M.R c
        | None ->
            (* Never live, so never coloured: anything will do. *)
            M.R 0)
  in
  let op o =
    match o with
    | M.Reg r -> M.Reg (of_reg r)
    | M.Imm _ -> o
    | M.Mem { base; index; scale; disp; sym } ->
        M.Mem
          {
            base = Option.map of_reg base;
            index = Option.map of_reg index;
            scale;
            disp;
            sym;
          }
  in
  let instr (i : M.instr) =
    match i with
    | M.Mov (a, b) -> M.Mov (op a, op b)
    | M.Lea (a, b) -> M.Lea (of_reg a, op b)
    | M.Alu (o, a, b) -> M.Alu (o, op a, op b)
    | M.Sar (a, n) -> M.Sar (op a, n)
    | M.Shl (a, n) -> M.Shl (op a, n)
    | M.Neg a -> M.Neg (op a)
    | M.Cmp (a, b) -> M.Cmp (op a, op b)
    | M.Setcc (c, a) -> M.Setcc (c, of_reg a)
    | M.Idiv a -> M.Idiv (of_reg a)
    | M.CallReg a -> M.CallReg (of_reg a)
    | M.Push a -> M.Push (op a)
    | M.Pop a -> M.Pop (op a)
    | M.Loadb (a, b) -> M.Loadb (of_reg a, op b)
    | M.Storeb (a, b) -> M.Storeb (op a, of_reg b)
    | other -> other
  in
  let used = ref [] in
  let note r = match r with M.R c when List.mem c M.callee_saved && not (List.mem c !used) -> used := c :: !used | _ -> () in
  List.iter
    (fun (b : M.block) ->
      b.M.code <- List.map instr b.M.code;
      b.M.term <- (match b.M.term with M.Ret o -> M.Ret (op o) | t -> t);
      List.iter
        (fun i ->
          let d, u = defs_uses i in
          List.iter note (d @ u))
        b.M.code)
    f.M.blocks;
  f.M.used_callee <- List.sort compare !used

let func (f : M.func) =
  let slots = Hashtbl.create 16 in
  let rec go () =
    match colour f with
    | colours -> apply f colours
    | exception Spilled vs ->
        List.iter
          (fun v ->
            if not (Hashtbl.mem slots v) then begin
              Hashtbl.replace slots v f.M.nspill;
              f.M.nspill <- f.M.nspill + 1
            end)
          vs;
        rewrite f vs (Hashtbl.find slots);
        go ()
  in
  go ()

let program (p : M.prog) = List.iter func p.M.funcs
