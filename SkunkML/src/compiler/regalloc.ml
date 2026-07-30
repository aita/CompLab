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
     3. one loop over four worklists -- simplify, coalesce, freeze, spill --
        doing exactly one thing per turn, in that priority order.  See the
        comment above `colour`: the interleaving is the point
     4. pop the stack, giving each node the lowest colour none of its already
        coloured neighbours has, seen through their aliases
     5. if anything spilled, give it a frame slot, rewrite the code to load
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

(* ---- how often a block runs ---------------------------------------------- *)

(* Whether a block is inside a loop.  A block that can reach itself is on a
   cycle, and every block of a natural loop can: it reaches the latch, and the
   latch reaches the header again.

   This is an approximation, and a deliberate one.  It is *sound* -- it never
   calls a block loop-free when it is in a loop -- but it over-approximates, and
   it cannot count nesting: an irreducible tangle is all "in a loop", and two
   nested loops look like one.  The exact answer is dominators and natural
   loops, which is what `loops.ml` does for the SSA graph and what would have to
   be written again here for the Mach one.  It would say nothing more.  Every
   loop in a SkunkML program is a self tail call ([10章](../doc/10-ssa.md)), the
   back edges of a function all point at the same header, and nothing nests --
   so "inside a loop" is the whole of what there is to know. *)
let in_loop (f : M.func) =
  let byid = Hashtbl.create 16 in
  List.iter (fun (b : M.block) -> Hashtbl.replace byid b.M.id b) f.M.blocks;
  let out_of id = match Hashtbl.find_opt byid id with Some b -> succs b | None -> [] in
  let cyclic = Hashtbl.create 16 in
  List.iter
    (fun (b : M.block) ->
      let seen = Hashtbl.create 16 in
      let rec go id =
        if not (Hashtbl.mem seen id) then begin
          Hashtbl.replace seen id ();
          List.iter go (out_of id)
        end
      in
      List.iter go (out_of b.M.id);
      if Hashtbl.mem seen b.M.id then Hashtbl.replace cyclic b.M.id ())
    f.M.blocks;
  fun id -> Hashtbl.mem cyclic id

(* ---- what a value costs to spill ----------------------------------------- *)

(* Chaitin's estimate: how many times the value is read or written, ten times
   over if the instruction is inside a loop.  Ten is the usual guess at how much
   more often a loop body runs than the code around it -- a guess, and all that
   is asked of it is to order the candidates.

   Divided by the degree (in `select_spill`), this is the whole of the spill
   heuristic: prefer the value that frees many neighbours and is barely touched,
   and not the one a loop reads every time round. *)
let spill_costs (f : M.func) =
  let hot = in_loop f in
  let cost = Hashtbl.create 256 in
  let bump w n = Hashtbl.replace cost n (w +. try Hashtbl.find cost n with Not_found -> 0.) in
  List.iter
    (fun (b : M.block) ->
      let w = if hot b.M.id then 10. else 1. in
      List.iter
        (fun i ->
          let d, u = defs_uses i in
          List.iter (bump w) (nodes (d @ u)))
        b.M.code;
      List.iter (bump w) (nodes (term_uses b.M.term)))
    f.M.blocks;
  cost

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

(* ---- moves ---------------------------------------------------------------- *)

(* The candidates for coalescing: a register-to-register move.  If its two ends
   can be given the same colour the move disappears, so the two nodes want to be
   one -- unless making them one makes the graph harder to colour, which is the
   whole difficulty. *)
let moves_of (f : M.func) =
  List.concat_map
    (fun (b : M.block) ->
      List.filter_map
        (function M.Mov (M.Reg d, M.Reg s) when d <> s -> Some (d, s) | _ -> None)
        b.M.code)
    f.M.blocks

(* ---- colouring ----------------------------------------------------------- *)

