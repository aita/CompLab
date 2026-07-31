(* The compiler's command line.

   It shares everything up to Flat with the interpreter -- the same parser, the
   same inference, the same decision trees, the same closure conversion -- and
   starts where those left off.  By then the program has no modules, no
   patterns and no nested functions, so none of the back end has heard of
   them. *)

let usage () =
  print_string
    "usage: skunkc [options] file.sk\n\
    \n\
     options:\n\
    \      --dump-ssa    print the SSA of the program as it was built, before\n\
    \                    any pass (not of the basis)\n\
    \      --dump-dom    print the dominator tree and the dominance frontiers\n\
    \      --dump-flat   print the A-normal form it was built from\n\
    \      --no-verify   skip the check that every use is dominated by its \
     definition\n\
    \      --selftest F  write a hand-built ELF to F: checks the assembler,\n\
    \                    the linker and the ELF writer on their own\n\
    \      --dump-opt    print the SSA again, after optimisation\n\
    \      --dump-mach   print the amd64 graph after register allocation\n\
    \      --sched-pre[=N]\n\
    \                    schedule before register allocation too, watching\n\
    \                    register pressure.  Measured and it did not pay, so it\n\
    \                    is off; N is the pressure threshold (see 17章の6節)\n\
    \      --no-opt      do not optimise: skip inlining, folding, sccp, gvn,\n\
    \                    dce and instruction scheduling\n\
    \  -o FILE           write the executable here (the default is a.out)\n\
    \      --dynamic     link against libc.so.6 instead of writing a\n\
    \                    freestanding executable\n\
    \      --dump-encoding\n\
    \                    print the bytes for the tricky addressing modes\n\
    \  -h, --help        this\n"

let dump_ssa = ref false
let dump_dom = ref false
let dump_flat = ref false
let verify = ref true
let dump_opt = ref false
let dump_mach = ref false
let sched_pre = ref None
let optimise = ref true
let dynamic = ref false
let out = ref None

let parse ~file source =
  let lexbuf = Lexing.from_string source in
  lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = file };
  try Parser.program Lexer.token lexbuf with
  | Parser.Error ->
      let loc = Loc.of_lexing lexbuf.lex_start_p in
      Loc.syntax_error loc "unexpected %s"
        (match Lexing.lexeme lexbuf with "" -> "end of file" | s -> "`" ^ s ^ "`")

(* One compilation unit, as far as Flat.  The globals seen so far are threaded
   through because closure conversion has to know which names not to capture. *)
let to_flat env globals ~file ~source =
  Types.renumber ();
  let decs = parse ~file source in
  let env, items = Elab.program env decs in
  let items = Patmat.program items in
  (match Loc.take_warnings () with
  | [] -> ()
  | ws ->
      flush stdout;
      List.iter
        (fun (loc, msg) -> Printf.eprintf "%s: warning: %s\n" (Loc.to_string loc) msg)
        ws;
      flush stderr);
  let names =
    List.filter_map
      (fun (i : Core.item) -> if i.Core.iname = "" then None else Some i.Core.iname)
      items
  in
  let globals = globals @ names in
  (env, globals, Closure.program globals items)

(* The corner cases of the encoding, as bytes.  Every line here was checked
   against the system assembler once; the golden file is what keeps it checked.
   The list is not a program -- it is the addressing modes that have a special
   case in `asm.ml`, so that a wrong REX bit or a missing SIB byte shows up as a
   diff and not as a crash in a compiled program. *)
