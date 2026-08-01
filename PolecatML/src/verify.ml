(* The verifier.

   The machine is a compilation target, and a compilation target that trusts its
   input has no way to tell a compiler bug from a program bug.  So before a
   program runs, every instruction is checked against the function it sits in:
   that its operands are in range, that its jumps land on instructions, and —
   the only part that is not a bounds check — that the operand stack has the same
   height on every path to every instruction.

   That last one is what makes the stack discipline a static property.  If two
   paths reach an instruction with different heights then "the second operand of
   this add" means different things depending on how control got there, and no
   amount of running the program will tell you which was meant.  A compiler that
   is right never does it, which is exactly why it is worth checking.

   The height walk also answers [max_stack], so the compiler asks this file for
   the number rather than counting as it emits. *)

type failure = { fid : int; pc : int; message : string }

exception Bad of failure

let fail fid pc fmt =
  Printf.ksprintf (fun message -> raise (Bad { fid; pc; message })) fmt

let show ~(program : Machine.program) failure =
  let f = program.Machine.functions.(failure.fid) in
  let name = match f.Machine.name with Some n -> n | None -> "?" in
  Printf.sprintf "function %d (%s), instruction %d: %s" failure.fid name
    failure.pc failure.message

(* How many operands an instruction takes and leaves.  [None] means it does not
   fall through to the next instruction. *)
let stack_effect (instr : Machine.instr) =
  match instr with
  | Machine.Const _ | Machine.ConstUnit | Machine.ConstBool _ -> Some (0, 1)
  | Machine.LoadLocal _ | Machine.LoadCapture _ -> Some (0, 1)
  | Machine.StoreLocal _ -> Some (1, 1)
  | Machine.InitLocal _ -> Some (1, 0)
  | Machine.Pop -> Some (1, 0)
  | Machine.Dup -> Some (1, 2)
  | Machine.AddI64 | Machine.SubI64 | Machine.MulI64 | Machine.DivI64
  | Machine.ModI64 ->
      Some (2, 1)
  | Machine.NegI64 -> Some (1, 1)
  | Machine.EqI64 | Machine.NeI64 | Machine.LtI64 | Machine.LeI64 | Machine.GtI64
  | Machine.GeI64 ->
      Some (2, 1)
  | Machine.MakeTuple n -> Some (n, 1)
  | Machine.TupleGet _ -> Some (1, 1)
  | Machine.MakeClosure _ -> Some (0, 1)
  | Machine.Jump _ -> Some (0, 0)
  | Machine.JumpIfFalse _ -> Some (1, 0)
  | Machine.Call n -> Some (n + 1, 1)
  | Machine.CallStatic (_, n) -> Some (n, 1)
  | Machine.Return | Machine.ReturnCall _ | Machine.ReturnCallStatic _
  | Machine.Trap _ ->
      None

let successors pc (instr : Machine.instr) =
  match instr with
  | Machine.Jump target -> [ target ]
  | Machine.JumpIfFalse target -> [ target; pc + 1 ]
  | Machine.Return | Machine.ReturnCall _ | Machine.ReturnCallStatic _
  | Machine.Trap _ ->
      []
  | _ -> [ pc + 1 ]

(* The height of the operand stack above the frame's base, before each
   instruction.  [None] where control cannot reach.  Unreachable code is not an
   error — nothing is claimed about it — but falling off the end is. *)
let heights fid (f : Machine.func) =
  let n = Array.length f.Machine.code in
  if n = 0 then fail fid 0 "a function needs at least one instruction";
  let before = Array.make n (-1) in
  let rec walk pc height =
    if pc < 0 || pc >= n then fail fid pc "control leaves the code";
    if before.(pc) >= 0 then (
      if before.(pc) <> height then
        fail fid pc
          "the operand stack is %d deep on one path here and %d on another"
          before.(pc) height)
    else (
      before.(pc) <- height;
      let instr = f.Machine.code.(pc) in
      (match stack_effect instr with
      | None -> ()
      | Some (pops, pushes) ->
          if height < pops then
            fail fid pc "this needs %d operand(s) and only %d are there" pops height;
          let height = height - pops + pushes in
          List.iter (fun target -> walk target height) (successors pc instr));
      match instr with
      | Machine.Return ->
          if height <> 1 then
            fail fid pc "a return needs exactly its result on the stack, not %d"
              height
      | Machine.ReturnCall arity ->
          if height <> arity + 1 then
            fail fid pc
              "a tail call of %d argument(s) needs the callee and its arguments \
               and nothing else, but the stack is %d deep"
              arity height
      | Machine.ReturnCallStatic (_, arity) ->
          if height <> arity then
            fail fid pc
              "a static tail call of %d argument(s) needs its arguments and \
               nothing else, but the stack is %d deep"
              arity height
      | _ -> ())
  in
  walk 0 0;
  before