(* Iterated register coalescing (George and Appel).  Chaitin's algorithm alone
   leaves every copy in place; coalescing removes a copy by fusing its two nodes
   into one, and the two passes have to be *interleaved* rather than run in
   sequence, because each one creates work for the other -- simplifying reduces
   degrees, which makes a coalesce safe that was not; coalescing raises a degree,
   which makes a node need simplifying.

   So there is one loop over four worklists, and it does exactly one thing per
   turn, in priority order:

     simplify   a node with fewer than K neighbours and no moves: push it
     coalesce   a move whose ends can safely become one node: fuse them
     freeze     a low-degree node whose moves are all blocked: give up on its
                moves so it can be simplified
     spill      nothing else is possible: push the cheapest node optimistically
                (Briggs) and hope its neighbours share colours

   "Safely" is the interesting word.  Fusing two nodes can only make colouring
   harder, so a test has to say when it cannot:

     George      for a move against a precoloured node: every neighbour of the
                 other end is already either low-degree, precoloured, or a
                 neighbour of this one -- so it loses nothing
     Briggs      for two ordinary nodes: the fused node has fewer than K
                 neighbours of significant degree, so it will still simplify

   Neither is exact.  Both are *conservative*: they never fuse a pair that would
   make a colourable graph uncolourable, and they refuse some pairs that would
   have been fine.  Fusing without a test and undoing it when the colouring
   fails -- Park and Moon's optimistic coalescing -- is the usual answer to
   that, and here it is not worth it: on these programs Briggs refuses almost
   nothing, and where it does refuse the optimism costs more spills than the
   copies it saves ([13章](../doc/13-regalloc.md)). *)

exception Spilled of int list

(* [unspillable] holds the nodes that must not be chosen to spill: the fresh
   registers a previous rewrite made.  Their live ranges are two instructions
   long, so spilling one again would insert a load right next to the store that
   fed it and leave the round no smaller than it started -- the one way this
   loop could fail to converge. *)
