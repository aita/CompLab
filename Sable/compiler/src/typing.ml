(* Hindley--Milner type inference, without generalization.

   Unification is destructive (see Types.unify), so checking is a single
   bottom-up walk that fills in the type variables the parser attached to every
   binder, pattern and `match`.  The later passes read those variables back:
   Match_compile in particular needs the scrutinee type to know which
   constructors a column can hold. *)

open Syntax

exception Error of string

let fail fmt = Printf.ksprintf (fun msg -> raise (Error msg)) fmt

(* Functions provided by the runtime.  A name that is neither bound locally nor
   listed here is a genuine unbound-variable error rather than an implicitly
   declared external. *)
let externals =
  [
    ("print_int", Types.Fun ([ Types.Int ], Types.Unit));
    ("print_char", Types.Fun ([ Types.Int ], Types.Unit));
    ("print_newline", Types.Fun ([ Types.Unit ], Types.Unit));
    ("read_int", Types.Fun ([ Types.Unit ], Types.Int));
  ]

(* A comparison compiles to a single machine-word comparison, so it is only
   meaningful on unboxed types.  The operand type is often still an unresolved
   variable when we meet it, so record it and check once everything is known. *)
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

(* Bindings introduced by a pattern, checked against the type the scrutinee
   column must have. *)
let rec infer_pattern pat expected =
  match pat with
  | Pwild t ->
    unify_in "in a `_` pattern" expected t;
    []
  | Pvar (x, t) ->
    unify_in (Printf.sprintf "in the pattern variable `%s`" x) expected t;
    [ (x, t) ]
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
  | Pconstr (name, ps) ->
    let c = lookup_constr name in
    check_arity name (List.length c.Datatype.arg_types) (List.length ps);
    unify_in
      (Printf.sprintf "in the pattern `%s`" name)
      expected
      (Types.Named c.Datatype.owner);
    List.concat (List.map2 infer_pattern ps c.Datatype.arg_types)

let check_linear pat bindings =
  let rec dup seen = function
    | [] -> None
    | (x, _) :: rest -> if List.mem x seen then Some x else dup (x :: seen) rest
  in
  match dup [] bindings with
  | Some x ->
    fail "the variable `%s` is bound twice in the pattern `%s`" x
      (string_of_pattern pat)
  | None -> ()

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
    deferred_comparisons := (t1, string_of_cmp op) :: !deferred_comparisons;
    Types.Bool
  | If (cond, e1, e2) ->
    unify_in "in the condition of `if`" Types.Bool (infer_exp env cond);
    let t1 = infer_exp env e1 in
    unify_in "between the branches of `if`" t1 (infer_exp env e2);
    t1
  | Let ((x, t), e1, e2) ->
    unify_in (Printf.sprintf "in the definition of `%s`" x) t (infer_exp env e1);
    infer_exp (Ident.Map.add x t env) e2
  | Var x -> (
    match Ident.Map.find_opt x env with
    | Some t -> t
    | None -> fail "unbound variable `%s`" x)
  | Let_rec (fds, body) ->
    (* Every name of the group is visible in every body, so mutual recursion
       type-checks here; whether it can be compiled is Closure's business. *)
    let env =
      List.fold_left
        (fun env fd -> Ident.Map.add (fst fd.name) (snd fd.name) env)
        env fds
    in
    List.iter
      (fun fd ->
        (* Arguments are passed in registers and there are only so many; a
           function that wants more should take a tuple. *)
        if List.length fd.args > Riscv.max_args then
          fail "`%s` takes %d arguments; at most %d are supported (pass a tuple)"
            (Ident.display (fst fd.name))
            (List.length fd.args) Riscv.max_args;
        let body_env =
          List.fold_left (fun env (x, t) -> Ident.Map.add x t env) env fd.args
        in
        unify_in
          (Printf.sprintf "in the body of `%s`" (fst fd.name))
          (snd fd.name)
          (Types.Fun (List.map snd fd.args, infer_exp body_env fd.body)))
      fds;
    infer_exp env body
  | App (fn, args) ->
    let tfn = infer_exp env fn in
    let targs = List.map (infer_exp env) args in
    let tres = Types.fresh_var () in
    unify_in "in a function application" tfn (Types.Fun (targs, tres));
    tres
  | Tuple es -> Types.Tuple (List.map (infer_exp env) es)
  | Let_tuple (xts, e1, e2) ->
    unify_in "in a tuple pattern" (Types.Tuple (List.map snd xts)) (infer_exp env e1);
    let env = List.fold_left (fun env (x, t) -> Ident.Map.add x t env) env xts in
    infer_exp env e2
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
    unify_in "in the scrutinee of `match`" info.scrutinee_type (infer_exp env scrutinee);
    List.iter
      (fun case ->
        let bindings = infer_pattern case.pat info.scrutinee_type in
        check_linear case.pat bindings;
        let env = List.fold_left (fun env (x, t) -> Ident.Map.add x t env) env bindings in
        unify_in "between the cases of `match`" info.result_type (infer_exp env case.action))
      cases;
    info.result_type
  | Field _ | Match_failure _ ->
    failwith "Typing: compiler-generated node reached the type checker"

let check exp =
  Datatype.check_wellformed ();
  deferred_comparisons := [];
  let env =
    List.fold_left (fun env (x, t) -> Ident.Map.add x t env) Ident.Map.empty externals
  in
  let t = infer_exp env exp in
  unify_in "at the top level (a program must have type unit)" Types.Unit t;
  List.iter
    (fun (t, op) ->
      match Types.resolve t with
      | Types.Int | Types.Bool | Types.Unit -> ()
      | t ->
        fail "`%s` cannot compare values of type %s (only int, bool and unit)" op
          (Types.to_string t))
    !deferred_comparisons;
  exp
