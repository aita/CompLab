(* The machine itself: fetch, do, repeat.

   The state is three things and no more — the program, the operand stack, the
   frame stack.  There is deliberately no "current function" or "current pc"
   field: those live in the top frame, and keeping a second copy of them would be
   two things that can disagree.

   [loop] is tail recursive, so a program of any length runs in constant OCaml
   stack; and the machine's own frame stack only grows for calls that are not in
   tail position, which is what [ReturnCall] is for.  Between the two, a tail
   recursive function in the source language costs nothing anywhere.

   The type errors below — [ExpectedInt] and friends — cannot happen for a
   program that came through the type checker.  They are here because the machine
   is also a target for code that did not, and because a machine that answers
   "this is not a tuple" is a better instrument than one that segfaults. *)

type t = {
  program : Machine.program;
  values : Value_stack.t;
  frames : Frame_stack.t;
  mutable steps : int;
}

(* What the run cost.  [deepest] is the whole of the tail call story: a loop
   written as tail recursion keeps it at 1, and the same loop written without
   tail calls makes it as deep as the loop is long. *)
type stats = { steps : int; deepest : int }

exception Trapped of Machine.runtime_error

let die error = raise (Trapped error)

let int_of = function Machine.VInt n -> n | _ -> die Machine.ExpectedInt
let bool_of = function Machine.VBool b -> b | _ -> die Machine.ExpectedBool
let tuple_of = function Machine.VTuple t -> t | _ -> die Machine.ExpectedTuple

let function_at vm id =
  if id < 0 || id >= Array.length vm.program.Machine.functions then
    die (Machine.InvalidFunction id);
  vm.program.Machine.functions.(id)

let push vm value = Value_stack.push vm.values value

let pop vm =
  try Value_stack.pop vm.values with Value_stack.Underflow -> die Machine.StackUnderflow

let local (frame : Frame_stack.frame) i =
  if i < 0 || i >= Array.length frame.Frame_stack.locals then
    die (Machine.InvalidLocal i);
  frame.Frame_stack.locals.(i)

let capture (frame : Frame_stack.frame) i =
  let captures = frame.Frame_stack.closure.Machine.captures in
  if i < 0 || i >= Array.length captures then die (Machine.InvalidCapture i);
  captures.(i)

(* Enter a call.  The arguments have already been taken off the operand stack.

   An ordinary call pushes a frame whose base is wherever the stack now stands;
   a tail call throws away everything this frame put on the stack, and replaces
   the frame itself — so the caller waiting below is now waiting for the callee's
   result, and there is one continuation where a naive compiler would have
   two. *)
let enter vm (closure : Machine.closure) ~arity ~drop_callee ~tail =
  let f = function_at vm closure.Machine.function_id in
  if arity <> f.Machine.arity then
    die (Machine.WrongArity { expected = f.Machine.arity; actual = arity });
  (* The arguments go straight from the operand stack into the slots they will
     be read from, youngest first, and the callee — which sits under them for a
     [Call] and nowhere for a [CallStatic] — comes off last. *)
  let locals =
    Array.make (max 1 (max f.Machine.local_count f.Machine.arity)) Machine.VUnit
  in
  for i = arity - 1 downto 0 do
    locals.(i) <- pop vm
  done;
  if drop_callee then ignore (pop vm);
  if tail then (
    let old = Frame_stack.top vm.frames in
    let stack_base = old.Frame_stack.stack_base in
    Value_stack.truncate vm.values stack_base;
    Frame_stack.replace_top vm.frames
      { Frame_stack.closure; pc = 0; locals; stack_base })
  else
    Frame_stack.push vm.frames
      {
        Frame_stack.closure;
        pc = 0;
        locals;
        stack_base = Value_stack.length vm.values;
      }

(* The calling convention puts the callee under its arguments:
   `... callee arg0 ... argN-1`.  It is read without popping, because the
   arguments have to come off first. *)
let callee_under vm arity =
  match
    try Value_stack.peek vm.values arity
    with Value_stack.Underflow -> die Machine.StackUnderflow
  with
  | Machine.VClosure c -> c
  | _ -> die Machine.NotCallable