let encodings () =
  let module M = Mach in
  let r i = M.Reg (M.R i) in
  let mem ?base ?index ?(scale = 1) ?(disp = 0) ?sym () =
    M.Mem { base; index; scale; disp; sym }
  in
  (* Indices into [Mach.reg_name], not x86 numbers. *)
  let rax = 0 and rcx = 1 and rdx = 2 and rsi = 3 and rdi = 4 in
  let r8 = 5 and r11 = 7 and rbx = 9 and r12 = 10 and r13 = 11 and r15 = 13 in
  [
    M.Mov (r rax, M.Imm 1);
    M.Mov (r r15, M.Imm (-1));
    M.Mov (r rax, M.Imm 0x1_0000_0000);
    M.Mov (r rbx, r r8);
    M.Mov (r r8, r rbx);
    (* rbx has no REX; r12 as a base forces a SIB; r13 as a base forces a
       displacement byte even though it is zero. *)
    M.Mov (r rax, mem ~base:(M.R rbx) ());
    M.Mov (r rax, mem ~base:(M.R r12) ());
    M.Mov (r rax, mem ~base:(M.R r13) ());
    M.Mov (r rax, mem ~base:(M.R rbx) ~disp:8 ());
    M.Mov (r rax, mem ~base:(M.R rbx) ~disp:1000 ());
    M.Mov (r rax, mem ~base:(M.R rbx) ~index:(M.R r15) ~scale:8 ~disp:16 ());
    M.Mov (mem ~base:(M.R r12) ~disp:24 (), r rdi);
    M.Lea (M.R rsi, mem ~sym:"msg" ());
    M.Alu ("add", r rax, r rcx);
    M.Alu ("sub", r r11, M.Imm 7);
    M.Alu ("and", r rax, M.Imm 4096);
    M.Alu ("imul", r rdx, r rsi);
    (* Strength reduction's two shapes: an immediate multiplier, in both widths,
       and an address with a scale but no base. *)
    M.Alu ("imul", r rdx, M.Imm 7);
    M.Alu ("imul", r rdx, M.Imm 255);
    M.Lea (M.R rbx, mem ~index:(M.R rax) ~scale:2 ~disp:(-1) ());
    M.Sar (r rax, 1);
    M.Shl (r r13, 3);
    M.Neg (r rbx);
    M.Cmp (r rax, r r12);
    M.Setcc ("l", M.R rsi);
    M.Cqo;
    M.Idiv (M.R rcx);
    M.Push (r rbx);
    M.Pop (r r13);
    M.CallReg (M.R r11);
    M.Syscall;
  ]

let dump_encoding () =
  List.iter
    (fun i ->
      let st = Asm.create () in
      Asm.instr st i;
      let b = Asm.contents st in
      let hex = String.concat "" (List.init (String.length b) (fun k -> Printf.sprintf "%02x" (Char.code b.[k]))) in
      Printf.printf "%-24s %s\n" hex (Mach.instr_str i))
    (encodings ())

