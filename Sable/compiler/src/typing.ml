(* Hindley--Milner type inference with let-polymorphism.

   Unification is destructive (see Types), so checking is a single bottom-up
   walk.  A `let` generalizes: the variables its right-hand side introduced and
   that nothing outside can constrain become quantified, and each use of the
   name gets its own copy of them.  That is what makes one compiled `length`
   work on a list of anything -- the back end needs no help, because every value
   in this language is one machine word whether it is an integer or a pointer.

   Two restrictions worth stating.  Only syntactic values are generalized, the
   usual value restriction, without which a polymorphic value held in a mutable
   array would let a program store an integer and read back a pointer.  And the
   operands of a comparison are pinned to the outermost level so that they are
   never quantified: `=` compiles to a single machine comparison, so it has to
   settle on a type this compiler can compare that way.

   The type variables the parser attached to binders are written, never unified
   against; see the note in Types. *)

open Syntax

exception Error of string

let fail fmt = Printf.ksprintf (fun msg -> raise (Error msg)) fmt

(* Functions provided by the runtime.  A name that is neither bound locally nor
   listed here is a genuine unbound-variable error rather than an implicitly
   declared external.  All of them are monomorphic. *)
let externals =
  [
    ("print_int", Types.Fun ([ Types.Int ], Types.Unit));
    ("print_char", Types.Fun ([ Types.Int ], Types.Unit));
    ("print_newline", Types.Fun ([ Types.Unit ], Types.Unit));
    ("read_int", Types.Fun ([ Types.Unit ], Types.Int));
    ("print_string", Types.Fun ([ Types.String ], Types.Unit));
    ("string_concat", Types.Fun ([ Types.String; Types.String ], Types.String));
    ("string_equal", Types.Fun ([ Types.String; Types.String ], Types.Bool));
  ]

(* A comparison compiles to one machine-word comparison, so it is only
   meaningful on unboxed types.  The operand type is often still a variable
   when we meet it, so record it and check once everything is known. *)
let deferred_comparisons : (Types.t * string) list ref = ref []

let unify_in where expected actual =
  try Types.unify expected actual with
  | Types.Unify _ ->
    fail "type error %s:\n  expected: %s\n  but got:  %s" where
      (Types.to_string expected) (Types.to_string actual)

let lookup_constr name =
  match Datatype.find_constr name with
  | Some c -> c
  | None -> fail "unknown constructor `%s`" name

let check_arity name expected got =
  if expected <> got then
    fail "the constructor `%s` expects %d argument(s) but is given %d" name expected got

