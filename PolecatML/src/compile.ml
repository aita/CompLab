(* Resolved core to machine code.

   The rule the whole file obeys: compiling an expression emits instructions that
   leave exactly one value on the operand stack, and touch nothing below it.
   Every case below can be read as a small proof of that, given it of the parts.

   The other half of the file is the [tail] flag.  An expression in tail position
   is one whose value is the value of the call that contains it, so instead of
   producing a value it *finishes* the call: an application in tail position
   becomes [ReturnCall], which reuses the frame, and anything else becomes its
   ordinary code followed by [Return].  Tail position is a property of where an
   expression sits, and it is decided here, once, by passing the flag down the
   two places it survives — the branches of an `if`, and the body of a `let`.
   The machine is then told outright which kind of call to make, and never has to
   work it out. *)

type builder = {
  mutable code : Machine.instr array;
  mutable n : int;
  mutable constants : Machine.value list; (* reversed *)
  mutable const_count : int;
  const_index : (Machine.value, int) Hashtbl.t;
}

let create () =
  {
    code = Array.make 32 Machine.Return;
    n = 0;
    constants = [];
    const_count = 0;
    const_index = Hashtbl.create 16;
  }

let emit b instr =
  if b.n = Array.length b.code then (
    let bigger = Array.make (2 * b.n) Machine.Return in
    Array.blit b.code 0 bigger 0 b.n;
    b.code <- bigger);
  b.code.(b.n) <- instr;
  b.n <- b.n + 1

(* A jump whose target is not known yet: emit it, and patch it once the target
   instruction has been emitted. *)
let emit_hole b =
  let at = b.n in
  emit b (Machine.Jump (-1));
  at

let patch b at instr = b.code.(at) <- instr
let here b = b.n

let constant b value =
  match Hashtbl.find_opt b.const_index value with
  | Some i -> i
  | None ->
      let i = b.const_count in
      Hashtbl.add b.const_index value i;
      b.constants <- value :: b.constants;
      b.const_count <- i + 1;
      i

let prim_instr = function
  | Core.Add -> Machine.AddI64
  | Core.Sub -> Machine.SubI64
  | Core.Mul -> Machine.MulI64
  | Core.Div -> Machine.DivI64
  | Core.Mod -> Machine.ModI64
  | Core.Neg -> Machine.NegI64
  | Core.Eq -> Machine.EqI64
  | Core.Ne -> Machine.NeI64
  | Core.Lt -> Machine.LtI64
  | Core.Le -> Machine.LeI64
  | Core.Gt -> Machine.GtI64
  | Core.Ge -> Machine.GeI64

let rec gen b ~tail (e : Resolve.expr) =
  match e with
  (* An application is the only expression that can end a call by itself. *)
  | Resolve.App (f, args) ->
      gen b ~tail:false f;
      List.iter (gen b ~tail:false) args;
      let arity = List.length args in
      emit b (if tail then Machine.ReturnCall arity else Machine.Call arity)
  | Resolve.AppGlobal (id, args) ->
      List.iter (gen b ~tail:false) args;
      let arity = List.length args in
      emit b
        (if tail then Machine.ReturnCallStatic (id, arity)
         else Machine.CallStatic (id, arity))
  (* Both branches are in the position the `if` itself was in.  When that is tail
     position each branch ends the call, so there is nothing to jump to and no
     join: the `else` label is the only one needed. *)
  | Resolve.If (cond, yes, no) ->
      gen b ~tail:false cond;
      let to_else = emit_hole b in
      gen b ~tail yes;
      if tail then (
        patch b to_else (Machine.JumpIfFalse (here b));
        gen b ~tail no)
      else
        let to_done = emit_hole b in
        patch b to_else (Machine.JumpIfFalse (here b));
        gen b ~tail:false no;
        patch b to_done (Machine.Jump (here b))
  (* A binding is a slot, so the value goes straight into it and the body is
     compiled in the same position the `let` was in. *)
  | Resolve.Let (slot, rhs, body) ->
      gen b ~tail:false rhs;
      emit b (match slot with Some s -> Machine.InitLocal s | None -> Machine.Pop);
      gen b ~tail body
  (* Taking a tuple apart: keep a copy of it while there are fields left to
     read, and let the last field consume it. *)
  | Resolve.Untuple (rhs, slots, body) ->
      gen b ~tail:false rhs;
      let width = List.length slots in
      if width = 0 then emit b Machine.Pop
      else
        List.iteri
          (fun i slot ->
            if i < width - 1 then emit b Machine.Dup;
            emit b (Machine.TupleGet i);
            emit b
              (match slot with Some s -> Machine.InitLocal s | None -> Machine.Pop))
          slots;
      gen b ~tail body
  | _ ->
      gen_value b e;
      if tail then emit b Machine.Return

(* The expressions that only produce a value. *)
and gen_value b (e : Resolve.expr) =
  match e with
  | Resolve.Int n -> emit b (Machine.Const (constant b (Machine.VInt n)))
  | Resolve.Bool v -> emit b (Machine.ConstBool v)
  | Resolve.Unit -> emit b Machine.ConstUnit
  | Resolve.Local i -> emit b (Machine.LoadLocal i)
  | Resolve.Capture i -> emit b (Machine.LoadCapture i)
  (* A function that captures nothing has exactly one closure value, so it can
     live in the constant pool instead of being built each time it is named. *)
  | Resolve.Global id ->
      emit b
        (Machine.Const
           (constant b (Machine.VClosure { function_id = id; captures = [||] })))
  | Resolve.Tuple es ->
      List.iter (gen b ~tail:false) es;
      emit b (Machine.MakeTuple (List.length es))
  | Resolve.Proj (i, e) ->
      gen b ~tail:false e;
      emit b (Machine.TupleGet i)
  | Resolve.Prim (op, args) ->
      List.iter (gen b ~tail:false) args;
      emit b (prim_instr op)
  | Resolve.Closure (id, sources) -> emit b (Machine.MakeClosure (id, sources))
  | Resolve.If _ | Resolve.Let _ | Resolve.Untuple _ | Resolve.App _
  | Resolve.AppGlobal _ ->
      gen b ~tail:false e

let func fid (f : Resolve.func) =
  let b = create () in
  gen b ~tail:true f.Resolve.body;
  let built =
    {
      Machine.name = f.Resolve.name;
      arity = f.Resolve.arity;
      local_count = f.Resolve.local_count;
      capture_count = f.Resolve.capture_count;
      max_stack = 0;
      constants = Array.of_list (List.rev b.constants);
      code = Array.sub b.code 0 b.n;
    }
  in
  { built with Machine.max_stack = Verify.max_stack fid built }

let program (r : Resolve.program) =
  {
    Machine.entry = r.Resolve.entry;
    functions = Array.mapi func r.Resolve.functions;
  }
