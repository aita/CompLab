(* Turn a file into an OCaml string, so that the compiled runtime travels inside
   the compiler.  Run as a script by dune; there is no executable to build. *)

let () =
  let path = Sys.argv.(1) in
  let ch = open_in_bin path in
  let n = in_channel_length ch in
  let s = really_input_string ch n in
  close_in ch;
  print_string "(* Generated from src/runtime/runtime.c.  Do not edit. *)\nlet bytes =\n  \"";
  String.iteri
    (fun i c ->
      if i > 0 && i mod 20 = 0 then print_string "\\\n   ";
      Printf.printf "\\x%02x" (Char.code c))
    s;
  print_string "\"\n"
