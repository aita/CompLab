(* The type objects.

   Two types are the same when [equal] says so. Everything is compared by its
   shape except a struct, which is nominal: two declarations with identical
   fields are still different types, so a struct carries an identity of its
   own. *)

type t =
  | Void
  | Bool
  | Int
  | Byte
  | Char
  | Float32
  | Float64
  | String
  | Array of t
  | Pointer of t
  | Struct of structure
  | Function of t list * t
  (* The type of the `null` literal on its own. It converts to any pointer, and
     never appears in a declaration. *)
  | Null_pointer

and structure = {
  id : int;
  module_name : string;
  name : string;
  (* Filled in once every struct has a type, so that a field may name the
     struct it belongs to. *)
  mutable fields : (string * t) list;
  mutable complete : bool;
}

let next_id = ref 0

let declare_struct ~module_name ~name =
  incr next_id;
  { id = !next_id; module_name; name; fields = []; complete = false }

let qualified_name structure =
  Printf.sprintf "%s.%s" structure.module_name structure.name

let index_of structure name =
  let rec search index = function
    | [] -> -1
    | (field, _) :: rest ->
        if field = name then index else search (index + 1) rest
  in
  search 0 structure.fields

let field_at structure index = List.nth structure.fields index

(* Struct types stop the walk at their identity, so this terminates even where a
   struct reaches itself through a pointer. *)
let rec equal left right =
  match (left, right) with
  | Void, Void
  | Bool, Bool
  | Int, Int
  | Byte, Byte
  | Char, Char
  | Float32, Float32
  | Float64, Float64
  | String, String
  | Null_pointer, Null_pointer ->
      true
  | Array left, Array right | Pointer left, Pointer right -> equal left right
  | Struct left, Struct right -> left.id = right.id
  | ( Function (left_parameters, left_result),
      Function (right_parameters, right_result) ) ->
      List.length left_parameters = List.length right_parameters
      && List.for_all2 equal left_parameters right_parameters
      && equal left_result right_result
  | _ -> false

let is_integer = function Int | Byte | Char -> true | _ -> false
let is_floating = function Float32 | Float64 -> true | _ -> false
let is_numeric kind = is_integer kind || is_floating kind

(* The range a whole-number literal must fall in to be written as this type. *)
let range_of = function
  | Byte -> (0L, 255L)
  | Char -> (0L, 0x10FFFFL)
  | _ -> (Int64.min_int, Int64.max_int)

let rec describe = function
  | Void -> "void"
  | Bool -> "bool"
  | Int -> "int"
  | Byte -> "byte"
  | Char -> "char"
  | Float32 -> "float32"
  | Float64 -> "float64"
  | String -> "string"
  | Null_pointer -> "null"
  | Array element -> Printf.sprintf "array<%s>" (describe element)
  | Pointer element -> Printf.sprintf "*%s" (describe element)
  | Struct structure -> qualified_name structure
  | Function (parameters, result) ->
      Printf.sprintf "fun(%s) -> %s"
        (String.concat ", " (List.map describe parameters))
        (describe result)

(* Whether a value of [from] may be used where [target] is wanted. There are no
   implicit numeric conversions, so this is equality apart from `null`, which
   stands for any pointer. *)
let assignable ~from ~target =
  equal from target
  || match (from, target) with Null_pointer, Pointer _ -> true | _ -> false
