(* Out of the compiler and into a file.

   What the module is, by the time it gets here, is a string.  So this file
   writes it out and hands it to LLVM's own command line, which parses it,
   verifies it, runs the pass pipeline, selects instructions, allocates
   registers and writes an object -- and then links it against the runtime.

   `clang` is the whole of the dependency.  It is the LLVM driver that accepts
   `.ll` on its input, and one invocation of it is what `opt` and `llc` would do
   in two: `-O2` is the pass pipeline, `-fno-pic -mcmodel=small` is the static
   relocation model that makes a global's address an immediate, and `-c` stops
   after the object.  Linking is the same program with `-nostdlib -static
   -no-pie`, because the runtime is freestanding and defines `_start` itself.

   Nothing here links against `libLLVM`, and nothing here knows an LLVM
   enumeration constant.  When something is wrong with the module, the message
   comes from LLVM's own parser and points into a file that is left on disk for
   reading. *)

let clang = "clang"

let quote = Filename.quote

(* A temporary that survives a failure, because the thing that failed is the
   text in it and the message that came out points at a line of it. *)
let write_temp prefix suffix contents =
  let path = Filename.temp_file prefix suffix in
  let ch = open_out_bin path in
  output_string ch contents;
  close_out ch;
  path

let run ~keep cmd =
  if Sys.command cmd <> 0 then begin
    flush stdout;
    (match keep with
    | Some path -> Printf.eprintf "skunkllvm: the module that failed is in %s\n" path
    | None -> ());
    Loc.fail ~where:"error" Loc.unknown "clang failed"
  end

(* `-fno-pic` is the static relocation model and `-mcmodel=small` the code
   model: together they are what make a global's address an immediate and a call
   a direct call, in an executable that is linked at a fixed address.  The
   module names no target triple -- it is meant to be readable and portable, not
   tied to the machine that wrote it -- so clang is told not to remark on
   supplying one. *)
let flags level =
  Printf.sprintf "-O%d -fno-pic -fno-pie -mcmodel=small -Wno-override-module" level

let stage ~ll ~out ~level ~mode =
  run ~keep:(Some ll)
    (Printf.sprintf "%s %s %s %s -o %s" clang (flags level) mode (quote ll) (quote out))

let object_file ~ll ~out ~level = stage ~ll ~out ~level ~mode:"-c"
let assembly ~ll ~out ~level = stage ~ll ~out ~level ~mode:"-S"
let optimised_ir ~ll ~out ~level = stage ~ll ~out ~level ~mode:"-S -emit-llvm"

(* The runtime travels inside the compiler as bytes and is written out beside
   the object, so what this needs on disk is one program. *)
let link ~path ~obj =
  let rt = write_temp "skunk_runtime" ".o" Runtime_obj.bytes in
  run ~keep:None
    (Printf.sprintf "%s -nostdlib -static -o %s %s %s" clang (quote path) (quote obj) (quote rt));
  Sys.remove rt

let executable ~ll ~path ~level =
  let obj = Filename.temp_file "skunk" ".o" in
  object_file ~ll ~out:obj ~level;
  link ~path ~obj;
  Sys.remove obj
