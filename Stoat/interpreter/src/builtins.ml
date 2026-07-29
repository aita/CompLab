(* Global functions plus the methods that primitive values respond to
   (xs.push(1), s.split(",") and friends). *)

open Value

let builtin name fn = VBuiltin { bi_name = name; bi_fn = fn }

let bad_args name args =
  error "%s: unexpected arguments (%s)" name
    (String.concat ", " (List.map type_name args))

let want_int name = function
  | VInt n -> n
  | v -> error "%s expects an int but got %s" name (type_name v)

let want_str name = function
  | VStr s -> s
  | v -> error "%s expects a string but got %s" name (type_name v)

let want_num name = function
  | VInt n -> float_of_int n
  | VFloat f -> f
  | v -> error "%s expects a number but got %s" name (type_name v)

(* An index of [n] into a container of [len] elements, counting from the end
   when negative. *)
let resolve_index name n len =
  let i = if n < 0 then n + len else n in
  if i < 0 || i >= len then error "%s: index %d is out of range (length %d)" name n len;
  i

let find_sub hay needle start =
  let hl = String.length hay and nl = String.length needle in
  let rec go i = if i + nl > hl then -1 else if String.sub hay i nl = needle then i else go (i + 1) in
  if nl = 0 then -1 else go start

(* ------------------------------------------------------------------ *)
(* String methods                                                      *)
(* ------------------------------------------------------------------ *)

let split_string s sep =
  if sep = "" then error "split: the separator must not be empty";
  let out = Dynarray.create () in
  let rec go start =
    match find_sub s sep start with
    | -1 -> Dynarray.add_last out (VStr (String.sub s start (String.length s - start)))
    | i ->
        Dynarray.add_last out (VStr (String.sub s start (i - start)));
        go (i + String.length sep)
  in
  go 0;
  VList out

let replace_all s old fresh =
  if old = "" then error "replace: the pattern must not be empty";
  let buf = Buffer.create (String.length s) in
  let rec go start =
    match find_sub s old start with
    | -1 -> Buffer.add_string buf (String.sub s start (String.length s - start))
    | i ->
        Buffer.add_string buf (String.sub s start (i - start));
        Buffer.add_string buf fresh;
        go (i + String.length old)
  in
  go 0;
  Buffer.contents buf

let starts_with s prefix =
  String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

let ends_with s suffix =
  let ls = String.length s and lp = String.length suffix in
  ls >= lp && String.sub s (ls - lp) lp = suffix

let string_attr (s : string) (name : string) : value option =
  let m fn = Some (builtin ("string." ^ name) fn) in
  match name with
  | "len" -> m (function [] -> VInt (String.length s) | a -> bad_args "string.len" a)
  | "upper" -> m (function [] -> VStr (String.uppercase_ascii s) | a -> bad_args "string.upper" a)
  | "lower" -> m (function [] -> VStr (String.lowercase_ascii s) | a -> bad_args "string.lower" a)
  | "trim" -> m (function [] -> VStr (String.trim s) | a -> bad_args "string.trim" a)
  | "chars" ->
      m (function
        | [] ->
            let d = Dynarray.create () in
            String.iter (fun c -> Dynarray.add_last d (VStr (String.make 1 c))) s;
            VList d
        | a -> bad_args "string.chars" a)
  | "split" -> m (function [ v ] -> split_string s (want_str "split" v) | a -> bad_args "string.split" a)
  | "contains" ->
      m (function
        | [ v ] ->
            let needle = want_str "contains" v in
            VBool (needle = "" || find_sub s needle 0 >= 0)
        | a -> bad_args "string.contains" a)
  | "starts_with" ->
      m (function [ v ] -> VBool (starts_with s (want_str "starts_with" v)) | a -> bad_args "string.starts_with" a)
  | "ends_with" ->
      m (function [ v ] -> VBool (ends_with s (want_str "ends_with" v)) | a -> bad_args "string.ends_with" a)
  | "replace" ->
      m (function
        | [ a; b ] -> VStr (replace_all s (want_str "replace" a) (want_str "replace" b))
        | a -> bad_args "string.replace" a)
  | "substr" ->
      m (function
        | [ a; b ] ->
            let start = want_int "substr" a and len = want_int "substr" b in
            let n = String.length s in
            let start = if start < 0 then start + n else start in
            if start < 0 || start > n || len < 0 || start + len > n then
              error "substr: %d..%d is out of range (length %d)" start (start + len) n;
            VStr (String.sub s start len)
        | a -> bad_args "string.substr" a)
  | _ -> None

