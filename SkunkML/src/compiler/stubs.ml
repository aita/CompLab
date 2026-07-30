(* The basis, as static data.

   `print`, `not`, `!`, `Int`, `String` and `Array` are ordinary names in the
   program: `Int.toString` is a field read from a record held in a global, and
   then a call.  Nothing about them is special, which means the compiler does
   not have to special-case them -- but it does have to make them exist.

   All of it is static.  A closure that captures nothing is a two-word block, a
   structure is a record of those blocks, and a global's word can be filled in by
   the linker.  So the whole basis is data in the data section plus one short
   stub per function, and no start-up code runs to build it.

   A stub exists because the runtime routines take their arguments in registers
   while the language passes one argument, a tuple where it needs more.  Unpacking
   that tuple is all a stub does. *)

module A = Asm
open Rt

type shape = One | Pair | Triple

let toplevel = [ ("print", "skunk_print", One); ("not", "skunk_not", One); ("!", "skunk_deref", One) ]

let structures =
  [
    ( "Int",
      [
        ("toString", "skunk_int_to_string", One);
        ("abs", "skunk_abs", One);
        ("min", "skunk_min", Pair);
        ("max", "skunk_max", Pair);
        ("compare", "skunk_compare", Pair);
      ] );
    ( "String",
      [
        ("size", "skunk_size", One);
        ("compare", "skunk_compare", Pair);
        ("substring", "skunk_substring", Triple);
      ] );
    ( "Array",
      [
        ("array", "skunk_array", Pair);
        ("fromList", "skunk_array_from_list", One);
        ("toList", "skunk_array_to_list", One);
        ("length", "skunk_array_length", One);
        ("sub", "skunk_array_sub", Pair);
        ("update", "skunk_array_update", Triple);
      ] );
  ]

let stub_label name = "basis_" ^ Statics.mangle name

(* The closure arrives in rdi and the argument in rsi, and neither is wanted:
   what the routine wants is the argument, or its fields. *)
let stub_body shape target =
  (match shape with
  | One -> [ movr rdi rsi ]
  | Pair -> [ load rdi (at rsi); load rsi (at ~disp:8 rsi) ]
  | Triple -> [ load rdi (at rsi); load rdx (at ~disp:16 rsi); load rsi (at ~disp:8 rsi) ])
  @ [ Jump target ]

(* Interning the data has to happen before anything is selected, because
   selection asks for the global of a name and would otherwise create an empty
   one. *)
let register () =
  List.iter
    (fun (name, _, _) ->
      ignore (Statics.global name (Some (Statics.static_closure (stub_label name)))))
    toplevel;
  List.iter
    (fun (name, fields) ->
      (* Sorted, because that is what a record is here: a field is reached by
         offset, and the offset came from the sorted labels. *)
      let fields = Types.sort_fields (List.map (fun (f, _, _) -> (f, ())) fields) in
      let labels = List.map fst fields in
      let blocks =
        List.map (fun (f, ()) -> Statics.static_closure (stub_label (name ^ "." ^ f))) fields
      in
      ignore (Statics.global name (Some (Statics.static_record labels blocks))))
    structures

let text st =
  List.iter (fun (name, target, shape) ->
      A.label st (stub_label name);
      emit st (stub_body shape target))
    (toplevel
    @ List.concat_map
        (fun (s, fs) -> List.map (fun (f, t, sh) -> (s ^ "." ^ f, t, sh)) fs)
        structures)
