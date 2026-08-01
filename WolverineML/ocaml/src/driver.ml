(* The pipeline, and the toolchain around it.

   {v
   source ─lex─▶ tokens ─parse─▶ tree ─check─▶ typed tree ─lower─▶ CFG
          ─ssa─▶ SSA ─opt─▶ SSA ─select─▶ machine IR ─out of SSA─▶
          ─regalloc─▶ coloured ─emit─▶ ARMv8
   v}

   Assembling and linking is left to a cross [gcc], and running to [qemu-aarch64]
   when the machine underneath is not itself an ARM. *)

exception Toolchain of string

let stages = [ "tokens"; "ast"; "ir"; "ssa"; "opt"; "dag"; "mach"; "flat"; "ra"; "asm" ]

type options = { checks : bool; optimise : bool; max_regs : int (* 0 for the whole machine *) }

let default = { checks = true; optimise = true; max_regs = 0 }

let registers opts =
  if opts.max_regs = 0 then Registers.all else Registers.limited opts.max_regs

let to_ir source opts =
  let prog = Parser.parse source in
  Typecheck.check prog;
  (prog, Lower.lower prog { Lower.checks = opts.checks })

(* The pipeline, stopped as soon as [upto] has something to show.

   There is one of these and not two: a dump is the pipeline halted, not a second
   description of it that has to be kept in step. *)
let compile_module source opts upto =
  let _, m = to_ir source opts in
  let allocs = ref Ir.StrMap.empty in
  (* Each pass is named by what it leaves behind, so "as far as [upto]" is a walk
     down this list that stops after the pass of that name has run.  [ir] runs
     nothing: lowering has already left it. *)
  let passes =
    [ ("ir", fun () -> ());
      ("ssa", fun () -> Ssa.construct_module m);
      ("opt", fun () -> if opts.optimise then Opt.optimise m);
      ("dag", fun () -> List.iter Ssa.split_critical_edges m.Ir.funcs);
      ( "mach",
        fun () ->
          Select.select_module m;
          Mach.verify_module m );
      ("flat", fun () -> Outofssa.destruct_module m);
      ("asm", fun () -> allocs := Allocator.allocate_module m (registers opts))
    ]
  in
  let rec run = function
    | [] -> ()
    | (name, pass) :: rest ->
        pass ();
        if name <> upto then run rest
  in
  run passes;
  (m, !allocs)

let compile_to_asm ?(no_borrow = false) source opts =
  let m, allocs = compile_module source opts "asm" in
  Emit.emit_module ~no_borrow allocs m

let show_dags m =
  String.concat "\n\n"
    (List.map
       (fun (f : Ir.func) ->
         "fun " ^ f.flabel ^ "\n"
         ^ String.concat "\n"
             (List.map (fun (label, g) -> label ^ ":\n" ^ Dag.show g) (Select.graphs f)))
       m.Ir.funcs)
  ^ "\n"

(* Run the pipeline as far as [name], and show what it has by then. *)
let stage source name opts =
  match name with
  | "tokens" ->
      String.concat "\n"
        (List.map
           (fun (t : Lexer.token) ->
             Printf.sprintf "%s\t%s\t%s" (Diag.show_span t.at) (Lexer.name t.kind)
               (Ir.as_text t.text))
           (Lexer.lex source))
  | "ast" ->
      let prog = Parser.parse source in
      Typecheck.check prog;
      Astshow.show_program prog
  | _ -> (
      let m, allocs = compile_module source opts name in
      match name with
      | "dag" -> show_dags m
      | "asm" -> Emit.emit_module allocs m
      | _ -> Ir.show_module ~allocs m)

(* -- the toolchain ---------------------------------------------------------- *)

let read_file path =
  let channel = open_in_bin path in
  let text = really_input_string channel (in_channel_length channel) in
  close_in channel;
  text

let write_file path text =
  let channel = open_out_bin path in
  output_string channel text;
  close_out channel