let arith vm op =
  let rhs = int_of (pop vm) in
  let lhs = int_of (pop vm) in
  push vm (Machine.VInt (op lhs rhs))

(* [f] takes the sign of the comparison, and is monomorphic on purpose: handing
   the polymorphic `=` to a higher-order function here would call the generic
   comparison for every integer the program compares. *)
let compare_op vm (f : int -> bool) =
  let rhs = int_of (pop vm) in
  let lhs = int_of (pop vm) in
  push vm (Machine.VBool (f (Int64.compare lhs rhs)))

let divide op vm =
  let rhs = int_of (pop vm) in
  let lhs = int_of (pop vm) in
  if rhs = 0L then die Machine.DivisionByZero;
  push vm (Machine.VInt (op lhs rhs))

let trace_line vm (frame : Frame_stack.frame) pc instr =
  Printf.eprintf "%3d  %-28s | %s\n"
    frame.Frame_stack.closure.Machine.function_id
    (Printf.sprintf "%4d %s" pc (Disasm.show_instr instr))
    (String.concat " "
       (List.init (Value_stack.length vm.values) (fun i ->
            Machine.show_value
              (Value_stack.peek vm.values (Value_stack.length vm.values - 1 - i)))))

(* Fetch, then do, then fetch again.  The fetch is written out here rather than
   called: the top frame says which function is running and where in it, and
   returning those to a caller would mean building a tuple for every instruction
   the machine executes. *)
