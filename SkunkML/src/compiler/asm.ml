(* The assembler: amd64 instructions to bytes.

   There is no `as` and no `cc` after this.  The compiler encodes the
   instructions itself, `link.ml` gives everything an address and patches the
   references, and `elf.ml` writes the file -- so what comes out is an
   executable, not a `.s` to hand to somebody else's toolchain.

   Encoding x86-64 is three tables in a trench coat, and this file is honest
   about which three:

     REX     one prefix byte carrying the operand size (W) and the fourth bit
             of each of the three register fields (R, X, B).  Registers r8 and
             up exist only because of it.
     ModRM   two bits saying how the second operand is addressed, and two
             three-bit register fields.  `mod = 11` means "a register", and
             everything else means memory.
     SIB     the extra byte a `base + index * scale` address needs, because
             ModRM has no room for a second register.

   Two escape hatches in that scheme cost most of the special cases below.
   `rm = 100` means "there is a SIB byte", so rsp and r12 -- which are numbered
   100 -- can never be a plain base.  And `mod = 00, rm = 101` means
   "rip-relative", so rbp and r13 can never be a base with no displacement; they
   get a zero one. *)

module M = Mach

type kind = Rel32 | Abs64

type reloc = { at : int; kind : kind; sym : string; addend : int }

type t = {
  buf : Buffer.t;
  mutable relocs : reloc list;
  syms : (string, int) Hashtbl.t; (* label -> offset in this section *)
}

let create () = { buf = Buffer.create 4096; relocs = []; syms = Hashtbl.create 64 }
let here st = Buffer.length st.buf
let byte st n = Buffer.add_char st.buf (Char.chr (n land 0xff))

let bytes st l = List.iter (byte st) l

let word32 st n =
  for i = 0 to 3 do
    byte st ((n asr (8 * i)) land 0xff)
  done

let word64 st n =
  for i = 0 to 7 do
    byte st ((n asr (8 * i)) land 0xff)
  done

let label st name =
  if Hashtbl.mem st.syms name then
    failwith ("asm: duplicate label " ^ name);
  Hashtbl.replace st.syms name (here st)

let align st n =
  while here st mod n <> 0 do
    byte st 0x90
  done

(* A reference to a symbol, patched by the linker.  [Rel32] is what a call, a
   jump and a rip-relative address all use: four bytes holding the distance
   from the *end* of the instruction, which is why the addend is negative for
   anything that has bytes after the field. *)
let reloc st kind sym addend =
  st.relocs <- { at = here st; kind; sym; addend } :: st.relocs;
  match kind with Rel32 -> word32 st 0 | Abs64 -> word64 st 0

let dq_sym st sym = reloc st Abs64 sym 0
let zeros st n = for _ = 1 to n do byte st 0 done
let dq st n = word64 st n
let ascii st s = String.iter (fun c -> Buffer.add_char st.buf c) s

(* ---- operands ------------------------------------------------------------ *)

let num = function
  | M.R i -> M.x86.(i)
  | M.V i -> failwith (Printf.sprintf "asm: virtual register v%d reached the assembler" i)

type rex = { w : bool; r : int; x : int; b : int }

let no_rex = { w = true; r = 0; x = 0; b = 0 }

let put_rex st rx =
  let v = 0x40 lor (if rx.w then 8 else 0) lor (rx.r lsl 2) lor (rx.x lsl 1) lor rx.b in
  (* The prefix is only needed when it says something, but with W always set on
     64-bit operands it always does. *)
  byte st v

