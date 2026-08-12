(* One error type for the whole interpreter, and the position formatting that
   goes with it.  Every phase raises [Error]; the driver catches it once. *)

exception Error of string

let where (p : Lexing.position) =
  Printf.sprintf "%s:%d:%d" p.pos_fname p.pos_lnum (p.pos_cnum - p.pos_bol + 1)

let at (p : Lexing.position) fmt =
  Printf.ksprintf (fun msg -> raise (Error (where p ^ ": " ^ msg))) fmt
