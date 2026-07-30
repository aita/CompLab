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
    \      --dump-opt    print the SSA again, after optimisation\n\
    \      --dump-mach   print the amd64 graph after register allocation\n\
    \      --no-opt      do not optimise: skip folding, sccp, gvn and dce\n\
    \  -o FILE           write the executable here (the default is a.out)\n\
    \      --dump-encoding\n\
    \                    print the bytes for the tricky addressing modes\n\
    \  -h, --help        this\n"

let dump_ssa = ref false
let dump_dom = ref false
let dump_flat = ref false
let verify = ref true
let selftest_to = ref None
let dump_opt = ref false
let dump_mach = ref false
let optimise = ref true
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

(* Checking the assembler, the linker, the ELF writer and the runtime without
   the rest of the compiler.  `skunk_program` is written out by hand here, and
   the values it reports are static blocks with hand-written descriptors -- so
   what this exercises is exactly the layer the code generator will sit on:
   the allocator, `show`, structural equality, the string routines and the
   arithmetic that can fail.

   It is how a code generator gets off the ground.  If this runs and prints what
   the interpreter would print, then anything that goes wrong afterwards is
   selection or register allocation. *)
let selftest path =
  let open Rt in
  let text = Asm.create () and data = Asm.create () in
  Rt.data_start data;
  Asm.label text "skunk_program";
  let tagged n = imm ((2 * n) + 1) in
  (* The value first: computing it takes rdi, so the label goes in last. *)
  let report name value = value @ [ lea rdi (glob (lit name)); Cl "skunk_report" ] in
  (* A static block: the descriptor word goes down first, so the label -- which
     is the value -- is at offset 8 from it, exactly as on the heap. *)
  let block name desc fields =
    Asm.align data 8;
    Asm.dq_sym data desc;
    Asm.label data name;
    List.iter (function `Int n -> Asm.dq data ((2 * n) + 1) | `Sym s -> Asm.dq_sym data s) fields
  in
  (* The same program as tests/selftest.sk, so that the interpreter's output for
     it is the golden file for this one too. *)
  emit text
    ([ lea rdi (glob (lit "datatype tree = Leaf of int")); Cl "skunk_report_label" ]
    @ report "val i : int" [ mov (o rsi) (tagged 42) ]
    @ report "val j : int" [ mov (o rsi) (tagged (-7)) ]
    @ report "val s : string" [ lea rsi (glob "t_str") ]
    @ report "val u : unit" [ load rsi (glob "skunk_the_unit") ]
    @ report "val t : int * string" [ lea rsi (glob "t_tuple") ]
    @ report "val r : { age : int, name : string }" [ lea rsi (glob "t_record") ]
    @ report "val xs : int list" [ lea rsi (glob "t_list") ]
    @ report "val e : int list" [ lea rsi (glob "t_empty") ]
    @ report "val c : tree" [ lea rsi (glob "t_con") ]
    @ report "val f : 'a -> 'a" [ lea rsi (glob "t_clos") ]
    (* Now the routines: each result is reported, so the golden file pins down
       what they computed. *)
    @ report "val cat : string"
        [ lea rdi (glob "t_str"); lea rsi (glob "t_str"); Cl "skunk_concat"; movr rsi rax ]
    @ report "val sub : string"
        [
          lea rdi (glob "t_str");
          mov (o rsi) (tagged 2);
          mov (o rdx) (tagged 3);
          Cl "skunk_substring";
          movr rsi rax;
        ]
    @ report "val len : int" [ lea rdi (glob "t_str"); Cl "skunk_size"; movr rsi rax ]
    @ report "val str : string" [ mov (o rdi) (tagged (-1234)); Cl "skunk_int_to_string"; movr rsi rax ]
    @ report "val eq : bool"
        [ lea rdi (glob "t_list"); lea rsi (glob "t_list2"); Cl "skunk_equal"; movr rsi rax ]
    @ report "val ne : bool"
        [ lea rdi (glob "t_list"); lea rsi (glob "t_empty"); Cl "skunk_noteq"; movr rsi rax ]
    @ report "val lt : bool" [ mov (o rdi) (tagged 3); mov (o rsi) (tagged 10); Cl "skunk_lt"; movr rsi rax ]
    @ report "val gt : bool" [ lea rdi (glob "t_str"); lea rsi (glob "t_str2"); Cl "skunk_gt"; movr rsi rax ]
    @ report "val q : int"
        [ mov (o rdi) (tagged 17); mov (o rsi) (tagged 5); Cl "skunk_div"; movr rsi rax ]
    @ report "val m : int"
        [ mov (o rdi) (tagged (-17)); mov (o rsi) (tagged 5); Cl "skunk_mod"; movr rsi rax ]
    @ report "val arr : int array"
        [ mov (o rdi) (tagged 3); mov (o rsi) (tagged 9); Cl "skunk_array"; movr rsi rax ]
    @ report "val rr : int ref" [ mov (o rdi) (tagged 5); Cl "skunk_ref"; movr rsi rax ]
    (* And what a program that prints rather than reports looks like. *)
    @ [ lea rdi (glob "t_str2"); Cl "skunk_print" ]
    @ [ Ret ]);
  Rt.text text;
  descriptor data "t_pair_desc" ~kind:0 ~nfields:2 ~con:None ~labels:None ~list:0 ~tag:0;
  descriptor data "t_rec_desc" ~kind:0 ~nfields:2 ~con:None ~labels:(Some "t_rec_labels") ~list:0 ~tag:0;
  descriptor data "t_nil_desc" ~kind:1 ~nfields:0 ~con:(Some (lit "nil")) ~labels:None ~list:1 ~tag:0;
  descriptor data "t_cons_desc" ~kind:1 ~nfields:1 ~con:(Some (lit "::")) ~labels:None ~list:2 ~tag:0;
  descriptor data "t_con_desc" ~kind:1 ~nfields:1 ~con:(Some (lit "Leaf")) ~labels:None ~list:0 ~tag:0;
  descriptor data "t_clos_desc" ~kind:3 ~nfields:1 ~con:None ~labels:None ~list:0 ~tag:0;
  Asm.align data 8;
  Asm.label data "t_rec_labels";
  Asm.dq_sym data (lit "age");
  Asm.dq_sym data (lit "name");
  string_block data "t_str" "hi\tthere \"you\"\n";
  string_block data "t_str2" "zebra\n";
  (* [1, 2], twice, so that equality has two structurally equal values that are
     not the same pointer. *)
  block "t_empty" "t_nil_desc" [];
  List.iter
    (fun (suffix : string) ->
      block ("t_p2" ^ suffix) "t_pair_desc" [ `Int 2; `Sym "t_empty" ];
      block ("t_c2" ^ suffix) "t_cons_desc" [ `Sym ("t_p2" ^ suffix) ];
      block ("t_p1" ^ suffix) "t_pair_desc" [ `Int 1; `Sym ("t_c2" ^ suffix) ];
      block ("t_list" ^ suffix) "t_cons_desc" [ `Sym ("t_p1" ^ suffix) ])
    [ ""; "2" ];
  block "t_tuple" "t_pair_desc" [ `Int 42; `Sym "t_str2" ];
  block "t_record" "t_rec_desc" [ `Int 30; `Sym "t_str2" ];
  block "t_con" "t_con_desc" [ `Int 7 ];
  block "t_clos" "t_clos_desc" [ `Int 0 ];
  Rt.data data;
  Rt.data_end data;
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
    | "--no-opt" :: rest ->
        optimise := false;
        args rest
    | "-o" :: f :: rest ->
        out := Some f;
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
         if !dump_ssa then print_string (Ssa.prog_to_string prog);
         if !dump_dom then
           List.iter (fun f -> print_string (Dom.to_string f)) (Dom.all_funcs prog);
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
         Outofssa.program mach;
         Regalloc.program mach;
         if !dump_mach then print_string (Mach.to_string mach);
         Emit.program mach ~path:(Option.value !out ~default:"a.out")
       with Loc.Error { loc; where; msg } ->
         flush stdout;
         Printf.eprintf "%s: %s: %s\n" (Loc.to_string loc) where msg;
         exit 1)
