(* Source positions, and the one exception every system reports errors with. *)

type t = { file : string; line : int; col : int }

let unknown = { file = "?"; line = 0; col = 0 }

let of_lexing (p : Lexing.position) =
  { file = p.pos_fname; line = p.pos_lnum; col = p.pos_cnum - p.pos_bol + 1 }

let to_string l =
  if l.line = 0 then l.file else Printf.sprintf "%s:%d:%d" l.file l.line l.col

(* Every failure the user is meant to see -- a syntax error, a type error, a
   verification condition the solver would not discharge, a runtime fault --
   is one of these.  [where] is the phase, so that a message says which of the
   passes rejected the program. *)
exception Error of { loc : t; where : string; msg : string }

let fail ?(where = "error") loc fmt =
  Printf.ksprintf (fun msg -> raise (Error { loc; where; msg })) fmt

let type_error loc fmt = fail ~where:"type error" loc fmt
let syntax_error loc fmt = fail ~where:"syntax error" loc fmt
let runtime_error loc fmt = fail ~where:"runtime error" loc fmt
