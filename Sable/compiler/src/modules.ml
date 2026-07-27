(* Modules and functors.

   A module here is a naming discipline and nothing else, so this pass is all
   there is to them: it renames each definition inside a `struct` to a name
   carrying its path, records what the module exports, and rewrites the
   definitions into ordinary nested `let`s around the rest of the program.
   Nothing downstream knows modules exist -- the type checker, the optimizer and
   the back end are untouched, which is why a function defined in a module is
   polymorphic exactly as it would be anywhere else.

   Functors work the same way, by elaboration.  There is no separate
   compilation here and every application is visible, so `F (Arg)` re-resolves
   F's body with its parameter bound to Arg, giving that application its own
   copy of the definitions.  This is defunctorization, the same thing MLton does
   to a whole program.  What it costs is a copy of the body per application;
   what it buys is that functors need no runtime representation and no support
   anywhere else in the compiler.

   The argument is checked against the parameter's signature first, by binding
   each declared value at its declared type.  A signature's `'a` is a rigid
   variable (Types.Rigid), so `val id : 'a -> 'a` accepts a polymorphic identity
   and rejects one that only works on integers -- the generality has to go the
   right way.

   The pass tracks every binder, not only the ones a module introduces: a local
   `let x` inside `open M in ...` must shadow `M.x`, so ordinary bindings are
   recorded too, mapping a name to itself. *)

open Syntax

exception Error of string

let fail fmt = Printf.ksprintf (fun msg -> raise (Error msg)) fmt

type entry =
  | Structure of scope
  | Functor_entry of functor_def

and functor_def = {
  parameter : string;
  parameter_sig : signature;
  body : item list;
  defined_in : scope; (* what was in scope where the functor was written *)
}

and scope = {
  values : Ident.t Ident.Map.t; (* the name as written -> the name it compiles to *)
  modules : entry Ident.Map.t;
  signatures : (Ident.t * Types.t) list Ident.Map.t;
}

let empty =
  { values = Ident.Map.empty; modules = Ident.Map.empty; signatures = Ident.Map.empty }

let bind_value name internal scope =
  { scope with values = Ident.Map.add name internal scope.values }

let bind_local name scope = bind_value name name scope
let bind_locals names scope = List.fold_left (fun scope x -> bind_local x scope) scope names
let latest _ _ newer = Some newer

(* Merge one module's contents into the current scope, as `open` does. *)
let merge outer inner =
  {
    values = Ident.Map.union latest outer.values inner.values;
    modules = Ident.Map.union latest outer.modules inner.modules;
    signatures = Ident.Map.union latest outer.signatures inner.signatures;
  }

let show_path path = String.concat "." path

let find_entry scope path =
  let rec walk scope seen = function
    | [] -> failwith "Modules: empty module path"
    | [ name ] -> (
      match Ident.Map.find_opt name scope.modules with
      | Some entry -> entry
      | None ->
        if seen = [] then fail "unbound module `%s`" name
        else fail "the module `%s` has no module `%s`" (show_path seen) name)
    | name :: rest -> (
      match Ident.Map.find_opt name scope.modules with
      | Some (Structure inner) -> walk inner (seen @ [ name ]) rest
      | Some (Functor_entry _) ->
        fail "`%s` is a functor; it has to be applied before its contents are used"
          (show_path (seen @ [ name ]))
      | None ->
        if seen = [] then fail "unbound module `%s`" name
        else fail "the module `%s` has no module `%s`" (show_path seen) name)
  in
  walk scope [] path

let find_structure scope path =
  match find_entry scope path with
  | Structure inner -> inner
  | Functor_entry _ ->
    fail "`%s` is a functor; it has to be applied before its contents are used"
      (show_path path)

let resolve_signature scope = function
  | Sig_values values ->
    List.iter
      (fun (name, t) ->
        Datatype.check_type (Printf.sprintf "in the declaration of `%s`" name) t)
      values;
    values
  | Sig_name name -> (
    match Ident.Map.find_opt name scope.signatures with
    | Some values -> values
    | None -> fail "unbound module type `%s`" name)

(* Check a structure against a signature, as a sequence of bindings that ask
   the type checker whether each declared value is general enough.  They bind
   names nothing can mention, and elimination drops them once they have done
   their work. *)
let signature_check ~what values structure =
  List.map
    (fun (name, declared) ->
      match Ident.Map.find_opt name structure.values with
      | None -> fail "%s does not match its signature: it has no value `%s`" what name
      | Some internal ->
        fun body ->
          Let
            ( (Ident.fresh "signature", Types.fresh_var ()),
              Annot (Var internal, declared),
              body ))
    values

let compose wraps body = List.fold_right (fun wrap acc -> wrap acc) wraps body

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
    let owner = find_structure scope path in
    match Ident.Map.find_opt x owner.values with
    | Some internal -> Var internal
    | None -> fail "the module `%s` has no value `%s`" (show_path path) x)
  | Module (name, module_exp, body) ->
    let entry, wrap = resolve_module_exp scope name module_exp in
    let scope = { scope with modules = Ident.Map.add name entry scope.modules } in
    wrap (resolve_exp scope body)
  | Module_type (name, signature, body) ->
    let values = resolve_signature scope signature in
    resolve_exp
      { scope with signatures = Ident.Map.add name values scope.signatures }
      body
  | Functor (name, parameter, parameter_sig, items, body) ->
    let entry =
      Functor_entry { parameter; parameter_sig; body = items; defined_in = scope }
    in
    resolve_exp { scope with modules = Ident.Map.add name entry scope.modules } body
  | Open (path, body) -> resolve_exp (merge scope (find_structure scope path)) body
  | Annot (e, t) -> Annot (recur e, t)
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
  | Let ((x, t), e1, e2) -> Let ((x, t), recur e1, resolve_exp (bind_local x scope) e2)
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

(* What a module expression denotes, and the definitions it contributes. *)
and resolve_module_exp scope prefix module_exp =
  match module_exp with
  | Mod_struct items ->
    let exports, wrap = resolve_items scope prefix items in
    (Structure exports, wrap)
  | Mod_path path -> (find_entry scope path, fun body -> body)
  | Mod_sealed (inner, signature) ->
    let entry, wrap = resolve_module_exp scope prefix inner in
    let structure =
      match entry with
      | Structure s -> s
      | Functor_entry _ -> fail "a functor cannot be given a signature here"
    in
    let values = resolve_signature scope signature in
    let checks =
      signature_check ~what:(Printf.sprintf "the module `%s`" prefix) values structure
    in
    (* Sealing hides whatever the signature does not mention. *)
    let sealed =
      List.fold_left
        (fun acc (name, _) ->
          bind_value name (Ident.Map.find name structure.values) acc)
        { empty with modules = structure.modules }
        values
    in
    (Structure sealed, fun body -> wrap (compose checks body))
  | Mod_apply (functor_path, argument) ->
    let definition =
      match find_entry scope functor_path with
      | Functor_entry f -> f
      | Structure _ -> fail "`%s` is a structure, not a functor" (show_path functor_path)
    in
    let argument_entry, argument_wrap =
      resolve_module_exp scope (prefix ^ ".argument") argument
    in
    let argument_scope =
      match argument_entry with
      | Structure s -> s
      | Functor_entry _ ->
        fail "the argument of `%s` is a functor, not a structure" (show_path functor_path)
    in
    let declared = resolve_signature scope definition.parameter_sig in
    let checks =
      signature_check
        ~what:(Printf.sprintf "the argument of `%s`" (show_path functor_path))
        declared argument_scope
    in
    (* The body may only see what the signature declares, so that a functor
       which happens to work with one argument does not quietly depend on
       something the next argument lacks.  It does see the argument's real
       types, though: elaborating per application is what makes functors free
       here, and it is also what stops the parameter from being abstract. *)
    let parameter_view =
      List.fold_left
        (fun acc (name, _) -> bind_value name (Ident.Map.find name argument_scope.values) acc)
        empty declared
    in
    (* Every application gets its own copy of the body, resolved with the
       parameter bound to this argument.  Ident.fresh keeps the copies apart. *)
    let inside =
      {
        definition.defined_in with
        modules =
          Ident.Map.add definition.parameter (Structure parameter_view)
            definition.defined_in.modules;
      }
    in
    let exports, body_wrap = resolve_items inside prefix definition.body in
    (Structure exports, fun body -> argument_wrap (compose checks (body_wrap body)))

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
  let export_module name entry =
    inside := { !inside with modules = Ident.Map.add name entry (!inside).modules };
    exports := { !exports with modules = Ident.Map.add name entry (!exports).modules }
  in
  (* A path-carrying name, made unique so that two modules -- or two
     applications of one functor -- may use the same member name.
     Ident.display trims the number back off for diagnostics. *)
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
        let renamed = List.map (fun fd -> (fst fd.name, internal_name (fst fd.name))) fds in
        (* The group's members see each other, and so does everything after. *)
        List.iter (fun (x, internal) -> export x internal) renamed;
        let fds =
          List.map2
            (fun fd (_, internal) ->
              resolve_fundef !inside { fd with name = (internal, snd fd.name) })
            fds renamed
        in
        add_wrap (fun k -> Let_rec (fds, k))
      | Item_module (name, module_exp) ->
        let entry, nested_wrap =
          resolve_module_exp !inside (prefix ^ "." ^ name) module_exp
        in
        export_module name entry;
        add_wrap nested_wrap
      | Item_module_type (name, signature) ->
        let values = resolve_signature !inside signature in
        let add s = { s with signatures = Ident.Map.add name values s.signatures } in
        inside := add !inside;
        exports := add !exports
      | Item_functor (name, parameter, parameter_sig, body) ->
        export_module name
          (Functor_entry { parameter; parameter_sig; body; defined_in = !inside })
      | Item_open path -> inside := merge !inside (find_structure !inside path))
    items;
  (!exports, !wrap)

let resolve exp = resolve_exp empty exp
