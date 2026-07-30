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
  mutable clos : M.reg; (* the running closure *)
  mutable param : M.reg; (* its argument *)
}

let fresh ctx =
  let r = M.V ctx.vreg in
  ctx.vreg <- ctx.vreg + 1;
  r

let put ctx i = ctx.code <- i :: ctx.code
let reg r = M.Reg r
let imm n = M.Imm n
let tagged n = imm ((2 * n) + 1)
let mem ?base ?index ?(scale = 1) ?(disp = 0) ?sym () = M.Mem { base; index; scale; disp; sym }
let glob name = mem ~sym:name ()
let field r i = mem ~base:r ~disp:(8 * i) ()

(* ---- the cost function --------------------------------------------------- *)

(* A value is a tile root -- it must end up in a register of its own -- unless
   it has exactly one use, that use is in the same block, and it is one of the
   operations an operand can absorb. *)
let absorbable (v : S.value) =
  match v.S.op with S.Field _ | S.Global _ | S.Const (S.CInt _) -> true | _ -> false

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
  | Nimm -> ( match v.S.op with S.Const (S.CInt _) -> 0 | _ -> inf)
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
  | ":=" -> Some "skunk_setref"
  | _ -> None

(* Tagged arithmetic.  An integer is 2n + 1, so

     a + b   is  a + b - 1        and with a constant, one lea
     a - b   is  a - b + 1
     a * b   is  (a >> 1) * (b - 1) + 1
     ~a      is  2 - a

   The constant cases are the reason to tile at all: `x + 1` is a single
   instruction that touches one register and writes another, and never has to
   untag anything. *)
let arith ctx op (args : S.value list) dst =
  match (op, args) with
  | "+", [ a; b ] when cost ctx b Nimm = 0 ->
      let n = match b.S.op with S.Const (S.CInt n) -> n | _ -> assert false in
      put ctx (M.Lea (dst, mem ~base:(in_reg ctx a) ~disp:(2 * n) ()))
  | "+", [ a; b ] ->
      let ra = in_reg ctx a in
      put ctx (M.Mov (reg dst, reg ra));
      put ctx (M.Alu ("add", reg dst, any ctx b));
      put ctx (M.Alu ("sub", reg dst, imm 1))
  | "-", [ a; b ] when cost ctx b Nimm = 0 ->
      let n = match b.S.op with S.Const (S.CInt n) -> n | _ -> assert false in
      put ctx (M.Lea (dst, mem ~base:(in_reg ctx a) ~disp:(-2 * n) ()))
  | "-", [ a; b ] ->
      let ra = in_reg ctx a in
      put ctx (M.Mov (reg dst, reg ra));
      put ctx (M.Alu ("sub", reg dst, any ctx b));
      put ctx (M.Alu ("add", reg dst, imm 1))
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
  | _ -> failwith ("select: no tile for " ^ op)

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

let start_block ctx bid preds =
  ctx.code <- [];
  (bid, preds)

let finish ctx (bid, preds) phis term =
  ctx.blocks <- { M.id = bid; phis; code = ctx.code; term; preds } :: ctx.blocks;
  ctx.code <- []

(* A switch becomes a chain of two-way branches, one per arm, each in its own
   block.  The first comparison stays where the switch was, so the first arm's
   predecessor does not move; the others gain a new one, which the phis in them
   have to be told about. *)
