(* The type checker, which also decides which variables escape.

   Types are monomorphic and there is nothing to infer but the type of a [val].
   A [fun] without a result type is a procedure and returns [unit], which is what
   makes recursion checkable without inference: every function's signature is
   known before any body is.

   The pass has a second job.  A variable read from inside a function nested more
   deeply than the one that binds it cannot live in a register, because the inner
   function reaches it through a static link at run time.  Every lookup that
   crosses a function boundary marks the variable as escaping, and the lowering
   pass gives those a frame slot instead. *)

open Types

let builtin_sigs =
  [
    ("print", [ String_t ], Unit_t, "wol_print");
    ("println", [ String_t ], Unit_t, "wol_println");
    ("printInt", [ Int_t ], Unit_t, "wol_print_int");
    ("flush", [], Unit_t, "wol_flush");
    ("getChar", [], String_t, "wol_getchar");
    ("ord", [ String_t ], Int_t, "wol_ord");
    ("chr", [ Int_t ], String_t, "wol_chr");
    ("size", [ String_t ], Int_t, "wol_size");
    ("substring", [ String_t; Int_t; Int_t ], String_t, "wol_substring");
    ("concat", [ String_t; String_t ], String_t, "wol_concat");
    ("intToString", [ Int_t ], String_t, "wol_int_to_string");
    ("stringToInt", [ String_t ], Int_t, "wol_string_to_int");
    ("exit", [ Int_t ], Unit_t, "wol_exit");
  ]

let arithmetic op = List.mem op [ "+"; "-"; "*"; "/"; "mod" ]
let ordering op = List.mem op [ "<"; "<="; ">"; ">=" ]
let equality op = List.mem op [ "="; "<>" ]

type scope = {
  mutable tys : (string * ty) list;
  mutable vals : (string * sym) list;
}

type checker = {
  mutable scopes : scope list;
  mutable depth : int;
  mutable loops : int;
  mutable labels : (string * int) list;
}

let prelude () =
  let vals =
    List.map
      (fun (name, params, result, symbol) ->
        ( name,
          Fun
            {
              fun_name = name;
              label = symbol;
              params = List.mapi (fun i t -> new_var (Printf.sprintf "a%d" i) t false 0) params;
              result;
              fun_depth = 0;
              builtin = Some symbol;
            } ))
      builtin_sigs
    @ List.map
        (fun name ->
          ( name,
            Fun
              {
                fun_name = name;
                label = name;
                params = [];
                result = Unit_t;
                fun_depth = 0;
                builtin = Some name;
              } ))
        [ "array"; "length"; "not" ]
  in
  {
    tys = [ ("int", Int_t); ("string", String_t); ("bool", Bool_t); ("unit", Unit_t) ];
    vals;
  }

(* -- scopes ---------------------------------------------------------------- *)

let push c = c.scopes <- { tys = []; vals = [] } :: c.scopes
let pop c = c.scopes <- List.tl c.scopes

let bind_val c name sym =
  let top = List.hd c.scopes in
  top.vals <- (name, sym) :: top.vals

let bind_type c name ty =
  let top = List.hd c.scopes in
  top.tys <- (name, ty) :: top.tys

let lookup_val c name at =
  let rec go = function
    | [] -> Diag.type_error at "`%s` is not bound" name
    | s :: rest -> ( match List.assoc_opt name s.vals with Some v -> v | None -> go rest)
  in
  go c.scopes

let lookup_type c name at =
  let rec go = function
    | [] -> Diag.type_error at "`%s` is not a type" name
    | s :: rest -> ( match List.assoc_opt name s.tys with Some t -> t | None -> go rest)
  in
  go c.scopes

let unique_label c name =
  let n = match List.assoc_opt name c.labels with Some n -> n | None -> 0 in
  c.labels <- (name, n + 1) :: List.remove_assoc name c.labels;
  if n = 0 then "wol_" ^ name else Printf.sprintf "wol_%s.%d" name n

let unify want got at where =
  if not (compatible want got) then
    Diag.type_error at "expected `%s`, found `%s` %s" (show want) (show got) where

(* -- types as they are written --------------------------------------------- *)

