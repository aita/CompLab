(* Command line driver: stoat [file.st]   (reads stdin when no file is given) *)

let usage =
  "usage: stoat [options] [file]\n\n\
   Runs a Stoat program.  With no file (or with '-') the program is read from\n\
   standard input.\n\n\
   options:\n\
  \  -h, --help   show this message\n"

let position_of lexbuf =
  let p = Lexing.lexeme_start_p lexbuf in
  Printf.sprintf "%s:%d:%d" p.pos_fname p.pos_lnum (p.pos_cnum - p.pos_bol + 1)

let fail msg =
  flush stdout;
  (* so that whatever the program printed comes first *)
  prerr_endline msg;
  exit 1

let parse lexbuf =
  try Parser.program Lexer.token lexbuf with
  | Lexer.Lex_error msg -> fail (Printf.sprintf "%s: %s" (position_of lexbuf) msg)
  | Ast.Syntax_error (pos, msg) ->
      fail
        (Printf.sprintf "%s:%d:%d: %s" pos.pos_fname pos.pos_lnum
           (pos.pos_cnum - pos.pos_bol + 1)
           msg)
  | Parser.Error ->
      fail (Printf.sprintf "%s: syntax error near %S" (position_of lexbuf) (Lexing.lexeme lexbuf))

let run_lexbuf name lexbuf =
  Lexing.set_filename lexbuf name;
  let program = parse lexbuf in
  let where () = Printf.sprintf "%s:%d" name !Interp.current_line in
  try Interp.run program with
  | Value.Stoat_error msg -> fail (Printf.sprintf "%s: runtime error: %s" (where ()) msg)
  | Interp.Return_exc _ -> fail (Printf.sprintf "%s: 'return' outside of a function" (where ()))
  | Interp.Break_exc -> fail (Printf.sprintf "%s: 'break' outside of a loop" (where ()))
  | Interp.Continue_exc -> fail (Printf.sprintf "%s: 'continue' outside of a loop" (where ()))
  | Stack_overflow -> fail (Printf.sprintf "%s: stack overflow (runaway recursion?)" (where ()))

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  match args with
  | [ ("-h" | "--help") ] -> print_string usage
  | [] | [ "-" ] -> run_lexbuf "<stdin>" (Lexing.from_channel stdin)
  | [ file ] ->
      let ic = try open_in_bin file with Sys_error msg -> fail msg in
      let lexbuf = Lexing.from_channel ic in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> run_lexbuf file lexbuf)
  | _ -> fail usage
