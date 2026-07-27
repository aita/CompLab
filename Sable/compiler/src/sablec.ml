(* The compiler driver. *)

let output_file = ref "-"
let register_budget = ref Riscv.max_colors
let optimizer_rounds = ref 3
let dump_knf = ref false
let dump_closure = ref false
let dump_riscv = ref false
let dump_regalloc = ref false
let check_cfg = ref false
let check_knf = ref false

let options =
  [
    ("-o", Arg.Set_string output_file, "<file>  write assembly here (default: stdout)");
    ( "-nregs",
      Arg.Set_int register_budget,
      Printf.sprintf "<n>  allocate out of n registers (%d..%d, default %d)"
        Riscv.min_colors Riscv.max_colors Riscv.max_colors );
    ("-O", Arg.Set_int optimizer_rounds, "<n>  run the optimizer n times (default 3)");
    ("--dump-knf", Arg.Set dump_knf, "  print the K-normalized program");
    ("--dump-closure", Arg.Set dump_closure, "  print the closure-converted program");
    ("--dump-riscv", Arg.Set dump_riscv, "  print the RISC-V code before register allocation");
    ("--dump-regalloc", Arg.Set dump_regalloc, "  report on register allocation");
    ( "--check-knf",
      Arg.Set check_knf,
      "  fail if the normalized program is not in K-normal form" );
    ( "--check-cfg",
      Arg.Set check_cfg,
      "  fail if any function's control-flow graph has a cycle" );
  ]

let usage = "usage: sablec [options] <file.sbl>"

let parse_file path =
  let channel = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
      let lexbuf = Lexing.from_channel channel in
      lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = path };
      (* Two forms of one language; the extension says which. *)
      let brace_form = Filename.check_suffix path ".sbb" in
      try
        if brace_form then Brace_parser.program Brace_lexer.token lexbuf
        else Parser.program Lexer.token lexbuf
      with
      | Parser.Error | Brace_parser.Error ->
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
  let check ~unique stage e =
    if !check_knf then
      try Knormal.check ~unique e
      with Knormal.Broken msg -> failwith (Printf.sprintf "%s: after %s, %s" path stage msg)
  in
  let normalized = Knormal.normalize ast in
  check ~unique:false "normalization" normalized;
  let normalized = Alpha.rename normalized in
  check ~unique:true "alpha renaming" normalized;
  let normalized = Optim.optimize ~rounds:!optimizer_rounds normalized in
  check ~unique:true "the optimizer" normalized;
  if !dump_knf then Dump.knormal stderr 0 normalized;
  let converted = Closure.convert normalized in
  if !dump_closure then Dump.closure_program stderr converted;
  let functions = Selection.translate converted in
  List.iter
    (fun func ->
      (* The back end reads a cycle-free graph in two places: liveness is done
         in one pass, and the spill cost counts uses without weighting them by
         loop depth (doc/regalloc.md §10).  Nothing in the language can produce
         a loop inside a function -- a loop in the source is a recursive call,
         which leaves it -- and this is what says so out loud. *)
      if !check_cfg && not (Cfg.is_acyclic (Cfg.build func)) then
        failwith
          (Printf.sprintf "%s: the control-flow graph has a cycle" func.Riscv.name);
      Liveness.eliminate_dead_code func;
      if !dump_riscv then Riscv.print_func stderr func;
      let report = Regalloc.allocate func in
      if !dump_regalloc then Regalloc.print_report stderr func.Riscv.name report;
      Peephole.run func;
      (* Order the blocks so that terminators fall through where they can.
         After peephole, which is what threads the jumps and strands the
         blocks this drops. *)
      Cfg.relayout func)
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
    | Lexer.Error msg | Brace_lexer.Error msg | Failure msg ->
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
