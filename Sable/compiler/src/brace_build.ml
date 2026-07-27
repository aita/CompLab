(* Helpers shared by the brace form's parser.

   The brace form is a second concrete syntax for this language: everything it
   builds is ordinary Syntax, so the type checker and the whole back end are
   untouched and cannot tell which form a program was written in.  What lives
   here is the part that does not fit in a grammar action -- turning a run of
   declarations into the nested `let`s the abstract syntax wants, and working
   out which functions are really mutually recursive, since the brace form has
   no keyword to say so. *)

open Syntax

(* One declaration, in whichever place declarations may appear: the top level,
   an `object` body, or a block. *)
type decl =
  | Dval of (Ident.t * Types.t) * t
  | Dval_tuple of (Ident.t * Types.t) list * t
  | Dfun of fundef
  | Dtype of type_decl
  | Dmodule of string * module_exp
  | Dfunctor of string * string * signature * item list
  | Dinterface of string * signature
  | Dimport of string list
  | Dexpression of t (* a statement evaluated for its effect *)

let typed name = (name, Types.fresh_var ())

(* `fun f()` and `f()`: a function of no arguments takes one the body cannot
   mention, because every function here takes at least one. *)
let unit_parameter () = (Ident.fresh "unit", Types.Unit)

(* An annotation is checked by the type checker and then erased. *)
let annotate exp = function None -> exp | Some t -> Annot (exp, t)

(* `fun f(a: Int) = e` forces the parameter's type with a binding nothing can
   refer to, the same way a signature is checked. *)
let constrain_parameters params body =
  List.fold_right
    (fun (name, declared) body ->
      match declared with
      | None -> body
      | Some t -> Let ((Ident.fresh "annotation", Types.fresh_var ()), Annot (Var name, t), body))
    params body

let make_function name params result body =
  let arguments =
    match params with [] -> [ unit_parameter () ] | _ -> List.map (fun (n, _) -> typed n) params
  in
  {
    name = typed name;
    args = arguments;
    body = constrain_parameters params (annotate body result);
  }

(* Every name an expression mentions.  Shadowing is ignored, which can only
   merge more functions into a group than strictly necessary. *)
let mentioned exp =
  let names = Hashtbl.create 16 in
  let rec walk e =
    match e with
    | Var x -> Hashtbl.replace names x ()
    | Unit | Bool _ | Int _ | Str _ | Nil | Constr (_, []) | Qualified _ -> ()
    | At (_, e) | Not e | Neg e | Str_length e | Annot (e, _) | Field (e, _, _) -> walk e
    | Arith (_, a, b) | Cmp (_, a, b) | Cons (a, b) | Str_get (a, b) | Array (a, b)
    | Get (a, b) ->
      walk a; walk b
    | If (a, b, c) | Put (a, b, c) -> walk a; walk b; walk c
    | Let (_, a, b) | Let_tuple (_, a, b) -> walk a; walk b
    | App (f, args) -> walk f; List.iter walk args
    | Tuple es | Constr (_, es) -> List.iter walk es
    | Let_rec (fds, body) -> List.iter (fun fd -> walk fd.body) fds; walk body
    | Match (_, scrutinee, cases) ->
      walk scrutinee;
      List.iter (fun case -> walk case.action) cases
    | Module (_, _, body) | Module_type (_, _, body) | Open (_, body)
    | Type_decl (_, body) | Functor (_, _, _, _, body) ->
      walk body
    | Match_failure _ -> ()
  in
  walk exp;
  names

(* Adjacent functions see one another, so that mutual recursion needs no
   keyword.  But putting them all in one recursive group would make them
   monomorphic in each other, and a `length` used at two element types would
   stop working.  So the run is split into strongly connected components of the
   call graph: exactly the functions that really are mutually recursive end up
   in a group, and Tarjan's order emits each component after the ones it
   depends on. *)