let rec loop ~trace vm =
  let frame = Frame_stack.top vm.frames in
  let f = function_at vm frame.Frame_stack.closure.Machine.function_id in
  let pc = frame.Frame_stack.pc in
  if pc < 0 || pc >= Array.length f.Machine.code then
    die Machine.InvalidProgramCounter;
  frame.Frame_stack.pc <- pc + 1;
  let instr = f.Machine.code.(pc) in
  vm.steps <- vm.steps + 1;
  if trace then trace_line vm frame pc instr;
  match instr with
  | Machine.Const i ->
      if i < 0 || i >= Array.length f.Machine.constants then
        die (Machine.InvalidConstant i);
      push vm f.Machine.constants.(i);
      loop ~trace vm
  | Machine.ConstUnit ->
      push vm Machine.VUnit;
      loop ~trace vm
  | Machine.ConstBool v ->
      push vm (Machine.VBool v);
      loop ~trace vm
  | Machine.LoadLocal i ->
      push vm (local frame i);
      loop ~trace vm
  | Machine.StoreLocal i ->
      if i < 0 || i >= Array.length frame.Frame_stack.locals then
        die (Machine.InvalidLocal i);
      frame.Frame_stack.locals.(i) <-
        (try Value_stack.peek vm.values 0
         with Value_stack.Underflow -> die Machine.StackUnderflow);
      loop ~trace vm
  | Machine.InitLocal i ->
      let value = pop vm in
      if i < 0 || i >= Array.length frame.Frame_stack.locals then
        die (Machine.InvalidLocal i);
      frame.Frame_stack.locals.(i) <- value;
      loop ~trace vm
  | Machine.LoadCapture i ->
      push vm (capture frame i);
      loop ~trace vm
  | Machine.Pop ->
      ignore (pop vm);
      loop ~trace vm
  | Machine.Dup ->
      let value = try Value_stack.peek vm.values 0 with Value_stack.Underflow -> die Machine.StackUnderflow in
      push vm value;
      loop ~trace vm
  | Machine.AddI64 ->
      arith vm Int64.add;
      loop ~trace vm
  | Machine.SubI64 ->
      arith vm Int64.sub;
      loop ~trace vm
  | Machine.MulI64 ->
      arith vm Int64.mul;
      loop ~trace vm
  | Machine.DivI64 ->
      divide Int64.div vm;
      loop ~trace vm
  | Machine.ModI64 ->
      divide Int64.rem vm;
      loop ~trace vm
  | Machine.NegI64 ->
      let n = int_of (pop vm) in
      push vm (Machine.VInt (Int64.neg n));
      loop ~trace vm
  | Machine.EqI64 ->
      compare_op vm (fun c -> c = 0);
      loop ~trace vm
  | Machine.NeI64 ->
      compare_op vm (fun c -> c <> 0);
      loop ~trace vm
  | Machine.LtI64 ->
      compare_op vm (fun c -> c < 0);
      loop ~trace vm
  | Machine.LeI64 ->
      compare_op vm (fun c -> c <= 0);
      loop ~trace vm
  | Machine.GtI64 ->
      compare_op vm (fun c -> c > 0);
      loop ~trace vm
  | Machine.GeI64 ->
      compare_op vm (fun c -> c >= 0);
      loop ~trace vm
  | Machine.MakeTuple width ->
      if width < 0 then die (Machine.TupleIndexOutOfBounds width);
      let fields = Array.make (max 1 width) Machine.VUnit in
      for i = width - 1 downto 0 do
        fields.(i) <- pop vm
      done;
      push vm (Machine.VTuple (Array.sub fields 0 width));
      loop ~trace vm
  | Machine.TupleGet i ->
      let fields = tuple_of (pop vm) in
      if i < 0 || i >= Array.length fields then
        die (Machine.TupleIndexOutOfBounds i);
      push vm fields.(i);
      loop ~trace vm
  (* The captured values are fetched from this frame, not from the stack: the
     instruction says where each of them lives. *)
  | Machine.MakeClosure (id, sources) ->
      let callee = function_at vm id in
      if Array.length sources <> callee.Machine.capture_count then
        die (Machine.InvalidFunction id);
      let captures =
        Array.map
          (function
            | Machine.FromLocal i -> local frame i
            | Machine.FromCapture i -> capture frame i)
          sources
      in
      push vm (Machine.VClosure { Machine.function_id = id; captures });
      loop ~trace vm
  | Machine.Jump target ->
      if target < 0 || target >= Array.length f.Machine.code then
        die (Machine.InvalidJumpTarget target);
      frame.Frame_stack.pc <- target;
      loop ~trace vm
  | Machine.JumpIfFalse target ->
      if target < 0 || target >= Array.length f.Machine.code then
        die (Machine.InvalidJumpTarget target);
      if not (bool_of (pop vm)) then frame.Frame_stack.pc <- target;
      loop ~trace vm
  | Machine.Call arity ->
      enter vm (callee_under vm arity) ~arity ~drop_callee:true ~tail:false;
      loop ~trace vm
  | Machine.ReturnCall arity ->
      enter vm (callee_under vm arity) ~arity ~drop_callee:true ~tail:true;
      loop ~trace vm
  | Machine.CallStatic (id, arity) ->
      enter vm
        { Machine.function_id = id; captures = [||] }
        ~arity ~drop_callee:false ~tail:false;
      loop ~trace vm
  | Machine.ReturnCallStatic (id, arity) ->
      enter vm
        { Machine.function_id = id; captures = [||] }
        ~arity ~drop_callee:false ~tail:true;
      loop ~trace vm
  | Machine.Return ->
      let result = pop vm in
      let frame = Frame_stack.pop vm.frames in
      Value_stack.truncate vm.values frame.Frame_stack.stack_base;
      if Frame_stack.is_empty vm.frames then result
      else (
        push vm result;
        loop ~trace vm)
  | Machine.Trap error -> die error

let run_stats ?(trace = false) (program : Machine.program) =
  let vm =
    {
      program;
      values = Value_stack.create 64;
      frames = Frame_stack.create 64;
      steps = 0;
    }
  in
  let stats () = { steps = vm.steps; deepest = Frame_stack.deepest vm.frames } in
  try
    let entry = function_at vm program.Machine.entry in
    if entry.Machine.arity <> 0 then
      die (Machine.WrongArity { expected = entry.Machine.arity; actual = 0 });
    enter vm
      { Machine.function_id = program.Machine.entry; captures = [||] }
      ~arity:0 ~drop_callee:false ~tail:false;
    let value = loop ~trace vm in
    Ok (value, stats ())
  with
  | Trapped error -> Error error
  | Value_stack.Underflow -> Error Machine.StackUnderflow
  | Frame_stack.Empty -> Error Machine.StackUnderflow

let run ?(trace = false) program =
  match run_stats ~trace program with
  | Ok (value, _) -> Ok value
  | Error error -> Error error