let rec resolve c (t : Ast.ty_exp) =
  match t.ty_node with
  | Ast.Ty_name name -> lookup_type c name t.ty_at
  | Ast.Ty_array elem -> Array_t (resolve c elem)
  | Ast.Ty_record _ ->
      Diag.type_error t.ty_at "a record type has to be given a name by `type`"

(* -- declarations ---------------------------------------------------------- *)

let rec decls c list = List.iter (decl c) list

and decl c = function
  | Ast.Type_decl binds -> type_decl c binds
  | Ast.Val_decl d -> val_decl c d
  | Ast.Fun_decl binds -> fun_decl c binds

and type_decl c binds =
  let records =
    List.filter_map
      (fun (b : Ast.type_bind) ->
        match b.bound.ty_node with
        | Ast.Ty_record fields ->
            let r = { rec_name = b.bind_name; fields = [] } in
            bind_type c b.bind_name (Record_t r);
            Some (r, fields)
        | _ -> None)
      binds
  in
  List.iter
    (fun (b : Ast.type_bind) ->
      match b.bound.ty_node with
      | Ast.Ty_record _ -> ()
      | _ -> bind_type c b.bind_name (resolve c b.bound))
    binds;
  List.iter
    (fun (r, fields) ->
      let seen = Hashtbl.create 8 in
      List.iter
        (fun (f : Ast.ty_field) ->
          if Hashtbl.mem seen f.field_name then
            Diag.type_error f.field_at "duplicate field `%s`" f.field_name;
          Hashtbl.replace seen f.field_name ();
          r.fields <- r.fields @ [ (f.field_name, resolve c f.field_ty) ])
        fields)
    records

and val_decl c (d : Ast.val_decl) =
  let got = exp c d.init in
  let got =
    match d.written with
    | None -> got
    | Some written ->
        let want = resolve c written in
        unify want got d.init.at "in this binding";
        want
  in
  match d.bound_name with
  | None -> unify Unit_t got d.init.at "in `val () =`"
  | Some name ->
      if got = Nil_t then
        Diag.type_error d.decl_at "`%s` needs a type annotation to hold `nil`" name;
      let sym = new_var name got d.is_var c.depth in
      d.decl_sym <- Some sym;
      bind_val c name (Var sym)

and fun_decl c binds =
  List.iter
    (fun (b : Ast.fun_bind) ->
      let seen = Hashtbl.create 8 in
      let params =
        Util.map_in_order
          (fun (p : Ast.param) ->
            if Hashtbl.mem seen p.param_name then
              Diag.type_error p.param_at "duplicate parameter `%s`" p.param_name;
            Hashtbl.replace seen p.param_name ();
            let sym = new_var p.param_name (resolve c p.param_ty) false (c.depth + 1) in
            p.param_sym <- Some sym;
            sym)
          b.fun_params
      in
      let result = match b.result with None -> Unit_t | Some t -> resolve c t in
      let sym =
        {
          fun_name = b.fun_label;
          label = unique_label c b.fun_label;
          params;
          result;
          fun_depth = c.depth + 1;
          builtin = None;
        }
      in
      b.sym <- Some sym;
      bind_val c b.fun_label (Fun sym))
    binds;
  List.iter
    (fun (b : Ast.fun_bind) ->
      let signature = Option.get b.sym in
      c.depth <- c.depth + 1;
      let outer = c.loops in
      c.loops <- 0;
      push c;
      List.iter
        (fun (p : Ast.param) -> bind_val c p.param_name (Var (Option.get p.param_sym)))
        b.fun_params;
      let got = exp c b.fun_body in
      unify signature.result got b.fun_body.at
        (Printf.sprintf "in the body of `%s`" b.fun_label);
      pop c;
      c.loops <- outer;
      c.depth <- c.depth - 1)
    binds

(* -- expressions ----------------------------------------------------------- *)

and exp c (e : Ast.exp) =
  let ty = infer c e in
  e.ty <- Some ty;
  ty

