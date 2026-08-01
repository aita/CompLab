(* The three-address IR, and the control flow graph both IRs are written in.

   There are two instruction sets in this compiler.  This file has the first:
   three-address code over virtual registers, which is what lowering produces,
   what [ssa.ml] puts into SSA and what [opt.ml] rewrites.  The second is in
   [mach.ml], and instruction selection replaces the arithmetic of this one with
   it.

   OCaml cannot add a constructor to a variant from another file, so [Machine]
   and the record it carries are declared here even though [mach.ml] owns
   everything about what they mean: the table of forms, which ones the emitter
   expands, and the verifier that says what may no longer appear.  That is the
   one seam the other three ports do not have.

   What the two sets share is everything else — the registers, the blocks, the
   graph, the frame — so the passes that only care about the shape of a function
   (liveness, dominance, the register allocator, the verifiers) work on either.
   That is what [defs], [uses], [map_uses], [set_def] and [has_effect] below are
   for: an instruction says which register it writes and which it reads, and
   nothing outside this file has to match on what it is.

   Nothing here is ARM-specific except that a register holds exactly one 64-bit
   word, and the frame layout at the top, which the emitter and the nested
   functions have to agree about. *)

module IntSet = Set.Make (Int)
module IntMap = Map.Make (Int)
module StrSet = Set.Make (String)
module StrMap = Map.Make (String)

(* A virtual register.  "Does it write anything" is a [reg option] and not a
   register no real one ever has: the type is what says an instruction may write
   nothing, so the places that have to think about it are the places that fail to
   compile without thinking about it. *)
type reg = int

let word = 8

(* How many arguments AAPCS64 passes in registers.  The rest go on the stack, and
   the frame layout below knows where. *)
let argument_registers = 8

(* Where a frame slot sits, relative to the frame pointer.

   Slot 0 of every nested function holds its static link, so a frame chain can be
   walked without knowing whose frame it is.  Negative slots are the arguments
   the caller had to pass on the stack: they are already in the frame, above the
   saved frame record, so nothing has to be copied for them and they never take a
   register at entry. *)
let slot_offset slot =
  if slot < 0 then 16 + (word * (-slot - 1)) else -word * (slot + 1)

(* The machine instruction: a form, a register it writes and some it reads.
   [mach.ml] is where the forms are listed and checked. *)
type mach = {
  form : string;
  m_dst : reg option;
  srcs : reg list;
  imm : int64;
  symbol : string;
  effectful : bool;
}

type instr =
  | Const of { dst : reg; value : int64 }
  | Str_const of { dst : reg; str_symbol : string }
  | Move of { dst : reg; src : reg }
  | Bin of { dst : reg; op : string; lhs : reg; rhs : reg }
  | Cmp of { dst : reg; op : string; lhs : reg; rhs : reg }
  | Load of { dst : reg; base : reg; offset : int }
  | Store of { base : reg; offset : int; src : reg }
  (* Read a frame slot of this function — an escaping variable, or a spill. *)
  | Load_slot of { dst : reg; slot : int }
  | Store_slot of { slot : int; src : reg }
  (* The frame pointer itself, which is what a static link points at. *)
  | Frame_addr of { dst : reg }
  | Call of { dst : reg option; callee : string; args : reg list }
  | Jmp of { target : string }
  | Cbr of {
      cond : reg;
      then_ : string;
      else_ : string;
      (* After selection a branch may read the flags a comparison just set
         instead of testing a register, and then it reads no register at all. *)
      code : string;
    }
  | Ret of { value : reg option }
  | Machine of mach

(* One edge of a phi.  They are a list and not a map because the order they were
   placed in is the order a dump has to print them in. *)
type phi_arg = { pred : string; arg : reg }

type phi = { phi_dst : reg; args : phi_arg list }

(* -- what every instruction of either set can be asked ---------------------- *)

(* The register it writes, if it writes one. *)
let defs = function
  | Const c -> Some c.dst
  | Str_const c -> Some c.dst
  | Move m -> Some m.dst
  | Bin b -> Some b.dst
  | Cmp c -> Some c.dst
  | Load l -> Some l.dst
  | Load_slot l -> Some l.dst
  | Frame_addr f -> Some f.dst
  | Call c -> c.dst
  | Machine m -> m.m_dst
  | Store _ | Store_slot _ | Jmp _ | Cbr _ | Ret _ -> None

(* The registers it reads.  A phi's arguments are read on the edges, not here, so
   they are not among them. *)
