(* The engine's shared vocabulary.

   Solving a goal is a call that invokes a continuation once per solution and
   returns when the goal has no more:

     solve db goal barrier (fun () -> ...)

   So backtracking is what happens when the continuation returns, and
   OCaml's own stack is the choice point stack.  Nothing about that is
   reversible, which is why the cut needs its own channel out.

   A cut has already produced its solutions by the time control comes back to
   it, and what it must do then is discard the alternatives its predicate
   still had.  Those alternatives are OCaml stack frames, so the cut raises
   [Cut] naming the frame that owns it, and every predicate call catches its
   own number and returns quietly.  A barrier is what makes a cut in a clause
   cut that clause's predicate and nothing outside it -- and what makes call/1
   opaque to cut, since call/1 hands its goal a barrier of its own.

   [solve] is a reference because the built-in predicates need to call back
   into the engine and are compiled before it.  Solve.install fills it in. *)

type cont = unit -> unit

exception Cut of int

let barrier_counter = ref 0

let new_barrier () =
  incr barrier_counter;
  !barrier_counter

(* How many user predicate calls have been resolved: statistics/2 reports it,
   and it is the only number that says how much work a query did. *)
let inferences = ref 0

(* ------------------------------------------------------------- the tracer *)

(* The four ports of a predicate call.  Call and Fail are the two ends of
   [Solve.predicate]; Exit is the continuation being invoked and Redo is it
   returning, which is the whole of backtracking made visible.

   Trace output goes to standard error, so that it does not mix into what the
   program prints. *)
let tracing = ref false
let trace_depth = ref 0
let show_goal : (Term.term -> string) ref = ref (fun _ -> "?")

let port name goal =
  if !tracing then begin
    let depth = !trace_depth in
    flush stdout;
    Printf.eprintf "%*s%s: (%d) %s\n" (2 * min depth 20) "" name depth (!show_goal goal);
    flush stderr
  end

let solve : (Db.t -> Term.term -> int -> cont -> unit) ref =
  ref (fun _ _ _ _ -> Term.bug "the engine was not installed")

(* Run a goal with a barrier of its own, so a cut inside it stops here.  This
   is call/1's whole implementation, and the right way for a built-in to run a
   goal it was handed. *)
let call_goal db goal sk =
  let barrier = new_barrier () in
  try !solve db goal barrier sk with Cut b when b = barrier -> ()

exception Found

(* Succeed at most once, keeping the bindings of the first solution. *)
let once db goal =
  try
    call_goal db goal (fun () -> raise Found);
    false
  with Found -> true

(* Ask whether a goal has a solution, and leave no trace of asking.  \+/1 and
   the condition of if-then-else are this. *)
let provable db goal =
  let m = Term.mark () in
  let result = once db goal in
  Term.undo_to m;
  result

(* Every solution's worth of a template, copied out before the bindings that
   produced it are undone.  findall/3 and its relatives are this. *)
let collect db goal template =
  let out = ref [] in
  let m = Term.mark () in
  call_goal db goal (fun () -> out := Term.copy_term template :: !out);
  Term.undo_to m;
  List.rev !out
