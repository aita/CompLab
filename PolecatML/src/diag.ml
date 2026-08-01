(* Where something is in the source, and how a failure says so.

   Every pass that can reject a program raises [Error], and only the driver
   catches it.  A position of [nowhere] means "this failure is about the program
   as a whole", and the message is printed without a line number. *)

type pos = { line : int; col : int }

let nowhere = { line = 0; col = 0 }

exception Error of pos * string

(* [error pos "..."] is a printf: the passes below read better when the message
   is built where it is raised. *)
let error pos fmt = Printf.ksprintf (fun msg -> raise (Error (pos, msg))) fmt

let show_pos pos = Printf.sprintf "%d:%d" pos.line pos.col

let to_string ~file (pos, msg) =
  if pos.line = 0 then Printf.sprintf "%s: %s" file msg
  else Printf.sprintf "%s:%d:%d: %s" file pos.line pos.col msg
