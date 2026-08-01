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

(* A virtual register.  Registers are numbered from zero, so [no_reg] is a value
   no real one ever has, and "does it write anything" is answered with it. *)
type reg = int

let no_reg = -1

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
  mutable m_dst : reg;
  mutable srcs : reg list;
  imm : int64;
  symbol : string;
  effectful : bool;
}

type instr =
  | Const of { mutable dst : reg; value : int64 }
  | Str_const of { mutable dst : reg; str_symbol : string }
  | Move of { mutable dst : reg; mutable src : reg }
  | Bin of { mutable dst : reg; op : string; mutable lhs : reg; mutable rhs : reg }
  | Cmp of { mutable dst : reg; op : string; mutable lhs : reg; mutable rhs : reg }
  | Load of { mutable dst : reg; mutable base : reg; offset : int }
  | Store of { mutable base : reg; offset : int; mutable src : reg }
  (* Read a frame slot of this function — an escaping variable, or a spill. *)
  | Load_slot of { mutable dst : reg; mutable slot : int }
  | Store_slot of { mutable slot : int; mutable src : reg }
  (* The frame pointer itself, which is what a static link points at. *)
  | Frame_addr of { mutable dst : reg }
  | Call of { mutable dst : reg; callee : string; mutable args : reg list }
  | Jmp of { mutable target : string }
  | Cbr of {
      mutable cond : reg;
      mutable then_ : string;
      mutable else_ : string;
      (* After selection a branch may read the flags a comparison just set
         instead of testing a register, and then it reads no register at all. *)
      mutable code : string;
    }
  | Ret of { mutable value : reg }
  | Machine of mach

(* One edge of a phi.  They are a list and not a map because the order they were
   placed in is the order a dump has to print them in. *)
type phi_arg = { pred : string; mutable arg : reg }

type phi = { mutable phi_dst : reg; mutable args : phi_arg list }

(* -- what every instruction of either set can be asked ---------------------- *)

(* The register it writes, or [no_reg]. *)
let defs = function
  | Const c -> c.dst
  | Str_const c -> c.dst
  | Move m -> m.dst
  | Bin b -> b.dst
  | Cmp c -> c.dst
  | Load l -> l.dst
  | Load_slot l -> l.dst
  | Frame_addr f -> f.dst
  | Call c -> c.dst
  | Machine m -> m.m_dst
  | Store _ | Store_slot _ | Jmp _ | Cbr _ | Ret _ -> no_reg

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
  | Ret r -> if r.value = no_reg then [] else [ r.value ]
  | Const _ | Str_const _ | Load_slot _ | Frame_addr _ | Jmp _ -> []

(* Rewrite the registers it reads, in place. *)
let map_uses f = function
  | Move m -> m.src <- f m.src
  | Bin b ->
      b.lhs <- f b.lhs;
      b.rhs <- f b.rhs
  | Cmp c ->
      c.lhs <- f c.lhs;
      c.rhs <- f c.rhs
  | Load l -> l.base <- f l.base
  | Store s ->
      s.base <- f s.base;
      s.src <- f s.src
  | Store_slot s -> s.src <- f s.src
  | Call c -> c.args <- Util.map_in_order f c.args
  | Machine m -> m.srcs <- Util.map_in_order f m.srcs
  | Cbr c -> if c.code = "" then c.cond <- f c.cond
  | Ret r -> if r.value <> no_reg then r.value <- f r.value
  | Const _ | Str_const _ | Load_slot _ | Frame_addr _ | Jmp _ -> ()

let set_def instr r =
  match instr with
  | Const c -> c.dst <- r
  | Str_const c -> c.dst <- r
  | Move m -> m.dst <- r
  | Bin b -> b.dst <- r
  | Cmp c -> c.dst <- r
  | Load l -> l.dst <- r
  | Load_slot l -> l.dst <- r
  | Frame_addr f -> f.dst <- r
  | Call c -> c.dst <- r
  | Machine m -> m.m_dst <- r
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
  mutable colours : int IntMap.t;
  mutable spill_slots : int IntMap.t;
  mutable saved : int list;
}

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
    colours = IntMap.empty;
    spill_slots = IntMap.empty;
    saved = [];
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

(* [set_arg] keeps an argument where it was, and appends a new one at the end. *)
let set_arg phi pred r =
  match phi_arg phi pred with
  | Some a -> a.arg <- r
  | None -> phi.args <- phi.args @ [ { pred; arg = r } ]

let remove_arg phi pred =
  match phi_arg phi pred with
  | None -> None
  | Some a ->
      phi.args <- List.filter (fun other -> other.pred <> pred) phi.args;
      Some a.arg

let phi_preds phi = List.map (fun a -> a.pred) phi.args

(* -- rewiring --------------------------------------------------------------- *)

let rename_target instr old fresh =
  match instr with
  | Jmp j -> if j.target = old then j.target <- fresh
  | Cbr c ->
      if c.then_ = old then c.then_ <- fresh;
      if c.else_ = old then c.else_ <- fresh
  | _ -> ()

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
      List.iter
        (fun phi -> phi.args <- List.filter (fun a -> StrSet.mem a.pred live) phi.args)
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

let reg_name f r =
  match IntMap.find_opt r f.colours with
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
      if c.dst = no_reg then call else name c.dst ^ " = " ^ call
  | Jmp j -> "jmp " ^ j.target
  | Cbr c ->
      let test = if c.code <> "" then c.code ^ "?" else name c.cond ^ " ?" in
      Printf.sprintf "br %s %s : %s" test c.then_ c.else_
  | Ret r -> if r.value = no_reg then "ret" else "ret " ^ name r.value
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
      if m.m_dst = no_reg then written else name m.m_dst ^ " = " ^ written

let show_phi name phi =
  let parts =
    List.map (fun a -> Printf.sprintf "%s: %s" a.pred (name a.arg)) phi.args
  in
  Printf.sprintf "%s = phi [%s]" (name phi.phi_dst) (String.concat ", " parts)

let show_func f =
  let name = reg_name f in
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

let show_module m =
  let parts = List.map show_func m.funcs in
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
