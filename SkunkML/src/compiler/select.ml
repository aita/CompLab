(* Instruction selection: value SSA to amd64, still in a graph and still with
   phis.

   Two things happen here, and they are worth keeping apart in your head.

   *Lowering* is the part with no choices in it.  A record becomes an allocation
   and a run of stores; a closure becomes a block whose first word is a code
   address; `+` becomes the two instructions that tagged integers need.  Nothing
   about the machine is being decided, only spelled out.

   *Tiling* is the part with choices.  One SSA value can turn into different
   instructions depending on what its neighbours are, because an amd64 operand
   can do work by itself: `[rbx + 24]` is a whole field access hidden inside
   another instruction's operand, and `lea rax, [rbx + 84]` is a whole tagged
   addition.  Choosing well means covering the value graph with as few, as cheap
   tiles as possible, and that is a shortest-path problem: `cost v nt` is the
   cheapest way to produce value `v` as an operand of kind `nt`, and it is
   defined in terms of the same question about `v`'s arguments.  Memoise it and
   you have the dynamic-programming tiler (Aho and Johnson); the memo is what
   stops the exponential blowup of trying every combination.

   The DP only runs where it can: on a value with exactly one use, in the block
   that uses it.  A value used twice has to live in a register anyway, so it is
   a tile root, and the graph is cut there.  This is where value SSA pays for
   itself -- the use count is a field, so "is this a tile root" is not an
   analysis, it is a lookup. *)

module S = Ssa
module M = Mach

(* ---- what an operand can be ---------------------------------------------- *)

(* The nonterminals of the tiler's grammar, cheapest first.  [Nimm] is an
   immediate, [Nmem] an addressing mode, [Nreg] a register.  Every value can be
   produced as [Nreg]; the other two are the opportunities. *)
type nt = Nimm | Nmem | Nreg

let inf = 1000

