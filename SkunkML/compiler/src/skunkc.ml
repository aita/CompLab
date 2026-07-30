(* The compiler's command line.

   It shares everything up to Flat with the interpreter -- the same parser, the
   same inference, the same decision trees, the same closure conversion -- and
   starts where those left off.  By then the program has no modules, no
   patterns and no nested functions, so none of the back end has heard of
   them. *)

let usage () =
  print_string
    "usage: skunkc [options] file.sk\n\
    \n\
     options:\n\
    \      --dump-ssa    print the SSA of the program (not of the basis)\n\
    \      --dump-flat   print the A-normal form it was built from\n\
    \      --no-verify   skip the check that every use is dominated by its \
     definition\n\
    \  -h, --help        this\n"

let dump_ssa = ref false
let dump_flat = ref false
let verify = ref true

let parse ~file source =
  let lexbuf = Lexing.from_string source in
  lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = file };
  try Parser.program Lexer.token lexbuf with
  | Parser.Error ->
      let loc = Loc.of_lexing lexbuf.lex_start_p in
      Loc.syntax_error loc "unexpected %s"
        (match Lexing.lexeme lexbuf with "" -> "end of file" | s -> "`" ^ s ^ "`")

(* One compilation unit, as far as Flat.  The globals seen so far are threaded
   through because closure conversion has to know which names not to capture. *)
let to_flat env globals ~file ~source =
  Types.renumber ();
  let decs = parse ~file source in
  let env, items = Elab.program env decs in
  let items = Patmat.program items in
  (match Loc.take_warnings () with
  | [] -> ()
  | ws ->
      flush stdout;
      List.iter
        (fun (loc, msg) -> Printf.eprintf "%s: warning: %s\n" (Loc.to_string loc) msg)
        ws;
      flush stderr);
  let names =
    List.filter_map
      (fun (i : Core.item) -> if i.Core.iname = "" then None else Some i.Core.iname)
      items
  in
  let globals = globals @ names in
  (env, globals, Closure.program globals items)

let () =
  let file = ref None in
  let rec args = function
    | [] -> ()
    | "--dump-ssa" :: rest ->
        dump_ssa := true;
        args rest
    | "--dump-flat" :: rest ->
        dump_flat := true;
        args rest
    | "--no-verify" :: rest ->
        verify := false;
        args rest
    | ("-h" | "--help") :: _ ->
        usage ();
        exit 0
    | a :: rest ->
        if String.length a > 0 && a.[0] = '-' then begin
          Printf.eprintf "skunkc: unknown option %s\n" a;
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
          Printf.eprintf "skunkc: %s\n" m;
          exit 2
      in
      Types.reset ();
      Core.reset ();
      (try
         (* The basis first, so that its globals exist; only the program is
            dumped, because nobody asked to read the prelude. *)
         let env, globals, _ =
           to_flat (Basis.env ()) (Basis.globals ()) ~file:"<basis>"
             ~source:Basis.prelude
         in
         let _, globals, flat = to_flat env globals ~file:path ~source in
         if !dump_flat then print_string (Flat.program_to_string flat);
         let prog = Build.program globals flat in
         (if !verify then
            match Dom.check_prog prog with
            | [] -> ()
            | bad ->
                flush stdout;
                List.iter (fun m -> Printf.eprintf "skunkc: not in SSA: %s\n" m) bad;
                exit 1);
         if !dump_ssa then print_string (Ssa.prog_to_string prog);
         if (not !dump_ssa) && not !dump_flat then
           prerr_endline "skunkc: the back end stops at SSA for now; try --dump-ssa"
       with Loc.Error { loc; where; msg } ->
         flush stdout;
         Printf.eprintf "%s: %s: %s\n" (Loc.to_string loc) where msg;
         exit 1)
