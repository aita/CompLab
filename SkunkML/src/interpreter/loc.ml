(* Source positions, and the one exception every pass reports failure with. *)

type t = { file : string; line : int; col : int }

let unknown = { file = "?"; line = 0; col = 0 }

let of_lexing (p : Lexing.position) =
  { file = p.pos_fname; line = p.pos_lnum; col = p.pos_cnum - p.pos_bol + 1 }

let to_string l =
  if l.line = 0 then l.file else Printf.sprintf "%s:%d:%d" l.file l.line l.col

(* Every failure the user is meant to see is one of these.  [where] names the
   pass, so a message says which stage of the pipeline rejected the program. *)
exception Error of { loc : t; where : string; msg : string }

let fail ?(where = "error") loc fmt =
  Printf.ksprintf (fun msg -> raise (Error { loc; where; msg })) fmt

let syntax_error loc fmt = fail ~where:"syntax error" loc fmt
let type_error loc fmt = fail ~where:"type error" loc fmt
let module_error loc fmt = fail ~where:"signature error" loc fmt
let runtime_error loc fmt = fail ~where:"runtime error" loc fmt

(* A warning is not a failure: a non-exhaustive match is still a program, and
   it still runs -- until it reaches the case nobody wrote. *)
let warnings : (t * string) list ref = ref []

let warn loc fmt =
  Printf.ksprintf
    (fun msg -> warnings := (loc, msg) :: !warnings)
    fmt

let take_warnings () =
  let ws = List.rev !warnings in
  warnings := [];
  ws