let uses = function
  | Move m -> [ m.src ]
  | Bin b -> [ b.lhs; b.rhs ]
  | Cmp c -> [ c.lhs; c.rhs ]
  | Load l -> [ l.base ]
  | Store s -> [ s.base; s.src ]
  | Store_slot s -> [ s.src ]
  | Call c -> c.args
  | Machine m -> m.srcs
  | Cbr c -> if c.code <> "" then [] else [ c.cond ]
  | Ret r -> Option.to_list r.value
  | Const _ | Str_const _ | Load_slot _ | Frame_addr _ | Jmp _ -> []

(* The same instruction with the registers it reads renamed.

   An instruction is a value, so this answers with a new one rather than
   changing the old, and the caller puts it back where the old one was:

     Dynarray.set b.instrs at (map_uses rename (Dynarray.get b.instrs at))

   Nothing downstream notices, because no pass holds an instruction anywhere but
   in the block it came out of. *)
let map_uses f = function
  | Move m -> Move { m with src = f m.src }
  | Bin b ->
      let lhs = f b.lhs in
      Bin { b with lhs; rhs = f b.rhs }
  | Cmp c ->
      let lhs = f c.lhs in
      Cmp { c with lhs; rhs = f c.rhs }
  | Load l -> Load { l with base = f l.base }
  | Store s ->
      let base = f s.base in
      Store { s with base; src = f s.src }
  | Store_slot s -> Store_slot { s with src = f s.src }
  | Call c -> Call { c with args = Util.map_in_order f c.args }
  | Machine m -> Machine { m with srcs = Util.map_in_order f m.srcs }
  | Cbr c -> if c.code = "" then Cbr { c with cond = f c.cond } else Cbr c
  | Ret r -> Ret { value = Option.map f r.value }
  | (Const _ | Str_const _ | Load_slot _ | Frame_addr _ | Jmp _) as i -> i

(* The same instruction, writing [r] instead.  Only asked of one that writes. *)
let with_def r = function
  | Const c -> Const { c with dst = r }
  | Str_const c -> Str_const { c with dst = r }
  | Move m -> Move { m with dst = r }
  | Bin b -> Bin { b with dst = r }
  | Cmp c -> Cmp { c with dst = r }
  | Load l -> Load { l with dst = r }
  | Load_slot l -> Load_slot { l with dst = r }
  | Frame_addr _ -> Frame_addr { dst = r }
  | Call c -> Call { c with dst = Some r }
  | Machine m -> Machine { m with m_dst = Some r }
  | Store _ | Store_slot _ | Jmp _ | Cbr _ | Ret _ ->
      failwith "this instruction defines nothing"

(* True when it has to be kept even if its result is dead. *)
let has_effect = function
  | Store _ | Store_slot _ | Call _ | Jmp _ | Cbr _ | Ret _ -> true
  | Machine m -> m.effectful
  | _ -> false

(* -- the graph -------------------------------------------------------------- *)

type block = {
  label : string;
  mutable phis : phi list;
  (* A growable array, because the passes append, insert and replace by index the
     way the Python list does. *)
  mutable instrs : instr Dynarray.t;
  mutable preds : string list;
}

(* One function: a frame, a set of parameters, and a graph of blocks. *)
type func = {
  flabel : string;
  fname : string;
  params : reg Dynarray.t;
  depth : int;
  entry : string;
  blocks : (string, block) Hashtbl.t;
  (* A growable array and not a list: a block is appended at the end, and
     appending to a list is what made lowering quadratic in the block count. *)
  order : string Dynarray.t;
  mutable nregs : int;
  mutable nslots : int;
  mutable link_slot : int;
}

(* What the allocator decided.

   Not fields of [func], because none of it is part of the program: a colouring
   is an assignment from the program's registers to the machine's, and the
   emitter is the only thing that has to read one.  A pass answers with its
   result rather than writing it back into what it was given. *)
type allocation = {
  colours : int IntMap.t;
  (* The callee-saved registers this function actually used, in order. *)
  saved : int list;
  (* Which frame slot each spilled register went to. *)
  spilled : int IntMap.t;
}

let unallocated = { colours = IntMap.empty; saved = []; spilled = IntMap.empty }

(* A literal and the symbol it is emitted under, in the order they were first
   seen. *)
type string_lit = { lit_symbol : string; text : string }

type modul = { mutable funcs : func list; mutable strings : string_lit list }

let new_func label name depth =
  {
    flabel = label;
    fname = name;
    params = Dynarray.create ();
    depth;
    entry = "entry";
    blocks = Hashtbl.create 16;
    order = Dynarray.create ();
    nregs = 0;
    nslots = 0;
    link_slot = -1;
  }

let new_reg f =
  f.nregs <- f.nregs + 1;
  f.nregs - 1

let new_slot f =
  f.nslots <- f.nslots + 1;
  f.nslots - 1

let block f label =
  match Hashtbl.find_opt f.blocks label with
  | Some b -> b
  | None -> failwith ("no block " ^ label ^ " in " ^ f.fname)

