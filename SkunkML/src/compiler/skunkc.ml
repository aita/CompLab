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
    \      --dump-ssa    print the SSA of the program (not of the basis)\n\
    \      --dump-dom    print the dominator tree and the dominance frontiers\n\
    \      --dump-flat   print the A-normal form it was built from\n\
    \      --no-verify   skip the check that every use is dominated by its \
     definition\n\
    \      --selftest F  write a hand-built ELF to F: checks the assembler,\n\
    \                    the linker and the ELF writer on their own\n\
    \      --dump-encoding\n\
    \                    print the bytes for the tricky addressing modes\n\
    \  -h, --help        this\n"

let dump_ssa = ref false
let dump_dom = ref false
let dump_flat = ref false
let verify = ref true
let selftest_to = ref None

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

(* Checking the assembler, the linker and the ELF writer without the rest of
   the compiler.  The program is written out by hand: say hello, exit 0.  It is
   how a code generator gets off the ground -- if this runs, the three lowest
   layers are right, and anything that goes wrong afterwards is selection or
   register allocation. *)
let selftest path =
  let module M = Mach in
  let text = Asm.create () and data = Asm.create () in
  Asm.label data "msg";
  Asm.ascii data "hello from skunkc\n";
  Asm.label text "_start";
  let r n = M.Reg (M.R n) in
  (* write(1, msg, 18) *)
  List.iter (Asm.instr text)
    [
      M.Mov (r M.rax, M.Imm 1);
      M.Mov (r M.rdi, M.Imm 1);
      M.Lea (M.R M.rsi, M.Mem { base = None; index = None; scale = 1; disp = 0; sym = Some "msg" });
      M.Mov (r M.rdx, M.Imm 18);
      M.Syscall;
      (* exit(0) *)
      M.Mov (r M.rax, M.Imm 60);
      M.Alu ("xor", r M.rdi, r M.rdi);
      M.Syscall;
    ];
  Link.link ~path ~text ~data ~entry:"_start"

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
  let r8 = 5 and r11 = 7 and rbx = 8 and r12 = 9 and r13 = 10 and r15 = 12 in
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
    M.Sar (r rax, 1);
    M.Shl (r r13, 3);
    M.Neg (r rbx);
    M.Cmp (r rax, r r12);
    M.Setcc ("l", M.R rsi);
    M.Cqo;
    M.Idiv (M.R rcx);
    M.Push (r rbx);
    M.Pop (r r13);
    M.CallReg (M.R r11, None);
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
    | "--no-verify" :: rest ->
        verify := false;
        args rest
    | "--selftest" :: out :: rest ->
        selftest_to := Some out;
        args rest
    | "--dump-encoding" :: _ ->
        dump_encoding ();
        exit 0
    | ("-h" | "--help") :: _ ->
        usage ();
        exit 0
    | a :: rest ->
        if String.length a > 0 && a.[0] = '-' then begin
          Printf.eprintf "skunkc: unknown option %s\n" a;
          exit 2
        end;
        file := Some a;
        args rest
  in
  args (List.tl (Array.to_list Sys.argv));
  (match !selftest_to with
  | Some out ->
      selftest out;
      exit 0
  | None -> ());
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
         (* The basis first, so that its globals exist; only the program is
            dumped, because nobody asked to read the prelude. *)
         let env, globals, _ =
           to_flat (Basis.env ()) (Basis.globals ()) ~file:"<basis>"
             ~source:Basis.prelude
         in
         let _, globals, flat = to_flat env globals ~file:path ~source in
         if !dump_flat then print_string (Flat.program_to_string flat);
         let prog = Build.program globals flat in
         (if !verify then
            match Dom.check_prog prog with
            | [] -> ()
            | bad ->
                flush stdout;
                List.iter (fun m -> Printf.eprintf "skunkc: not in SSA: %s\n" m) bad;
                exit 1);
         if !dump_ssa then print_string (Ssa.prog_to_string prog);
         if !dump_dom then
           List.iter (fun f -> print_string (Dom.to_string f)) (Dom.all_funcs prog);
         if (not !dump_ssa) && (not !dump_dom) && not !dump_flat then
           prerr_endline "skunkc: the back end stops at SSA for now; try --dump-ssa"
       with Loc.Error { loc; where; msg } ->
         flush stdout;
         Printf.eprintf "%s: %s: %s\n" (Loc.to_string loc) where msg;
         exit 1)
