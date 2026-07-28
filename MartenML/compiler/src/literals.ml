(* String literals.

   A string is a read-only block: one word of length, then the bytes.  Equal
   literals share one block, which is safe because strings are immutable. *)

let labels : (string, Ident.label) Hashtbl.t = Hashtbl.create 16
let order : (Ident.label * string) list ref = ref []

let reset () =
  Hashtbl.reset labels;
  order := []

let intern text =
  match Hashtbl.find_opt labels text with
  | Some label -> label
  | None ->
    let label = Printf.sprintf "martenml_str_%d" (Hashtbl.length labels) in
    Hashtbl.replace labels text label;
    order := (label, text) :: !order;
    label

let all () = List.rev !order