(* Generalizing an arbitrary expression is unsound once mutable state is in the
   language, so only these are generalized.  `fun x -> e` reaches here as a
   one-shot `let rec` whose body is the function's own name. *)
let rec is_value = function
  | Unit | Bool _ | Int _ | Str _ | Var _ | Nil -> true
  | Cons (head, tail) -> is_value head && is_value tail
  | Tuple es -> List.for_all is_value es
  | Constr (_, es) -> List.for_all is_value es
  | Let_rec (_, body) -> is_value body
  | _ -> false

(* What a pattern binds, and the type each column must have.  A pattern
   variable simply takes the type of the value it stands for. *)
let rec infer_pattern pat expected =
  match pat with
  | Pwild slot ->
    Types.assign slot expected;
    []
  | Pvar (x, slot) ->
    Types.assign slot expected;
    [ (x, expected) ]
  | Pint _ ->
    unify_in "in an integer pattern" expected Types.Int;
    []
  | Pbool _ ->
    unify_in "in a boolean pattern" expected Types.Bool;
    []
  | Punit ->
    unify_in "in a `()` pattern" expected Types.Unit;
    []
  | Ptuple ps ->
    let ts = List.map (fun _ -> Types.fresh_var ()) ps in
    unify_in "in a tuple pattern" expected (Types.Tuple ts);
    List.concat (List.map2 infer_pattern ps ts)
  | Pnil ->
    unify_in "in a `[]` pattern" expected (Types.List (Types.fresh_var ()));
    []
  | Pcons (head, tail) ->
    let element = Types.fresh_var () in
    unify_in "in a `::` pattern" expected (Types.List element);
    infer_pattern head element @ infer_pattern tail expected
  | Pconstr (name, ps) ->
    let c = lookup_constr name in
    check_arity name (List.length c.Datatype.arg_types) (List.length ps);
    unify_in
      (Printf.sprintf "in the pattern `%s`" name)
      expected
      (Types.Named c.Datatype.owner);
    List.concat (List.map2 infer_pattern ps c.Datatype.arg_types)

let check_linear pat bindings =
  let rec duplicate seen = function
    | [] -> None
    | (x, _) :: rest -> if List.mem x seen then Some x else duplicate (x :: seen) rest
  in
  match duplicate [] bindings with
  | Some x ->
    fail "the variable `%s` is bound twice in the pattern `%s`" x (string_of_pattern pat)
  | None -> ()

let bind_all bindings env =
  List.fold_left (fun env (x, t) -> Ident.Map.add x (Types.monomorphic t) env) env bindings

let rec infer_exp env exp =
  match exp with
  | Unit -> Types.Unit
  | Bool _ -> Types.Bool
  | Int _ -> Types.Int
  | Not e ->
    unify_in "in the argument of `not`" Types.Bool (infer_exp env e);
    Types.Bool
  | Neg e ->
    unify_in "in the argument of unary `-`" Types.Int (infer_exp env e);
    Types.Int
  | Arith (op, e1, e2) ->
    let where = Printf.sprintf "in an operand of `%s`" (string_of_arith op) in
    unify_in where Types.Int (infer_exp env e1);
    unify_in where Types.Int (infer_exp env e2);
    Types.Int
  | Cmp (op, e1, e2) ->
    let where = Printf.sprintf "in the operands of `%s`" (string_of_cmp op) in
    let t1 = infer_exp env e1 in
    let t2 = infer_exp env e2 in
    unify_in where t1 t2;
    (* Never quantify what a comparison rests on. *)
    Types.pin t1;
    deferred_comparisons := (t1, string_of_cmp op) :: !deferred_comparisons;
    Types.Bool
  | If (cond, e1, e2) ->
    unify_in "in the condition of `if`" Types.Bool (infer_exp env cond);
    let t1 = infer_exp env e1 in
    unify_in "between the branches of `if`" t1 (infer_exp env e2);
    t1
  | Let ((x, slot), e1, e2) ->
    Types.enter_level ();
    let t1 = infer_exp env e1 in
    Types.leave_level ();
    let scheme = if is_value e1 then Types.generalize t1 else Types.monomorphic t1 in
    Types.assign slot t1;
    infer_exp (Ident.Map.add x scheme env) e2
  | Var x -> (
    match Ident.Map.find_opt x env with
    | Some scheme -> Types.instantiate scheme
    | None -> fail "unbound variable `%s`" x)
  | Let_rec (fds, body) -> infer_letrec env fds body
  | App (fn, args) ->
    let tfn = infer_exp env fn in
    let targs = List.map (infer_exp env) args in
    let tresult = Types.fresh_var () in
    unify_in "in a function application" tfn (Types.Fun (targs, tresult));
    tresult
  | Tuple es -> Types.Tuple (List.map (infer_exp env) es)
  | Let_tuple (xts, e1, e2) ->
    let ts = List.map (fun _ -> Types.fresh_var ()) xts in
    unify_in "in a tuple pattern" (Types.Tuple ts) (infer_exp env e1);
    List.iter2 (fun (_, slot) t -> Types.assign slot t) xts ts;
    infer_exp (bind_all (List.map2 (fun (x, _) t -> (x, t)) xts ts) env) e2
  | Array (size, init) ->
    unify_in "in the size of `Array.make`" Types.Int (infer_exp env size);
    Types.Array (infer_exp env init)
  | Get (arr, idx) ->
    let elt = Types.fresh_var () in
    unify_in "in an array access" (Types.Array elt) (infer_exp env arr);
    unify_in "in an array index" Types.Int (infer_exp env idx);
    elt
  | Put (arr, idx, v) ->
    let elt = infer_exp env v in
    unify_in "in an array assignment" (Types.Array elt) (infer_exp env arr);
    unify_in "in an array index" Types.Int (infer_exp env idx);
    Types.Unit
  | Str _ -> Types.String
  | Str_length e ->
    unify_in "in the argument of `String.length`" Types.String (infer_exp env e);
    Types.Int
  | Str_get (s, i) ->
    unify_in "in a string access" Types.String (infer_exp env s);
    unify_in "in a string index" Types.Int (infer_exp env i);
    Types.Int
  | Nil -> Types.List (Types.fresh_var ())
  | Cons (head, tail) ->
    let element = infer_exp env head in
    unify_in "in the tail of `::`" (Types.List element) (infer_exp env tail);
    Types.List element
  | Constr (name, args) ->
    let c = lookup_constr name in
    check_arity name (List.length c.Datatype.arg_types) (List.length args);
    List.iteri
      (fun i (arg, t) ->
        unify_in
          (Printf.sprintf "in argument %d of `%s`" (i + 1) name)
          t (infer_exp env arg))
      (List.combine args c.Datatype.arg_types);
    Types.Named c.Datatype.owner
  | Match (info, scrutinee, cases) ->
    let tscrutinee = infer_exp env scrutinee in
    let tresult = Types.fresh_var () in
    List.iter
      (fun case ->
        let bindings = infer_pattern case.pat tscrutinee in
        check_linear case.pat bindings;
        unify_in "between the cases of `match`" tresult
          (infer_exp (bind_all bindings env) case.action))
      cases;
    Types.assign info.scrutinee_type tscrutinee;
    Types.assign info.result_type tresult;
    tresult
  | Qualified _ | Module _ | Open _ ->
    failwith "Typing: modules should have been resolved away by Modules"
  | Field _ | Match_failure _ ->
    failwith "Typing: compiler-generated node reached the type checker"

(* A whole `let rec ... and ...` group.  Inside the group the names stay
   monomorphic -- polymorphic recursion is not inferable -- and each becomes a
   scheme once the group has been checked. *)
and infer_letrec env fds body =
  Types.enter_level ();
  let selves = List.map (fun fd -> (fst fd.name, Types.fresh_var ())) fds in
  let group_env =
    List.fold_left (fun env (x, t) -> Ident.Map.add x (Types.monomorphic t) env) env selves
  in
  List.iter2
    (fun fd (_, self) ->
      (* Arguments are passed in registers and there are only so many; a
         function that wants more should take a tuple. *)
      if List.length fd.args > Riscv.max_args then
        fail "`%s` takes %d arguments; at most %d are supported (pass a tuple)"
          (Ident.display (fst fd.name))
          (List.length fd.args) Riscv.max_args;
      let args = List.map (fun (x, slot) -> (x, slot, Types.fresh_var ())) fd.args in
      let body_env = bind_all (List.map (fun (x, _, t) -> (x, t)) args) group_env in
      let tbody = infer_exp body_env fd.body in
      unify_in
        (Printf.sprintf "in the body of `%s`" (Ident.display (fst fd.name)))
        self
        (Types.Fun (List.map (fun (_, _, t) -> t) args, tbody));
      List.iter (fun (_, slot, t) -> Types.assign slot t) args)
    fds selves;
  Types.leave_level ();
  let env =
    List.fold_left2
      (fun env fd (_, self) ->
        Types.assign (snd fd.name) self;
        Ident.Map.add (fst fd.name) (Types.generalize self) env)
      env fds selves
  in
  infer_exp env body

let check exp =
  Datatype.check_wellformed ();
  deferred_comparisons := [];
  let env =
    List.fold_left
      (fun env (x, t) -> Ident.Map.add x (Types.monomorphic t) env)
      Ident.Map.empty externals
  in
  let t = infer_exp env exp in
  unify_in "at the top level (a program must have type unit)" Types.Unit t;
  List.iter
    (fun (t, op) ->
      match Types.resolve t with
      | Types.Int | Types.Bool | Types.Unit -> ()
      | Types.String ->
        fail "`%s` cannot compare strings; use `String.equal`" op
      | t ->
        fail
          "`%s` cannot compare values of type %s.\n\
           Only int, bool and unit compare as a single machine word." op
          (Types.to_string t))
    !deferred_comparisons;
  exp
