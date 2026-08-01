(* The abstract machine: its values, its instructions, and the shape of a
   compiled program.

   Nothing here runs anything — [Vm] does that — and nothing here knows about the
   language the front end reads.  This file is the contract between the two: the
   compiler may only produce what is written down here, and the machine may only
   assume it.

   Four things describe the state of the machine.

     S   the operand stack        the temporaries of the expression in progress
     E   locals and captures      the arguments and bindings of the call in progress
     C   a function's code, and a program counter into it
     K   the frame stack          the calls that are waiting

   That is CEK's control, environment and continuation, with the values a CEK
   machine carries around inside a redex put on a stack of their own.  The
   environment is in two halves because the halves are made at different times:
   the locals when the call happens, the captures when the closure was built.

   The instructions are OCaml constructors, not bytes.  Encoding them would be a
   separate and mechanical step; what matters here is that the set is fixed, that
   every instruction has one effect on the stack, and that a verifier can check a
   program against both before it runs. *)

type function_id = int

(* Where a captured value comes from, seen from the frame that builds the
   closure.  There are only two places it can be: that frame's own locals, or its
   own captures.  A closure is therefore built without touching the operand
   stack — the sources are part of the instruction. *)
type capture_source = FromLocal of int | FromCapture of int

type value =
  | VInt of int64
  | VBool of bool
  | VUnit
  | VTuple of value array
  | VClosure of closure

(* A closure is a function and the values it captured, and nothing else.  The
   code lives in the program, once, however many closures point at it. *)
and closure = { function_id : function_id; captures : value array }

type runtime_error =
  | StackUnderflow
  | InvalidLocal of int
  | InvalidCapture of int
  | InvalidConstant of int
  | InvalidJumpTarget of int
  | InvalidFunction of int
  | NotCallable
  | WrongArity of { expected : int; actual : int }
  | ExpectedInt
  | ExpectedBool
  | ExpectedTuple
  | TupleIndexOutOfBounds of int
  | DivisionByZero
  | InvalidProgramCounter
  | ExplicitTrap of string

let error_message = function
  | StackUnderflow -> "the operand stack ran out"
  | InvalidLocal i -> Printf.sprintf "there is no local %d" i
  | InvalidCapture i -> Printf.sprintf "there is no capture %d" i
  | InvalidConstant i -> Printf.sprintf "there is no constant %d" i
  | InvalidJumpTarget i -> Printf.sprintf "%d is not an instruction here" i
  | InvalidFunction i -> Printf.sprintf "there is no function %d" i
  | NotCallable -> "this value is not a function"
  | WrongArity { expected; actual } ->
      Printf.sprintf "this function takes %d argument(s), not %d" expected actual
  | ExpectedInt -> "an integer was expected"
  | ExpectedBool -> "a boolean was expected"
  | ExpectedTuple -> "a tuple was expected"
  | TupleIndexOutOfBounds i -> Printf.sprintf "this tuple has no field %d" i
  | DivisionByZero -> "division by zero"
  | InvalidProgramCounter -> "the program counter left the code"
  | ExplicitTrap message -> message

type instr =
  (* constants *)
  | Const of int
  | ConstUnit
  | ConstBool of bool
  (* the environment *)
  | LoadLocal of int
  | StoreLocal of int (* writes a slot and leaves the value on the stack *)
  | InitLocal of int (* pops into a slot: what an immutable binding needs *)
  | LoadCapture of int
  (* the operand stack *)
  | Pop
  | Dup
  (* arithmetic *)
  | AddI64
  | SubI64
  | MulI64
  | DivI64
  | ModI64
  | NegI64
  (* comparison *)
  | EqI64
  | NeI64
  | LtI64
  | LeI64
  | GtI64
  | GeI64
  (* tuples *)
  | MakeTuple of int
  | TupleGet of int
  (* closures *)
  | MakeClosure of function_id * capture_source array
  (* control flow *)
  | Jump of int
  | JumpIfFalse of int
  (* calls.  [ReturnCall] is the tail call: it replaces the current frame instead
     of pushing one, which is what makes recursion in tail position cost no
     stack.  The compiler decides which of the two to emit, and the machine never
     looks at what follows a [Call] to work it out. *)
  | Call of int
  | ReturnCall of int
  | CallStatic of function_id * int
  | ReturnCallStatic of function_id * int
  | Return
  (* a failure the compiler put there on purpose *)
  | Trap of runtime_error

type func = {
  name : string option;
  arity : int;
  local_count : int; (* the arguments are locals 0 .. arity-1 *)
  capture_count : int;
  max_stack : int; (* how far the operand stack can rise inside this call *)
  constants : value array;
  code : instr array;
}

type program = { entry : function_id; functions : func array }

(* How a value prints.  A closure prints as `fn` because there is nothing else
   true to say about it: two closures over the same code with different captures
   are different values, and neither has a name at run time. *)
let rec show_value = function
  | VInt n -> Int64.to_string n
  | VBool true -> "true"
  | VBool false -> "false"
  | VUnit -> "()"
  | VTuple vs ->
      "(" ^ String.concat ", " (Array.to_list (Array.map show_value vs)) ^ ")"
  | VClosure _ -> "fn"