let switch ctx (bid, preds) phis (v : S.value) arms dflt fail =
  let keyed =
    List.map
      (fun (k, (b : S.block)) ->
        match k with
        | Core.Kint n -> (`Int (tagged n), b)
        | Core.Ktag c -> (`Int (imm c.Types.cidx), b)
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
  let rec chain here phis = function
    | [] -> (
        match default with
        | `Block b -> finish ctx here phis (M.Jmp b)
        | `Fail -> finish ctx here phis (M.Halt fail))
    | (key, (target : S.block)) :: rest ->
        let next = if rest = [] then match default with `Block b -> b | `Fail -> -1
                   else (ctx.fresh_bid <- ctx.fresh_bid + 1; ctx.fresh_bid - 1) in
        (match key with
        | `Int k ->
            let s = match scrutinee with `Tag t -> reg t | `Val r -> reg r in
            put ctx (M.Cmp (s, k))
        | `Str s ->
            let sv = match scrutinee with `Tag t -> reg t | `Val r -> reg r in
            put ctx (M.Mov (reg (M.R M.rdi), sv));
            put ctx (M.Lea (M.R M.rsi, glob (Statics.str s)));
            call ctx "skunk_equal";
            let t = fresh ctx in
            put ctx (M.Lea (t, glob "skunk_true"));
            put ctx (M.Cmp (reg (M.R M.rax), reg t)));
        let hid = fst here in
        if rest = [] then begin
          match default with
          | `Block b -> finish ctx here phis (M.Jcc ("e", target.S.bid, b));
              if hid <> bid then begin
                ctx.renames <- (target.S.bid, bid, hid) :: ctx.renames;
                ctx.renames <- (b, bid, hid) :: ctx.renames
              end
          | `Fail ->
              (* The failure needs a block of its own, because a block has one
                 terminator and this one already has a branch. *)
              ctx.fresh_bid <- ctx.fresh_bid + 1;
              let fb = ctx.fresh_bid - 1 in
              finish ctx here phis (M.Jcc ("e", target.S.bid, fb));
              if hid <> bid then ctx.renames <- (target.S.bid, bid, hid) :: ctx.renames;
              finish ctx (start_block ctx fb [ hid ]) [] (M.Halt fail)
        end
        else begin
          finish ctx here phis (M.Jcc ("e", target.S.bid, next));
          if hid <> bid then ctx.renames <- (target.S.bid, bid, hid) :: ctx.renames;
          chain (start_block ctx next [ hid ]) [] rest
        end
  in
  chain (bid, preds) phis keyed

let epilogue_ret ctx v = put ctx (M.Mov (reg (M.R M.rax), reg (in_reg ctx v)))

let block ctx (b : S.block) =
  let here = start_block ctx b.S.bid (List.map (fun (p : S.block) -> p.S.bid) b.S.preds) in
  (* A phi's destination is a register of its own; its sources are the operands
     the predecessors will copy from. *)
  let phis =
    List.map
      (fun (p : S.value) ->
        let d = fresh ctx in
        Hashtbl.replace ctx.regs p.S.vid d;
        ( d,
          List.map2
            (fun (pred : S.block) (a : S.value) ->
              ( pred.S.bid,
                match a.S.op with
                | S.Const (S.CInt n) -> tagged n
                | _ -> reg (Hashtbl.find ctx.regs a.S.vid) ))
            b.S.preds p.S.args ))
      b.S.phis
  in
  List.iter (value ctx) b.S.values;
  match b.S.term with
  | S.Ret v ->
      epilogue_ret ctx v;
      finish ctx here phis (M.Ret (reg (M.R M.rax)))
  | S.TailCall (f, a) ->
      put ctx (M.Mov (reg (M.R M.rdi), reg (in_reg ctx f)));
      put ctx (M.Mov (reg (M.R M.rsi), reg (in_reg ctx a)));
      finish ctx here phis M.TailCall
  | S.Jump t -> finish ctx here phis (M.Jmp t.S.bid)
  | S.Fail (loc, _) ->
      (* The message is the runtime's; what the compiler has to supply is where
         in the source it happened. *)
      finish ctx here phis (M.Halt (Loc.to_string loc))
  | S.Switch (v, arms, dflt) ->
      switch ctx here phis v arms dflt (Loc.to_string Loc.unknown)

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
      clos = M.V 0;
      param = M.V 0;
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
  (* Fix up the phis whose predecessors moved into a comparison chain. *)
  List.iter
    (fun (b : M.block) ->
      b.M.phis <-
        List.map
          (fun (d, srcs) ->
            ( d,
              List.map
                (fun (p, o) ->
                  match
                    List.find_opt (fun (t, old, _) -> t = b.M.id && old = p) ctx.renames
                  with
                  | Some (_, _, nw) -> (nw, o)
                  | None -> (p, o))
                srcs ))
          b.M.phis;
      b.M.preds <-
        List.map
          (fun p ->
            match List.find_opt (fun (t, old, _) -> t = b.M.id && old = p) ctx.renames with
            | Some (_, _, nw) -> nw
            | None -> p)
          b.M.preds)
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

(* ---- the program --------------------------------------------------------- *)

(* [List.filter_map] with the index, which the standard library does not
   have. *)
let filteri_map f l = List.filter_map (fun x -> x) (List.mapi f l)

let program (p : S.prog) =
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
