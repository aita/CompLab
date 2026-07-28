(* The tools outside the compiler: the assembler, the linker, and the machine
   that runs what comes out.

   `martenmlc -run` and the golden tests need the same three steps -- compile,
   assemble, execute -- so they are written once, here, and neither goes
   through a shell.  What that buys is not portability so much as arguments:
   every one of these is an element of an argv, so a path with a space in it,
   or a file whose name starts with a dash, is not a quoting question.

   Nothing above this module knows it exists; it is the compiler's driver
   talking to the outside, not a pass. *)

exception Error of string

let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

type target = Riscv | Wasm

let target_of_string = function
  | "riscv" -> Riscv
  | "wasm" -> Wasm
  | other -> error "unknown target `%s'" other

(* What the compiler writes for each target: assembly, or WebAssembly text. *)
let extension = function Riscv -> ".s" | Wasm -> ".wat"

(* Where the runtime lives in this repository.  `-runtime` overrides it, which
   is what a build from somewhere else has to do. *)
let default_runtime = function
  | Riscv -> Filename.concat "runtime" "martenml_runtime.c"
  | Wasm -> Filename.concat "runtime" "martenml_runtime.wat"

(* wasm has no machine to hand the module to, only a host; this is the one this
   repository ships.  See runtime/martenml_wasm.mjs. *)
let default_host = Filename.concat "runtime" "martenml_wasm.mjs"

(* ------------------------------------------------------------- the programs *)

let executable_exists name =
  if String.contains name '/' then Sys.file_exists name
  else
    String.split_on_char ':' (try Sys.getenv "PATH" with Not_found -> "")
    |> List.exists (fun dir ->
           match Unix.access (Filename.concat dir name) [ Unix.X_OK ] with
           | () -> true
           | exception Unix.Unix_error _ -> false)

(* What each target needs installed, in the order it is used. *)
let tools = function
  | Riscv -> [ "riscv64-linux-gnu-gcc"; "qemu-riscv64" ]
  | Wasm -> [ "wat2wasm"; "node" ]

let missing_tool target =
  List.find_opt (fun tool -> not (executable_exists tool)) (tools target)

(* ------------------------------------------------------------- running them *)

type redirect =
  | Inherit
  | To_file of string
  | Onto_stdout (* for a child's stderr: the two streams interleave in ours *)

(* Unix.waitpid answers OCaml's own signal numbers, which are negative and
   nothing to do with the system's.  A shell reports 128 + the system's, and
   the golden files are written in a shell's terms, so this converts.  Only the
   signals a compiled program can actually die of are worth naming. *)
let system_signal n =
  let known =
    [
      (Sys.sigint, 2); (Sys.sigquit, 3); (Sys.sigill, 4); (Sys.sigabrt, 6);
      (Sys.sigbus, 7); (Sys.sigfpe, 8); (Sys.sigkill, 9); (Sys.sigsegv, 11);
      (Sys.sigpipe, 13); (Sys.sigterm, 15);
    ]
  in
  Option.value ~default:0 (List.assoc_opt n known)

(* Spawn [command] and wait for it.  The answer is the status a shell would
   report. *)
let run ?(stdout = Inherit) ?(stderr = Inherit) command args =
  (* Anything we have printed has to be out before the child writes. *)
  flush Stdlib.stdout;
  flush Stdlib.stderr;
  let opened = ref [] in
  let descriptor default = function
    | Inherit -> default
    | Onto_stdout -> Unix.stdout
    | To_file path ->
      let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644 in
      opened := fd :: !opened;
      fd
  in
  let out = descriptor Unix.stdout stdout in
  let err = descriptor Unix.stderr stderr in
  Fun.protect
    ~finally:(fun () -> List.iter Unix.close !opened)
    (fun () ->
      let pid =
        try Unix.create_process command (Array.of_list (command :: args)) Unix.stdin out err
        with Unix.Unix_error (e, _, _) -> error "%s: %s" command (Unix.error_message e)
      in
      match snd (Unix.waitpid [] pid) with
      | Unix.WEXITED status -> status
      | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + system_signal n)

(* ---------------------------------------------------------- scratch space *)

let rec remove_tree path =
  match Sys.is_directory path with
  | exception Sys_error _ -> ()
  | true ->
    Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
    Sys.rmdir path
  | false -> Sys.remove path

(* Everything an invocation builds is thrown away afterwards, however it ends. *)
let with_temp_dir prefix f =
  let dir = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

(* --------------------------------------------------- assembling and running *)

(* What the compiler wrote, turned into something that can be run.  Answers the
   path to it. *)
let assemble ~target ~runtime ~compiled ~dir =
  match target with
  | Riscv ->
    let program = Filename.concat dir "program" in
    if run "riscv64-linux-gnu-gcc" [ "-static"; "-o"; program; compiled; runtime ] <> 0 then
      error "riscv64-linux-gnu-gcc could not assemble and link %s" compiled;
    program
  | Wasm ->
    (* There is nothing to link: the runtime is already inside the module.
       Tail calls are not optional -- a loop written as tail recursion is a
       `return_call`, and without them it would grow the stack until it
       broke. *)
    let program = Filename.concat dir "program.wasm" in
    if run "wat2wasm" [ "--enable-tail-call"; "-o"; program; compiled ] <> 0 then
      error "wat2wasm rejected %s" compiled;
    program

let execute ~target ~host ?stdout ?stderr program =
  match target with
  | Riscv -> run ?stdout ?stderr "qemu-riscv64" [ program ]
  | Wasm ->
    (* `--stack-size` is in kilobytes and bounds how deep recursion that is not
       a tail call may go; V8's default leaves room for only a few thousand
       wasm frames.  runtime/martenml_wasm.mjs says more. *)
    run ?stdout ?stderr "node" [ "--no-warnings"; "--stack-size=6000"; host; program ]
