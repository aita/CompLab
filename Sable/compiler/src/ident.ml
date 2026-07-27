(* Identifiers and assembly labels.

   Source identifiers stay strings all the way to closure conversion; [fresh]
   makes them unique so that later passes can treat the name as the identity of
   a binding (see Alpha).  The "." separator cannot appear in a source name, so
   a generated name never collides with a user one. *)

type t = string

(* A label in the emitted assembly. *)
type label = string

module Map = Map.Make (String)
module Set = Set.Make (String)

let counter = ref 0

let fresh prefix =
  incr counter;
  Printf.sprintf "%s.%d" prefix !counter

(* The name as the programmer wrote it: [fresh] appends ".<n>" to keep bindings
   apart, which is noise in a diagnostic. *)
let display x =
  match String.rindex_opt x '.' with
  | Some i
    when i > 0
         && i < String.length x - 1
         && String.for_all
              (fun c -> c >= '0' && c <= '9')
              (String.sub x (i + 1) (String.length x - i - 1)) ->
    String.sub x 0 i
  | _ -> x

let fresh_label prefix =
  incr counter;
  Printf.sprintf ".L%s%d" prefix !counter

(* Source names may contain characters the assembler dislikes ('.' from
   [fresh], and the ML-style prime).  Mangle them into a flat symbol. *)
let to_label x =
  let b = Buffer.create (String.length x + 8) in
  Buffer.add_string b "sable_";
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> Buffer.add_char b c
      | '.' -> Buffer.add_char b '_'
      | '\'' -> Buffer.add_string b "_q"
      | _ -> Buffer.add_string b "_")
    x;
  Buffer.contents b

(* Externals live in the runtime and keep a predictable name. *)
let extern_label x = "sable_" ^ x