(* ------------------------------------------------------------------ *)
(* List methods                                                        *)
(* ------------------------------------------------------------------ *)

let list_attr (d : value Dynarray.t) (name : string) : value option =
  let m fn = Some (builtin ("list." ^ name) fn) in
  match name with
  | "len" -> m (function [] -> VInt (Dynarray.length d) | a -> bad_args "list.len" a)
  | "push" ->
      m (function
        | [ v ] ->
            Dynarray.add_last d v;
            VNil
        | a -> bad_args "list.push" a)
  | "pop" ->
      m (function
        | [] ->
            if Dynarray.is_empty d then error "list.pop: the list is empty";
            Dynarray.pop_last d
        | a -> bad_args "list.pop" a)
  | "insert" ->
      m (function
        | [ i; v ] ->
            let n = want_int "list.insert" i in
            let len = Dynarray.length d in
            let i = if n < 0 then n + len else n in
            if i < 0 || i > len then error "list.insert: index %d is out of range (length %d)" n len;
            Dynarray.add_last d v;
            for j = len downto i + 1 do
              Dynarray.set d j (Dynarray.get d (j - 1))
            done;
            Dynarray.set d i v;
            VNil
        | a -> bad_args "list.insert" a)
  | "remove_at" ->
      m (function
        | [ i ] ->
            let len = Dynarray.length d in
            let i = resolve_index "list.remove_at" (want_int "list.remove_at" i) len in
            let v = Dynarray.get d i in
            for j = i to len - 2 do
              Dynarray.set d j (Dynarray.get d (j + 1))
            done;
            Dynarray.remove_last d;
            v
        | a -> bad_args "list.remove_at" a)
  | "contains" ->
      m (function
        | [ v ] -> VBool (Dynarray.exists (equal v) d)
        | a -> bad_args "list.contains" a)
  | "index_of" ->
      m (function
        | [ v ] ->
            let n = Dynarray.length d in
            let rec go i = if i >= n then VInt (-1) else if equal v (Dynarray.get d i) then VInt i else go (i + 1) in
            go 0
        | a -> bad_args "list.index_of" a)
  | "join" ->
      m (function
        | [ sep ] ->
            let sep = want_str "list.join" sep in
            VStr (String.concat sep (List.map display (Dynarray.to_list d)))
        | a -> bad_args "list.join" a)
  | "reverse" ->
      m (function
        | [] ->
            let out = Dynarray.create () in
            for i = Dynarray.length d - 1 downto 0 do
              Dynarray.add_last out (Dynarray.get d i)
            done;
            VList out
        | a -> bad_args "list.reverse" a)
  | "copy" -> m (function [] -> VList (Dynarray.copy d) | a -> bad_args "list.copy" a)
  | "map" ->
      m (function
        | [ f ] ->
            let out = Dynarray.create () in
            Array.iter (fun v -> Dynarray.add_last out (call f [ v ])) (Dynarray.to_array d);
            VList out
        | a -> bad_args "list.map" a)
  | "filter" ->
      m (function
        | [ f ] ->
            let out = Dynarray.create () in
            Array.iter (fun v -> if truthy (call f [ v ]) then Dynarray.add_last out v) (Dynarray.to_array d);
            VList out
        | a -> bad_args "list.filter" a)
  | "each" ->
      m (function
        | [ f ] ->
            Array.iter (fun v -> ignore (call f [ v ])) (Dynarray.to_array d);
            VNil
        | a -> bad_args "list.each" a)
  | "fold" ->
      m (function
        | [ init; f ] -> Array.fold_left (fun acc v -> call f [ acc; v ]) init (Dynarray.to_array d)
        | a -> bad_args "list.fold" a)
  | _ -> None

(* Attributes of everything that is not an object or a class. *)
let primitive_attr (v : value) (name : string) : value option =
  match v with
  | VStr s -> string_attr s name
  | VList d -> list_attr d name
  | _ -> None

(* ------------------------------------------------------------------ *)
(* Global functions                                                    *)
(* ------------------------------------------------------------------ *)