let () =
  let file = ref None in
  let rec args = function
    | [] -> ()
    | "--dump-ssa" :: rest ->
        dump_ssa := true;
        args rest
    | "--dump-dom" :: rest ->
        dump_dom := true;
        args rest
    | "--dump-flat" :: rest ->
        dump_flat := true;
        args rest
    | "--dump-opt" :: rest ->
        dump_opt := true;
        args rest
    | "--dump-mach" :: rest ->
        dump_mach := true;
        args rest
    | "--sched-pre" :: rest ->
        sched_pre := Some None;
        args rest
    | "--no-opt" :: rest ->
        optimise := false;
        args rest
    | "--dynamic" :: rest ->
        dynamic := true;
        args rest
    | "-o" :: f :: rest ->
        out := Some f;
        args rest
    | "--no-verify" :: rest ->
        verify := false;
        args rest
    | "--dump-encoding" :: _ ->
        dump_encoding ();
        exit 0
    | ("-h" | "--help") :: _ ->
        usage ();
        exit 0
    | a :: rest when String.length a > 12 && String.sub a 0 12 = "--sched-pre=" ->
        sched_pre := Some (int_of_string_opt (String.sub a 12 (String.length a - 12)));
        args rest
    | a :: rest ->
        if String.length a > 0 && a.[0] = '-' then begin
          Printf.eprintf "skunkc: unknown option %s\n" a;
          exit 2
        end;
        file := Some a;
        args rest
  in
  args (List.tl (Array.to_list Sys.argv));
  match !file with
  | None ->
      usage ();
      exit 2
  | Some path ->
      let source =
        try
          let ch = open_in_bin path in
          let n = in_channel_length ch in
          let s = really_input_string ch n in
          close_in ch;
          s
        with Sys_error m ->
          Printf.eprintf "skunkc: %s\n" m;
          exit 2
      in
      Types.reset ();
      Core.reset ();
      (try
         (* The basis first.  Its half that is written in SkunkML is compiled
            exactly like the program -- same parser, same inference, same
            decision trees, same back end -- and its top-level bindings run
            first, silently: nothing prints while the prelude is defining
            `map` and `foldl`. *)
         let env, globals, basis_flat =
           to_flat (Basis.env ()) (Basis.globals ()) ~file:"<basis>"
             ~source:Basis.prelude
         in
         let _, globals, flat = to_flat env globals ~file:path ~source in
         if !dump_flat then print_string (Flat.program_to_string flat);
         (* `--dump-ssa` and `--dump-dom` are the SSA the builder made out of
            what the front end wrote ([10章](../../doc/10-ssa.md)), so they have
            to be taken before inlining -- which happens on Flat, one pass
            earlier.  Building a second copy is the price, and only a dump pays
            it. *)
         let built = if !dump_ssa || !dump_dom then Some (Build.program globals flat) else None in
         (* Inlining sees both units at once: the file calls the basis, and it
            can rebind the basis's names, which is the question that decides
            whether a global still holds the function it was defined with. *)
         let basis_flat, flat =
           if !optimise then Inline.program basis_flat flat else (basis_flat, flat)
         in
         let basis = Build.program globals basis_flat in
         let prog = Build.program globals flat in
         let whole =
           {
             Ssa.funcs = basis.Ssa.funcs @ prog.Ssa.funcs;
             items =
               List.map (fun (i : Ssa.item) -> { i with Ssa.ilabel = None }) basis.Ssa.items
               @ prog.Ssa.items;
           }
         in
         (if !verify then
            match Dom.check_prog whole with
            | [] -> ()
            | bad ->
                flush stdout;
                List.iter (fun m -> Printf.eprintf "skunkc: not in SSA: %s\n" m) bad;
                exit 1);
         let shown = Option.value built ~default:prog in
         if !dump_ssa then print_string (Ssa.prog_to_string shown);
         if !dump_dom then
           List.iter (fun f -> print_string (Dom.to_string f)) (Dom.all_funcs shown);
         let whole = if !optimise then Loops.program whole else whole in
         if !optimise then begin
           Opt.program whole;
           (* Optimisation has to leave it in SSA: every use still dominated by
              its definition, every phi still with one argument per
              predecessor.  Checking again is cheap and catches a pass that
              moved a value somewhere it does not dominate. *)
           if !verify then
             match Dom.check_prog whole with
             | [] -> ()
             | bad ->
                 flush stdout;
                 List.iter (fun m -> Printf.eprintf "skunkc: optimisation broke SSA: %s\n" m) bad;
                 exit 1
         end;
         if !dump_opt then print_string (Ssa.prog_to_string prog);
         (* The back end.  Selection needs the basis to exist first, because a
            program that mentions `print` wants the global that holds it. *)
         Statics.reset ();
         Stubs.register ();
         let mach = Select.program whole in
         (match !sched_pre with
         | None -> Outofssa.program mach
         | Some threshold -> Outofssa.program ~sched_pre:threshold mach);
         Regalloc.program mach;
         if !optimise then Sched.program mach;
         if !dump_mach then print_string (Mach.to_string mach);
         Emit.program ~dynamic:!dynamic mach ~path:(Option.value !out ~default:"a.out")
       with Loc.Error { loc; where; msg } ->
         flush stdout;
         Printf.eprintf "%s: %s: %s\n" (Loc.to_string loc) where msg;
         exit 1)
