(* A-normal form, and the pass that puts the core tree into it.

   Two rules make a program A-normal.  Every operand is an *atom* — a constant or
   a name, never a computation — so nothing is nested inside anything that
   computes.  And every intermediate result is named by a `let`, so the order the
   program is evaluated in is the order it is written in, and a `let` is where
   the interpreter has to think about anything at all.

   That is a stronger claim than the core tree makes, and it is the same claim
   the stack machine makes about its code: an operand is on the stack before the
   instruction that reads it runs.  ANF names those operands where the machine
   numbers them.  The compiler in this project does not go through this form —
   the code generator walks the resolved core tree, and the operand stack does
   what a name would have done — so what is here is a second reading of the same
   language, and `Anf_eval` runs it.

   The interesting case is `if`.  A branch cannot be an operand, because an
   operand has to be an atom, so `let x = if c then a else b in rest` cannot be
   written in this form at all.  A-normalisation's usual answer is to push the
   continuation into both branches, which writes `rest` out twice — and `andalso`
   is an `if` here, so a line of ordinary boolean arithmetic would double the
   rest of the program once per operator.  The answer that does not is a *join
   point*: `rest` is named, both branches jump to the name, and the jump is not a
   call — it takes no closure, keeps no return address, and cannot be a value.
   `Join` and `Jump` below are that, and the shape they produce is worth reading
   next to the machine's `JumpIfFalse`, which is the same idea with a number
   instead of a name. *)

type name = Core.name

type atom =
  | Int of int64
  | Bool of bool
  | Unit
  | Var of name

(* Something that computes a value, out of atoms.  The nesting stops here: no
   field of a computation is another computation. *)
type comp =
  | Atom of atom
  | Prim of Core.prim * atom list
  | Tuple of atom list
  | Proj of int * atom
  | Fn of lambda
  | App of atom * atom list

and expr =
  | Ret of comp (* the value of the enclosing function *)
  | Let of name * comp * expr
  | If of atom * expr * expr
  | Letrec of (name * lambda) list * expr
  (* [Join (j, x, body, rest)] — `join j (x) = body in rest`.  A jump to [j] from
     inside [rest] continues with [body], and there is nothing to return to. *)
  | Join of name * name * expr * expr
  | Jump of name * atom

and lambda = { lname : string option; params : name list; body : expr }

(* Where the value being computed is going.

   The first two are cheap: each is one instruction, so a branch may write either
   of them into both of its arms.  A [Bind] is not — it carries the whole rest of
   the program — and that is exactly when a join point is made instead. *)
type cont =
  | Return
  | Jump_to of name
  | Bind of name * expr

let apply k atom =
  match k with
  | Return -> Ret (Atom atom)
  | Jump_to j -> Jump (j, atom)
  | Bind (n, rest) -> Let (n, Atom atom, rest)

let bind k comp =
  match k with
  | Return -> Ret comp
  | Jump_to j ->
      let t = Core.fresh "t" in
      Let (t, comp, Jump (j, Var t))
  | Bind (n, rest) -> Let (n, comp, rest)

let rec normalize (e : Core.expr) (k : cont) =
  match e with
  | Core.Int n -> apply k (Int n)
  | Core.Bool b -> apply k (Bool b)
  | Core.Unit -> apply k Unit
  | Core.Var n -> apply k (Var n)
  | Core.Tuple es -> atoms es (fun args -> bind k (Tuple args))
  | Core.Proj (i, e) -> atom e (fun a -> bind k (Proj (i, a)))
  | Core.Prim (op, es) -> atoms es (fun args -> bind k (Prim (op, args)))
  | Core.Fn l -> bind k (Fn (lambda l))
  | Core.App (f, args) ->
      atom f (fun callee -> atoms args (fun args -> bind k (App (callee, args))))
  | Core.Let (Some n, rhs, body) -> normalize rhs (Bind (n, normalize body k))
  | Core.Let (None, rhs, body) ->
      normalize rhs (Bind (Core.fresh "ignored", normalize body k))
  | Core.Untuple (rhs, binders, body) ->
      atom rhs (fun a ->
          let rec fields i binders =
            match binders with
            | [] -> normalize body k
            | Some n :: rest -> Let (n, Proj (i, a), fields (i + 1) rest)
            (* A projection has no effect to keep, so a field nobody named is a
               field nobody reads. *)
            | None :: rest -> fields (i + 1) rest
          in
          fields 0 binders)
  | Core.Letrec (group, body) ->
      Letrec (List.map (fun (n, l) -> (n, lambda l)) group, normalize body k)
  (* The branch itself is where the continuation has to be decided. *)
  | Core.If (c, t, f) -> (
      atom c (fun a ->
          match k with
          | Return | Jump_to _ -> If (a, normalize t k, normalize f k)
          | Bind (n, rest) ->
              (* [rest] is what happens once the branch has a value, and both
                 arms need it.  Name it, and let the arms jump to it: the name is
                 the join point, and its parameter is the binding the `let`
                 was going to make anyway. *)
              let j = Core.fresh "join" in
              Join
                ( j,
                  n,
                  rest,
                  If (a, normalize t (Jump_to j), normalize f (Jump_to j)) )))

(* An operand.  Anything that is already an atom stays where it is; anything else
   is computed into a name first, and [k] is handed the name. *)
and atom (e : Core.expr) k =
  match e with
  | Core.Int n -> k (Int n)
  | Core.Bool b -> k (Bool b)
  | Core.Unit -> k Unit
  | Core.Var n -> k (Var n)
  | _ ->
      let t = Core.fresh "t" in
      normalize e (Bind (t, k (Var t)))

(* Left to right, which is the order the language evaluates in and therefore the
   order the bindings have to come out in. *)
and atoms es k =
  match es with
  | [] -> k []
  | e :: rest -> atom e (fun a -> atoms rest (fun more -> k (a :: more)))

and lambda (l : Core.lambda) =
  {
    lname = l.Core.lname;
    params = l.Core.params;
    body = normalize l.Core.body Return;
  }

let program (core : Core.expr) = normalize core Return

(* How big the form is, in nodes.  The point of the join point is that this stays
   proportional to the core tree it came from, and the tests measure it. *)
let size expr =
  let rec go expr =
    match expr with
    | Ret c -> 1 + comp c
    | Let (_, c, rest) -> 1 + comp c + go rest
    | If (_, t, f) -> 1 + go t + go f
    | Letrec (group, rest) ->
        1 + List.fold_left (fun n (_, l) -> n + go l.body) 0 group + go rest
    | Join (_, _, body, rest) -> 1 + go body + go rest
    | Jump _ -> 1
  and comp c =
    match c with
    | Atom _ -> 1
    | Prim (_, args) -> 1 + List.length args
    | Tuple args -> 1 + List.length args
    | Proj _ -> 2
    | Fn l -> 1 + go l.body
    | App (_, args) -> 2 + List.length args
  in
  go expr