let add_block f label =
  if Hashtbl.mem f.blocks label then failwith ("block " ^ label ^ " already exists");
  let b = { label; phis = []; instrs = Dynarray.create (); preds = [] } in
  Hashtbl.replace f.blocks label b;
  Dynarray.add_last f.order label;
  b

(* Every block, in the order they were made.  [iter_blocks] is the same walk
   without building the list, which is what the passes that run to a fixed point
   reach for. *)
let iter_blocks f g = Dynarray.iter (fun label -> g (block f label)) f.order

let walk f = List.map (block f) (Dynarray.to_list f.order)

(* The labels, as a list, for the two places that have to snapshot them before
   adding blocks to the very array they are walking. *)
let order_list f = Dynarray.to_list f.order

let emit b instr = Dynarray.add_last b.instrs instr
let instrs b = Dynarray.to_list b.instrs

(* The instructions without building the list, for the passes that run to a fixed
   point and would otherwise allocate one per round. *)
let iter_instrs b g = Dynarray.iter g b.instrs

(* Put every instruction through [g] and keep the answer where it came from,
   which is what a pass that rewrites instructions does. *)
let map_instrs b g =
  for at = 0 to Dynarray.length b.instrs - 1 do
    Dynarray.set b.instrs at (g (Dynarray.get b.instrs at))
  done

let map_phis b g = b.phis <- List.map g b.phis
let set_instrs b list = b.instrs <- Dynarray.of_list list
let count b = Dynarray.length b.instrs
let nth b i = Dynarray.get b.instrs i

let terminator b =
  if Dynarray.is_empty b.instrs then failwith ("block " ^ b.label ^ " is unterminated");
  let last = Dynarray.get b.instrs (Dynarray.length b.instrs - 1) in
  match last with
  | Jmp _ | Cbr _ | Ret _ -> last
  | _ -> failwith ("block " ^ b.label ^ " falls through")

let succs b =
  match terminator b with
  | Jmp j -> [ j.target ]
  | Cbr c -> if c.then_ <> c.else_ then [ c.then_; c.else_ ] else [ c.then_ ]
  | _ -> []

(* -- phis ------------------------------------------------------------------- *)

let phi_arg phi pred = List.find_opt (fun a -> a.pred = pred) phi.args

(* A phi is a value too.  [set_arg] keeps an argument where it was and appends a
   new one at the end; [remove_arg] answers with the argument and the phi without
   it, so the caller cannot forget one of the two. *)
let set_arg pred r phi =
  if List.exists (fun a -> a.pred = pred) phi.args then
    { phi with
      args = List.map (fun a -> if a.pred = pred then { a with arg = r } else a) phi.args }
  else { phi with args = phi.args @ [ { pred; arg = r } ] }

let remove_arg pred phi =
  match phi_arg phi pred with
  | None -> None
  | Some a ->
      Some (a.arg, { phi with args = List.filter (fun o -> o.pred <> pred) phi.args })

let phi_preds phi = List.map (fun a -> a.pred) phi.args

(* -- rewiring --------------------------------------------------------------- *)

let rename_target old fresh = function
  | Jmp j -> Jmp { target = (if j.target = old then fresh else j.target) }
  | Cbr c ->
      Cbr
        { c with
          then_ = (if c.then_ = old then fresh else c.then_);
          else_ = (if c.else_ = old then fresh else c.else_)
        }
  | i -> i

let recompute_preds f =
  Hashtbl.iter (fun _ b -> b.preds <- []) f.blocks;
  (* Built by prepending and reversed once, because the order predecessors are
     listed in is what a dump prints. *)
  iter_blocks f (fun b ->
      List.iter (fun s -> let t = block f s in t.preds <- b.label :: t.preds) (succs b));
  Hashtbl.iter (fun _ b -> b.preds <- List.rev b.preds) f.blocks

let reachable f =
  let seen = ref StrSet.empty in
  let rec go label =
    if not (StrSet.mem label !seen) then begin
      seen := StrSet.add label !seen;
      List.iter go (succs (block f label))
    end
  in
  go f.entry;
  !seen

let drop_unreachable f =
  let live = reachable f in
  let kept = Dynarray.create () in
  Dynarray.iter
    (fun label ->
      if StrSet.mem label live then Dynarray.add_last kept label
      else Hashtbl.remove f.blocks label)
    f.order;
  Dynarray.clear f.order;
  Dynarray.append f.order kept;
  iter_blocks f (fun b ->
      b.phis <-
        List.map
          (fun phi -> { phi with args = List.filter (fun a -> StrSet.mem a.pred live) phi.args })
          b.phis);
  recompute_preds f