and infer c (e : Ast.exp) =
  match e.node with
  | Ast.Int_lit _ -> Int_t
  | Ast.Str_lit _ -> String_t
  | Ast.Bool_lit _ -> Bool_t
  | Ast.Nil_lit -> Nil_t
  | Ast.Unit_lit -> Unit_t
  | Ast.Var v -> variable c e v
  | Ast.Call call -> call_exp c e call
  | Ast.Record_lit r -> record_lit c e r
  | Ast.Index (array, index) -> index_exp c e array index
  | Ast.Field f -> field_exp c e f
  | Ast.Neg operand ->
      unify Int_t (exp c operand) e.at "in a negation";
      Int_t
  | Ast.Bin (op, lhs, rhs) -> binop c e op lhs rhs
  | Ast.Logic (op, lhs, rhs) ->
      unify Bool_t (exp c lhs) lhs.at (Printf.sprintf "on the left of `%s`" op);
      unify Bool_t (exp c rhs) rhs.at (Printf.sprintf "on the right of `%s`" op);
      Bool_t
  | Ast.Assign (target, value) -> assign c e target value
  | Ast.If (cond, then_, else_) -> if_exp c e cond then_ else_
  | Ast.While (cond, body) ->
      unify Bool_t (exp c cond) cond.at "as a `while` condition";
      c.loops <- c.loops + 1;
      unify Unit_t (exp c body) body.at "in a `while` body";
      c.loops <- c.loops - 1;
      Unit_t
  | Ast.For f -> for_exp c f
  | Ast.Break ->
      if c.loops = 0 then Diag.type_error e.at "`break` is outside any loop";
      Unit_t
  | Ast.Seq items -> List.fold_left (fun _ item -> exp c item) Unit_t items
  | Ast.Let (ds, body) ->
      push c;
      decls c ds;
      let ty = exp c body in
      pop c;
      ty

and variable c (e : Ast.exp) (v : Ast.var) =
  match lookup_val c v.name e.at with
  | Fun _ ->
      Diag.type_error e.at "`%s` is a function, and functions are not values" v.name
  | Var sym ->
      if sym.var_depth < c.depth then sym.escapes <- true;
      v.var_sym <- Some sym;
      sym.var_ty

and arity (e : Ast.exp) (call : Ast.call) want =
  if List.length call.args <> want then
    Diag.type_error e.at "`%s` takes %d argument%s, given %d" call.callee want
      (if want = 1 then "" else "s")
      (List.length call.args)

and call_exp c (e : Ast.exp) (call : Ast.call) =
  match lookup_val c call.callee e.at with
  | Var _ -> Diag.type_error e.at "`%s` is a variable, not a function" call.callee
  | Fun f -> (
      call.fun_sym <- Some f;
      match f.builtin with
      | Some "array" ->
          arity e call 2;
          let n = List.nth call.args 0 and init = List.nth call.args 1 in
          unify Int_t (exp c n) n.at "as an array length";
          let elem = exp c init in
          if elem = Nil_t then
            Diag.type_error init.at "`array` cannot tell which record `nil` stands for";
          Array_t elem
      | Some "length" ->
          arity e call 1;
          let arg = List.hd call.args in
          (match exp c arg with
          | Array_t _ -> ()
          | got -> Diag.type_error arg.at "`length` wants an array, found `%s`" (show got));
          Int_t
      | Some "not" ->
          arity e call 1;
          unify Bool_t (exp c (List.hd call.args)) e.at "in a call to `not`";
          Bool_t
      | _ ->
          arity e call (List.length f.params);
          List.iter2
            (fun (arg : Ast.exp) (p : var_sym) ->
              unify p.var_ty (exp c arg) arg.at
                (Printf.sprintf "in a call to `%s`" call.callee))
            call.args f.params;
          f.result)

