(* The compiler driver. *)

let output_file = ref "-"
let target_name = ref "riscv"
let runtime_file = ref ""
let host_file = ref ""
let run_program = ref false
let register_budget = ref Riscv.max_colors
let optimizer_rounds = ref 3
let inline_threshold = ref 12
let dump_knf = ref false
let dump_closure = ref false
let dump_linear = ref false
let dump_riscv = ref false
let dump_regalloc = ref false
let check_cfg = ref false
let check_knf = ref false
let check_linear = ref false

let options =
  [
    ("-o", Arg.Set_string output_file, "<file>  write the output here (default: stdout)");
    ( "-target",
      Arg.Symbol ([ "riscv"; "wasm" ], fun t -> target_name := t),
      "  emit RV64 assembly, or WebAssembly text (default: riscv)" );
    ("-run", Arg.Set run_program, "  assemble, link and run it instead of writing it out");
    ( "-runtime",
      Arg.Set_string runtime_file,
      "<file>  the runtime: linked in for riscv, copied into the module for \
       wasm (default: runtime/martenml_runtime.c or .wat)" );
    ( "-host",
      Arg.Set_string host_file,
      "<file.mjs>  what runs a wasm module under WASI (default: \
       runtime/martenml_wasm.mjs)" );
    ( "-nregs",
      Arg.Set_int register_budget,
      Printf.sprintf "<n>  allocate out of n registers (%d..%d, default %d)"
        Riscv.min_colors Riscv.max_colors Riscv.max_colors );
    ("-O", Arg.Set_int optimizer_rounds, "<n>  run the optimizer n times (default 3)");
    ( "-inline",
      Arg.Set_int inline_threshold,
      "<n>  inline functions of at most n nodes (0 disables, default 12)" );
    ("--dump-knf", Arg.Set dump_knf, "  print the K-normalized program");
    ("--dump-closure", Arg.Set dump_closure, "  print the closure-converted program");
    ("--dump-linear", Arg.Set dump_linear, "  print the linear IR: the control-flow graph before the machine");
    ("--dump-riscv", Arg.Set dump_riscv, "  print the RISC-V code before register allocation");
    ("--dump-regalloc", Arg.Set dump_regalloc, "  report on register allocation");
    ( "--check-knf",
      Arg.Set check_knf,
      "  fail if the normalized program is not in K-normal form" );
    ( "--check-linear",
      Arg.Set check_linear,
      "  fail if the linear IR is not well formed" );
    ( "--check-cfg",
      Arg.Set check_cfg,
      "  fail if any function's control-flow graph has a cycle" );
  ]

let usage = "usage: martenmlc [options] <file.mml>"

let parse_file path =
  let channel = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
      let lexbuf = Lexing.from_channel channel in
      lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = path };
      (* Two forms of one language; the extension says which. *)
      let brace_form = Filename.check_suffix path ".mmb" in
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

(* Closure-converted code into RV64 assembly: a control-flow graph, then a
   machine, then registers.  The other back end needs none of it. *)
let compile_riscv path converted channel =
  let linear = Linear.translate converted in
  if !check_linear then
    List.iter
      (fun f ->
        try Linear.check f
        with Linear.Broken msg -> failwith (Printf.sprintf "%s: %s" path msg))
      linear;
  if !dump_linear then Dump.linear stderr linear;
  let functions = Selection.translate linear in
  List.iter
    (fun func ->
      (* The back end reads a cycle-free graph in two places: liveness is done
         in one pass, and the spill cost counts uses without weighting them by
         loop depth (doc/regalloc.md §11).  Nothing in the language can produce
         a loop inside a function -- a loop in the source is a recursive call,
         which leaves it -- and this is what says so out loud. *)
      if !check_cfg && not (Cfg.is_acyclic (Riscv.cfg func)) then
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
      Riscv.relayout func)
    functions;
  Emit.program channel functions

(* The runtime and the WASI host: where they live in this repository unless
   told otherwise.  Saying so here rather than guessing from the executable's
   own path means the answer is a plain relative name a reader can check. *)
let runtime_path target =
  let path =
    if !runtime_file <> "" then !runtime_file else Toolchain.default_runtime target
  in
  if not (Sys.file_exists path) then
    failwith (Printf.sprintf "%s: no such file; say -runtime <file> to point at the runtime" path);
  path

let host_path () =
  let path = if !host_file <> "" then !host_file else Toolchain.default_host in
  if not (Sys.file_exists path) then
    failwith (Printf.sprintf "%s: no such file; say -host <file.mjs> to point at the WASI host" path);
  path

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
  let normalized = Inline.expand ~threshold:!inline_threshold normalized in
  check ~unique:true "inlining" normalized;
  let normalized = Optim.optimize ~rounds:!optimizer_rounds normalized in
  check ~unique:true "the optimizer" normalized;
  if !dump_knf then Dump.knormal stderr 0 normalized;
  let converted = Closure.convert normalized in
  if !dump_closure then Dump.closure_program stderr converted;
  let target = Toolchain.target_of_string !target_name in
  (* The two back ends part company here.  WebAssembly has structured control
     flow and unlimited locals, so the tree needs neither a control-flow graph
     nor a register allocator and goes straight out; see doc/wasm.md. *)
  let write_to file =
    let channel = if file = "-" then stdout else open_out file in
    (match target with
     | Toolchain.Wasm -> Wasm.program channel ~runtime:(runtime_path target) converted
     | Toolchain.Riscv -> compile_riscv path converted channel);
    flush channel;
    if file <> "-" then close_out channel
  in
  if not !run_program then write_to !output_file
  else begin
    (match Toolchain.missing_tool target with
     | Some tool -> failwith (Printf.sprintf "%s is required to run the program" tool)
     | None -> ());
    let host = match target with Toolchain.Wasm -> host_path () | Toolchain.Riscv -> "" in
    (* Exit after the scratch directory is gone, not from inside it. *)
    let status =
      Toolchain.with_temp_dir "martenml" (fun dir ->
          let compiled = Filename.concat dir ("program" ^ Toolchain.extension target) in
          write_to compiled;
          let program =
            Toolchain.assemble ~target ~runtime:(runtime_path target) ~compiled ~dir
          in
          Toolchain.execute ~target ~host program)
    in
    exit status
  end

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
      exit 1
    | Wasm.Error msg ->
      Printf.eprintf "%s\n" msg;
      exit 1
    | Toolchain.Error msg ->
      Printf.eprintf "%s\n" msg;
      exit 1)
  | _ ->
    Arg.usage options usage;
    exit 2
