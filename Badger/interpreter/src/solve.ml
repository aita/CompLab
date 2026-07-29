(* Resolution.

   [solve db goal barrier sk] calls [sk] once for every solution of [goal] and
   returns when there are no more.  There is no explicit choice point stack:
   OCaml's own stack holds the alternatives, and backtracking is [sk]
   returning.  What has to be explicit is the trail, so that the bindings a
   failed branch made are gone before the next one starts, and the cut, so
   that a branch can announce that the alternatives behind it are dead.

   Everything here is a control construct, and the reason they are here rather
   than in Builtins is [barrier]: `,` `;` `->` and the arms of a disjunction
   are transparent to cut, so they pass the caller's barrier down, and a cut
   under them cuts the clause they came from.  Every built-in, call/1
   included, is opaque instead. *)

let rec solve db goal barrier (sk : Engine.cont) =
  match Term.deref goal with
  | Term.Atom "true" -> sk ()
  | Term.Atom ("fail" | "false") -> ()
  | Term.Atom "!" ->
      sk ();
      (* Control has come back, so everything after this point in the
         predicate that owns [barrier] is not to be tried.  Those alternatives
         are stack frames between here and there. *)
      raise (Engine.Cut barrier)
  | Term.Struct (",", [| first; second |]) ->
      solve db first barrier (fun () -> solve db second barrier sk)
  | Term.Struct (";", [| left; right |]) -> (
      match Term.deref left with
      | Term.Struct ("->", [| condition; then_ |]) ->
          let m = Term.mark () in
          if Engine.once db condition then solve db then_ barrier sk
          else begin
            Term.undo_to m;
            solve db right barrier sk
          end
      | Term.Struct ("*->", [| condition; then_ |]) ->
          (* Soft cut: every solution of the condition is kept, but the else
             branch is only reached if there were none at all. *)
          let m = Term.mark () in
          let any = ref false in
          Engine.call_goal db condition (fun () ->
              any := true;
              solve db then_ barrier sk);
          if not !any then begin
            Term.undo_to m;
            solve db right barrier sk
          end
      | _ ->
          let m = Term.mark () in
          solve db left barrier sk;
          Term.undo_to m;
          solve db right barrier sk)
  | Term.Struct ("->", [| condition; then_ |]) ->
      let m = Term.mark () in
      if Engine.once db condition then solve db then_ barrier sk else Term.undo_to m
  | Term.Struct ("*->", [| condition; then_ |]) ->
      Engine.call_goal db condition (fun () -> solve db then_ barrier sk)
  | Term.Struct ("\\+", [| goal |]) -> if not (Engine.provable db goal) then sk ()
  | Term.Var _ -> Term.instantiation_error "call/1"
  | (Term.Int _ | Term.Float _) as t -> Term.type_error "callable" t "call/1"
  | Term.Local _ -> Term.bug "a stored clause reached solve uninstantiated"
  | goal -> (
      let indicator = Term.indicator_of goal "call/1" in
      match Builtins.find indicator with
      | Some builtin -> builtin db (Term.args_of goal) sk
      | None -> predicate db goal indicator sk)

(* A user predicate: try each clause in turn, from a copy of the clause and
   from the trail as it was when the call began. *)
and predicate db goal indicator sk =
  match Db.find db indicator with
  | None ->
      if !Flags.unknown_error then
        Term.existence_error "procedure" (Term.indicator_term indicator)
          (Printf.sprintf "%s/%d" (fst indicator) (snd indicator))
  | Some p ->
      incr Engine.inferences;
      let goal_key =
        match Term.deref goal with
        | Term.Struct (_, args) when Array.length args > 0 -> Db.key_of args.(0)
        | _ -> Db.KNone
      in
      let mark = Term.mark () in
      let my = Engine.new_barrier () in
      let depth = !Engine.trace_depth in
      Engine.port "Call" goal;
      (* Exit is the continuation being invoked, and Redo is it coming back.
         Wrapping [sk] is the only place the tracer needs to be, because that
         is the only place backtracking happens. *)
      let traced_sk () =
        Engine.trace_depth := depth;
        Engine.port "Exit" goal;
        sk ();
        Engine.port "Redo" goal;
        Engine.trace_depth := depth + 1
      in
      let sk = if !Engine.tracing then traced_sk else sk in
      let attempt (clause : Db.clause) =
        if Db.compatible clause.key goal_key then begin
          Term.undo_to mark;
          let frame = Db.frame_for clause in
          if Term.unify (Db.instantiate clause.head frame) goal then begin
            Engine.trace_depth := depth + 1;
            solve db (Db.instantiate clause.body frame) my sk;
            Engine.trace_depth := depth
          end
        end
      in
      (* The clause list is read once: a goal that asserts to or retracts from
         the predicate it is running in sees the predicate as it was. *)
      let clauses = p.clauses in
      (try List.iter attempt clauses with Engine.Cut b when b = my -> ());
      Engine.trace_depth := depth;
      Term.undo_to mark;
      Engine.port "Fail" goal

let install () = Engine.solve := solve