type ctx = {
  mutable vreg : int;
  mutable code : M.instr list; (* the current block, reversed *)
  mutable blocks : M.block list; (* finished, reversed *)
  mutable fresh_bid : int;
  (* Which virtual register holds each SSA value that got one. *)
  regs : (int, M.reg) Hashtbl.t;
  (* Where a value's single use is, when it has exactly one. *)
  one_use : (int, int) Hashtbl.t;
  (* Phi predecessors that moved because a switch grew a comparison chain. *)
  mutable renames : (int * int * int) list; (* target block, old pred, new pred *)
  (* Phis, resolved after every block has been selected.  A loop header's phi
     takes an argument from the latch, which is a *later* block, so its virtual
     register does not exist yet when the header is selected. *)
  mutable pending : (int * (M.reg * (int * S.value) list)) list;
  mutable clos : M.reg; (* the running closure *)
  mutable param : M.reg; (* its argument *)
  (* The block being filled: its id and its predecessors.  It is in the context
     rather than a local of [block] because a bounds check splits the block it
     is in, and the values after the check go into the new one. *)
  mutable here : int * int list;
}

let fresh ctx =
  let r = M.V ctx.vreg in
  ctx.vreg <- ctx.vreg + 1;
  r

let fresh_block ctx =
  ctx.fresh_bid <- ctx.fresh_bid + 1;
  ctx.fresh_bid - 1

let put ctx i = ctx.code <- i :: ctx.code
let reg r = M.Reg r
let imm n = M.Imm n
let tagged n = imm ((2 * n) + 1)
let mem ?base ?index ?(scale = 1) ?(disp = 0) ?sym () = M.Mem { base; index; scale; disp; sym }
let glob name = mem ~sym:name ()
let field r i = mem ~base:r ~disp:(8 * i) ()

(* An immediate and a displacement are four bytes wide, and a tagged integer is
   twice the number that was written -- so a constant stops fitting at 2^30,
   less than a thousandth of the way to where an `int` stops.  [Asm.fits32] is
   the same test the assembler makes before it refuses to truncate a field;
   asking it *here* is what turns "cannot encode that" into "choose another
   tile", and the other tile is always the same one: a register, loaded by the
   ten-byte movabs that [M.Mov (Reg, Imm)] widens to by itself. *)
let fits_tagged n = Asm.fits32 ((2 * n) + 1)

(* ---- the cost function --------------------------------------------------- *)

(* A value is a tile root -- it must end up in a register of its own -- unless
   it has exactly one use, that use is in the same block, and it is one of the
   operations an operand can absorb. *)
let absorbable (v : S.value) =
  match v.S.op with
  | S.Field _ | S.Global _ -> true
  (* A constant no operand field can hold is a tile root like anything else: it
     gets a register of its own, and consumers read it from there. *)
  | S.Const (S.CInt n) -> fits_tagged n
  | _ -> false

let foldable ctx (v : S.value) =
  absorbable v && v.S.uses = 1
  &&
  match Hashtbl.find_opt ctx.one_use v.S.vid with
  | Some b -> b = v.S.home.S.bid
  | None -> false

(* [cost] is memoised per selection, which is what makes this dynamic
   programming rather than exhaustive search: each (value, nonterminal) pair is
   answered once. *)
let memo : (int * nt, int) Hashtbl.t = Hashtbl.create 256

let rec cost ctx (v : S.value) nt =
  match Hashtbl.find_opt memo (v.S.vid, nt) with
  | Some c -> c
  | None ->
      let c = compute ctx v nt in
      Hashtbl.replace memo (v.S.vid, nt) c;
      c

and compute ctx v nt =
  match nt with
  | Nimm -> ( match v.S.op with S.Const (S.CInt n) when fits_tagged n -> 0 | _ -> inf)
  | Nmem ->
      if not (foldable ctx v) then inf
      else (
        match (v.S.op, v.S.args) with
        (* base + displacement: a field access with nothing of its own to do. *)
        | S.Field _, [ a ] -> cost ctx a Nreg
        (* rip-relative: a global needs no register at all. *)
        | S.Global _, [] -> 0
        | _ -> inf)
  | Nreg ->
      (* Already in a register if it is a tile root; otherwise the cheapest way
         of getting it into one. *)
      if not (foldable ctx v) then 0
      else min (cost ctx v Nimm + 1) (cost ctx v Nmem + 1)

(* ---- emitting an operand ------------------------------------------------- *)

(* Given the nonterminal the DP chose, produce the operand.  The two functions
   are separate so that the cost can be asked without emitting anything, which
   is what lets a consumer compare `Nmem` against `Nreg` before committing. *)
let rec operand ctx (v : S.value) nt =
  match nt with
  | Nimm -> ( match v.S.op with S.Const (S.CInt n) -> tagged n | _ -> assert false)
  | Nmem -> (
      match (v.S.op, v.S.args) with
      | S.Field (_, i), [ a ] -> (
          match operand ctx a Nreg with
          | M.Reg r -> field r i
          | _ -> assert false)
      | S.Global g, [] -> glob (Statics.global g None)
      | _ -> assert false)
  | Nreg ->
      if not (foldable ctx v) then reg (Hashtbl.find ctx.regs v.S.vid)
      else begin
        let d = fresh ctx in
        let nt' = if cost ctx v Nimm <= cost ctx v Nmem then Nimm else Nmem in
        put ctx (M.Mov (reg d, operand ctx v nt'));
        reg d
      end

(* The two things a consumer asks for. *)
let in_reg ctx v =
  match operand ctx v Nreg with M.Reg r -> r | _ -> assert false

(* An operand for something that can take memory or an immediate: whichever the
   DP says is cheapest. *)
let any ctx v =
  let best = List.fold_left (fun b nt -> if cost ctx v nt < cost ctx v b then nt else b) Nreg
      [ Nimm; Nmem ] in
  operand ctx v best

(* ---- values -------------------------------------------------------------- *)

let call ctx sym = put ctx (M.Call sym)

(* A runtime routine with its arguments already chosen: they go in rdi and rsi,
   the result comes back in rax, and the value is moved out of rax at once so
   that the allocator is free to put it anywhere. *)
let runtime ctx sym args dst =
  List.iteri
    (fun i a ->
      let r = match i with 0 -> M.rdi | 1 -> M.rsi | 2 -> M.rdx | _ -> assert false in
      put ctx (M.Mov (reg (M.R r), a)))
    args;
  call ctx sym;
  match dst with None -> () | Some d -> put ctx (M.Mov (reg d, reg (M.R M.rax)))

(* Allocation is a call, so the descriptor and the word count go in registers
   and the block comes back in one. *)
let alloc ctx desc words dst =
  put ctx (M.Lea (M.R M.rdi, glob desc));
  put ctx (M.Mov (reg (M.R M.rsi), imm words));
  call ctx "skunk_alloc";
  put ctx (M.Mov (reg dst, reg (M.R M.rax)))

(* ---- blocks -------------------------------------------------------------- *)

(* Starting and finishing a block.  They are up here rather than with the
   terminators because a bounds check needs them: the check is a branch, a block
   holds one terminator, so the value in the middle of a block that carries a
   check ends the block it was in and opens two more. *)

let start_block ctx bid preds =
  ctx.code <- [];
  ctx.here <- (bid, preds)

let finish ctx phis term =
  let bid, preds = ctx.here in
  ctx.blocks <- { M.id = bid; phis; code = ctx.code; term; preds } :: ctx.blocks;
  ctx.code <- []

let prim_routine = function
  | "^" -> Some "skunk_concat"
  | "@" -> Some "skunk_append"
  | "<" -> Some "skunk_lt"
  | "<=" -> Some "skunk_le"
  | ">" -> Some "skunk_gt"
  | ">=" -> Some "skunk_ge"
  | "=" -> Some "skunk_equal"
  | "<>" -> Some "skunk_noteq"
  | "div" -> Some "skunk_div"
  | "mod" -> Some "skunk_mod"
  | _ -> None

(* Tagged arithmetic.  An integer is 2n + 1, so

     a + b   is  a + b - 1        one lea, always
     a - b   is  (a + 1) - b
     a * b   is  (a - 1) * (b >> 1) + 1
     ~a      is  2 - a

   Every one of these has a fixup on it that the untagged arithmetic would not
   need, and `lea` is where the fixups go: it adds two registers and a constant
   in one instruction, it writes somewhere neither of them is, and it does not
   touch the flags.  So `a + b` is a whole tagged addition -- `lea -1(%ra,%rb)`
   -- rather than a move, an add and a subtract, and `x + 1` is the same tile
   with the register replaced by the constant.  The subtraction cannot fold its
   right operand into an address, but it can fold the fixup: `(a + 1) - b` puts
   the `+1` in the lea that would otherwise have been a `mov`. *)

(* The number a lea would put in its displacement, scaled the way that tile
   needs it -- [2n] to add a tagged constant, [-2n] to subtract one -- or [None]
   when four bytes will not hold it.  The scaling is why the check is here and
   not left to [cost ... Nimm]: `x - ~1073741824` has a tagged constant that
   fits and a displacement that does not, so the two questions have different
   answers at the edge. *)
let displacement (b : S.value) k =
  match b.S.op with
  | S.Const (S.CInt n) when Asm.fits32 (k * n) -> Some (k * n)
  | _ -> None

(* Which of two arguments is the constant, and what the other one is.  `+` and
   `*` are commutative and nothing upstream moves the constant to a side: `3 * r
   * r` associates to the left, so the constant is the *left* argument of the
   outer multiply.  Asking both sides costs one comparison and is the difference
   between one instruction and six on that line. *)
let commuted (a : S.value) (b : S.value) k =
  match displacement b k with
  | Some d -> Some (a, d)
  | None -> ( match displacement a k with Some d -> Some (b, d) | None -> None)

let arith ctx op (args : S.value list) dst =
  match (op, args) with
  | "+", [ a; b ] -> (
      match commuted a b 2 with
      | Some (x, d) -> put ctx (M.Lea (dst, mem ~base:(in_reg ctx x) ~disp:d ()))
      | None ->
          let ra = in_reg ctx a in
          let rb = in_reg ctx b in
          put ctx (M.Lea (dst, mem ~base:ra ~index:rb ~scale:1 ~disp:(-1) ())))
  | "-", [ a; b ] -> (
      match displacement b (-2) with
      | Some d -> put ctx (M.Lea (dst, mem ~base:(in_reg ctx a) ~disp:d ()))
      | None ->
          let ra = in_reg ctx a in
          let ob = any ctx b in
          put ctx (M.Lea (dst, mem ~base:ra ~disp:1 ()));
          put ctx (M.Alu ("sub", reg dst, ob)))
  | "*", [ a; b ] ->
      let ra = in_reg ctx a in
      let t = fresh ctx in
      put ctx (M.Mov (reg t, any ctx b));
      put ctx (M.Alu ("sub", reg t, imm 1));
      put ctx (M.Mov (reg dst, reg ra));
      put ctx (M.Sar (reg dst, 1));
      put ctx (M.Alu ("imul", reg dst, reg t));
      put ctx (M.Alu ("or", reg dst, imm 1))
  | "~", [ a ] ->
      let ra = in_reg ctx a in
      put ctx (M.Mov (reg dst, imm 2));
      put ctx (M.Alu ("sub", reg dst, reg ra))
  (* `/` is real-only, and the tiles above are tagged *integer* arithmetic.  No
     real can reach here -- `build.ml` refuses a real literal and refuses the
     Real and Math structures -- so this is the message for a program that got
     past both, not a hole to be filled by accident. *)
  | "/", _ ->
      Loc.fail ~where:"unsupported" Loc.unknown
        "/ needs a tile the back end does not have yet (see doc/18-abi.md)"
  | _ -> failwith ("select: no tile for " ^ op)

(* ---- the store ----------------------------------------------------------- *)

(* Reading and writing memory, whose shape the ABI has already settled (see
   doc/18-abi.md): a ref block is one word at offset 0, an array block is
   `[length][elements...]`, and the length word is *untagged* -- it is a header
   rather than a value, which is exactly why the collector skips it.

   None of these is absorbed into another instruction's operand the way a field
   read is.  A field read is from a block that never changes, so moving it later
   in the block cannot change its answer; a deref can, because a store to the
   same cell may be sitting in between.  The tiler has no memory dependences in
   it, so the safe thing is to keep the load where the SSA put it. *)

(* An array's length: one load, and then tag it.  `lea 1(%r,%r,1)` is 2r + 1 in
   one instruction, which is what an untagged header has to become before the
   program can see it as an int. *)
let array_length ctx a dst =
  put ctx (M.Mov (reg dst, field a 0));
  put ctx (M.Lea (dst, mem ~base:dst ~index:dst ~scale:1 ~disp:1 ()))

(* The bounds check, and the untagged index the addressing mode then wants.

   One comparison does both halves of it.  The index is compared *unsigned*
   against the length, so a negative index -- which as an unsigned number is
   enormous -- fails the same test that a too-large one fails, and `k >= 0` never
   needs an instruction of its own.

   The check is a branch, and a block holds one terminator, so this ends the
   block it is in and opens two: the one that reports and the one that carries
   on.  The failure is the runtime routine that was doing all of this before, so
   the message it prints is the same message by construction rather than by
   agreeing to spell it the same way.  It does not return, and the halt after it
   is there because a block has to end somehow. *)
let bounds ctx routine args (a : M.reg) (i : M.reg) =
  let k = fresh ctx in
  put ctx (M.Mov (reg k, reg i));
  put ctx (M.Sar (reg k, 1));
  put ctx (M.Cmp (reg k, field a 0));
  let bad = fresh_block ctx and ok = fresh_block ctx in
  let hid = fst ctx.here in
  finish ctx [] (M.Jcc ("b", ok, bad));
  start_block ctx bad [ hid ];
  (* Every argument, including the one `Array.update` would store.  The routine
     fails before it looks at that one, so it could be left as whatever happens
     to be in the register -- but a call that is only correct because of what the
     callee does not read is a trap for whoever edits the callee. *)
  runtime ctx routine args None;
  finish ctx [] (M.Halt "?");
  start_block ctx ok [ hid ];
  k

(* Element i is at 8*(i+1), so the addressing mode does the whole of the index
   arithmetic: base, index, scale 8, and a displacement of 8 to step over the
   length word.  This is the one place the tiler builds an `index * scale`. *)
let element a k = mem ~base:a ~index:k ~scale:8 ~disp:8 ()

let value ctx (v : S.value) =
  if foldable ctx v then ()
  else begin
    let dst = fresh ctx in
    Hashtbl.replace ctx.regs v.S.vid dst;
    match (v.S.op, v.S.args) with
    | S.Const (S.CInt n), _ -> put ctx (M.Mov (reg dst, tagged n))
    | S.Const (S.CStr s), _ -> put ctx (M.Lea (dst, glob (Statics.str s)))
    | S.Const S.CUnit, _ -> put ctx (M.Mov (reg dst, glob "skunk_the_unit"))
    | S.Global g, _ -> put ctx (M.Mov (reg dst, glob (Statics.global g None)))
    | S.Param, _ -> put ctx (M.Mov (reg dst, reg ctx.param))
    | S.Capture i, _ -> put ctx (M.Mov (reg dst, field ctx.clos (i + 1)))
    | S.MkClos (label, n), _ ->
        alloc ctx (Statics.closure_desc n) (n + 1) dst;
        let t = fresh ctx in
        put ctx (M.Lea (t, glob (Statics.code_label label)));
        put ctx (M.Mov (field dst 0, reg t))
    | S.SetCap i, [ c; x ] ->
        let rc = in_reg ctx c in
        put ctx (M.Mov (field rc (i + 1), reg (in_reg ctx x)))
    | S.Call, [ f; a ] ->
        put ctx (M.Mov (reg (M.R M.rdi), reg (in_reg ctx f)));
        put ctx (M.Mov (reg (M.R M.rsi), reg (in_reg ctx a)));
        put ctx (M.Mov (reg (M.R M.rcx), field (M.R M.rdi) 0));
        put ctx (M.CallReg (M.R M.rcx));
        put ctx (M.Mov (reg dst, reg (M.R M.rax)))
    (* The store.  These five arrive as prims because [basis_ops] below turned
       the calls that spelled them into prims; nothing in the source says
       `prim !`. *)
    | S.Prim "!", [ r ] -> put ctx (M.Mov (reg dst, field (in_reg ctx r) 0))
    | S.Prim ":=", [ r; x ] ->
        let rr = in_reg ctx r in
        let rx = in_reg ctx x in
        put ctx (M.Mov (field rr 0, reg rx));
        (* An assignment is usually a statement, and its unit is usually not
           read.  Only fetch it when somebody wants it. *)
        if v.S.uses > 0 then put ctx (M.Mov (reg dst, glob "skunk_the_unit"))
    | S.Prim "Array.length", [ a ] -> array_length ctx (in_reg ctx a) dst
    | S.Prim "Array.sub", [ a; i ] ->
        let ra = in_reg ctx a in
        let ri = in_reg ctx i in
        let k = bounds ctx "skunk_array_sub" [ reg ra; reg ri ] ra ri in
        put ctx (M.Mov (reg dst, element ra k))
    | S.Prim "Array.update", [ a; i; x ] ->
        let ra = in_reg ctx a in
        let ri = in_reg ctx i in
        let rx = in_reg ctx x in
        let k = bounds ctx "skunk_array_update" [ reg ra; reg ri; reg rx ] ra ri in
        put ctx (M.Mov (element ra k, reg rx));
        if v.S.uses > 0 then put ctx (M.Mov (reg dst, glob "skunk_the_unit"))
    | S.Prim p, args -> (
        match prim_routine p with
        | Some sym ->
            let ops = List.map (fun a -> reg (in_reg ctx a)) args in
            runtime ctx sym ops (Some dst)
        | None -> arith ctx p args dst)
    | S.Record ls, args ->
        let n = List.length ls in
        (* The fields are read into registers before the allocation, because the
           allocation is a call and a call destroys the caller-saved ones. *)
        let ops = List.map (fun a -> in_reg ctx a) args in
        alloc ctx (Statics.record_desc ls) n dst;
        List.iteri (fun i r -> put ctx (M.Mov (field dst i, reg r))) ops
    | S.Con c, [] -> put ctx (M.Lea (dst, glob (Statics.nullary c)))
    | S.Con c, [ a ] ->
        let ra = in_reg ctx a in
        alloc ctx (Statics.con_desc c) 1 dst;
        put ctx (M.Mov (field dst 0, reg ra))
    | S.Field (_, i), [ a ] -> put ctx (M.Mov (reg dst, field (in_reg ctx a) i))
    | S.Payload, [ a ] -> put ctx (M.Mov (reg dst, field (in_reg ctx a) 0))
    | S.Phi, _ -> () (* handled with the block *)
    | op, _ -> failwith ("select: cannot select " ^ S.op_str { v with S.op })
  end

(* ---- terminators --------------------------------------------------------- *)

(* A switch becomes a chain of two-way branches, one per arm, each in its own
   block.  The first comparison stays where the switch was, so the first arm's
   predecessor does not move; the others gain a new one, which the phis in them
   have to be told about. *)
let switch ctx phis (v : S.value) arms dflt fail =
  let bid = fst ctx.here in
  let keyed =
    List.map
      (fun (k, (b : S.block)) ->
        match k with
        | Core.Kint n -> (`Int ((2 * n) + 1), b)
        | Core.Ktag c -> (`Int c.Types.cidx, b)
        | Core.Kstr s -> (`Str s, b))
      arms
  in
  (* For a datatype it is the tag that is compared, and the tag is in the
     descriptor. *)
  let scrutinee =
    match arms with
    | (Core.Ktag _, _) :: _ ->
        let d = fresh ctx and t = fresh ctx in
        put ctx (M.Mov (reg d, mem ~base:(in_reg ctx v) ~disp:(-8) ()));
        put ctx (M.Mov (reg t, mem ~base:d ~disp:Rt.d_tag ()));
        `Tag t
    | _ -> `Val (in_reg ctx v)
  in
  let default =
    match dflt with
    | Some b -> `Block b.S.bid
    | None -> `Fail
  in
  let rec chain phis = function
    | [] -> (
        match default with
        | `Block b -> finish ctx phis (M.Jmp b)
        | `Fail -> finish ctx phis (M.Halt fail))
    | (key, (target : S.block)) :: rest ->
        let next =
          if rest = [] then match default with `Block b -> b | `Fail -> -1
          else fresh_block ctx
        in
        (match key with
        | `Int k ->
            let s = match scrutinee with `Tag t -> reg t | `Val r -> reg r in
            (* cmp's immediate is four bytes like every other, so a key wider
               than that is compared out of a register.  Tags are small; it is
               `case n of 3000000000 => ...` that gets here. *)
            let k =
              if Asm.fits32 k then imm k
              else begin
                let t = fresh ctx in
                put ctx (M.Mov (reg t, imm k));
                reg t
              end
            in
            put ctx (M.Cmp (s, k))
        | `Str s ->
            let sv = match scrutinee with `Tag t -> reg t | `Val r -> reg r in
            put ctx (M.Mov (reg (M.R M.rdi), sv));
            put ctx (M.Lea (M.R M.rsi, glob (Statics.str s)));
            call ctx "skunk_equal";
            let t = fresh ctx in
            put ctx (M.Lea (t, glob "skunk_true"));
            put ctx (M.Cmp (reg (M.R M.rax), reg t)));
        let hid = fst ctx.here in
        if rest = [] then begin
          match default with
          | `Block b -> finish ctx phis (M.Jcc ("e", target.S.bid, b));
              if hid <> bid then begin
                ctx.renames <- (target.S.bid, bid, hid) :: ctx.renames;
                ctx.renames <- (b, bid, hid) :: ctx.renames
              end
          | `Fail ->
              (* The failure needs a block of its own, because a block has one
                 terminator and this one already has a branch. *)
              let fb = fresh_block ctx in
              finish ctx phis (M.Jcc ("e", target.S.bid, fb));
              if hid <> bid then ctx.renames <- (target.S.bid, bid, hid) :: ctx.renames;
              start_block ctx fb [ hid ];
              finish ctx [] (M.Halt fail)
        end
        else begin
          finish ctx phis (M.Jcc ("e", target.S.bid, next));
          if hid <> bid then ctx.renames <- (target.S.bid, bid, hid) :: ctx.renames;
          start_block ctx next [ hid ];
          chain [] rest
        end
  in
  chain phis keyed

let epilogue_ret ctx v = put ctx (M.Mov (reg (M.R M.rax), reg (in_reg ctx v)))

let block ctx (b : S.block) =
  start_block ctx b.S.bid (List.map (fun (p : S.block) -> p.S.bid) b.S.preds);
  (* A phi's destination is a register of its own; its sources are the operands
     the predecessors will copy from. *)
  List.iter
    (fun (p : S.value) ->
      let d = fresh ctx in
      Hashtbl.replace ctx.regs p.S.vid d;
      ctx.pending <-
        (b.S.bid, (d, List.map2 (fun (pred : S.block) a -> (pred.S.bid, a)) b.S.preds p.S.args))
        :: ctx.pending)
    b.S.phis;
  let phis = [] in
  List.iter (value ctx) b.S.values;
  (* A bounds check may have split the block, in which case the terminator is
     leaving from somewhere else than it arrived, and the phis in the successors
     name a predecessor that no longer branches to them. *)
  let hid = fst ctx.here in
  if hid <> b.S.bid then
    List.iter
      (fun (s : S.block) -> ctx.renames <- (s.S.bid, b.S.bid, hid) :: ctx.renames)
      (S.succs b);
  match b.S.term with
  | S.Ret v ->
      epilogue_ret ctx v;
      finish ctx phis (M.Ret (reg (M.R M.rax)))
  | S.TailCall (f, a) ->
      put ctx (M.Mov (reg (M.R M.rdi), reg (in_reg ctx f)));
      put ctx (M.Mov (reg (M.R M.rsi), reg (in_reg ctx a)));
      finish ctx phis M.TailCall
  | S.Jump t -> finish ctx phis (M.Jmp t.S.bid)
  | S.Fail (loc, _) ->
      (* The message is the runtime's; what the compiler has to supply is where
         in the source it happened. *)
      finish ctx phis (M.Halt (Loc.to_string loc))
  | S.Switch (v, arms, dflt) -> switch ctx phis v arms dflt (Loc.to_string Loc.unknown)

(* ---- functions ----------------------------------------------------------- *)

(* Every value's single use, so that the tiler knows which values it may fold
   into an operand and which have to stand on their own. *)
let use_map (f : S.func) =
  let t = Hashtbl.create 64 in
  List.iter
    (fun (b : S.block) ->
      let note (v : S.value) = if v.S.uses = 1 then Hashtbl.replace t v.S.vid b.S.bid in
      List.iter (fun (v : S.value) -> List.iter note v.S.args) b.S.values;
      match b.S.term with
      | S.Ret v -> note v
      | S.TailCall (a, c) ->
          note a;
          note c
      | S.Switch (v, _, _) -> note v
      | S.Jump _ | S.Fail _ -> ())
    f.S.blocks;
  t

let func ?name (f : S.func) =
  Hashtbl.reset memo;
  let entry = f.S.entry.S.bid in
  let max_bid = List.fold_left (fun m (b : S.block) -> max m b.S.bid) 0 f.S.blocks in
  let ctx =
    {
      vreg = 0;
      code = [];
      blocks = [];
      fresh_bid = max_bid + 1;
      regs = Hashtbl.create 64;
      one_use = use_map f;
      renames = [];
      pending = [];
      clos = M.V 0;
      param = M.V 0;
      here = (entry, []);
    }
  in
  (* The prologue: the closure arrives in rdi and the argument in rsi, and both
     are copied straight into virtual registers so that the allocator can move
     them wherever it likes. *)
  ctx.clos <- fresh ctx;
  ctx.param <- fresh ctx;
  let prologue =
    [ M.Mov (reg ctx.param, reg (M.R M.rsi)); M.Mov (reg ctx.clos, reg (M.R M.rdi)) ]
  in
  List.iter (block ctx) f.S.blocks;
  let blocks = List.rev ctx.blocks in
  (* Now every value has its register, so the phis can be filled in. *)
  List.iter
    (fun (b : M.block) ->
      b.M.phis <-
        List.filter_map
          (fun (bid, (d, srcs)) ->
            if bid <> b.M.id then None
            else
              Some
                ( d,
                  List.map
                    (fun (p, (a : S.value)) ->
                      ( p,
                        match a.S.op with
                        | S.Const (S.CInt n) -> tagged n
                        | _ -> reg (Hashtbl.find ctx.regs a.S.vid) ))
                    srcs ))
          (List.rev ctx.pending))
    blocks;
  (* Fix up the phis whose predecessors moved -- into a comparison chain, or past
     a bounds check.  The moves compose: a block that a check split and that then
     ends in a switch renames twice, once per step, so the lookup follows the
     chain rather than stopping at the first link.  It terminates because each
     new id is a fresh one, so a rename never points backwards. *)
  let rec renamed target p =
    match List.find_opt (fun (t, old, _) -> t = target && old = p) ctx.renames with
    | Some (_, _, nw) when nw <> p -> renamed target nw
    | _ -> p
  in
  List.iter
    (fun (b : M.block) ->
      b.M.phis <-
        List.map
          (fun (d, srcs) -> (d, List.map (fun (p, o) -> (renamed b.M.id p, o)) srcs))
          b.M.phis;
      b.M.preds <- List.map (renamed b.M.id) b.M.preds)
    blocks;
  (* The prologue goes at the top of the entry block, after its phis (it has
     none: nothing jumps to the entry). *)
  List.iter
    (fun (b : M.block) -> if b.M.id = entry then b.M.code <- b.M.code @ prologue)
    blocks;
  {
    M.name = (match name with Some n -> n | None -> Statics.code_label f.S.fn);
    entry;
    blocks;
    nvreg = ctx.vreg;
    nspill = 0;
    used_callee = [];
  }

(* ---- the basis calls that are really machine operations ------------------ *)

(* `!r` reaches the machine as: read the global that holds the basis closure,
   load the code address out of it, call through it, and let the callee do one
   8-byte load.  `Array.sub (a, i)` is worse, because the language passes one
   argument: the pair is allocated, so a bounds-checked load costs a collection's
   worth of heap.  Every one of these is one or two instructions, and
   doc/18-abi.md already says which ones.

   This *is* a tile, but not one the cost function can express.  It spans four
   values -- the global, the field read, the tuple, the call -- and what it does
   to three of them is delete them, which is not something a per-value cost can
   say.  Half the time it is not even a value: `Array.sub` in tail position is a
   terminator.  So it is done first, by rewriting those four values into one
   prim, and the tiler downstream sees a prim like any other.

   Nothing outside this file ever sees these prims, which is why they are prims
   and not new `Ssa.op`s: the rewrite runs inside selection, after every pass
   that matches on an op has already run. *)

(* Which globals still hold what the basis put in them.  A global is a word, and
   a top-level binding of that name overwrites it -- `val ! = fn x => 0` is a
   legal program and means what it says -- so the rewrite only fires on a name no
   item of this program rebinds.  It is the same question `loops.ml` asks in
   `known` before it turns a call into a jump. *)
let basis_intact (p : S.prog) =
  let taken = Hashtbl.create 16 in
  List.iter
    (fun (i : S.item) -> if i.S.iname <> "" then Hashtbl.replace taken i.S.iname ())
    p.S.items;
  fun n -> not (Hashtbl.mem taken n)

(* Where a field sits in a basis structure.  The labels are sorted, because that
   is what a record is here: a field is reached by offset and the offset came
   from the sorted labels (`stubs.ml`).  Checking the offset as well as the name
   costs nothing and means this cannot drift away from what was laid out. *)
let structure_field s f =
  match List.assoc_opt s Stubs.structures with
  | None -> None
  | Some fields ->
      let sorted = Types.sort_fields (List.map (fun (n, _, _) -> (n, ())) fields) in
      let rec at i = function
        | (n, ()) :: _ when n = f -> Some i
        | _ :: rest -> at (i + 1) rest
        | [] -> None
      in
      at 0 sorted

(* The prim a callee stands for, and how many arguments it takes. *)
let inline_prim intact (f : S.value) =
  match (f.S.op, f.S.args) with
  | S.Global "!", _ when intact "!" -> Some ("!", 1)
  | S.Field (l, i), [ g ] -> (
      match (g.S.op, l) with
      | S.Global "Array", ("sub" | "update" | "length")
        when intact "Array" && structure_field "Array" l = Some i ->
          Some ("Array." ^ l, match l with "update" -> 3 | "sub" -> 2 | _ -> 1)
      | _ -> None)
  | _ -> None

(* The arguments the tile wants, out of the one argument the call passes.  Two or
   three of them arrive as a tuple, and a tuple is a record whose arguments are
   the values that were about to be stored in it -- so reading them straight is
   what lets the allocation go.  It is safe wherever the call is: a record's
   arguments dominate the record, and the record dominates the call.

   A tuple that was not built here (`val p = (a, i)` used twice, say) is not
   matched, and the call stays a call. *)
let untuple n (a : S.value) =
  if n = 1 then Some [ a ]
  else
    match (a.S.op, a.S.args) with
    | S.Record ls, args
      when List.length args = n && ls = List.init n (fun i -> string_of_int (i + 1)) ->
        Some args
    | _ -> None

let basis_ops intact (f : S.func) =
  let next =
    ref
      (List.fold_left
         (fun m (b : S.block) ->
           List.fold_left (fun m (v : S.value) -> max m (v.S.vid + 1)) m (b.S.phis @ b.S.values))
         0 f.S.blocks)
  in
  (* What the rewrite took the last use of.  Nothing else is going to come along
     and remove them -- the optimiser has already run, and with `--no-opt` it
     never ran at all -- so the pass clears up after itself, and only after
     itself: a value it did not consume is left alone however dead it is. *)
  let consumed = Hashtbl.create 16 in
  let eat (callee : S.value) (arg : S.value) =
    Hashtbl.replace consumed callee.S.vid ();
    Hashtbl.replace consumed arg.S.vid ();
    List.iter (fun (g : S.value) -> Hashtbl.replace consumed g.S.vid ()) callee.S.args
  in
  let hit = ref false in
  let recognise (g : S.value) (a : S.value) =
    match inline_prim intact g with
    | Some (p, n) -> (
        match untuple n a with
        | Some args ->
            eat g a;
            hit := true;
            Some (p, args)
        | None -> None)
    | None -> None
  in
  List.iter
    (fun (b : S.block) ->
      List.iter
        (fun (v : S.value) ->
          match (v.S.op, v.S.args) with
          | S.Call, [ g; a ] -> (
              match recognise g a with
              | Some (p, args) ->
                  v.S.op <- S.Prim p;
                  v.S.args <- args
              | None -> ())
          | _ -> ())
        b.S.values;
      match b.S.term with
      | S.TailCall (g, a) -> (
          match recognise g a with
          | Some (p, args) ->
              (* A tail call that is really a load returns the load, so the
                 terminator becomes a return of a value that did not exist. *)
              let v = { S.vid = !next; op = S.Prim p; args; home = b; uses = 0; origin = "" } in
              incr next;
              b.S.values <- b.S.values @ [ v ];
              b.S.term <- S.Ret v
          | None -> ())
      | _ -> ())
    f.S.blocks;
  if !hit then begin
    (* Repeated, because dropping the field read is what makes the global
       unused. *)
    let go = ref true in
    while !go do
      go := false;
      S.recount f;
      List.iter
        (fun (b : S.block) ->
          let keep (v : S.value) = v.S.uses > 0 || not (Hashtbl.mem consumed v.S.vid) in
          let before = List.length b.S.values in
          b.S.values <- List.filter keep b.S.values;
          if List.length b.S.values <> before then go := true)
        f.S.blocks
    done
  end

(* ---- the program --------------------------------------------------------- *)

(* [List.filter_map] with the index, which the standard library does not
   have. *)
let filteri_map f l = List.filter_map (fun x -> x) (List.mapi f l)

let program (p : S.prog) =
  let intact = basis_intact p in
  List.iter (basis_ops intact) p.S.funcs;
  List.iter (fun (i : S.item) -> Option.iter (basis_ops intact) i.S.ibody) p.S.items;
  let funcs = List.map (fun f -> func f) p.S.funcs in
  (* A top-level binding's body is a function of no arguments, and closure
     conversion did not have to give it a distinct name because nothing calls
     it.  Emission does need one, so it gets its position. *)
  let item_name i = Printf.sprintf "item_%d" i in
  let item_funcs =
    filteri_map
      (fun i (it : S.item) -> Option.map (func ~name:(item_name i)) it.S.ibody)
      p.S.items
  in
  let items =
    List.mapi
      (fun i (it : S.item) ->
        {
          M.it_global = (if it.S.iname = "" then None else Some (Statics.global it.S.iname None));
          it_code = Option.map (fun (_ : S.func) -> item_name i) it.S.ibody;
          it_label = Option.map Lazy.force it.S.ilabel;
          it_show = it.S.ishow;
        })
      p.S.items
  in
  { M.funcs = funcs @ item_funcs; globals = []; items }
