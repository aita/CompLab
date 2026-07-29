(* The runtime representation of a value.

   Memory is OCaml's to reclaim: a closure and the scope that holds it, which
   point at each other, go away like anything else because the collector traces
   rather than counts. What this module adds is a census of the objects the
   program has made, held through weak pointers so that counting them keeps
   nothing alive, which is all the `gc` module reports on. *)

type value =
  (* What `void` evaluates to. Every expression produces a value, so the ones
     that produce nothing produce this. *)
  | Unit
  | Bool of bool
  | Int of int64
  | Byte of int
  | Char of int
  | Float32 of float
  | Float64 of float
  | Text of string
  | Array of array_object
  (* A struct is a value type, so this object is cloned rather than shared
     wherever the value is copied. *)
  | Struct of struct_object
  | Pointer of pointer
  | Function of closure

(* An array's length is fixed when it is made, so an element keeps its place
   and a pointer into the run stays good. *)
and array_object = { element : Types.t; items : value array }
and struct_object = { structure : Types.structure; fields : value array }

(* A pointer names a slot inside an object. The object is what keeps the slot
   reachable. *)
and pointer =
  | Null
  | Cell_at of cell
  | Field_at of struct_object * int
  | Element_at of array_object * int

(* One variable's storage. Variables live in cells rather than in the scope's
   table so that a pointer to one survives the table growing. *)
and cell = { mutable held : value }

(* A block of named cells. Lookup walks outwards, which is how a closure body
   reaches the variables of the function that made it. *)
and environment = {
  parent : environment option;
  slots : (string, cell) Hashtbl.t;
}

(* A function value: the code, and the scope it was written in. A named function
   at the top level has no scope to carry. *)
and closure = { definition : Ast.func_def; captured : environment option }

(* -------------------------------------------------------------------------- *)
(* The census                                                                   *)
(* -------------------------------------------------------------------------- *)

module Census = struct
  (* Every object the program makes is entered here through a weak pointer.
     Nothing is ever read back out: the slots are only ever asked whether they
     are still full, which is what makes this a count of what is alive rather
     than something that keeps it alive. *)
  let slots = ref (Weak.create 4096)
  let used = ref 0
  let collections = ref 0

  (* Drops the entries the collector has emptied, keeping the rest in place. *)
  let compact () =
    let table = !slots in
    let kept = ref 0 in
    for index = 0 to !used - 1 do
      match Weak.get table index with
      | None -> ()
      | Some entry ->
          if !kept <> index then Weak.set table !kept (Some entry);
          incr kept
    done;
    for index = !kept to !used - 1 do
      Weak.set table index None
    done;
    used := !kept

  let collect () =
    Gc.full_major ();
    compact ();
    incr collections

  let grow () =
    let bigger = Weak.create (Weak.length !slots * 2) in
    Weak.blit !slots 0 bigger 0 !used;
    slots := bigger

  (* Collecting when the table fills is what keeps the census the size of what
     is alive rather than of everything ever made. *)
  let register entry =
    if !used >= Weak.length !slots then begin
      collect ();
      if !used * 4 >= Weak.length !slots * 3 then grow ()
    end;
    Weak.set !slots !used (Some entry);
    incr used

  (* How many objects survived the last collection, plus whatever has been made
     since. *)
  let live () = !used
end

let track entry =
  Census.register (Obj.repr entry);
  entry

(* -------------------------------------------------------------------------- *)
(* Making things                                                                *)
(* -------------------------------------------------------------------------- *)

let text contents = Text (track contents)

(* A literal makes a string every time it is evaluated, the way every other
   object is made where it is written. *)
let copied_text contents = text (String.sub contents 0 (String.length contents))
let array_object element items = Array (track { element; items })
let struct_object structure fields = Struct (track { structure; fields })
let cell held = track { held }
let environment parent = track { parent; slots = Hashtbl.create 8 }
let closure definition captured = Function (track { definition; captured })

let rec find_cell scope name =
  match Hashtbl.find_opt scope.slots name with
  | Some cell -> Some cell
  | None -> (
      match scope.parent with
      | Some parent -> find_cell parent name
      | None -> None)

let define scope name value = Hashtbl.replace scope.slots name (cell value)

(* -------------------------------------------------------------------------- *)
(* Working with values                                                          *)
(* -------------------------------------------------------------------------- *)

let load = function
  | Null -> invalid_arg "load"
  | Cell_at cell -> cell.held
  | Field_at (object_, index) -> object_.fields.(index)
  | Element_at (array, index) -> array.items.(index)

let store slot value =
  match slot with
  | Null -> invalid_arg "store"
  | Cell_at cell -> cell.held <- value
  | Field_at (object_, index) -> object_.fields.(index) <- value
  | Element_at (array, index) -> array.items.(index) <- value

(* Copies a value the way assignment does: structs field by field, all the way
   down, everything else by naming the same object again. *)
let rec copy_of value =
  match value with
  | Struct object_ ->
      struct_object object_.structure (Array.map copy_of object_.fields)
  | _ -> value

let same_pointer left right =
  match (left, right) with
  | Null, Null -> true
  | Cell_at left, Cell_at right -> left == right
  | Field_at (left, at), Field_at (right, to_) -> left == right && at = to_
  | Element_at (left, at), Element_at (right, to_) -> left == right && at = to_
  | _ -> false

(* Compares two values of the same type. Strings compare by content and structs
   field by field; arrays, closures and pointers compare by identity. *)
let rec equal_values left right =
  match (left, right) with
  | Unit, Unit -> true
  | Bool left, Bool right -> left = right
  | Int left, Int right -> Int64.equal left right
  | Byte left, Byte right | Char left, Char right -> left = right
  | Float32 left, Float32 right | Float64 left, Float64 right -> left = right
  | Text left, Text right -> String.equal left right
  | Array left, Array right -> left == right
  | Struct left, Struct right ->
      Array.length left.fields = Array.length right.fields
      &&
      let same = ref true in
      Array.iteri
        (fun index field ->
          if not (equal_values field right.fields.(index)) then same := false)
        left.fields;
      !same
  | Pointer left, Pointer right -> same_pointer left right
  | Function left, Function right -> left == right
  | _ -> false

(* The single-precision number nearest to this one. Every float32 arrives here,
   so that arithmetic on one is arithmetic on a float32. *)
let narrow value = Int32.float_of_bits (Int32.bits_of_float value)
