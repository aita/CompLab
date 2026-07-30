(* The command line.

   One program, one run.  Everything the passes do can be watched from here:
   `--dump-core` shows the typed A-normal form with its patterns still in it,
   `--dump-flat` shows the same program after pattern matching has become a
   decision tree and functions have become code blocks, and `--trace` shows the
   machine taking it apart one step at a time. *)

let usage () =
  print_string
    "usage: skunk [options] file.sk\n\
    \n\
     options:\n\
    \      --dump-core   print the typed Core -- A-normal form, patterns intact\n\
    \      --dump-flat   print the flat IR: code blocks, closures, join points\n\
    \      --trace       print every step the machine takes (to stderr)\n\
    \      --steps       report how many steps the machine took\n\
    \      --no-prelude  do not load the part of the basis written in SkunkML\n\
    \  -h, --help        this\n"

let parse ~file source =
  let lexbuf = Lexing.from_string source in
  lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = file };
  try Parser.program Lexer.token lexbuf with
  | Parser.Error ->
      let loc = Loc.of_lexing lexbuf.lex_start_p in
      Loc.syntax_error loc "unexpected %s"
        (match Lexing.lexeme lexbuf with "" -> "end of file" | s -> "`" ^ s ^ "`")

let dump_core = ref false
let dump_flat = ref false
let trace = ref false
let show_steps = ref false
let no_prelude = ref false

(* One compilation unit: parse, elaborate, compile the patterns, close the
   functions, then run each binding and report it.  The prelude and the user's
   program are two units over one machine, which is why the globals seen so far
   are threaded through: closure conversion has to know which names it must not
   capture. *)
let unit_of w env globals ~file ~source ~report =
  Types.renumber ();
  let decs = parse ~file source in
  let env, items = Elab.program env decs in
  let items = Patmat.program items in
  (* Warnings go to standard error so that they do not land in a program's
     output, and the two streams are flushed around them so that they land in
     the same place every time. *)
  (match Loc.take_warnings () with
  | [] -> ()
  | ws ->
      flush stdout;
      List.iter
        (fun (loc, msg) -> Printf.eprintf "%s: warning: %s\n" (Loc.to_string loc) msg)
        ws;
      flush stderr);
  let names = List.filter_map (fun (i : Core.item) ->
      if i.Core.iname = "" then None else Some i.Core.iname) items
  in
  if !dump_core && report then
    List.iter
      (fun (i : Core.item) ->
        match i.Core.ibody with
        | None -> ()
        | Some b ->
            Printf.printf "-- %s\n%s"
              (match i.Core.ilabel with Some l -> Lazy.force l | None -> i.Core.iname)
              (Core.block_to_string b))
      items;
  let prog = Closure.program (globals @ names) items in
  if !dump_flat && report then print_string (Flat.program_to_string prog);
  Machine.load w prog;
  List.iter
    (fun (i : Flat.item) ->
      let value =
        match i.Flat.ibody with
        | None -> None
        | Some b ->
            let v = Machine.run_block w b in
            if i.Flat.iname <> "" then Machine.define w i.Flat.iname v;
            Some v
      in
      if report then
        match (i.Flat.ilabel, value) with
        | None, _ -> ()
        | Some l, Some v when i.Flat.ishow ->
            Printf.printf "%s = %s\n" (Lazy.force l) (Machine.show w v)
        | Some l, _ -> print_endline (Lazy.force l))
    prog.Flat.items;
  (env, globals @ names)

let () =
  let file = ref None in
  let rec args = function
    | [] -> ()
    | "--dump-core" :: rest -> dump_core := true; args rest
    | "--dump-flat" :: rest -> dump_flat := true; args rest
    | "--trace" :: rest -> trace := true; args rest
    | "--steps" :: rest -> show_steps := true; args rest
    | "--no-prelude" :: rest -> no_prelude := true; args rest
    | ("-h" | "--help") :: _ -> usage (); exit 0
    | a :: rest ->
        if String.length a > 0 && a.[0] = '-' then begin
          Printf.eprintf "skunk: unknown option %s\n" a;
          exit 2
        end;
        file := Some a;
        args rest
  in
  args (List.tl (Array.to_list Sys.argv));
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
          Printf.eprintf "skunk: %s\n" m;
          exit 2
      in
      Types.reset ();
      Core.reset ();
      let w = Machine.create () in
      Basis.install w;
      (try
         let env, globals =
           if !no_prelude then (Basis.env (), Basis.globals ())
           else
             unit_of w (Basis.env ()) (Basis.globals ()) ~file:"<basis>"
               ~source:Basis.prelude ~report:false
         in
         (* The prelude is not what anyone asked to watch. *)
         w.Machine.trace <- !trace;
         (* The machine runs a program only after all of it has been checked:
            a program that does not typecheck should not have printed half of
            its output before saying so. *)
         ignore (unit_of w env globals ~file:path ~source ~report:true)
       with Loc.Error { loc; where; msg } ->
         flush stdout;
         Printf.eprintf "%s: %s: %s\n" (Loc.to_string loc) where msg;
         exit 1);
      if !show_steps then Printf.eprintf "%d steps, %d cells\n" w.Machine.steps w.Machine.next
