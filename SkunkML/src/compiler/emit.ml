(* Emission: a coloured control-flow graph to bytes.

   Everything hard has already happened.  The blocks are in an order, every
   operand is a real register or a frame slot, and the only decisions left are
   the frame and the jumps.

   The frame is as small as it can be: the callee-saved registers the colouring
   actually used, pushed on entry, then room for the spill slots.  There is no
   frame pointer -- nothing here allocates on the stack at run time, so `rsp` is
   constant through the body and a slot is `[rsp + 8i]`.

   A jump to the next block is not emitted at all, which is why the block order
   matters: it came from reverse postorder, so the common case is a fall
   through. *)

module M = Mach
module A = Asm

let label f (b : int) = Printf.sprintf "%s.b%d" f.M.name b

let prologue (f : M.func) =
  List.map (fun c -> M.Push (M.Reg (M.R c))) f.M.used_callee
  @ if f.M.nspill = 0 then [] else [ M.Alu ("sub", M.Reg (M.R M.rsp), M.Imm (8 * f.M.nspill)) ]

let epilogue (f : M.func) =
  (if f.M.nspill = 0 then [] else [ M.Alu ("add", M.Reg (M.R M.rsp), M.Imm (8 * f.M.nspill)) ])
  @ List.map (fun c -> M.Pop (M.Reg (M.R c))) (List.rev f.M.used_callee)

let func st (f : M.func) =
  A.label st f.M.name;
  let rec go = function
    | [] -> ()
    | (b : M.block) :: rest ->
        A.label st (label f b.M.id);
        if b.M.id = f.M.entry then List.iter (A.instr st) (prologue f);
        List.iter (A.instr st) (List.rev b.M.code);
        (match b.M.term with
        | M.Ret o ->
            if o <> M.Reg (M.R M.rax) then A.instr st (M.Mov (M.Reg (M.R M.rax), o));
            List.iter (A.instr st) (epilogue f);
            A.ret st
        | M.TailCall ->
            (* The code address has to be read before the frame goes away, and
               the scratch register is the one place it can wait: it is never
               allocated, and popping the callee-saved ones cannot touch it. *)
            A.instr st
              (M.Mov
                 ( M.Reg (M.R M.scratch),
                   M.Mem
                     { base = Some (M.R M.rdi); index = None; scale = 1; disp = 0; sym = None } ));
            List.iter (A.instr st) (epilogue f);
            A.jmp_indirect st (M.R M.scratch)
        | M.Halt where ->
            A.instr st (M.Lea (M.R M.rdi, M.Mem { base = None; index = None; scale = 1; disp = 0;
                                                  sym = Some (Statics.str where) }));
            A.instr st (M.Call "skunk_match_fail")
        | M.Jmp t -> ( match rest with n :: _ when n.M.id = t -> () | _ -> A.jmp st (label f t))
        | M.Jcc (c, t, e) -> (
            match rest with
            | n :: _ when n.M.id = t ->
                (* Invert rather than jump over a jump. *)
                let inv =
                  match c with
                  | "e" -> "ne"
                  | "ne" -> "e"
                  | "l" -> "ge"
                  | "ge" -> "l"
                  | "g" -> "le"
                  | "le" -> "g"
                  | c -> failwith ("emit: cannot invert " ^ c)
                in
                A.jcc st inv (label f e)
            | n :: _ when n.M.id = e -> A.jcc st c (label f t)
            | _ ->
                A.jcc st c (label f t);
                A.jmp st (label f e)));
        go rest
  in
  go f.M.blocks

(* What the whole program does: run each top-level binding in order, store its
   result in the global it names, and report it the way the interpreter reports
   it. *)
let program_entry st (p : M.prog) =
  A.label st "skunk_program";
  List.iter
    (fun (i : M.item) ->
      (match i.M.it_code with None -> () | Some code -> A.instr st (M.Call code));
      (match i.M.it_global with
      | None -> ()
      | Some g ->
          A.instr st
            (M.Mov
               ( M.Mem { base = None; index = None; scale = 1; disp = 0; sym = Some g },
                 M.Reg (M.R M.rax) )));
      match (i.M.it_label, i.M.it_code) with
      | None, _ -> ()
      | Some l, Some _ when i.M.it_show ->
          A.instr st (M.Mov (M.Reg (M.R M.rsi), M.Reg (M.R M.rax)));
          A.instr st
            (M.Lea
               ( M.R M.rdi,
                 M.Mem
                   { base = None; index = None; scale = 1; disp = 0; sym = Some (Statics.str l) } ));
          A.instr st (M.Call "skunk_report")
      | Some l, _ ->
          A.instr st
            (M.Lea
               ( M.R M.rdi,
                 M.Mem
                   { base = None; index = None; scale = 1; disp = 0; sym = Some (Statics.str l) } ));
          A.instr st (M.Call "skunk_report_label"))
    p.M.items;
  A.ret st

let program (p : M.prog) ~path =
  let text = A.create () and data = A.create () in
  List.iter (func text) p.M.funcs;
  program_entry text p;
  Stubs.text text;
  Rt.text text;
  Rt.data_start data;
  Statics.write data;
  Rt.data data;
  Rt.data_end data;
  Link.link ~path ~text ~data ~entry:"_start"
