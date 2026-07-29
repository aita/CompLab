(* The tree-walking evaluator. *)

open Ast
open Value

exception Return_exc of value
exception Break_exc
exception Continue_exc

(* Line of the statement being executed, reported when an error escapes. *)
let current_line = ref 0

type ctx = {
  env : env;
  defcls : cls option; (* class whose method we are running, for 'super' *)
}

let child ctx = { ctx with env = new_env (Some ctx.env) }

let rec exec_block ctx (b : block) : value =
  match b with
  | [] -> VNil
  | [ s ] -> exec_stmt ctx s
  | s :: rest ->
      ignore (exec_stmt ctx s);
      exec_block ctx rest

(* Bodies of if/while/for get their own scope, so a closure created inside a
   loop captures that iteration's bindings. *)
and exec_scoped ctx b = exec_block (child ctx) b

and exec_stmt ctx (s : stmt) : value =
  current_line := s.line;
  match s.desc with
  | SExpr e -> eval ctx e
  | SFun f ->
      define ctx.env f.fname (VFun (make_closure ctx f.fname f.params f.body));
      VNil
  | SClass d ->
      define ctx.env d.cname (VClass (make_class ctx d));
      VNil

and make_closure ctx name params body =
  { fn_name = name; fn_params = params; fn_body = body; fn_env = ctx.env; fn_class = ctx.defcls }

and make_class ctx (d : cls_decl) : cls =
  let bases =
    List.map
      (fun n ->
        match lookup_ref ctx.env n with
        | None -> error "base '%s' of class '%s' is not defined" n d.cname
        | Some r -> (
            match !r with
            | VClass c -> c
            | v -> error "base '%s' of class '%s' is a %s, not a class" n d.cname (type_name v)))
      d.bases
  in
  let c =
    {
      c_name = d.cname;
      c_bases = bases;
      c_mro = [];
      c_methods = Hashtbl.create 8;
      c_id = next_id ();
    }
  in
  c.c_mro <- c :: Mro.linearize d.cname bases;
  List.iter
    (fun (f : func) ->
      Hashtbl.replace c.c_methods f.fname
        {
          fn_name = d.cname ^ "." ^ f.fname;
          fn_params = f.params;
          fn_body = f.body;
          fn_env = ctx.env;
          fn_class = Some c;
        })
    d.meths;
  c

and eval ctx (e : expr) : value =
  match e with
  | Int n -> VInt n
  | Float f -> VFloat f
  | Str s -> VStr s
  | Bool b -> VBool b
  | Nil -> VNil
  | ListLit es -> VList (Dynarray.of_list (List.map (eval ctx) es))
  | Var x -> lookup ctx.env x
  | Let (x, e) ->
      define ctx.env x (eval ctx e);
      VNil
  | Assign (lhs, rhs) ->
      let v = eval ctx rhs in
      assign_to ctx lhs v;
      v
  | Binop (op, a, b) -> binop op (eval ctx a) (eval ctx b)
  | Unop (Neg, e) -> (
      match eval ctx e with
      | VInt n -> VInt (-n)
      | VFloat f -> VFloat (-.f)
      | v -> error "cannot negate a %s" (type_name v))
  | Unop (Not, e) -> VBool (not (truthy (eval ctx e)))
  | And (a, b) ->
      let v = eval ctx a in
      if truthy v then eval ctx b else v
  | Or (a, b) ->
      let v = eval ctx a in
      if truthy v then v else eval ctx b
  | Call (f, args) ->
      let fv = eval ctx f in
      call_value fv (List.map (eval ctx) args)
  | Field (e, name) -> get_attr (eval ctx e) name
  | Index (e, i) -> index_get (eval ctx e) (eval ctx i)
  | Super name -> super_attr ctx name
  | Fn (params, body) -> VFun (make_closure ctx "<anonymous>" params body)
  | If (c, t, e) ->
      if truthy (eval ctx c) then exec_scoped ctx t
      else ( match e with Some b -> exec_scoped ctx b | None -> VNil)
  | While (c, body) ->
      (try
         while truthy (eval ctx c) do
           try ignore (exec_scoped ctx body) with Continue_exc -> ()
         done
       with Break_exc -> ());
      VNil
  | For (x, e, body) ->
      let items = iterable (eval ctx e) in
      (try
         Array.iter
           (fun item ->
             let inner = child ctx in
             define inner.env x item;
             try ignore (exec_block inner body) with Continue_exc -> ())
           items
       with Break_exc -> ());
      VNil
  | Return e -> raise (Return_exc (match e with Some e -> eval ctx e | None -> VNil))
  | Break -> raise Break_exc
  | Continue -> raise Continue_exc

and iterable v =
  match v with
  | VList d -> Dynarray.to_array d
  | VStr s -> Array.init (String.length s) (fun i -> VStr (String.make 1 s.[i]))
  | v -> error "cannot iterate over a %s" (type_name v)

and assign_to ctx lhs v =
  match lhs with
  | Var x -> assign ctx.env x v
  | Field (e, name) -> (
      match eval ctx e with
      | VObj o -> Hashtbl.replace o.o_fields name v
      | other -> error "cannot set field '%s' on a %s" name (type_name other))
  | Index (e, i) -> (
      match (eval ctx e, eval ctx i) with
      | VList d, VInt n ->
          let len = Dynarray.length d in
          let idx = if n < 0 then n + len else n in
          if idx < 0 || idx >= len then error "index %d is out of range (length %d)" n len;
          Dynarray.set d idx v
      | VList _, k -> error "list indices must be ints, not %s" (type_name k)
      | other, _ -> error "cannot assign to an index of a %s" (type_name other))
  | _ -> error "invalid assignment target"

and index_get target key =
  match (target, key) with
  | VList d, VInt n ->
      let len = Dynarray.length d in
      let idx = if n < 0 then n + len else n in
      if idx < 0 || idx >= len then error "index %d is out of range (length %d)" n len;
      Dynarray.get d idx
  | VStr s, VInt n ->
      let len = String.length s in
      let idx = if n < 0 then n + len else n in
      if idx < 0 || idx >= len then error "index %d is out of range (length %d)" n len;
      VStr (String.make 1 s.[idx])
  | (VList _ | VStr _), k -> error "indices must be ints, not %s" (type_name k)
  | v, _ -> error "cannot index a %s" (type_name v)

and get_attr v name =
  match v with
  | VObj o -> (
      match Hashtbl.find_opt o.o_fields name with
      | Some field -> field
      | None -> (
          match find_method o.o_class name with
          | Some m -> VBound (v, m)
          | None -> error "%s has no field or method '%s'" o.o_class.c_name name))
  | VClass c -> (
      match find_method c name with
      | Some m -> VFun m (* unbound: the caller must supply 'self' via a receiver *)
      | None -> error "class %s has no method '%s'" c.c_name name)
  | _ -> (
      match Builtins.primitive_attr v name with
      | Some m -> m
      | None -> error "a %s has no field or method '%s'" (type_name v) name)

(* super.name looks for 'name' in the MRO of self, starting after the class
   whose method is currently running. *)
and super_attr ctx name =
  let self =
    match lookup_ref ctx.env "self" with
    | Some r -> !r
    | None -> error "'super' can only be used inside a method"
  in
  let defcls =
    match ctx.defcls with
    | Some c -> c
    | None -> error "'super' can only be used inside a method"
  in
  let mro = match self with VObj o -> o.o_class.c_mro | v -> error "'super' needs an object, got %s" (type_name v) in
  let rec after = function
    | [] -> []
    | c :: rest -> if same_class c defcls then rest else after rest
  in
  let rec search = function
    | [] ->
        error "no method '%s' after %s in the MRO of %s" name defcls.c_name (type_name self)
    | c :: rest -> (
        match Hashtbl.find_opt c.c_methods name with
        | Some m -> VBound (self, m)
        | None -> search rest)
  in
  search (after mro)

and call_value f args =
  match f with
  | VFun c -> call_closure c None args
  | VBound (recv, c) -> call_closure c (Some recv) args
  | VBuiltin b -> b.bi_fn args
  | VClass c -> instantiate c args
  | v -> error "a %s is not callable" (type_name v)

and call_closure c self args =
  let expected = List.length c.fn_params and got = List.length args in
  if expected <> got then
    error "%s expects %d argument%s but got %d" c.fn_name expected
      (if expected = 1 then "" else "s")
      got;
  let env = new_env (Some c.fn_env) in
  (match self with Some s -> define env "self" s | None -> ());
  List.iter2 (define env) c.fn_params args;
  let saved = !current_line in
  let result = try exec_block { env; defcls = c.fn_class } c.fn_body with Return_exc v -> v in
  current_line := saved;
  result

and instantiate c args =
  let o = { o_class = c; o_fields = Hashtbl.create 8; o_id = next_id () } in
  let self = VObj o in
  (match find_method c "init" with
  | Some init -> ignore (call_closure init (Some self) args)
  | None -> (
      match args with
      | [] -> ()
      | _ -> error "%s has no 'init' method, so it takes no arguments" c.c_name));
  self

and binop op a b =
  match (op, a, b) with
  | Eq, _, _ -> VBool (equal a b)
  | Ne, _, _ -> VBool (not (equal a b))
  | Add, VStr x, VStr y -> VStr (x ^ y)
  | Add, VList x, VList y ->
      let out = Dynarray.copy x in
      Dynarray.append out y;
      VList out
  | (Lt | Le | Gt | Ge), VStr x, VStr y ->
      let c = compare x y in
      VBool (match op with Lt -> c < 0 | Le -> c <= 0 | Gt -> c > 0 | _ -> c >= 0)
  | _, VInt x, VInt y -> (
      match op with
      | Add -> VInt (x + y)
      | Sub -> VInt (x - y)
      | Mul -> VInt (x * y)
      | Div -> if y = 0 then error "division by zero" else VInt (x / y)
      | Mod -> if y = 0 then error "division by zero" else VInt (x mod y)
      | Lt -> VBool (x < y)
      | Le -> VBool (x <= y)
      | Gt -> VBool (x > y)
      | Ge -> VBool (x >= y)
      | Eq | Ne -> assert false)
  | _, (VInt _ | VFloat _), (VInt _ | VFloat _) -> (
      let x = match a with VInt n -> float_of_int n | VFloat f -> f | _ -> assert false in
      let y = match b with VInt n -> float_of_int n | VFloat f -> f | _ -> assert false in
      match op with
      | Add -> VFloat (x +. y)
      | Sub -> VFloat (x -. y)
      | Mul -> VFloat (x *. y)
      | Div -> if y = 0.0 then error "division by zero" else VFloat (x /. y)
      | Mod -> if y = 0.0 then error "division by zero" else VFloat (Float.rem x y)
      | Lt -> VBool (x < y)
      | Le -> VBool (x <= y)
      | Gt -> VBool (x > y)
      | Ge -> VBool (x >= y)
      | Eq | Ne -> assert false)
  | _ ->
      error "unsupported operands for %s: %s and %s" (string_of_binop op) (type_name a) (type_name b)

(* ------------------------------------------------------------------ *)

let () = Value.call_ref := call_value

let run (program : block) : unit =
  let env = new_env None in
  Builtins.install env;
  current_line := 0;
  ignore (exec_block { env; defcls = None } program)
