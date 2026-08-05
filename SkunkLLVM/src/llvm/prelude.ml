(* The basis, as static data and one small function each.

   `print`, `not`, `!`, `Int`, `String` and `Array` are ordinary names in the
   program: `Int.toString` is a field read from a record held in a global, and
   then a call.  Nothing about them is special, which means the rest of the
   compiler does not have to special-case them -- but it does have to make them
   exist.

   All of it is static.  A closure that captures nothing is a two-word block, a
   structure is a record of those blocks, and a global's word is an initializer.
   So the whole basis is data plus one short function per routine, and no
   start-up code runs to build it.

   The function exists because the runtime routines take their arguments one
   apiece while the language passes a single argument, a tuple where it needs
   more.  Unpacking that tuple is all it does. *)

module Lay = Layout

type shape = One | Pair | Triple

let toplevel =
  [ ("print", "skunk_print", One); ("not", "skunk_not", One); ("!", "skunk_deref", One) ]

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

let all =
  toplevel
  @ List.concat_map (fun (s, fs) -> List.map (fun (f, t, sh) -> (s ^ "." ^ f, t, sh)) fs) structures

let stub_name name = "@basis_" ^ Lay.mangle name

(* The unpacking function.  Its own closure is not wanted -- it captures
   nothing -- and neither is the tuple, once its fields are out. *)
let stub (t : Lay.t) name target shape =
  let sym = stub_name name in
  ignore
    (Ir.func t.Lay.ir ~name:sym ~linkage:Ir.internal ~ret:Ir.i64 ~params:Lay.code_params);
  Ir.position t.Lay.ir (Ir.append_block t.Lay.ir "entry");
  let arg = Lay.argument_param in
  let args =
    match shape with
    | One -> [ arg ]
    | Pair -> [ Lay.field t arg 0; Lay.field t arg 1 ]
    | Triple -> [ Lay.field t arg 0; Lay.field t arg 1; Lay.field t arg 2 ]
  in
  Ir.ret t.Lay.ir (Lay.call t target args);
  Ir.render t.Lay.ir;
  sym

(* The basis has to exist before anything is lowered, because lowering asks for
   the global of a name and would otherwise create an empty one. *)
let register (t : Lay.t) =
  let closure name target shape = Lay.static_closure t (stub t name target shape) in
  List.iter
    (fun (name, target, shape) -> ignore (Lay.global t name (Some (closure name target shape))))
    toplevel;
  List.iter
    (fun (name, fields) ->
      (* Sorted, because that is what a record is here: a field is reached by
         offset, and the offset came from the sorted labels. *)
      let fields = Types.sort_fields (List.map (fun (f, _, _) -> (f, ())) fields) in
      let labels = List.map fst fields in
      let blocks =
        List.map
          (fun (f, ()) ->
            let full = name ^ "." ^ f in
            let _, target, shape = List.find (fun (n, _, _) -> n = full) all in
            closure full target shape)
          fields
      in
      ignore (Lay.global t name (Some (Lay.static_record t labels blocks))))
    structures

(* A structure the front end declares and this back end does not provide.  That
   is what `Real` and `Math` are until there is a representation for a real, and
   it has to be caught where the name is looked up: it is a global like any
   other, so without this it would become a word nobody ever fills in and the
   program would call through it. *)
let unstubbed x =
  List.mem_assoc x Basis.structures
  && not (List.mem_assoc x structures)
  && not (List.exists (fun (n, _, _) -> n = x) toplevel)