let max_stack fid (f : Machine.func) =
  let before = heights fid f in
  let best = ref 0 in
  Array.iteri
    (fun pc height ->
      if height >= 0 then
        match stack_effect f.Machine.code.(pc) with
        | Some (pops, pushes) -> best := max !best (max height (height - pops + pushes))
        | None -> best := max !best height)
    before;
  !best

(* Everything that is not about heights: indices, targets, and the arity of a
   call whose callee is known. *)
let check_operands (program : Machine.program) fid (f : Machine.func) =
  let n = Array.length f.Machine.code in
  let function_at pc id =
    if id < 0 || id >= Array.length program.Machine.functions then
      fail fid pc "there is no function %d" id;
    program.Machine.functions.(id)
  in
  Array.iteri
    (fun pc instr ->
      let local i =
        if i < 0 || i >= f.Machine.local_count then
          fail fid pc "there is no local %d (this function has %d)" i
            f.Machine.local_count
      in
      let capture i =
        if i < 0 || i >= f.Machine.capture_count then
          fail fid pc "there is no capture %d (this function has %d)" i
            f.Machine.capture_count
      in
      let target t =
        if t < 0 || t >= n then fail fid pc "%d is not an instruction here" t
      in
      match (instr : Machine.instr) with
      | Machine.Const i ->
          if i < 0 || i >= Array.length f.Machine.constants then
            fail fid pc "there is no constant %d" i
      | Machine.LoadLocal i | Machine.StoreLocal i | Machine.InitLocal i -> local i
      | Machine.LoadCapture i -> capture i
      | Machine.MakeTuple width ->
          if width < 0 then fail fid pc "a tuple cannot have %d fields" width
      | Machine.TupleGet i ->
          if i < 0 then fail fid pc "a tuple has no field %d" i
      | Machine.MakeClosure (id, sources) ->
          let callee = function_at pc id in
          if Array.length sources <> callee.Machine.capture_count then
            fail fid pc "function %d captures %d value(s), not %d" id
              callee.Machine.capture_count (Array.length sources);
          Array.iter
            (function
              | Machine.FromLocal i -> local i | Machine.FromCapture i -> capture i)
            sources
      | Machine.Jump t | Machine.JumpIfFalse t -> target t
      | Machine.Call arity | Machine.ReturnCall arity ->
          if arity < 0 then fail fid pc "a call cannot take %d arguments" arity
      | Machine.CallStatic (id, arity) | Machine.ReturnCallStatic (id, arity) ->
          let callee = function_at pc id in
          if callee.Machine.capture_count <> 0 then
            fail fid pc "function %d captures values and cannot be called statically"
              id;
          if callee.Machine.arity <> arity then
            fail fid pc "function %d takes %d argument(s), not %d" id
              callee.Machine.arity arity
      | _ -> ())
    f.Machine.code

let func program fid f =
  check_operands program fid f;
  let needed = max_stack fid f in
  if f.Machine.local_count < f.Machine.arity then
    fail fid 0 "a function with %d argument(s) needs at least that many locals"
      f.Machine.arity;
  if f.Machine.max_stack < needed then
    fail fid 0 "this function says it needs %d stack slot(s) but uses %d"
      f.Machine.max_stack needed

let program (program : Machine.program) =
  try
    let functions = program.Machine.functions in
    if program.Machine.entry < 0 || program.Machine.entry >= Array.length functions
    then fail 0 0 "the entry function does not exist";
    let entry = functions.(program.Machine.entry) in
    if entry.Machine.arity <> 0 || entry.Machine.capture_count <> 0 then
      fail program.Machine.entry 0
        "the entry function takes no arguments and captures nothing";
    Array.iteri (fun fid f -> func program fid f) functions;
    Ok ()
  with Bad failure -> Error failure
