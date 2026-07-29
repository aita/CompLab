(* Where a verification condition goes to be decided.

   By default it goes to solver.ml, which is built in and needs nothing
   installed.  `--smt CMD` sends it to a real solver instead, as SMT-LIB 2 on
   the standard input of `CMD` -- `--smt "z3 -in"` or `--smt "cvc5 --lang smt2"`
   -- and the answer is read back from its output.  The two backends are asked
   exactly the same question, so a goal the built-in procedure gives up on can
   be retried with a solver that will not. *)

type backend = Builtin | External of string

let backend = ref Builtin
let dump = ref false
let discharged = ref 0
let gave_up = ref 0

let ask_external cmd query =
  let out, inp = Unix.open_process cmd in
  output_string inp query;
  flush inp;
  close_out inp;
  let answer = ref "" in
  (try
     while !answer = "" do
       let line = String.trim (input_line out) in
       if line <> "" then answer := line
     done
   with End_of_file -> ());
  ignore (Unix.close_process (out, inp));
  match !answer with
  | "unsat" -> Solver.Proved
  | "sat" -> Solver.Unproved "the solver found a counterexample"
  | other -> Solver.Gave_up (Printf.sprintf "%s said %s" cmd other)

let discharge (vc : Logic.vc) =
  incr discharged;
  if !dump then (
    Printf.printf "-- %s: %s\n" (Loc.to_string vc.loc) vc.note;
    print_string (Logic.smtlib vc));
  let answer =
    match !backend with
    | Builtin -> Solver.check vc
    | External cmd -> ask_external cmd (Logic.smtlib vc)
  in
  match answer with
  | Solver.Proved -> ()
  | Solver.Unproved model ->
      Loc.fail ~where:"cannot verify" vc.loc "%s\n    %s\n    it can fail when %s"
        (Logic.show_vc vc) vc.note model
  | Solver.Gave_up why ->
      incr gave_up;
      Loc.fail ~where:"cannot verify" vc.loc
        "%s\n    %s\n    the built-in procedure gave up: %s (try --smt \"z3 -in\")"
        (Logic.show_vc vc) vc.note why