(* Emit ModRM (and SIB, and the displacement) for "this register field, that
   operand", and return the REX bits the two of them need. *)
let modrm st ~reg ~(rm : M.operand) =
  let rf = reg land 7 and rbit = (reg lsr 3) land 1 in
  match rm with
  | M.Reg r ->
      let n = num r in
      (fun () -> byte st (0xc0 lor (rf lsl 3) lor (n land 7))), { no_rex with r = rbit; b = (n lsr 3) land 1 }
  | M.Imm _ -> failwith "asm: an immediate cannot be a ModRM operand"
  | M.Mem { base; index; scale; disp; sym } -> (
      match (base, index, sym) with
      (* rip-relative: the only way to name static data without a base. *)
      | None, None, Some s ->
          ( (fun () ->
              byte st (0x00 lor (rf lsl 3) lor 5);
              reloc st Rel32 s (disp - 4)),
            { no_rex with r = rbit } )
      | None, None, None -> failwith "asm: an address with nothing in it"
      | _ ->
          let bn = match base with Some b -> num b | None -> 5 (* no base *) in
          let xn = match index with Some i -> num i | None -> 4 (* no index *) in
          let need_sib = index <> None || bn land 7 = 4 in
          (* rbp and r13 as a base have no zero-displacement form. *)
          let md =
            if base = None then 0
            else if disp = 0 && bn land 7 <> 5 then 0
            else if disp >= -128 && disp <= 127 then 1
            else 2
          in
          ( (fun () ->
              if need_sib then begin
                byte st ((md lsl 6) lor (rf lsl 3) lor 4);
                let sc = match scale with 1 -> 0 | 2 -> 1 | 4 -> 2 | 8 -> 3 | _ -> 0 in
                byte st ((sc lsl 6) lor ((xn land 7) lsl 3) lor (bn land 7))
              end
              else byte st ((md lsl 6) lor (rf lsl 3) lor (bn land 7));
              if base = None then word32 st disp
              else if md = 1 then byte st disp
              else if md = 2 then word32 st disp),
            {
              no_rex with
              r = rbit;
              x = (xn lsr 3) land 1;
              b = (bn lsr 3) land 1;
            } ) )

(* The usual shape: one prefix, one opcode, one ModRM.  The REX has to go
   *before* the opcode but is only known after looking at the operand, so the
   ModRM is emitted through a thunk. *)
let op_rm st opcode ~reg ~rm =
  let put, rx = modrm st ~reg ~rm in
  put_rex st rx;
  bytes st opcode;
  put ()

let reg_of = function M.Reg r -> num r | _ -> failwith "asm: expected a register"

(* ---- instructions -------------------------------------------------------- *)

let alu_opcode = function
  | "add" -> (0x01, 0)
  | "sub" -> (0x29, 5)
  | "and" -> (0x21, 4)
  | "or" -> (0x09, 1)
  | "xor" -> (0x31, 6)
  | "cmp" -> (0x39, 7)
  | op -> failwith ("asm: no opcode for " ^ op)

let cc = function
  | "e" -> 0x4
  | "ne" -> 0x5
  | "l" -> 0xc
  | "ge" -> 0xd
  | "le" -> 0xe
  | "g" -> 0xf
  | "a" -> 0x7
  | "ae" -> 0x3
  | "b" -> 0x2
  | "be" -> 0x6
  | c -> failwith ("asm: no condition " ^ c)

let rec instr st (i : M.instr) =
  match i with
  | M.Comment _ -> ()
  | M.Syscall -> bytes st [ 0x0f; 0x05 ]
  | M.Cqo ->
      put_rex st no_rex;
      byte st 0x99
  | M.Mov (M.Reg d, M.Imm n) ->
      (* The short form takes imm32 sign-extended; anything wider needs the
         ten-byte movabs. *)
      let n' = num d in
      if n >= -0x80000000 && n <= 0x7fffffff then begin
        put_rex st { no_rex with b = (n' lsr 3) land 1 };
        byte st 0xc7;
        byte st (0xc0 lor (n' land 7));
        word32 st n
      end
      else begin
        put_rex st { no_rex with b = (n' lsr 3) land 1 };
        byte st (0xb8 lor (n' land 7));
        word64 st n
      end
  | M.Mov (M.Reg d, src) -> op_rm st [ 0x8b ] ~reg:(num d) ~rm:src
  | M.Mov (dst, M.Reg s) -> op_rm st [ 0x89 ] ~reg:(num s) ~rm:dst
  | M.Mov ((M.Mem { base = None; index = None; sym = Some _; _ } as dst), M.Imm _) ->
      (* rip-relative plus an immediate would need the distance measured from
         after the immediate, and the relocation says "from after the
         displacement".  Rather than carry a second addend convention, refuse
         it: the code generator loads the constant into a register first. *)
      ignore dst;
      failwith "asm: cannot store an immediate through a rip-relative address"
  | M.Mov (dst, M.Imm n) ->
      let put, rx = modrm st ~reg:0 ~rm:dst in
      put_rex st rx;
      byte st 0xc7;
      put ();
      word32 st n
  | M.Mov (_, _) -> failwith "asm: mov needs a register on one side"
  | M.Lea (d, src) -> op_rm st [ 0x8d ] ~reg:(num d) ~rm:src
  | M.Alu ("imul", M.Reg d, src) -> op_rm st [ 0x0f; 0xaf ] ~reg:(num d) ~rm:src
  | M.Alu (op, dst, M.Imm n) ->
      let _, ext = alu_opcode op in
      let put, rx = modrm st ~reg:ext ~rm:dst in
      put_rex st rx;
      if n >= -128 && n <= 127 then begin
        byte st 0x83;
        put ();
        byte st n
      end
      else begin
        byte st 0x81;
        put ();
        word32 st n
      end
  | M.Alu (op, dst, M.Reg s) ->
      let code, _ = alu_opcode op in
      op_rm st [ code ] ~reg:(num s) ~rm:dst
  | M.Alu (op, M.Reg d, src) ->
      let code, _ = alu_opcode op in
      op_rm st [ code + 2 ] ~reg:(num d) ~rm:src
  | M.Alu (op, _, _) -> failwith ("asm: " ^ op ^ " needs a register on one side")
  | M.Sar (dst, n) ->
      let put, rx = modrm st ~reg:7 ~rm:dst in
      put_rex st rx;
      byte st 0xc1;
      put ();
      byte st n
  | M.Shl (dst, n) ->
      let put, rx = modrm st ~reg:4 ~rm:dst in
      put_rex st rx;
      byte st 0xc1;
      put ();
      byte st n
  | M.Neg dst ->
      let put, rx = modrm st ~reg:3 ~rm:dst in
      put_rex st rx;
      byte st 0xf7;
      put ()
  | M.Cmp (a, b) -> instr st (M.Alu ("cmp", a, b))
  | M.Setcc (c, d) ->
      (* setcc is a byte operation, and a REX is needed to reach the low byte of
         rsi, rdi and friends at all. *)
      let n = num d in
      byte st (0x40 lor ((n lsr 3) land 1));
      bytes st [ 0x0f; 0x90 lor cc c ];
      byte st (0xc0 lor (n land 7))
  | M.Idiv r ->
      let put, rx = modrm st ~reg:7 ~rm:(M.Reg r) in
      put_rex st rx;
      byte st 0xf7;
      put ()
  | M.Call (sym, _) ->
      byte st 0xe8;
      reloc st Rel32 sym (-4)
  | M.CallReg (r, _) ->
      let put, rx = modrm st ~reg:2 ~rm:(M.Reg r) in
      put_rex st { rx with w = false };
      byte st 0xff;
      put ()
  | M.Push (M.Reg r) ->
      let n = num r in
      if n >= 8 then byte st 0x41;
      byte st (0x50 lor (n land 7))
  | M.Pop (M.Reg r) ->
      let n = num r in
      if n >= 8 then byte st 0x41;
      byte st (0x58 lor (n land 7))
  | M.Push _ | M.Pop _ -> failwith "asm: push and pop take a register"
  | M.Loadb (d, src) -> op_rm st [ 0x0f; 0xb6 ] ~reg:(num d) ~rm:src
  | M.Storeb (dst, s) ->
      (* A byte store has no REX.W -- the operand size is fixed -- but it does
         need the prefix at all, or sil, dil and the low bytes of r8 and up
         cannot be named. *)
      let put, rx = modrm st ~reg:(num s) ~rm:dst in
      put_rex st { rx with w = false };
      byte st 0x88;
      put ()
  | M.RepMovsb -> bytes st [ 0xf3; 0xa4 ]

(* Jumps are always the four-byte form: choosing the short one would need a
   second pass, and nothing here is short of space. *)
let jmp st sym =
  byte st 0xe9;
  reloc st Rel32 sym (-4)

let jcc st c sym =
  bytes st [ 0x0f; 0x80 lor cc c ];
  reloc st Rel32 sym (-4)

let ret st = byte st 0xc3

let jmp_indirect st (r : M.reg) =
  let put, rx = modrm st ~reg:4 ~rm:(M.Reg r) in
  put_rex st { rx with w = false };
  byte st 0xff;
  put ()

let contents st = Buffer.contents st.buf