let colour (f : M.func) (unspillable : IS.t) =
  let _, live_out = liveness f in
  let adj, _ = build_graph f live_out in
  let cost = spill_costs f in
  let k_inf = 1_000_000 in
  (* Degrees, with the precoloured ones held at infinity so that they are never
     simplified and never spilled: they already have their colour. *)
  let degree = Hashtbl.create 256 in
  Hashtbl.iter
    (fun n s -> Hashtbl.replace degree n (if n < k then k_inf else IS.cardinal s))
    adj;
  let deg n = try Hashtbl.find degree n with Not_found -> 0 in
  let adjacent = Hashtbl.create 256 in
  Hashtbl.iter (fun n s -> Hashtbl.replace adjacent n s) adj;
  let adj_of n = try Hashtbl.find adjacent n with Not_found -> IS.empty in
  let interferes a b = IS.mem b (adj_of a) in
  (* The four worklists, plus what has been taken out of the graph. *)
  let simplify_wl = ref IS.empty and freeze_wl = ref IS.empty and spill_wl = ref IS.empty in
  let select_stack = ref [] and on_stack = ref IS.empty in
  let coalesced = ref IS.empty in
  let alias = Hashtbl.create 64 in
  let rec resolve n = if IS.mem n !coalesced then resolve (Hashtbl.find alias n) else n in
  (* Moves, by state.  A move is a pair of nodes. *)
  let move_list = Hashtbl.create 256 in
  let add_move n m =
    Hashtbl.replace move_list n (m :: (try Hashtbl.find move_list n with Not_found -> []))
  in
  let worklist_moves = ref [] and active_moves = ref [] in
  List.iter
    (fun (d, s) ->
      let m = (node d, node s) in
      add_move (fst m) m;
      add_move (snd m) m;
      worklist_moves := m :: !worklist_moves)
    (moves_of f);
  let pending m = List.mem m !worklist_moves || List.mem m !active_moves in
  let node_moves n = List.filter pending (try Hashtbl.find move_list n with Not_found -> []) in
  let move_related n = node_moves n <> [] in
  let live_nodes n = IS.diff (adj_of n) (IS.union !on_stack !coalesced) in
  (* Everything that is not precoloured starts on one of the three lists. *)
  Hashtbl.iter
    (fun n _ ->
      if n >= k then
        if deg n >= k then spill_wl := IS.add n !spill_wl
        else if move_related n then freeze_wl := IS.add n !freeze_wl
        else simplify_wl := IS.add n !simplify_wl)
    adj;
  (* A move becomes eligible again when something around it changed. *)
  let enable_moves ns =
    IS.iter
      (fun n ->
        List.iter
          (fun m ->
            if List.mem m !active_moves then begin
              active_moves := List.filter (fun x -> x <> m) !active_moves;
              worklist_moves := m :: !worklist_moves
            end)
          (try Hashtbl.find move_list n with Not_found -> []))
      ns
  in
  let add_worklist n =
    if n >= k && (not (move_related n)) && deg n < k then begin
      freeze_wl := IS.remove n !freeze_wl;
      simplify_wl := IS.add n !simplify_wl
    end
  in
  (* Taking a node out drops its neighbours' degrees, and a neighbour that falls
     below K becomes workable -- which is the step that makes this iterated. *)
  let decrement_degree n =
    let d = deg n in
    Hashtbl.replace degree n (d - 1);
    if d = k then begin
      enable_moves (IS.add n (live_nodes n));
      spill_wl := IS.remove n !spill_wl;
      if move_related n then freeze_wl := IS.add n !freeze_wl
      else simplify_wl := IS.add n !simplify_wl
    end
  in
  let simplify () =
    let n = IS.min_elt !simplify_wl in
    simplify_wl := IS.remove n !simplify_wl;
    select_stack := n :: !select_stack;
    on_stack := IS.add n !on_stack;
    IS.iter decrement_degree (live_nodes n)
  in
  (* George: safe when every neighbour of v is already harmless to u. *)
  let ok t r = deg t < k || t < k || interferes t r in
  (* Briggs: safe when the fused node will still simplify. *)
  let conservative ns =
    IS.cardinal (IS.filter (fun n -> deg n >= k) ns) < k
  in
  let combine u v =
    if IS.mem v !freeze_wl then freeze_wl := IS.remove v !freeze_wl
    else spill_wl := IS.remove v !spill_wl;
    coalesced := IS.add v !coalesced;
    Hashtbl.replace alias v u;
    Hashtbl.replace move_list u
      ((try Hashtbl.find move_list u with Not_found -> [])
      @ try Hashtbl.find move_list v with Not_found -> []);
    enable_moves (IS.singleton v);
    IS.iter
      (fun t ->
        (* Every interference of v becomes one of u. *)
        Hashtbl.replace adjacent t (IS.add u (adj_of t));
        Hashtbl.replace adjacent u (IS.add t (adj_of u));
        if t >= k then Hashtbl.replace degree t (deg t + 1);
        decrement_degree t)
      (live_nodes v);
    if deg u >= k && IS.mem u !freeze_wl then begin
      freeze_wl := IS.remove u !freeze_wl;
      spill_wl := IS.add u !spill_wl
    end
  in
  let coalesce () =
    let ((x, y) as m) = List.hd !worklist_moves in
    worklist_moves := List.tl !worklist_moves;
    let x = resolve x and y = resolve y in
    (* A precoloured node is always the one kept. *)
    let u, v = if y < k then (y, x) else (x, y) in
    if u = v then add_worklist u
    else if v < k || interferes u v then begin
      (* Constrained: the two are already in the graph together, or both are
         real registers.  The move has to stay. *)
      add_worklist u;
      add_worklist v
    end
    else if
      (if u < k then IS.for_all (fun t -> ok t u) (live_nodes v)
       else conservative (IS.union (live_nodes u) (live_nodes v)))
    then begin
      combine u v;
      add_worklist u
    end
    else active_moves := m :: !active_moves
  in
  (* Giving up on a node's moves is what lets it be simplified.  The copies stay
     in the program; the alternative is spilling something. *)
  let freeze_moves u =
    List.iter
      (fun ((x, y) as m) ->
        let v = if resolve y = resolve u then resolve x else resolve y in
        active_moves := List.filter (fun z -> z <> m) !active_moves;
        worklist_moves := List.filter (fun z -> z <> m) !worklist_moves;
        if (not (move_related v)) && deg v < k && v >= k then begin
          freeze_wl := IS.remove v !freeze_wl;
          simplify_wl := IS.add v !simplify_wl
        end)
      (node_moves u)
  in
  let freeze () =
    let n = IS.min_elt !freeze_wl in
    freeze_wl := IS.remove n !freeze_wl;
    simplify_wl := IS.add n !simplify_wl;
    freeze_moves n
  in
  let select_spill () =
    (* Cost over degree: what the memory traffic would cost, per neighbour the
       spill frees.  Degree alone would happily spill the value a loop reads
       every time round, which is the expensive mistake. *)
    let value n =
      if IS.mem n unspillable then infinity
      else (try Hashtbl.find cost n with Not_found -> 0.) /. float_of_int (max 1 (deg n))
    in
    let n =
      IS.fold (fun x best -> if value x < value best then x else best) !spill_wl
        (IS.min_elt !spill_wl)
    in
    spill_wl := IS.remove n !spill_wl;
    simplify_wl := IS.add n !simplify_wl;
    freeze_moves n
  in
  let rec loop () =
    if not (IS.is_empty !simplify_wl) then (simplify (); loop ())
    else if !worklist_moves <> [] then (coalesce (); loop ())
    else if not (IS.is_empty !freeze_wl) then (freeze (); loop ())
    else if not (IS.is_empty !spill_wl) then (select_spill (); loop ())
  in
  loop ();
  (* Colours, popping the stack.  A node sees its neighbours through their
     aliases, because a coalesced neighbour is somebody else now. *)
  let colours = Hashtbl.create 256 in
  for i = 0 to k - 1 do
    Hashtbl.replace colours i i
  done;
  let spills = ref [] in
  List.iter
    (fun n ->
      let taken =
        IS.fold
          (fun m acc ->
            match Hashtbl.find_opt colours (resolve m) with
            | Some c -> IS.add c acc
            | None -> acc)
          (adj_of n) IS.empty
      in
      let rec free c = if c >= k then None else if IS.mem c taken then free (c + 1) else Some c in
      match free 0 with
      | Some c -> Hashtbl.replace colours n c
      | None -> spills := n :: !spills)
    !select_stack;
  if !spills <> [] then raise (Spilled (List.map (fun n -> n - nphys) !spills));
  (* And the nodes that were fused take their alias's colour. *)
  IS.iter
    (fun n ->
      match Hashtbl.find_opt colours (resolve n) with
      | Some c -> Hashtbl.replace colours n c
      | None -> ())
    !coalesced;
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
  (* A move whose two ends were given the same colour is nothing.  Deleting it is
     not coalescing -- it does not reduce pressure, it only removes what the
     colouring made redundant -- but it is where the redundancy shows up. *)
  let pointless = function
    | M.Mov (a, b) -> a = b
    | _ -> false
  in
  let used = ref [] in
  let note r = match r with M.R c when List.mem c M.callee_saved && not (List.mem c !used) -> used := c :: !used | _ -> () in
  List.iter
    (fun (b : M.block) ->
      b.M.code <- List.filter (fun i -> not (pointless i)) (List.map instr b.M.code);
      b.M.term <- (match b.M.term with M.Ret o -> M.Ret (op o) | t -> t);
      List.iter
        (fun i ->
          let d, u = defs_uses i in
          List.iter note (d @ u))
        b.M.code)
    f.M.blocks;
  f.M.used_callee <- List.sort compare !used

(* One frame word per spilled value, and a value that spills twice keeps the
   word it had.  Two values that are never live together could share one -- it is
   the colouring problem over again, with slots for colours and no limit on how
   many -- but there is nothing here to share: a function spills because too much
   is live across one call, and everything live across that call interferes with
   everything else that is ([13章](../doc/13-regalloc.md)). *)
let func (f : M.func) =
  let slots = Hashtbl.create 16 in
  let unspillable = ref IS.empty in
  let rec go () =
    match colour f !unspillable with
    | colours -> apply f colours
    | exception Spilled vs ->
        List.iter
          (fun v ->
            if not (Hashtbl.mem slots v) then begin
              Hashtbl.replace slots v f.M.nspill;
              f.M.nspill <- f.M.nspill + 1
            end)
          vs;
        (* Everything the rewrite invents is off the table for the next round. *)
        let before = f.M.nvreg in
        rewrite f vs (Hashtbl.find slots);
        for i = before to f.M.nvreg - 1 do
          unspillable := IS.add (nphys + i) !unspillable
        done;
        go ()
  in
  go ()

let program (p : M.prog) = List.iter func p.M.funcs