(* Reverse post-order, which is the order every dataflow pass walks in. *)
let rpo f =
  let seen = ref StrSet.empty in
  let order = ref [] in
  let rec go label =
    if not (StrSet.mem label !seen) then begin
      seen := StrSet.add label !seen;
      List.iter go (succs (block f label));
      order := label :: !order
    end
  in
  go f.entry;
  !order

(* -- printing --------------------------------------------------------------- *)

let reg_name colours r =
  match IntMap.find_opt r colours with
  | Some colour -> Printf.sprintf "%%%d:%d" r colour
  | None -> Printf.sprintf "%%%d" r

let show_instr name instr =
  let joined rs = String.concat ", " (List.map name rs) in
  match instr with
  | Const c -> Printf.sprintf "%s = %Ld" (name c.dst) c.value
  | Str_const c -> Printf.sprintf "%s = &%s" (name c.dst) c.str_symbol
  | Move m -> Printf.sprintf "%s = %s" (name m.dst) (name m.src)
  | Bin b -> Printf.sprintf "%s = %s %s %s" (name b.dst) (name b.lhs) b.op (name b.rhs)
  | Cmp c -> Printf.sprintf "%s = %s %s %s" (name c.dst) (name c.lhs) c.op (name c.rhs)
  | Load l -> Printf.sprintf "%s = [%s + %d]" (name l.dst) (name l.base) l.offset
  | Store s -> Printf.sprintf "[%s + %d] = %s" (name s.base) s.offset (name s.src)
  | Load_slot l -> Printf.sprintf "%s = slot%d" (name l.dst) l.slot
  | Store_slot s -> Printf.sprintf "slot%d = %s" s.slot (name s.src)
  | Frame_addr fa -> Printf.sprintf "%s = frame" (name fa.dst)
  | Call c ->
      let call = Printf.sprintf "%s(%s)" c.callee (joined c.args) in
      (match c.dst with None -> call | Some d -> name d ^ " = " ^ call)
  | Jmp j -> "jmp " ^ j.target
  | Cbr c ->
      let test = if c.code <> "" then c.code ^ "?" else name c.cond ^ " ?" in
      Printf.sprintf "br %s %s : %s" test c.then_ c.else_
  | Ret r -> (match r.value with None -> "ret" | Some v -> "ret " ^ name v)
  | Machine m ->
      let operands = List.map name m.srcs in
      let operands =
        if m.symbol <> "" then operands @ [ m.symbol ]
        else if m.imm <> 0L || m.form = "const" then
          operands @ [ "#" ^ Int64.to_string m.imm ]
        else operands
      in
      let written =
        String.trim (m.form ^ " " ^ String.concat ", " operands)
      in
      (match m.m_dst with None -> written | Some d -> name d ^ " = " ^ written)

let show_phi name phi =
  let parts =
    List.map (fun a -> Printf.sprintf "%s: %s" a.pred (name a.arg)) phi.args
  in
  Printf.sprintf "%s = phi [%s]" (name phi.phi_dst) (String.concat ", " parts)

let show_func ?(alloc = unallocated) f =
  let name = reg_name alloc.colours in
  let out = ref [] in
  let put line = out := line :: !out in
  put
    (Printf.sprintf "fun %s(%s)  ; depth %d, %d slots" f.flabel
       (String.concat ", " (List.map name (Dynarray.to_list f.params)))
       f.depth f.nslots);
  List.iter
    (fun b ->
      let preds =
        if b.preds = [] then "" else "  ; preds: " ^ String.concat ", " b.preds
      in
      put (b.label ^ ":" ^ preds);
      List.iter (fun phi -> put ("    " ^ show_phi name phi)) b.phis;
      List.iter (fun i -> put ("    " ^ show_instr name i)) (instrs b))
    (walk f);
  String.concat "\n" (List.rev !out)

(* [as_text] widens every byte of a literal to the character of the same number,
   which is what a dump shows.  A literal is bytes and a dump is text, so the two
   have to be told apart somewhere; here is where. *)
let as_text literal =
  let b = Buffer.create (String.length literal) in
  String.iter (fun ch -> Buffer.add_utf_8_uchar b (Uchar.of_int (Char.code ch))) literal;
  Buffer.contents b

let show_module ?(allocs = StrMap.empty) m =
  let parts =
    List.map
      (fun f ->
        show_func ~alloc:(Option.value (StrMap.find_opt f.flabel allocs) ~default:unallocated) f)
      m.funcs
  in
  let parts =
    if m.strings = [] then parts
    else
      parts
      @ [
          String.concat "\n"
            (List.map
               (fun s -> Printf.sprintf "%s: \"%s\"" s.lit_symbol (as_text s.text))
               m.strings);
        ]
  in
  String.concat "\n\n" parts ^ "\n"
