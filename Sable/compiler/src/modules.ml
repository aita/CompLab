(* Modules.

   A module here is a naming discipline and nothing else, so this pass is all
   there is to them: it renames each definition inside a `struct` to a name
   carrying its path, records what the module exports, and rewrites the
   definitions into ordinary nested `let`s around the rest of the program.
   Nothing downstream of this pass knows that modules exist -- the type checker,
   the optimizer and the back end are untouched.

   That means the pass has to track every binder, not only the ones a module
   introduces: a local `let x` inside `open M in ...` must shadow `M.x`, so
   ordinary bindings are recorded too, mapping a name to itself. *)

open Syntax

exception Error of string

let fail fmt = Printf.ksprintf (fun msg -> raise (Error msg)) fmt

type scope = {
  values : Ident.t Ident.Map.t; (* the name as written -> the name it compiles to *)
  modules : scope Ident.Map.t;
}

let empty = { values = Ident.Map.empty; modules = Ident.Map.empty }
let bind_value name internal scope =
  { scope with values = Ident.Map.add name internal scope.values }

let bind_local name scope = bind_value name name scope
let bind_locals names scope = List.fold_left (fun scope x -> bind_local x scope) scope names

(* Merge one module's contents into the current scope, as `open` does. *)
let merge outer inner =
  {
    values = Ident.Map.union (fun _ _ latest -> Some latest) outer.values inner.values;
    modules = Ident.Map.union (fun _ _ latest -> Some latest) outer.modules inner.modules;
  }

let show_path path = String.concat "." path

let find_module scope path =
  let rec walk scope seen = function
    | [] -> scope
    | name :: rest -> (
      match Ident.Map.find_opt name scope.modules with
      | Some inner -> walk inner (seen @ [ name ]) rest
      | None ->
        if seen = [] then fail "unbound module `%s`" name
        else fail "the module `%s` has no module `%s`" (show_path seen) name)
  in
  walk scope [] path

let rec resolve_exp scope exp =
  let recur = resolve_exp scope in
  match exp with
  | Unit | Bool _ | Int _ | Str _ | Nil -> exp
  | Var x -> (
    (* A name this pass has not seen is either a runtime external or a genuine
       mistake; Typing is the one that decides which. *)
    match Ident.Map.find_opt x scope.values with
    | Some internal -> Var internal
    | None -> exp)
  | Qualified (path, x) -> (
    let owner = find_module scope path in
    match Ident.Map.find_opt x owner.values with
    | Some internal -> Var internal
    | None -> fail "the module `%s` has no value `%s`" (show_path path) x)
  | Module (name, items, body) ->
    let inner, wrap = resolve_items scope name items in
    let scope = { scope with modules = Ident.Map.add name inner scope.modules } in
    wrap (resolve_exp scope body)
  | Open (path, body) -> resolve_exp (merge scope (find_module scope path)) body
  | Not e -> Not (recur e)
  | Neg e -> Neg (recur e)
  | Arith (op, a, b) -> Arith (op, recur a, recur b)
  | Cmp (op, a, b) -> Cmp (op, recur a, recur b)
  | If (c, a, b) -> If (recur c, recur a, recur b)
  | Str_length e -> Str_length (recur e)
  | Str_get (a, b) -> Str_get (recur a, recur b)
  | Cons (a, b) -> Cons (recur a, recur b)
  | App (f, args) -> App (recur f, List.map recur args)
  | Tuple es -> Tuple (List.map recur es)
  | Array (a, b) -> Array (recur a, recur b)
  | Get (a, b) -> Get (recur a, recur b)
  | Put (a, b, c) -> Put (recur a, recur b, recur c)
  | Constr (name, args) -> Constr (name, List.map recur args)
  | Let ((x, t), e1, e2) ->
    Let ((x, t), recur e1, resolve_exp (bind_local x scope) e2)
  | Let_tuple (xts, e1, e2) ->
    let scope' = bind_locals (List.map fst xts) scope in
    Let_tuple (xts, recur e1, resolve_exp scope' e2)
  | Let_rec (fds, body) ->
    let scope' = bind_locals (List.map (fun fd -> fst fd.name) fds) scope in
    Let_rec (List.map (resolve_fundef scope') fds, resolve_exp scope' body)
  | Match (info, scrutinee, cases) ->
    let cases =
      List.map
        (fun case ->
          let bound = List.map fst (pattern_vars case.pat) in
          { case with action = resolve_exp (bind_locals bound scope) case.action })
        cases
    in
    Match (info, recur scrutinee, cases)
  | Field _ | Match_failure _ ->
    failwith "Modules: compiler-generated node reached name resolution"

and resolve_fundef scope fd =
  let scope = bind_locals (List.map fst fd.args) scope in
  { fd with body = resolve_exp scope fd.body }

(* The definitions of one `struct`, in order.  Returns what the module exports
   and a function that wraps the rest of the program in those definitions. *)
and resolve_items outer prefix items =
  let inside = ref outer in
  let exports = ref empty in
  let wrap = ref (fun k -> k) in
  let add_wrap f =
    let previous = !wrap in
    wrap := fun k -> previous (f k)
  in
  let export name internal =
    inside := bind_value name internal !inside;
    exports := bind_value name internal !exports
  in
  (* A path-carrying name, made unique so that two modules may use the same
     member name.  Ident.display trims the number back off for diagnostics. *)
  let internal_name name = Ident.fresh (prefix ^ "." ^ name) in
  List.iter
    (fun item ->
      match item with
      | Item_let ((x, t), e) ->
        let e = resolve_exp !inside e in
        let internal = internal_name x in
        export x internal;
        add_wrap (fun k -> Let ((internal, t), e, k))
      | Item_let_tuple (xts, e) ->
        let e = resolve_exp !inside e in
        let renamed = List.map (fun (x, t) -> (x, internal_name x, t)) xts in
        List.iter (fun (x, internal, _) -> export x internal) renamed;
        add_wrap (fun k ->
            Let_tuple (List.map (fun (_, internal, t) -> (internal, t)) renamed, e, k))
      | Item_let_rec fds ->
        let renamed =
          List.map (fun fd -> (fst fd.name, internal_name (fst fd.name))) fds
        in
        (* The group's members see each other, and so does everything after it. *)
        List.iter (fun (x, internal) -> export x internal) renamed;
        let fds =
          List.map2
            (fun fd (_, internal) ->
              resolve_fundef !inside { fd with name = (internal, snd fd.name) })
            fds renamed
        in
        add_wrap (fun k -> Let_rec (fds, k))
      | Item_module (name, items) ->
        let nested, nested_wrap = resolve_items !inside (prefix ^ "." ^ name) items in
        inside := { !inside with modules = Ident.Map.add name nested (!inside).modules };
        exports :=
          { !exports with modules = Ident.Map.add name nested (!exports).modules };
        add_wrap nested_wrap
      | Item_open path -> inside := merge !inside (find_module !inside path))
    items;
  (!exports, !wrap)

let resolve exp = resolve_exp empty exp
