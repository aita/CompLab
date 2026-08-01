(* The host functions, and the modules the implementation provides. *)

open Diagnostics
open Value

let text_of = function Text contents -> contents | _ -> invalid_arg "text_of"
let int_of = function Int value -> value | _ -> invalid_arg "int_of"
let float_of = function Float64 value -> value | _ -> invalid_arg "float_of"

(* The utf-8 of one code point. *)
let utf8_of code =
  let buffer = Buffer.create 4 in
  let byte value = Buffer.add_char buffer (Char.chr (value land 0xFF)) in
  if code < 0x80 then byte code
  else if code < 0x800 then begin
    byte (0xC0 lor (code lsr 6));
    byte (0x80 lor (code land 0x3F))
  end
  else if code < 0x10000 then begin
    byte (0xE0 lor (code lsr 12));
    byte (0x80 lor ((code lsr 6) land 0x3F));
    byte (0x80 lor (code land 0x3F))
  end
  else begin
    byte (0xF0 lor (code lsr 18));
    byte (0x80 lor ((code lsr 12) land 0x3F));
    byte (0x80 lor ((code lsr 6) land 0x3F));
    byte (0x80 lor (code land 0x3F))
  end;
  Buffer.contents buffer

(* -------------------------------------------------------------------------- *)
(* Writing a number                                                             *)
(*                                                                              *)
(* A number is written with the fewest digits that read back as the same one,   *)
(* in whichever of the two notations is shorter.                                *)
(* -------------------------------------------------------------------------- *)

(* The digits and the exponent of the shortest form that round-trips: the value
   is 0.d1d2... shifted, or rather d1.d2d3... times ten to the exponent. *)
let significant value =
  let rec search digits =
    let text = Printf.sprintf "%.*e" digits value in
    if digits >= 16 || float_of_string text = value then text
    else search (digits + 1)
  in
  let text = search 0 in
  let mantissa, exponent =
    match String.index_opt text 'e' with
    | Some at ->
        ( String.sub text 0 at,
          int_of_string (String.sub text (at + 1) (String.length text - at - 1))
        )
    | None -> (text, 0)
  in
  let mantissa =
    if String.contains mantissa '.' then
      String.concat "" (String.split_on_char '.' mantissa)
    else mantissa
  in
  (* Trailing zeros carry no information about which number this is. *)
  let last = ref (String.length mantissa) in
  while !last > 1 && mantissa.[!last - 1] = '0' do
    decr last
  done;
  (String.sub mantissa 0 !last, exponent)

let positional digits exponent =
  let length = String.length digits in
  if exponent >= 0 then
    if length <= exponent + 1 then
      digits ^ String.make (exponent + 1 - length) '0'
    else
      String.sub digits 0 (exponent + 1)
      ^ "."
      ^ String.sub digits (exponent + 1) (length - exponent - 1)
  else "0." ^ String.make (-exponent - 1) '0' ^ digits

let scientific digits exponent =
  let mantissa =
    if String.length digits = 1 then digits
    else
      String.sub digits 0 1 ^ "."
      ^ String.sub digits 1 (String.length digits - 1)
  in
  Printf.sprintf "%s%s%02d" mantissa
    (if exponent < 0 then "e-" else "e+")
    (abs exponent)

let float_text value =
  if Float.is_nan value then "nan"
  else if Float.abs value = Float.infinity then
    if value > 0.0 then "inf" else "-inf"
  else begin
    let sign = if Float.sign_bit value then "-" else "" in
    let digits, exponent = significant (Float.abs value) in
    let fixed = positional digits exponent in
    let short = scientific digits exponent in
    sign ^ if String.length short < String.length fixed then short else fixed
  end

(* -------------------------------------------------------------------------- *)
(* The table                                                                    *)
(*                                                                              *)
(* The names are prefixed so that they cannot collide with anything a program   *)
(* declares for itself, since a program may bind to one by writing a function   *)
(* without a body. The built-in modules stand for them under short names.       *)
(* -------------------------------------------------------------------------- *)

