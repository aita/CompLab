(* Printing machine code.

   The listing is the machine's own documentation: every dump in the book comes
   out of this file, and the tests compare against it.  So it says everything a
   reader has to know to follow the code by hand — the constant behind a [Const],
   the name behind a function id — as a comment after the instruction, and never
   anything that depends on the run. *)

let show_source = function
  | Machine.FromLocal i -> Printf.sprintf "local %d" i
  | Machine.FromCapture i -> Printf.sprintf "capture %d" i

let show_sources sources =
  "[" ^ String.concat ", " (Array.to_list (Array.map show_source sources)) ^ "]"

let show_instr (instr : Machine.instr) =
  match instr with
  | Machine.Const i -> Printf.sprintf "Const %d" i
  | Machine.ConstUnit -> "ConstUnit"
  | Machine.ConstBool v -> Printf.sprintf "ConstBool %b" v
  | Machine.LoadLocal i -> Printf.sprintf "LoadLocal %d" i
  | Machine.StoreLocal i -> Printf.sprintf "StoreLocal %d" i
  | Machine.InitLocal i -> Printf.sprintf "InitLocal %d" i
  | Machine.LoadCapture i -> Printf.sprintf "LoadCapture %d" i
  | Machine.Pop -> "Pop"
  | Machine.Dup -> "Dup"
  | Machine.AddI64 -> "AddI64"
  | Machine.SubI64 -> "SubI64"
  | Machine.MulI64 -> "MulI64"
  | Machine.DivI64 -> "DivI64"
  | Machine.ModI64 -> "ModI64"
  | Machine.NegI64 -> "NegI64"
  | Machine.EqI64 -> "EqI64"
  | Machine.NeI64 -> "NeI64"
  | Machine.LtI64 -> "LtI64"
  | Machine.LeI64 -> "LeI64"
  | Machine.GtI64 -> "GtI64"
  | Machine.GeI64 -> "GeI64"
  | Machine.MakeTuple n -> Printf.sprintf "MakeTuple %d" n
  | Machine.TupleGet i -> Printf.sprintf "TupleGet %d" i
  | Machine.MakeClosure (id, sources) ->
      Printf.sprintf "MakeClosure %d %s" id (show_sources sources)
  | Machine.Jump target -> Printf.sprintf "Jump %d" target
  | Machine.JumpIfFalse target -> Printf.sprintf "JumpIfFalse %d" target
  | Machine.Call arity -> Printf.sprintf "Call %d" arity
  | Machine.ReturnCall arity -> Printf.sprintf "ReturnCall %d" arity
  | Machine.CallStatic (id, arity) -> Printf.sprintf "CallStatic %d %d" id arity
  | Machine.ReturnCallStatic (id, arity) ->
      Printf.sprintf "ReturnCallStatic %d %d" id arity
  | Machine.Return -> "Return"
  | Machine.Trap error ->
      Printf.sprintf "Trap \"%s\"" (Machine.error_message error)

let function_name (program : Machine.program) id =
  if id < 0 || id >= Array.length program.Machine.functions then "?"
  else
    match program.Machine.functions.(id).Machine.name with
    | Some name -> name
    | None -> "anonymous"

(* What the instruction is really doing, when the number alone does not say. *)
let comment (program : Machine.program) (f : Machine.func) (instr : Machine.instr) =
  match instr with
  | Machine.Const i when i < Array.length f.Machine.constants -> (
      match f.Machine.constants.(i) with
      | Machine.VClosure c ->
          Some (Printf.sprintf "fn %s" (function_name program c.Machine.function_id))
      | value -> Some (Machine.show_value value))
  | Machine.MakeClosure (id, _)
  | Machine.CallStatic (id, _)
  | Machine.ReturnCallStatic (id, _) ->
      Some (function_name program id)
  | _ -> None

let show_func (program : Machine.program) id =
  let f = program.Machine.functions.(id) in
  let buf = Buffer.create 256 in
  let name = match f.Machine.name with Some n -> n | None -> "anonymous" in
  Buffer.add_string buf
    (Printf.sprintf
       "function %d %s: arity %d, locals %d, captures %d, stack %d\n" id name
       f.Machine.arity f.Machine.local_count f.Machine.capture_count
       f.Machine.max_stack);
  Array.iteri
    (fun i value ->
      Buffer.add_string buf
        (Printf.sprintf "  constant %d = %s\n" i (Machine.show_value value)))
    f.Machine.constants;
  Array.iteri
    (fun pc instr ->
      let text = show_instr instr in
      match comment program f instr with
      | Some note ->
          Buffer.add_string buf
            (Printf.sprintf "  %4d  %-28s ; %s\n" pc text note)
      | None -> Buffer.add_string buf (Printf.sprintf "  %4d  %s\n" pc text))
    f.Machine.code;
  Buffer.contents buf

let show_program (program : Machine.program) =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf (Printf.sprintf "entry %d\n" program.Machine.entry);
  Array.iteri
    (fun id _ ->
      Buffer.add_char buf '\n';
      Buffer.add_string buf (show_func program id))
    program.Machine.functions;
  Buffer.contents buf
