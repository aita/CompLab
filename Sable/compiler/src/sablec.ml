(* The compiler driver. *)

let output_file = ref "-"
let register_budget = ref Riscv.max_colors
let optimizer_rounds = ref 3
let dump_anf = ref false
let dump_closure = ref false
let dump_riscv = ref false
let dump_regalloc = ref false

let options =
  [
    ("-o", Arg.Set_string output_file, "<file>  write assembly here (default: stdout)");
    ( "-nregs",
      Arg.Set_int register_budget,
      Printf.sprintf "<n>  allocate out of n registers (%d..%d, default %d)"
        Riscv.min_colors Riscv.max_colors Riscv.max_colors );
    ("-O", Arg.Set_int optimizer_rounds, "<n>  run the optimizer n times (default 3)");
    ("--dump-anf", Arg.Set dump_anf, "  print the A-normalized program");
    ("--dump-closure", Arg.Set dump_closure, "  print the closure-converted program");
    ("--dump-riscv", Arg.Set dump_riscv, "  print the RISC-V code before register allocation");
    ("--dump-regalloc", Arg.Set dump_regalloc, "  report on register allocation");
  ]

let usage = "usage: sablec [options] <file.sbl>"

let parse_file path =
  let channel = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
      let lexbuf = Lexing.from_channel channel in
      lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = path };
      try Parser.program Lexer.token lexbuf with
      | Parser.Error ->
        let p = Lexing.lexeme_start_p lexbuf in
        failwith
          (Printf.sprintf "%s:%d:%d: syntax error at `%s'" p.pos_fname p.pos_lnum
             (p.pos_cnum - p.pos_bol)
             (Lexing.lexeme lexbuf)))

let compile path =
  Riscv.configure !register_budget;
  let ast = parse_file path in
  let ast = Modules.resolve ast in
  let ast = Typing.check ast in
  let ast = Match_compile.compile ast in
  let normalized = Alpha.rename (Anf.normalize ast) in
  let normalized = Optim.optimize ~rounds:!optimizer_rounds normalized in
  if !dump_anf then Dump.anf stderr 0 normalized;
  let converted = Closure.convert normalized in
  if !dump_closure then Dump.closure_program stderr converted;
  let functions = Selection.translate converted in
  List.iter
    (fun func ->
      Liveness.eliminate_dead_code func;
      if !dump_riscv then Riscv.print_func stderr func;
      let report = Regalloc.allocate func in
      if !dump_regalloc then Regalloc.print_report stderr func.Riscv.name report;
      Peephole.run func)
    functions;
  let channel = if !output_file = "-" then stdout else open_out !output_file in
  Emit.program channel functions;
  flush channel;
  if !output_file <> "-" then close_out channel

let () =
  let inputs = ref [] in
  Arg.parse options (fun arg -> inputs := arg :: !inputs) usage;
  match !inputs with
  | [ path ] -> (
    try compile path with
    | Lexer.Error msg | Failure msg ->
      Printf.eprintf "%s\n" msg;
      exit 1
    | Typing.Error msg ->
      Printf.eprintf "%s\n" msg;
      exit 1
    | Datatype.Error msg ->
      Printf.eprintf "%s\n" msg;
      exit 1
    | Modules.Error msg ->
      Printf.eprintf "%s\n" msg;
      exit 1
    | Closure.Error msg ->
      Printf.eprintf "%s\n" msg;
      exit 1
    | Selection.Error msg ->
      Printf.eprintf "%s\n" msg;
      exit 1)
  | _ ->
    Arg.usage options usage;
    exit 2
