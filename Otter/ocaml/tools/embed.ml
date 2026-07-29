(* Turns the built-in modules into an OCaml table, so that the interpreter
   carries them and `import io;` needs no file beside the program.

       embed modules/io.otter modules/str.otter ... > builtin_modules.ml

   The contents go in verbatim as a quoted string literal, so the one sequence
   that would end it early has to be absent. *)

let delimiter = "otter"

let read path =
  let channel = open_in_bin path in
  let text = really_input_string channel (in_channel_length channel) in
  close_in channel;
  text

let contains haystack needle =
  let limit = String.length haystack - String.length needle in
  let rec search index =
    index <= limit
    && (String.sub haystack index (String.length needle) = needle
       || search (index + 1))
  in
  search 0

let emit path =
  let name = Filename.remove_extension (Filename.basename path) in
  let text = read path in
  let closing = "|" ^ delimiter ^ "}" in
  if contains text closing then begin
    prerr_endline
      (path ^ " contains " ^ closing ^ ", which would end the string");
    exit 1
  end;
  Printf.printf "    (%S, {%s|%s|%s});\n" name delimiter text delimiter

let () =
  print_string
    "(* Generated from ocaml/modules by dune. Do not edit.\n\n\
    \   The built-in modules are ordinary Otter source, kept as ordinary files\n\
    \   and embedded here at build time. *)\n\n\
     let sources =\n\
    \  [\n";
  List.iter emit (List.tl (Array.to_list Sys.argv));
  print_string "  ]\n"