let natives : (string * (value array -> span -> value)) list =
  [
    ( "otter_io_print",
      fun arguments _ ->
        print_string (text_of arguments.(0));
        Unit );
    ( "otter_io_println",
      fun arguments _ ->
        print_string (text_of arguments.(0));
        print_newline ();
        Unit );
    ( "otter_io_read_line",
      fun _ _ -> text (try input_line stdin with End_of_file -> "") );
    ( "otter_str_from_int",
      fun arguments _ -> text (Int64.to_string (int_of arguments.(0))) );
    ( "otter_str_from_float",
      fun arguments _ -> text (float_text (float_of arguments.(0))) );
    ( "otter_str_from_bool",
      fun arguments _ ->
        text (match arguments.(0) with Bool true -> "true" | _ -> "false") );
    ( "otter_str_from_char",
      fun arguments _ ->
        text (utf8_of (match arguments.(0) with Char code -> code | _ -> 0)) );
    ( "otter_str_to_int",
      fun arguments span ->
        let contents = text_of arguments.(0) in
        let digits =
          if String.length contents > 0 && contents.[0] = '-' then
            String.sub contents 1 (String.length contents - 1)
          else contents
        in
        let whole =
          digits <> ""
          && String.for_all (function '0' .. '9' -> true | _ -> false) digits
        in
        match if whole then Int64.of_string_opt contents else None with
        | Some value -> Int value
        | None -> runtime_error span "`%s` is not a whole number" contents );
    ( "otter_str_substring",
      fun arguments span ->
        let contents = text_of arguments.(0) in
        let start = Int64.to_int (int_of arguments.(1)) in
        let length = Int64.to_int (int_of arguments.(2)) in
        if start < 0 || length < 0 || start + length > String.length contents
        then
          runtime_error span
            "the substring %d..%d lies outside a string of length %d" start
            (start + length) (String.length contents);
        text (String.sub contents start length) );
    ( "otter_str_index_of",
      fun arguments _ ->
        let contents = text_of arguments.(0) in
        let needle = text_of arguments.(1) in
        let limit = String.length contents - String.length needle in
        let rec search index =
          if index > limit then -1
          else if String.sub contents index (String.length needle) = needle then
            index
          else search (index + 1)
        in
        Int (Int64.of_int (search 0)) );
    ( "otter_math_sqrt",
      fun arguments _ -> Float64 (sqrt (float_of arguments.(0))) );
    ( "otter_math_pow",
      fun arguments _ ->
        Float64 (Float.pow (float_of arguments.(0)) (float_of arguments.(1))) );
    ( "otter_math_floor",
      fun arguments _ -> Float64 (Float.floor (float_of arguments.(0))) );
    ( "otter_math_ceil",
      fun arguments _ -> Float64 (Float.ceil (float_of arguments.(0))) );
    ("otter_math_abs", fun arguments _ -> Int (Int64.abs (int_of arguments.(0))));
    ( "otter_math_min",
      fun arguments _ ->
        let left = int_of arguments.(0) and right = int_of arguments.(1) in
        Int (if Int64.compare left right <= 0 then left else right) );
    ( "otter_math_max",
      fun arguments _ ->
        let left = int_of arguments.(0) and right = int_of arguments.(1) in
        Int (if Int64.compare left right >= 0 then left else right) );
    ( "otter_gc_collect",
      fun _ _ ->
        Census.collect ();
        Unit );
    ("otter_gc_live", fun _ _ -> Int (Int64.of_int (Census.live ())));
    ("otter_gc_collections", fun _ _ -> Int (Int64.of_int !Census.collections));
  ]

(* Looks up the host function standing behind a body-less declaration. *)
let find_native name = List.assoc_opt name natives

(* -------------------------------------------------------------------------- *)
(* The built-in modules                                                         *)
(* -------------------------------------------------------------------------- *)

(* One function of a built-in module: what it is called there, the host function
   it stands for, and its signature. *)
type builtin_function = {
  bf_name : string;
  bf_host : string;
  bf_parameters : Types.t list;
  bf_result : Types.t;
}

(* A module the implementation provides itself, so that it needs no file beside
   the program. `Program` turns one of these into an ordinary module whose
   functions have no body, which is what every other body-less function is. *)
type builtin_module = { bm_name : string; bm_functions : builtin_function list }

let entry name host parameters result =
  {
    bf_name = name;
    bf_host = host;
    bf_parameters = parameters;
    bf_result = result;
  }

let builtin_modules =
  [
    {
      bm_name = "io";
      bm_functions =
        [
          entry "print" "otter_io_print" [ Types.String ] Types.Void;
          entry "println" "otter_io_println" [ Types.String ] Types.Void;
          entry "read_line" "otter_io_read_line" [] Types.String;
        ];
    };
    {
      bm_name = "str";
      bm_functions =
        [
          entry "from_int" "otter_str_from_int" [ Types.Int ] Types.String;
          entry "from_float" "otter_str_from_float" [ Types.Float64 ]
            Types.String;
          entry "from_bool" "otter_str_from_bool" [ Types.Bool ] Types.String;
          entry "from_char" "otter_str_from_char" [ Types.Char ] Types.String;
          entry "to_int" "otter_str_to_int" [ Types.String ] Types.Int;
          entry "substring" "otter_str_substring"
            [ Types.String; Types.Int; Types.Int ]
            Types.String;
          entry "index_of" "otter_str_index_of"
            [ Types.String; Types.String ]
            Types.Int;
        ];
    };
    {
      bm_name = "math";
      bm_functions =
        [
          entry "sqrt" "otter_math_sqrt" [ Types.Float64 ] Types.Float64;
          entry "pow" "otter_math_pow"
            [ Types.Float64; Types.Float64 ]
            Types.Float64;
          entry "floor" "otter_math_floor" [ Types.Float64 ] Types.Float64;
          entry "ceil" "otter_math_ceil" [ Types.Float64 ] Types.Float64;
          entry "abs" "otter_math_abs" [ Types.Int ] Types.Int;
          entry "min" "otter_math_min" [ Types.Int; Types.Int ] Types.Int;
          entry "max" "otter_math_max" [ Types.Int; Types.Int ] Types.Int;
        ];
    };
    {
      bm_name = "gc";
      bm_functions =
        [
          entry "collect" "otter_gc_collect" [] Types.Void;
          entry "live" "otter_gc_live" [] Types.Int;
          entry "collections" "otter_gc_collections" [] Types.Int;
        ];
    };
  ]

let find_builtin_module name =
  List.find_opt (fun entry -> entry.bm_name = name) builtin_modules
