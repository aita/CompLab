(* Turn a file into an OCaml string, so that the compiler carries its run-time
   system inside itself and needs nothing on disk beside the binary. *)

let () =
  let path = Sys.argv.(1) in
  let channel = open_in_bin path in
  let text = really_input_string channel (in_channel_length channel) in
  close_in channel;
  Printf.printf "(* Generated from %s.  Do not edit. *)\n\nlet text = %S\n"
    (Filename.basename path) text