and record_lit c (e : Ast.exp) (r : Ast.record_lit) =
  match lookup_type c r.tyname e.at with
  | Record_t rec_ ->
      let seen = Hashtbl.create 8 in
      List.iter
        (fun (f : Ast.field_init) ->
          if Hashtbl.mem seen f.init_name then
            Diag.type_error f.init_at "field `%s` is given twice" f.init_name;
          if index rec_ f.init_name < 0 then
            Diag.type_error f.init_at "`%s` has no field `%s`" rec_.rec_name f.init_name;
          Hashtbl.replace seen f.init_name f)
        r.inits;
      let ordered =
        List.map
          (fun (name, want) ->
            match Hashtbl.find_opt seen name with
            | None -> Diag.type_error e.at "field `%s` is missing" name
            | Some (init : Ast.field_init) ->
                unify want (exp c init.value) init.init_at
                  (Printf.sprintf "in field `%s`" name);
                init)
          rec_.fields
      in
      r.inits <- ordered;
      Record_t rec_
  | _ -> Diag.type_error e.at "`%s` is not a record type" r.tyname

and index_exp c (e : Ast.exp) array index =
  match exp c array with
  | Array_t elem ->
      unify Int_t (exp c index) index.Ast.at "as an array index";
      elem
  | got -> Diag.type_error e.at "`%s` is not an array" (show got)

and field_exp c (e : Ast.exp) (f : Ast.field) =
  match exp c f.record with
  | Record_t rec_ -> (
      match field_type rec_ f.select with
      | None ->
          Diag.type_error e.at "`%s` has no field `%s`" rec_.rec_name f.select
      | Some ty ->
          f.offset <- index rec_ f.select;
          ty)
  | got -> Diag.type_error e.at "`%s` is not a record" (show got)

and binop c (e : Ast.exp) op lhs rhs =
  let l = exp c lhs in
  let r = exp c rhs in
  if arithmetic op then begin
    unify Int_t l lhs.Ast.at (Printf.sprintf "on the left of `%s`" op);
    unify Int_t r rhs.Ast.at (Printf.sprintf "on the right of `%s`" op);
    Int_t
  end
  else if op = "^" then begin
    unify String_t l lhs.Ast.at "on the left of `^`";
    unify String_t r rhs.Ast.at "on the right of `^`";
    String_t
  end
  else if ordering op then
    match l with
    | Int_t | String_t ->
        unify l r rhs.Ast.at (Printf.sprintf "on the right of `%s`" op);
        Bool_t
    | _ -> Diag.type_error e.at "`%s` compares int or string, not `%s`" op (show l)
  else if equality op then begin
    if l = Unit_t || r = Unit_t then
      Diag.type_error e.at "`%s` cannot compare `unit`" op;
    if not (compatible l r) then
      Diag.type_error e.at "`%s` compares `%s` with `%s`" op (show l) (show r);
    Bool_t
  end
  else Diag.type_error e.at "unknown operator `%s`" op

and assign c (e : Ast.exp) (target : Ast.exp) value =
  let ty = exp c target in
  (match target.node with
  | Ast.Var { var_sym = Some sym; _ } when not sym.mutable_ ->
      Diag.type_error e.at "`%s` is a `val`, so it cannot be assigned" sym.var_name
  | _ -> ());
  unify ty (exp c value) value.at "in an assignment";
  Unit_t

and if_exp c (e : Ast.exp) cond then_ else_ =
  unify Bool_t (exp c cond) cond.Ast.at "as an `if` condition";
  let t = exp c then_ in
  match else_ with
  | None ->
      unify Unit_t t then_.Ast.at "in an `if` with no `else`";
      Unit_t
  | Some els ->
      let e' = exp c els in
      if not (compatible t e') then
        Diag.type_error e.at "the branches differ: `%s` and `%s`" (show t) (show e');
      if t = Nil_t then e' else t

and for_exp c (f : Ast.for_exp) =
  unify Int_t (exp c f.lo) f.lo.at "as a `for` bound";
  unify Int_t (exp c f.hi) f.hi.at "as a `for` bound";
  let sym = new_var f.binder Int_t false c.depth in
  f.loop_sym <- Some sym;
  push c;
  bind_val c f.binder (Var sym);
  c.loops <- c.loops + 1;
  unify Unit_t (exp c f.body) f.body.at "in a `for` body";
  c.loops <- c.loops - 1;
  pop c;
  Unit_t

(* [check] types the program in place: every node comes back with its type. *)
let check (prog : Ast.program) =
  let c = { scopes = [ prelude () ]; depth = 0; loops = 0; labels = [] } in
  push c;
  decls c prog;
  pop c
