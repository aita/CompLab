(* Source positions, and the two kinds of error. *)

(* Where something is in a source file. Columns are counted in bytes, which is
   what the lexer hands us and what an editor jumping to a position wants. *)
type position = { line : int; column : int }
type span = { file : string; start : position }

let of_position (position : Lexing.position) =
  {
    file = position.pos_fname;
    start =
      {
        line = position.pos_lnum;
        column = position.pos_cnum - position.pos_bol + 1;
      };
  }

let describe span =
  if span.file = "" then "<unknown>"
  else if span.start.line = 0 then span.file
  else Printf.sprintf "%s:%d:%d" span.file span.start.line span.start.column

(* A complaint about the program text: a syntax error, an unresolved name, a
   type mismatch. Everything the front end rejects arrives as one of these. *)
exception Compile_error of span * string

(* A fault while the program runs: a division by zero, an index out of range, a
   null dereference. The language checks these rather than letting them
   through. *)
exception Runtime_error of span * string

let report span message = Printf.sprintf "%s: %s" (describe span) message

let compile_error span format =
  Printf.ksprintf (fun message -> raise (Compile_error (span, message))) format

let runtime_error span format =
  Printf.ksprintf (fun message -> raise (Runtime_error (span, message))) format