let range_list args =
  let start, stop, step =
    match args with
    | [ b ] -> (0, want_int "range" b, 1)
    | [ a; b ] -> (want_int "range" a, want_int "range" b, 1)
    | [ a; b; s ] -> (want_int "range" a, want_int "range" b, want_int "range" s)
    | a -> bad_args "range" a
  in
  if step = 0 then error "range: the step must not be 0";
  let d = Dynarray.create () in
  let i = ref start in
  while if step > 0 then !i < stop else !i > stop do
    Dynarray.add_last d (VInt !i);
    i := !i + step
  done;
  VList d

let to_int name = function
  | VInt n -> VInt n
  | VFloat f -> VInt (int_of_float f)
  | VBool b -> VInt (if b then 1 else 0)
  | VStr s -> (
      match int_of_string_opt (String.trim s) with
      | Some n -> VInt n
      | None -> error "%s: cannot convert %s to an int" name (repr (VStr s)))
  | v -> error "%s: cannot convert %s to an int" name (type_name v)

let to_float name = function
  | VInt n -> VFloat (float_of_int n)
  | VFloat f -> VFloat f
  | VStr s -> (
      match float_of_string_opt (String.trim s) with
      | Some f -> VFloat f
      | None -> error "%s: cannot convert %s to a float" name (repr (VStr s)))
  | v -> error "%s: cannot convert %s to a float" name (type_name v)

let length_of name = function
  | VStr s -> VInt (String.length s)
  | VList d -> VInt (Dynarray.length d)
  | v -> error "%s: %s has no length" name (type_name v)

(* min/max keep ints as ints so that len(xs) - 1 stays exact. *)
let extremum name better args =
  match args with
  | [] -> error "%s expects at least one argument" name
  | first :: rest ->
      ignore (want_num name first);
      List.fold_left
        (fun acc v -> if better (want_num name v) (want_num name acc) then v else acc)
        first rest

let globals : (string * (value list -> value)) list =
  [
    ( "print",
      fun args ->
        print_endline (String.concat " " (List.map display args));
        VNil );
    ("str", function [ v ] -> VStr (display v) | a -> bad_args "str" a);
    ("repr", function [ v ] -> VStr (repr v) | a -> bad_args "repr" a);
    ("len", function [ v ] -> length_of "len" v | a -> bad_args "len" a);
    ("type", function [ v ] -> VStr (type_name v) | a -> bad_args "type" a);
    ("bool", function [ v ] -> VBool (truthy v) | a -> bad_args "bool" a);
    ("int", function [ v ] -> to_int "int" v | a -> bad_args "int" a);
    ("float", function [ v ] -> to_float "float" v | a -> bad_args "float" a);
    ("range", range_list);
    ( "abs",
      function
      | [ VInt n ] -> VInt (abs n)
      | [ VFloat f ] -> VFloat (Float.abs f)
      | a -> bad_args "abs" a );
    ("min", extremum "min" ( < ));
    ("max", extremum "max" ( > ));
    ("sqrt", function [ v ] -> VFloat (sqrt (want_num "sqrt" v)) | a -> bad_args "sqrt" a);
    ("floor", function [ v ] -> VInt (int_of_float (Float.floor (want_num "floor" v))) | a -> bad_args "floor" a);
    ("ceil", function [ v ] -> VInt (int_of_float (Float.ceil (want_num "ceil" v))) | a -> bad_args "ceil" a);
    ( "class_of",
      function
      | [ VObj o ] -> VClass o.o_class
      | [ v ] -> error "class_of: %s is not an object" (type_name v)
      | a -> bad_args "class_of" a );
    ( "mro",
      function
      | [ VClass c ] -> VList (Dynarray.of_list (List.map (fun k -> VStr k.c_name) c.c_mro))
      | [ VObj o ] -> VList (Dynarray.of_list (List.map (fun k -> VStr k.c_name) o.o_class.c_mro))
      | a -> bad_args "mro" a );
    ( "is_instance",
      function
      | [ VObj o; VClass c ] -> VBool (List.exists (same_class c) o.o_class.c_mro)
      | [ _; VClass _ ] -> VBool false
      | a -> bad_args "is_instance" a );
    ( "assert",
      function
      | [ c ] -> if truthy c then VNil else error "assertion failed"
      | [ c; msg ] -> if truthy c then VNil else error "assertion failed: %s" (display msg)
      | a -> bad_args "assert" a );
  ]

let install (env : env) =
  List.iter (fun (name, fn) -> define env name (builtin name fn)) globals
