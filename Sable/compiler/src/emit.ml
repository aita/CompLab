(* Emitting RV64 assembly.

   By the time a function reaches here every register is a machine register, so
   this pass only has to lay out the frame and print instructions.  The frame
   is fixed-size and addressed from sp, so there is no frame pointer:

       sp + F-8   saved return address, if the function calls anything
       sp + 0..   one slot per spilled value
       sp         (16-byte aligned, as the ABI requires)

   Two registers are held back from the allocator and used here: t5 to
   materialize offsets too large for an instruction's 12-bit immediate, and t6
   to carry the closure into a call. *)

let out = ref stdout
let line fmt = Printf.ksprintf (fun s -> Printf.fprintf !out "\t%s\n" s) fmt
let label name = Printf.fprintf !out "%s:\n" name
let comment text = Printf.fprintf !out "\t# %s\n" text

let reg = Riscv.register_names

let frame_size (func : Riscv.func) =
  let bytes = (func.Riscv.num_spill_slots * 8) + if Riscv.is_leaf func then 0 else 8 in
  (bytes + 15) / 16 * 16

(* sp = sp + n, for any n. *)
let adjust_stack n =
  if n <> 0 then
    if Riscv.fits_immediate n then line "addi sp, sp, %d" n
    else begin
      line "li %s, %d" reg.(Riscv.scratch) n;
      line "add sp, sp, %s" reg.(Riscv.scratch)
    end

(* A load or store whose offset may not fit in the instruction. *)
let memory op value base offset =
  if Riscv.fits_immediate offset then line "%s %s, %d(%s)" op reg.(value) offset reg.(base)
  else begin
    line "li %s, %d" reg.(Riscv.scratch) offset;
    line "add %s, %s, %s" reg.(Riscv.scratch) reg.(Riscv.scratch) reg.(base);
    line "%s %s, 0(%s)" op reg.(value) reg.(Riscv.scratch)
  end

let immediate_mnemonic = function
  | Riscv.Add -> "addi"
  | Riscv.And -> "andi"
  | Riscv.Or -> "ori"
  | Riscv.Xor -> "xori"
  | Riscv.Sll -> "slli"
  | Riscv.Sra -> "srai"
  | Riscv.Slt -> "slti"
  | op -> failwith (Riscv.string_of_binop op ^ " has no immediate form")

let instruction = function
  | Riscv.Li (d, n) -> line "li %s, %d" reg.(d) n
  | Riscv.La (d, l) -> line "la %s, %s" reg.(d) l
  | Riscv.Move (d, s) -> if d <> s then line "mv %s, %s" reg.(d) reg.(s)
  | Riscv.Arith (op, d, a, b) ->
    line "%s %s, %s, %s" (Riscv.string_of_binop op) reg.(d) reg.(a) reg.(b)
  | Riscv.Arith_imm (op, d, a, n) ->
    line "%s %s, %s, %d" (immediate_mnemonic op) reg.(d) reg.(a) n
  | Riscv.Load (d, base, off) -> memory "ld" d base off
  | Riscv.Store (src, base, off) -> memory "sd" src base off
  | Riscv.Call (Riscv.Direct l, _) -> line "call %s" l
  | Riscv.Call (Riscv.Indirect r, _) -> line "jalr %s" reg.(r)

let epilogue func size =
  if not (Riscv.is_leaf func) then memory "ld" Riscv.ra Riscv.sp (size - 8);
  adjust_stack size

(* [next] is the label laid out immediately after this block, so a branch to it
   can fall through instead of jumping. *)
let terminator func size next term =
  match term with
  | Riscv.Jump l -> if Some l <> next then line "j %s" l
  | Riscv.Branch (cond, a, b, if_true, if_false) ->
    if Some if_false = next then
      line "%s %s, %s, %s" (Riscv.string_of_cond cond) reg.(a) reg.(b) if_true
    else if Some if_true = next then
      (* Invert rather than emit two jumps. *)
      let inverse =
        match cond with Riscv.Eq -> Riscv.Ne | Riscv.Ne -> Riscv.Eq | Riscv.Lt -> Riscv.Ge | Riscv.Ge -> Riscv.Lt
      in
      line "%s %s, %s, %s" (Riscv.string_of_cond inverse) reg.(a) reg.(b) if_false
    else begin
      line "%s %s, %s, %s" (Riscv.string_of_cond cond) reg.(a) reg.(b) if_true;
      line "j %s" if_false
    end
  | Riscv.Return _ ->
    epilogue func size;
    line "ret"
  | Riscv.Tail_call (callee, _) ->
    epilogue func size;
    (* The frame is already gone, so this is a jump and the callee returns
       straight to our caller. *)
    (match callee with
     | Riscv.Direct l -> line "tail %s" l
     | Riscv.Indirect r -> line "jr %s" reg.(r))

let function_ func =
  let size = frame_size func in
  Printf.fprintf !out "\n\t.globl %s\n\t.p2align 2\n\t.type %s, @function\n" func.Riscv.name
    func.Riscv.name;
  let rec blocks = function
    | [] -> ()
    | (b : Riscv.block) :: rest ->
      let next = match rest with next :: _ -> Some next.Riscv.label | [] -> None in
      if b.Riscv.label = func.Riscv.name then begin
        label b.Riscv.label;
        if size > 0 then begin
          adjust_stack (-size);
          if not (Riscv.is_leaf func) then memory "sd" Riscv.ra Riscv.sp (size - 8)
        end
      end
      else label b.Riscv.label;
      List.iter instruction b.Riscv.body;
      terminator func size next b.Riscv.terminator;
      blocks rest
  in
  blocks func.Riscv.blocks;
  Printf.fprintf !out "\t.size %s, .-%s\n" func.Riscv.name func.Riscv.name

(* One read-only block per constant constructor, so that `Leaf` costs an
   address rather than an allocation. *)
let constant_constructors () =
  let decls = Datatype.all_decls () in
  let constants =
    List.concat_map
      (fun (d : Datatype.decl) -> List.filter Datatype.is_constant d.constrs)
      decls
  in
  if constants <> [] then begin
    Printf.fprintf !out "\n\t.section .rodata\n\t.p2align 3\n";
    List.iter
      (fun (c : Datatype.constr) ->
        comment (Printf.sprintf "%s.%s" c.owner c.cname);
        label (Datatype.const_label c);
        line ".quad %d" c.tag)
      constants
  end

let program channel functions =
  out := channel;
  Printf.fprintf !out "\t.text\n";
  List.iter function_ functions;
  constant_constructors ()