let dependency_groups fundefs =
  let functions = Array.of_list fundefs in
  let count = Array.length functions in
  let index_of = Hashtbl.create 16 in
  Array.iteri (fun i fd -> Hashtbl.replace index_of (fst fd.name) i) functions;
  let calls =
    Array.map
      (fun fd ->
        let names = mentioned fd.body in
        Hashtbl.fold
          (fun name () acc ->
            match Hashtbl.find_opt index_of name with Some j -> j :: acc | None -> acc)
          names [])
      functions
  in
  let number = Array.make count (-1) in
  let low = Array.make count 0 in
  let on_stack = Array.make count false in
  let stack = ref [] in
  let next = ref 0 in
  let components = ref [] in
  let rec visit v =
    number.(v) <- !next;
    low.(v) <- !next;
    incr next;
    stack := v :: !stack;
    on_stack.(v) <- true;
    List.iter
      (fun w ->
        if number.(w) < 0 then begin
          visit w;
          low.(v) <- min low.(v) low.(w)
        end
        else if on_stack.(w) then low.(v) <- min low.(v) number.(w))
      calls.(v);
    if low.(v) = number.(v) then begin
      let rec pop acc =
        match !stack with
        | w :: rest ->
          stack := rest;
          on_stack.(w) <- false;
          if w = v then w :: acc else pop (w :: acc)
        | [] -> acc
      in
      components := pop [] :: !components
    end
  in
  for v = 0 to count - 1 do
    if number.(v) < 0 then visit v
  done;
  List.rev_map (fun component -> List.map (fun i -> functions.(i)) component) !components

let rec group_functions = function
  | [] -> []
  | Dfun _ :: _ as decls ->
    let rec span acc = function
      | Dfun fd :: rest -> span (fd :: acc) rest
      | rest -> (List.rev acc, rest)
    in
    let run, rest = span [] decls in
    List.map (fun group -> `Functions group) (dependency_groups run)
    @ group_functions rest
  | other :: rest -> `Single other :: group_functions rest

(* Declarations wrapped around a continuation: what the top level and a block
   both need. *)
let to_expression decls body =
  List.fold_right
    (fun grouped body ->
      match grouped with
      | `Functions group -> Let_rec (group, body)
      | `Single (Dval (binder, e)) -> Let (binder, e, body)
      | `Single (Dval_tuple (binders, e)) -> Let_tuple (binders, e, body)
      | `Single (Dtype decl) -> Type_decl (decl, body)
      | `Single (Dmodule (name, module_exp)) -> Module (name, module_exp, body)
      | `Single (Dfunctor (name, parameter, signature, items)) ->
        Functor (name, parameter, signature, items, body)
      | `Single (Dinterface (name, signature)) -> Module_type (name, signature, body)
      | `Single (Dimport path) -> Open (path, body)
      | `Single (Dexpression e) ->
        Let ((Ident.fresh "statement", Types.Unit), e, body)
      | `Single (Dfun _) -> assert false)
    (group_functions decls) body

let to_items decls =
  List.concat_map
    (fun grouped ->
      match grouped with
      | `Functions group -> [ Item_let_rec group ]
      | `Single (Dval (binder, e)) -> [ Item_let (binder, e) ]
      | `Single (Dval_tuple (binders, e)) -> [ Item_let_tuple (binders, e) ]
      | `Single (Dtype decl) -> [ Item_type decl ]
      | `Single (Dmodule (name, module_exp)) -> [ Item_module (name, module_exp) ]
      | `Single (Dfunctor (name, parameter, signature, items)) ->
        [ Item_functor (name, parameter, signature, items) ]
      | `Single (Dinterface (name, signature)) -> [ Item_module_type (name, signature) ]
      | `Single (Dimport path) -> [ Item_open path ]
      | `Single (Dexpression _) ->
        failwith "an object body has no place for a bare expression"
      | `Single (Dfun _) -> assert false)
    (group_functions decls)

(* A program is its declarations followed by a call to `main`. *)
let program decls = to_expression decls (App (Var "main", [ Unit ]))

let list_of elements = List.fold_right (fun e rest -> Cons (e, rest)) elements Nil
let dotted path = String.concat "." path