let which name =
  let dirs = String.split_on_char ':' (try Sys.getenv "PATH" with Not_found -> "") in
  List.find_map
    (fun dir ->
      let path = Filename.concat dir name in
      if Sys.file_exists path && not (Sys.is_directory path) then Some path else None)
    dirs

let on_arm () =
  match which "uname" with
  | None -> false
  | Some _ -> (
      let channel = Unix.open_process_in "uname -m" in
      let machine = try input_line channel with End_of_file -> "" in
      ignore (Unix.close_process_in channel);
      match machine with "aarch64" | "arm64" -> true | _ -> false)

let cross_cc () =
  match Sys.getenv_opt "WOLV_CC" with
  | Some cc when cc <> "" -> cc
  | _ -> (
      let names =
        [ "aarch64-linux-gnu-gcc"; "aarch64-linux-gnu-cc"; "aarch64-none-linux-gnu-gcc" ]
      in
      match List.find_map which names with
      | Some found -> found
      | None -> (
          match if on_arm () then List.find_map which [ "cc"; "gcc" ] else None with
          | Some found -> found
          | None ->
              raise
                (Toolchain "no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC")))

let emulator () =
  if on_arm () then []
  else
    match List.find_map which [ "qemu-aarch64"; "qemu-aarch64-static" ] with
    | Some found -> [ found ]
    | None -> raise (Toolchain "no qemu-aarch64 found, and this machine is not an ARM")

type completed = { exit_code : int; stdout : string; stderr : string }

let temp_dir () =
  let path = Filename.temp_file "wolv" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let rec remove_dir path =
  if Sys.is_directory path then begin
    Array.iter (fun entry -> remove_dir (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path
  end
  else Sys.remove path

(* Both pipes go to files and the input comes from one, so that a program which
   fills a pipe cannot wait for a reader that is itself waiting. *)
let execute command args stdin_text =
  let dir = temp_dir () in
  let fin =
    match stdin_text with
    | None -> Unix.stdin
    | Some text ->
        let path = Filename.concat dir "in" in
        write_file path text;
        Unix.openfile path [ Unix.O_RDONLY ] 0o600
  in
  let out_path = Filename.concat dir "out" and err_path = Filename.concat dir "err" in
  let fout = Unix.openfile out_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let ferr = Unix.openfile err_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let pid = Unix.create_process command (Array.of_list (command :: args)) fin fout ferr in
  let _, status = Unix.waitpid [] pid in
  if fin <> Unix.stdin then Unix.close fin;
  Unix.close fout;
  Unix.close ferr;
  let stdout = read_file out_path and stderr = read_file err_path in
  remove_dir dir;
  let code = match status with Unix.WEXITED n -> n | _ -> 1 in
  { exit_code = code; stdout; stderr }

let build ?(no_borrow = false) source out opts =
  let asm = compile_to_asm ~no_borrow source opts in
  let cc = cross_cc () in
  let dir = temp_dir () in
  let assembly = Filename.concat dir "program.s" in
  write_file assembly asm;
  (* The run-time system travels inside the compiler and is unpacked to compile. *)
  let csource = Filename.concat dir "runtime.c" in
  write_file csource Runtime_source.text;
  let done_ = execute cc [ "-static"; "-O2"; "-o"; out; assembly; csource ] (Some "") in
  remove_dir dir;
  if done_.exit_code <> 0 then
    raise (Toolchain ("the assembler refused it:\n" ^ done_.stderr))

(* [stdin_text] of [None] hands the program the standard input this process was
   given. *)
let run ?(no_borrow = false) ?(stdin_text = None) source opts =
  let dir = temp_dir () in
  let binary = Filename.concat dir "program" in
  build ~no_borrow source binary opts;
  let prefix = emulator () in
  let done_ =
    match prefix with
    | [] -> execute binary [] stdin_text
    | command :: rest -> execute command (rest @ [ binary ]) stdin_text
  in
  remove_dir dir;
  done_
