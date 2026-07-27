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

let position : Lexing.position option ref = ref None

let fail fmt =
  Printf.ksprintf
    (fun msg ->
      match !position with
      | Some p -> raise (Error (Printf.sprintf "%s: %s" (describe_position p) msg))
      | None -> raise (Error msg))
    fmt

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
  types : string Ident.Map.t;
  constructors : string Ident.Map.t;
  modules : entry Ident.Map.t;
  signatures : signature_body Ident.Map.t;
}

(* A signature with its type expressions resolved, except for the names it
   declares abstract: those are filled in from whichever structure it is
   matched against, which is all the type sharing this language needs. *)
and signature_body = { abstract : string list; declared : (Ident.t * Types.t) list }

let empty =
  {
    values = Ident.Map.empty;
    types = Ident.Map.empty;
    constructors = Ident.Map.empty;
    modules = Ident.Map.empty;
    signatures = Ident.Map.empty;
  }

let bind_value name internal scope =
  { scope with values = Ident.Map.add name internal scope.values }

let bind_local name scope = bind_value name name scope
let bind_locals names scope = List.fold_left (fun scope x -> bind_local x scope) scope names
let latest _ _ newer = Some newer

(* Merge one module's contents into the current scope, as `open` does. *)
let merge outer inner =
  {
    values = Ident.Map.union latest outer.values inner.values;
    types = Ident.Map.union latest outer.types inner.types;
    constructors = Ident.Map.union latest outer.constructors inner.constructors;
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

(* `M.N.x` as written; the last component is the name and the rest the path. *)
let split_dotted name =
  match List.rev (String.split_on_char '.' name) with
  | last :: reversed_path -> (List.rev reversed_path, last)
  | [] -> ([], name)

let owner_of scope path = if path = [] then scope else find_structure scope path

let find_type ~where scope written =
  let path, name = split_dotted written in
  let owner = owner_of scope path in
  match Ident.Map.find_opt name owner.types with
  | Some internal -> internal
  | None ->
    if path = [] then fail "unknown type `%s` %s" name where
    else fail "the module `%s` has no type `%s` (%s)" (show_path path) name where

let find_constructor scope written =
  let path, name = split_dotted written in
  let owner = owner_of scope path in
  match Ident.Map.find_opt name owner.constructors with
  | Some internal -> internal
  | None when Ident.Map.mem name owner.modules ->
    (* A capitalised name may be either; say which one it turned out to be. *)
    fail "`%s` is a module, not a value" written
  | None ->
    if path = [] then fail "unknown constructor `%s`" name
    else fail "the module `%s` has no constructor `%s`" (show_path path) name

(* Rewrite the type names a written type mentions into the ones they compile
   to.  Names listed in [abstract] are left alone: a signature's own `type t`
   has no meaning until the signature is matched. *)
let rec resolve_type ~where ?(abstract = []) scope t =
  let recur = resolve_type ~where ~abstract scope in
  match t with
  | Types.Named name when List.mem name abstract -> t
  | Types.Named name -> Types.Named (find_type ~where scope name)
  | Types.Fun (args, result) -> Types.Fun (List.map recur args, recur result)
  | Types.Tuple ts -> Types.Tuple (List.map recur ts)
  | Types.Array t -> Types.Array (recur t)
  | Types.List t -> Types.List (recur t)
  | t -> t

(* Fill a signature's abstract types in from the structure being matched. *)
let substitute assignments t =
  let rec walk t =
    match t with
    | Types.Named name -> (
      match List.assoc_opt name assignments with Some replacement -> replacement | None -> t)
    | Types.Fun (args, result) -> Types.Fun (List.map walk args, walk result)
    | Types.Tuple ts -> Types.Tuple (List.map walk ts)
    | Types.Array t -> Types.Array (walk t)
    | Types.List t -> Types.List (walk t)
    | t -> t
  in
  walk t

let resolve_signature scope = function
  | Sig_items items ->
    let abstract =
      List.filter_map (function Sig_type name -> Some name | Sig_val _ -> None) items
    in
    let declared =
      List.filter_map
        (function
          | Sig_type _ -> None
          | Sig_val (name, t) ->
            let where = Printf.sprintf "in the declaration of `%s`" name in
            Some (name, resolve_type ~where ~abstract scope t))
        items
    in
    { abstract; declared }
  | Sig_name name -> (
    match Ident.Map.find_opt name scope.signatures with
    | Some body -> body
    | None -> fail "unbound module type `%s`" name)

(* Check a structure against a signature, as a sequence of bindings that ask
   the type checker whether each declared value is general enough.  They bind
   names nothing can mention, and elimination drops them once they have done
   their work. *)
let match_signature ~what body structure =
  let assignments =
    List.map
      (fun name ->
        match Ident.Map.find_opt name structure.types with
        | Some internal -> (name, Types.Named internal)
        | None -> fail "%s does not match its signature: it has no type `%s`" what name)
      body.abstract
  in
  let checks =
    List.map
      (fun (name, declared) ->
        match Ident.Map.find_opt name structure.values with
        | None -> fail "%s does not match its signature: it has no value `%s`" what name
        | Some internal ->
          fun rest ->
            let check = Annot (Var internal, substitute assignments declared) in
            let check = match !position with Some p -> At (p, check) | None -> check in
            Let ((Ident.fresh "signature", Types.fresh_var ()), check, rest))
      body.declared
  in
  (* What the signature lets through: its own names, and none of the
     constructors, which is what makes a sealed type abstract. *)
  let view =
    List.fold_left
      (fun acc (name, t) ->
        let internal = match t with Types.Named n -> n | _ -> assert false in
        { acc with types = Ident.Map.add name internal acc.types })
      { empty with modules = structure.modules }
      assignments
  in
  let view =
    List.fold_left
      (fun acc (name, _) -> bind_value name (Ident.Map.find name structure.values) acc)
      view body.declared
  in
  (checks, view)

let compose wraps body = List.fold_right (fun wrap acc -> wrap acc) wraps body

(* Register a run of type declarations.  Their names are bound first, so that
   the declarations may refer to one another and to themselves. *)
let declare_types scope prefix decls =
  let qualify name = if prefix = "" then name else prefix ^ "." ^ name in
  let scope =
    List.fold_left
      (fun scope (d : type_decl) ->
        { scope with types = Ident.Map.add d.tname (Ident.fresh (qualify d.tname)) scope.types })
      scope decls
  in
  List.fold_left
    (fun scope (d : type_decl) ->
      let internal = Ident.Map.find d.tname scope.types in
      let constructors =
        List.map
          (fun (cname, args) ->
            let where = Printf.sprintf "in the declaration of `%s`" d.tname in
            (Ident.fresh (qualify cname), List.map (resolve_type ~where scope) args))
          d.tconstrs
      in
      Datatype.declare internal constructors;
      List.fold_left2
        (fun scope (cname, _) (internal_c, _) ->
          { scope with constructors = Ident.Map.add cname internal_c scope.constructors })
        scope d.tconstrs constructors)
    scope decls

let rec resolve_exp scope exp =
  let recur = resolve_exp scope in
  match exp with
  | At (p, e) ->
    let saved = !position in
    position := Some p;
    let e = resolve_exp scope e in
    position := saved;
    At (p, e)
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
  | Type_decl _ ->
    (* A run of declarations, so that they may be mutually recursive. *)
    let rec gather acc = function
      | Type_decl (d, rest) -> gather (d :: acc) rest
      | rest -> (List.rev acc, rest)
    in
    let decls, rest = gather [] exp in
    resolve_exp (declare_types scope "" decls) rest
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
  | Constr (name, args) ->
    let internal = find_constructor scope name in
    Constr (internal, List.map recur (flatten_constructor_args internal args))
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
          let pat = resolve_pattern scope case.pat in
          let bound = List.map fst (pattern_vars pat) in
          { pat; action = resolve_exp (bind_locals bound scope) case.action })
        cases
    in
    Match (info, recur scrutinee, cases)
  | Field _ | Match_failure _ ->
    failwith "Modules: compiler-generated node reached name resolution"

(* `Node (l, v, r)` reaches here as one parenthesized tuple; a constructor of
   matching arity takes the components as its arguments, as in OCaml. *)
and flatten_constructor_args internal args =
  let arity = List.length (Datatype.constr_exn internal).Datatype.arg_types in
  match args with
  | [ Tuple es ] when arity = List.length es && arity <> 1 -> es
  | _ -> args

and resolve_pattern scope pat =
  match pat with
  | Pwild _ | Pvar _ | Pint _ | Pbool _ | Punit | Pnil -> pat
  | Ptuple ps -> Ptuple (List.map (resolve_pattern scope) ps)
  | Pcons (head, tail) -> Pcons (resolve_pattern scope head, resolve_pattern scope tail)
  | Pconstr (name, ps) ->
    let internal = find_constructor scope name in
    let arity = List.length (Datatype.constr_exn internal).Datatype.arg_types in
    let ps =
      match ps with
      | [ Ptuple inner ] when arity = List.length inner && arity <> 1 -> inner
      | _ -> ps
    in
    Pconstr (internal, List.map (resolve_pattern scope) ps)

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
    let body = resolve_signature scope signature in
    let checks, sealed =
      match_signature ~what:(Printf.sprintf "the module `%s`" prefix) body structure
    in
    (Structure sealed, fun rest -> wrap (compose checks rest))
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
    (* The body may only see what the signature declares, so that a functor
       which happens to work with one argument does not quietly depend on
       something the next argument lacks.  A `type t` in the signature reaches
       the body with the argument's type but without its constructors, which is
       what makes it abstract there. *)
    let checks, parameter_view =
      match_signature
        ~what:(Printf.sprintf "the argument of `%s`" (show_path functor_path))
        (resolve_signature scope definition.parameter_sig)
        argument_scope
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
  (* Types are bound before anything else in the structure, so that the order
     of declarations inside a `struct` does not matter to them. *)
  let type_decls = List.filter_map (function Item_type d -> Some d | _ -> None) items in
  if type_decls <> [] then begin
    let declared = declare_types !inside prefix type_decls in
    inside := declared;
    exports :=
      {
        !exports with
        types =
          List.fold_left
            (fun acc (d : type_decl) ->
              Ident.Map.add d.tname (Ident.Map.find d.tname declared.types) acc)
            (!exports).types type_decls;
        constructors =
          List.fold_left
            (fun acc (d : type_decl) ->
              List.fold_left
                (fun acc (cname, _) ->
                  Ident.Map.add cname (Ident.Map.find cname declared.constructors) acc)
                acc d.tconstrs)
            (!exports).constructors type_decls;
      }
  end;
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
      | Item_type _ -> () (* already registered above *)
      | Item_open path -> inside := merge !inside (find_structure !inside path))
    items;
  (!exports, !wrap)

let resolve exp = resolve_exp empty exp
