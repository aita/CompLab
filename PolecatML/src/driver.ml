(* The pipeline, in one place.

     source
       |  Lexer, Parser
     surface tree
       |  Typecheck                        types, and every top-level name
       |  Desugar                          patterns and sugar gone, names unique
     core tree
       |  Resolve                          names become slots and captures
     resolved core
       |  Compile                          one instruction array per function
     machine code
       |  Verify                           heights, indices, targets, arities
       |  Vm                               or Eval, for the same answer twice
     value

   A program has no output of its own: it evaluates to the tuple of everything it
   bound, and printing that tuple against the types the checker inferred is the
   whole of what running one looks like. *)

type stage = Tokens | Types | Core | Anf | Resolved | Code

let stage_of_string = function
  | "tokens" -> Some Tokens
  | "types" -> Some Types
  | "core" -> Some Core
  | "anf" -> Some Anf
  | "resolved" -> Some Resolved
  | "code" -> Some Code
  | _ -> None

let stage_names = [ "tokens"; "types"; "core"; "anf"; "resolved"; "code" ]

type front = {
  types : (string * Types.t) list; (* every top-level name, in order *)
  core : Core.expr;
}

let front source =
  let decls = Parser.program source in
  let types = Typecheck.program decls in
  let core, names = Desugar.program decls in
  (* The two passes walked the same declarations and must have seen the same
     names in the same order; the printing below relies on it. *)
  if List.map fst types <> names then
    Diag.error Diag.nowhere "internal: the checker and the desugarer disagree";
  { types; core }

let compile source =
  let f = front source in
  let program = Compile.program (Resolve.program f.core) in
  (f, program)

let verify program =
  match Verify.program program with
  | Ok () -> ()
  | Error failure ->
      Diag.error Diag.nowhere "the compiled program is not well formed: %s"
        (Verify.show ~program failure)

(* `val name : type = value`, one line per top-level binding. *)
let report types values =
  let buf = Buffer.create 256 in
  List.iteri
    (fun i (name, ty) ->
      Buffer.add_string buf
        (Printf.sprintf "val %s : %s = %s\n" name (Types.show ty) (values i)))
    types;
  Buffer.contents buf

let run_stats ?(trace = false) ?(check = true) source =
  let f, program = compile source in
  if check then verify program;
  match Vm.run_stats ~trace program with
  | Error error ->
      Diag.error Diag.nowhere "the machine stopped: %s" (Machine.error_message error)
  | Ok (Machine.VTuple values, stats) ->
      (report f.types (fun i -> Machine.show_value values.(i)), stats)
  | Ok (other, _) ->
      Diag.error Diag.nowhere "internal: the program returned %s"
        (Machine.show_value other)

let run ?(trace = false) ?(check = true) source =
  fst (run_stats ~trace ~check source)

(* The same program through the A-normal form and its interpreter. *)
let interpret_anf source =
  let f = front source in
  let anf = Anf.program f.core in
  match
    try Anf_eval.program anf
    with Anf_eval.Error message ->
      Diag.error Diag.nowhere "the ANF interpreter stopped: %s" message
  with
  | Anf_eval.VTuple values -> report f.types (fun i -> Anf_eval.show values.(i))
  | other ->
      Diag.error Diag.nowhere "internal: the program returned %s"
        (Anf_eval.show other)

(* The same program through the reference evaluator.  The answer has to be the
   same text, character for character. *)
let interpret source =
  let f = front source in
  match (try Eval.program f.core with Eval.Error message ->
           Diag.error Diag.nowhere "the evaluator stopped: %s" message)
  with
  | Eval.VTuple values -> report f.types (fun i -> Eval.show values.(i))
  | other ->
      Diag.error Diag.nowhere "internal: the program returned %s" (Eval.show other)

let emit stage source =
  match stage with
  | Tokens -> Dump.tokens source
  | Types ->
      let f = front source in
      String.concat ""
        (List.map
           (fun (name, ty) -> Printf.sprintf "val %s : %s\n" name (Types.show ty))
           f.types)
  | Core -> Dump.core_program (front source).core
  | Anf -> Dump.anf_program (Anf.program (front source).core)
  | Resolved -> Dump.resolved_program (Resolve.program (front source).core)
  | Code ->
      let _, program = compile source in
      verify program;
      Disasm.show_program program
