(* Source positions, and the one exception every pass raises. *)

(* A position in the source, counted from one. *)
type span = { line : int; col : int }

let show_span s = Printf.sprintf "%d:%d" s.line s.col

(* Which pass raised an error, so a test can ask for the one it means. *)
type kind = Lex | Parse | Type_check

(* A user-facing compile error, carrying where it happened. *)
exception Error of { kind : kind; at : span; msg : string }

let message = function
  | Error e -> e.msg
  | exn -> Printexc.to_string exn

(* [show] is what the command line prints: the position, then the message. *)
let show = function
  | Error e -> Printf.sprintf "%s: %s" (show_span e.at) e.msg
  | exn -> Printexc.to_string exn

let raise_at kind at msg = raise (Error { kind; at; msg })

let lex_error at fmt = Printf.ksprintf (raise_at Lex at) fmt
let parse_error at fmt = Printf.ksprintf (raise_at Parse at) fmt
let type_error at fmt = Printf.ksprintf (raise_at Type_check at) fmt
