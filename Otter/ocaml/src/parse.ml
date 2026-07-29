(* Drives the lexer and the generated parser, and turns their complaints into
   ours. Parsing stops at the first problem: a tree patched up by error recovery
   is not worth checking. *)

open Diagnostics

let offending lexbuf =
  match Lexing.lexeme lexbuf with
  | "" -> "the end of the file"
  | text -> Printf.sprintf "`%s`" text

(* Parses one file into a module. The caller supplies the text, so that the
   built-in modules can be parsed from memory. *)
let parse_module ~file ~text =
  let lexbuf = Lexing.from_string text in
  Lexing.set_filename lexbuf file;
  try Parser.program Lexer.token lexbuf with
  | Lexer.Error (span, message) -> raise (Compile_error (span, message))
  | Parser.Error ->
      raise
        (Compile_error
           ( Diagnostics.of_position (Lexing.lexeme_start_p lexbuf),
             Printf.sprintf "%s is not what was expected here"
               (offending lexbuf) ))
