(* Runtime values, environments and the error type shared by the evaluator
   and the builtins. *)

exception Stoat_error of string

let error fmt = Printf.ksprintf (fun msg -> raise (Stoat_error msg)) fmt

type value =
  | VNil
  | VBool of bool
  | VInt of int
  | VFloat of float
  | VStr of string
  | VList of value Dynarray.t
  | VFun of closure
  | VBound of value * closure (* receiver + method *)
  | VBuiltin of builtin
  | VClass of cls
  | VObj of obj

and closure = {
  fn_name : string;
  fn_params : string list;
  fn_body : Ast.block;
  fn_env : env;
  fn_class : cls option; (* defining class: where 'super' starts looking *)
}

and builtin = {
  bi_name : string;
  bi_fn : value list -> value;
}

and cls = {
  c_name : string;
  c_bases : cls list;
  mutable c_mro : cls list; (* C3 linearization, starting with the class itself *)
  c_methods : (string, closure) Hashtbl.t;
  c_id : int;
}

and obj = {
  o_class : cls;
  o_fields : (string, value) Hashtbl.t;
  o_id : int;
}

and env = {
  vars : (string, value ref) Hashtbl.t;
  parent : env option;
}

let next_id =
  let counter = ref 0 in
  fun () ->
    incr counter;
    !counter

(* The evaluator installs itself here so that builtins (list.map, printing an
   object through its to_string method, ...) can call back into Stoat code. *)
let call_ref : (value -> value list -> value) ref =
  ref (fun _ _ -> error "the interpreter is not initialised")

let call f args = !call_ref f args

(* Environments *)

let new_env parent = { vars = Hashtbl.create 8; parent }
let define env name v = Hashtbl.replace env.vars name (ref v)

let rec lookup_ref env name =
  match Hashtbl.find_opt env.vars name with
  | Some r -> Some r
  | None -> ( match env.parent with Some p -> lookup_ref p name | None -> None)

let lookup env name =
  match lookup_ref env name with
  | Some r -> !r
  | None -> error "undefined variable '%s'" name

let assign env name v =
  match lookup_ref env name with
  | Some r -> r := v
  | None -> error "'%s' is not defined; use 'let %s = ...' to declare it" name name

(* Classes *)

let same_class a b = a.c_id = b.c_id

let find_method (c : cls) (name : string) : closure option =
  let rec go = function
    | [] -> None
    | k :: rest -> (
        match Hashtbl.find_opt k.c_methods name with
        | Some m -> Some m
        | None -> go rest)
  in
  go c.c_mro

(* Inspecting values *)

let type_name = function
  | VNil -> "nil"
  | VBool _ -> "bool"
  | VInt _ -> "int"
  | VFloat _ -> "float"
  | VStr _ -> "string"
  | VList _ -> "list"
  | VFun _ | VBound _ | VBuiltin _ -> "function"
  | VClass _ -> "class"
  | VObj o -> o.o_class.c_name

let truthy = function VNil -> false | VBool b -> b | _ -> true

let rec equal a b =
  match (a, b) with
  | VNil, VNil -> true
  | VBool x, VBool y -> x = y
  | VInt x, VInt y -> x = y
  | VFloat x, VFloat y -> x = y
  | VInt x, VFloat y | VFloat y, VInt x -> float_of_int x = y
  | VStr x, VStr y -> String.equal x y
  | VList x, VList y ->
      Dynarray.length x = Dynarray.length y
      && (let n = Dynarray.length x in
          let rec go i =
            i >= n || (equal (Dynarray.get x i) (Dynarray.get y i) && go (i + 1))
          in
          go 0)
  | VObj x, VObj y -> x.o_id = y.o_id
  | VClass x, VClass y -> x.c_id = y.c_id
  | VFun x, VFun y -> x == y
  | VBuiltin x, VBuiltin y -> x == y
  | VBound (r1, m1), VBound (r2, m2) -> equal r1 r2 && m1 == m2
  | _ -> false

let float_to_string f =
  if Float.is_nan f then "nan"
  else if Float.is_integer f && Float.abs f < 1e16 then Printf.sprintf "%.1f" f
  else
    let s = Printf.sprintf "%.17g" f in
    let shorter = Printf.sprintf "%.15g" f in
    if float_of_string shorter = f then shorter else s

let escape_string s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\r' -> Buffer.add_string buf "\\r"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"';
  Buffer.contents buf

(* [display] is what print/str produce; [repr] is used for values nested inside
   a list, where strings keep their quotes. *)
let rec display v =
  match v with
  | VNil -> "nil"
  | VBool true -> "true"
  | VBool false -> "false"
  | VInt n -> string_of_int n
  | VFloat f -> float_to_string f
  | VStr s -> s
  | VList d ->
      let parts = List.map repr (Dynarray.to_list d) in
      "[" ^ String.concat ", " parts ^ "]"
  | VFun f -> Printf.sprintf "<fun %s>" f.fn_name
  | VBound (_, f) -> Printf.sprintf "<method %s>" f.fn_name
  | VBuiltin b -> Printf.sprintf "<builtin %s>" b.bi_name
  | VClass c -> Printf.sprintf "<class %s>" c.c_name
  | VObj o -> (
      match find_method o.o_class "to_string" with
      | Some m -> (
          match call (VBound (v, m)) [] with
          | VStr s -> s
          | VObj self when self.o_id = o.o_id -> Printf.sprintf "<%s object>" o.o_class.c_name
          | other -> display other)
      | None -> Printf.sprintf "<%s object>" o.o_class.c_name)

and repr v = match v with VStr s -> escape_string s | _ -> display v
