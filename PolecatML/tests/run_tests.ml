(* The test suite, as one executable.

   There are three kinds of test here.

   The golden ones run every program in `programs/` and every example, and
   compare what it prints with the `.out` beside it — and then run the same
   program twice more, through the evaluator over the core tree and through the
   one over A-normal form, and demand the same text.  Those runs are the point: a
   golden file only says the answer has not changed, but three independent
   implementations agreeing says the answer is right.

   The unit ones exercise the two stacks, and hand-write machine programs that
   the compiler would never produce — a [Trap], a [Dup], a jump to nowhere, a
   stack that is two different heights at a join — because the verifier and the
   machine have to be right about those as well.

   And one measures: a tail recursive program runs a million iterations and the
   frame stack is asked how deep it ever got. *)

let checks = ref 0
let failures = ref 0

let check name ok =
  incr checks;
  if not ok then (
    incr failures;
    Printf.printf "  FAIL  %s\n" name)

let check_text name ~expected ~actual =
  incr checks;
  if expected <> actual then (
    incr failures;
    Printf.printf "  FAIL  %s\n" name;
    let lines text = String.split_on_char '\n' text in
    let rec diff n want got =
      match (want, got) with
      | [], [] -> ()
      | w :: ws, g :: gs ->
          if w <> g then Printf.printf "    %d: want %S\n    %d: got  %S\n" n w n g;
          diff (n + 1) ws gs
      | w :: ws, [] ->
          Printf.printf "    %d: want %S\n    %d: got  <nothing>\n" n w n;
          diff (n + 1) ws []
      | [], g :: gs ->
          Printf.printf "    %d: want <nothing>\n    %d: got  %S\n" n n g;
          diff (n + 1) [] gs
    in
    diff 1 (lines expected) (lines actual))

let read path =
  let ch = open_in_bin path in
  let text = really_input_string ch (in_channel_length ch) in
  close_in ch;
  text

let files_in dir suffix =
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name suffix)
  |> List.sort compare
  |> List.map (fun name -> Filename.concat dir name)

(* ------------------------------------------------------- golden programs *)

let golden path =
  let name = Filename.basename path in
  let source = read path in
  let expected = read (Filename.remove_extension path ^ ".out") in
  (match Polecat.Driver.run source with
  | actual -> check_text (name ^ " (machine)") ~expected ~actual
  | exception Polecat.Diag.Error (_, message) ->
      check (name ^ " (machine): " ^ message) false);
  (match Polecat.Driver.interpret source with
  | actual -> check_text (name ^ " (evaluator)") ~expected ~actual
  | exception Polecat.Diag.Error (_, message) ->
      check (name ^ " (evaluator): " ^ message) false);
  (match Polecat.Driver.interpret_anf source with
  | actual -> check_text (name ^ " (anf)") ~expected ~actual
  | exception Polecat.Diag.Error (_, message) ->
      check (name ^ " (anf): " ^ message) false);
  let dumped stage suffix =
    let dump_path = Filename.remove_extension path ^ suffix in
    if Sys.file_exists dump_path then
      match Polecat.Driver.emit stage source with
      | actual ->
          check_text (name ^ " (" ^ suffix ^ ")") ~expected:(read dump_path) ~actual
      | exception Polecat.Diag.Error (_, message) ->
          check (name ^ " (" ^ suffix ^ "): " ^ message) false
  in
  dumped Polecat.Driver.Code ".code";
  dumped Polecat.Driver.Anf ".anf"

(* ---------------------------------------------------------- the front end *)

let rejects what source =
  incr checks;
  match Polecat.Driver.run source with
  | _ ->
      incr failures;
      Printf.printf "  FAIL  %s: accepted\n" what
  | exception Polecat.Diag.Error _ -> ()

let front_end () =
  rejects "an unbound name" "val x = y";
  rejects "adding a boolean" "val x = 1 + true";
  rejects "a branch of two types" "val x = if true then 1 else false";
  rejects "comparing functions" "fun f (n) = n\nval x = f = f";
  rejects "the wrong number of arguments" "fun f (a) = a\nval x = f (1, 2)";
  rejects "a field of an unknown tuple" "fun f (t) = #1 t";
  rejects "a field a tuple does not have" "val x = #3 (1, 2)";
  rejects "an occurs check" "val f = fn (x) => x (x)";
  rejects "an unclosed comment" "(* val x = 1";
  rejects "a missing `end`" "val x = let val y = 1 in y";
  rejects "a chain of comparisons" "val x = 1 < 2 < 3";
  rejects "division by zero" "val x = 1 / 0";
  rejects "a remainder by zero" "val x = 1 mod 0";
  (* And two the checker has to accept, next to ones it must not. *)
  check "a shadowed name is not a redefinition"
    (Polecat.Driver.run "val x = 1\nval x = true" = "val x : int = 1\nval x : bool = true\n");
  check "an annotation that agrees"
    (Polecat.Driver.run "val x : int = 1" = "val x : int = 1\n")

(* ----------------------------------------------------------- the stacks *)

let value_stack () =
  let s = Polecat.Value_stack.create 2 in
  let v n = Polecat.Machine.VInt (Int64.of_int n) in
  List.iter (Polecat.Value_stack.push s) [ v 1; v 2; v 3; v 4; v 5 ];
  check "the value stack grows" (Polecat.Value_stack.length s = 5);
  check "peek 0 is the top" (Polecat.Value_stack.peek s 0 = v 5);
  check "peek 4 is the bottom" (Polecat.Value_stack.peek s 4 = v 1);
  check "pop takes the top" (Polecat.Value_stack.pop s = v 5);
  check "pop again" (Polecat.Value_stack.pop s = v 4);
  Polecat.Value_stack.truncate s 1;
  check "truncate cuts to a height" (Polecat.Value_stack.length s = 1);
  check "and leaves what is below" (Polecat.Value_stack.peek s 0 = v 1);
  Polecat.Value_stack.truncate s 5;
  check "truncating above the top does nothing" (Polecat.Value_stack.length s = 1);
  check "the last pop empties it" (Polecat.Value_stack.pop s = v 1);
  check "and then it underflows"
    (match Polecat.Value_stack.pop s with
    | _ -> false
    | exception Polecat.Value_stack.Underflow -> true)

let frame_stack () =
  let s = Polecat.Frame_stack.create 1 in
  let frame id =
    {
      Polecat.Frame_stack.closure =
        { Polecat.Machine.function_id = id; captures = [||] };
      pc = 0;
      locals = [||];
      stack_base = 0;
    }
  in
  check "a new frame stack is empty" (Polecat.Frame_stack.is_empty s);
  Polecat.Frame_stack.push s (frame 1);
  Polecat.Frame_stack.push s (frame 2);
  check "the top is the last pushed"
    ((Polecat.Frame_stack.top s).Polecat.Frame_stack.closure
       .Polecat.Machine.function_id = 2);
  Polecat.Frame_stack.replace_top s (frame 3);
  check "replacing the top does not deepen it" (Polecat.Frame_stack.depth s = 2);
  check "and the top is the replacement"
    ((Polecat.Frame_stack.top s).Polecat.Frame_stack.closure
       .Polecat.Machine.function_id = 3);
  ignore (Polecat.Frame_stack.pop s);
  ignore (Polecat.Frame_stack.pop s);
  check "popping everything empties it" (Polecat.Frame_stack.is_empty s);
  check "the deepest is remembered" (Polecat.Frame_stack.deepest s = 2);
  check "and then it is empty"
    (match Polecat.Frame_stack.pop s with
    | _ -> false
    | exception Polecat.Frame_stack.Empty -> true)

(* ------------------------------------------- hand-written machine code *)

let func ?(name = "test") ?(arity = 0) ?(locals = 0) ?(captures = 0)
    ?(constants = [||]) code =
  {
    Polecat.Machine.name = Some name;
    arity;
    local_count = max locals arity;
    capture_count = captures;
    max_stack = 8;
    constants;
    code;
  }

let program functions = { Polecat.Machine.entry = 0; functions }

let runs what expected functions =
  incr checks;
  let p = program functions in
  match Polecat.Verify.program p with
  | Error failure ->
      incr failures;
      Printf.printf "  FAIL  %s: %s\n" what (Polecat.Verify.show ~program:p failure)
  | Ok () -> (
      match Polecat.Vm.run p with
      | Ok value when value = expected -> ()
      | Ok value ->
          incr failures;
          Printf.printf "  FAIL  %s: got %s\n" what
            (Polecat.Machine.show_value value)
      | Error error ->
          incr failures;
          Printf.printf "  FAIL  %s: %s\n" what (Polecat.Machine.error_message error))

let traps what expected functions =
  incr checks;
  match Polecat.Vm.run (program functions) with
  | Error error when error = expected -> ()
  | Error error ->
      incr failures;
      Printf.printf "  FAIL  %s: %s\n" what (Polecat.Machine.error_message error)
  | Ok value ->
      incr failures;
      Printf.printf "  FAIL  %s: returned %s\n" what
        (Polecat.Machine.show_value value)

let rejected what functions =
  incr checks;
  match Polecat.Verify.program (program functions) with
  | Error _ -> ()
  | Ok () ->
      incr failures;
      Printf.printf "  FAIL  %s: the verifier accepted it\n" what

let handwritten () =
  let open Polecat.Machine in
  let int n = VInt (Int64.of_int n) in
  (* The three instructions the compiler has no reason to emit. *)
  runs "Dup and StoreLocal" (int 14)
    [|
      func ~locals:1
        ~constants:[| int 7 |]
        [| Const 0; Dup; StoreLocal 0; AddI64; Return |];
    |];
  traps "Trap stops the machine"
    (ExplicitTrap "on purpose")
    [| func [| Trap (ExplicitTrap "on purpose") |] |];
  (* Ordinary calls, to the same code, through both call instructions. *)
  runs "a static call and a closure call" (int 20)
    [|
      func
        ~constants:[| int 5; VClosure { function_id = 1; captures = [||] } |]
        [| Const 0; CallStatic (1, 1); Const 1; Const 0; Call 1; AddI64; Return |];
      func ~name:"double" ~arity:1 [| LoadLocal 0; LoadLocal 0; AddI64; Return |];
    |];
  (* A tuple, taken apart the way a pattern compiles to: a [Dup] for every
     field but the last, and the last one consumes the tuple. *)
  runs "tuples" (int 1)
    [|
      func ~locals:1
        ~constants:[| int 1; int 2 |]
        [|
          Const 0;
          Const 1;
          MakeTuple 2;
          Dup;
          TupleGet 0;
          InitLocal 0;
          TupleGet 1;
          LoadLocal 0;
          SubI64;
          Return;
        |];
    |];
  (* The machine's own type errors, for code that did not come from the
     checker. *)
  traps "adding a boolean" ExpectedInt
    [| func [| ConstBool true; ConstBool true; AddI64; Return |] |];
  traps "calling a number" NotCallable
    [| func ~constants:[| int 1 |] [| Const 0; Const 0; Call 1; Return |] |];
  traps "the wrong number of arguments"
    (WrongArity { expected = 1; actual = 0 })
    [|
      func [| CallStatic (1, 0); Return |];
      func ~name:"one" ~arity:1 [| LoadLocal 0; Return |];
    |];
  traps "dividing by zero" DivisionByZero
    [|
      func
        ~constants:[| int 1; int 0 |]
        [| Const 0; Const 1; DivI64; Return |];
    |];
  traps "a field that is not there"
    (TupleIndexOutOfBounds 3)
    [| func ~constants:[| int 1 |] [| Const 0; MakeTuple 1; TupleGet 3; Return |] |];
  (* And what the verifier is for. *)
  rejected "an empty function" [| func [||] |];
  rejected "falling off the end" [| func ~constants:[| int 1 |] [| Const 0 |] |];
  rejected "a jump to nowhere" [| func [| Jump 9; Return |] |];
  rejected "a local that does not exist" [| func [| LoadLocal 3; Return |] |];
  rejected "a capture that does not exist" [| func [| LoadCapture 0; Return |] |];
  rejected "a constant that does not exist" [| func [| Const 0; Return |] |];
  rejected "an underflow"
    [| func [| AddI64; Return |] |];
  rejected "returning nothing" [| func [| Return |] |];
  rejected "returning two things"
    [| func ~constants:[| int 1 |] [| Const 0; Const 0; Return |] |];
  (* The two paths to instruction 4 leave the stack at different heights. *)
  rejected "a join whose paths disagree"
    [|
      func
        ~constants:[| int 1 |]
        [| ConstBool true; JumpIfFalse 4; Const 0; Const 0; Return |];
    |];
  rejected "a static call of the wrong arity"
    [|
      func ~constants:[| int 1 |] [| Const 0; CallStatic (1, 1); Return |];
      func ~name:"two" ~arity:2 [| LoadLocal 0; Return |];
    |];
  rejected "a static call of a function that captures"
    [|
      func [| CallStatic (1, 0); Return |];
      func ~name:"captures" ~captures:1 [| LoadCapture 0; Return |];
    |];
  rejected "a closure built with the wrong number of captures"
    [|
      func [| MakeClosure (1, [||]); Return |];
      func ~name:"captures" ~captures:1 [| LoadCapture 0; Return |];
    |];
  rejected "a function that says it needs less stack than it does"
    [|
      {
        (func ~constants:[| int 1 |] [| Const 0; Const 0; AddI64; Return |]) with
        max_stack = 1;
      };
    |]

(* --------------------------------------------------------- A-normal form *)

let normalize source =
  let decls = Polecat.Parser.program source in
  ignore (Polecat.Typecheck.program decls);
  let core, _ = Polecat.Desugar.program decls in
  Polecat.Anf.program core

let rec count_joins expr =
  let open Polecat.Anf in
  match expr with
  | Ret c -> in_comp c
  | Let (_, c, rest) -> in_comp c + count_joins rest
  | If (_, t, f) -> count_joins t + count_joins f
  | Letrec (group, rest) ->
      List.fold_left (fun n (_, l) -> n + count_joins l.body) 0 group
      + count_joins rest
  | Join (_, _, body, rest) -> 1 + count_joins body + count_joins rest
  | Jump _ -> 0

and in_comp c =
  let open Polecat.Anf in
  match c with Fn l -> count_joins l.body | _ -> 0

let anf () =
  (* A branch in tail position needs no join point: both arms end the function,
     so there is nothing after them to share. *)
  check "a tail branch makes no join point"
    (count_joins (normalize "fun f (n) = if n = 0 then 1 else 2\n") = 0);
  (* A branch whose value is bound does: the rest of the program is what both
     arms have to reach, and it is named rather than written twice. *)
  check "a bound branch makes one join point"
    (count_joins (normalize "val x = if true then 1 else 2\nval y = x + 1\n") = 1);
  (* `andalso` and `not` are branches too, so this is three of them, and each
     one binds its value: three join points where a duplicating normaliser
     would have written the rest of the program out eight times. *)
  check "each boolean operator is a branch"
    (count_joins
       (normalize "val a = true andalso false andalso true\nval b = not a\n")
    = 3);
  (* And the reason the join point is there at all.  Twenty bound branches in
     sequence: a normaliser that pushed the continuation into both arms would
     write the rest of the program out 2^20 times, and this would not finish.  *)
  let chain =
    let buf = Buffer.create 1024 in
    Buffer.add_string buf "val x0 = 1\n";
    for i = 1 to 20 do
      Buffer.add_string buf
        (Printf.sprintf "val x%d = if x%d > 0 then x%d + 1 else x%d - 1\n" i (i - 1)
           (i - 1) (i - 1))
    done;
    Buffer.contents buf
  in
  let size = Polecat.Anf.size (normalize chain) in
  check
    (Printf.sprintf "twenty bound branches stay small (%d nodes)" size)
    (size < 500);
  check "and the program still runs"
    (let text = Polecat.Driver.interpret_anf chain in
     let last = List.nth (String.split_on_char '\n' text) 20 in
     last = "val x20 : int = 21")

(* ------------------------------------------------------------ tail calls *)

let tail_calls () =
  let source =
    "fun count (i, limit) = if i = limit then i else count (i + 1, limit)\n\
     fun even (n) = if n = 0 then true else odd (n - 1)\n\
     and odd (n) = if n = 0 then false else even (n - 1)\n\
     fun withCapture (k, n) =\n\
    \  let fun go (i, acc) = if i = 0 then acc else go (i - 1, acc + k)\n\
    \  in go (n, 0) end\n\
     val a = count (0, 1000000)\n\
     val b = even (1000000)\n\
     val c = withCapture (2, 1000000)\n"
  in
  let text, stats = Polecat.Driver.run_stats source in
  check "a million tail calls give the right answers"
    (text
    = "val count : (int, int) -> int = fn\n\
       val even : int -> bool = fn\n\
       val odd : int -> bool = fn\n\
       val withCapture : (int, int) -> int = fn\n\
       val a : int = 1000000\n\
       val b : bool = true\n\
       val c : int = 2000000\n");
  (* Three million calls, and the frame stack never held more than the entry
     frame and the one being reused. *)
  check
    (Printf.sprintf "and the frame stack stayed %d deep" stats.Polecat.Vm.deepest)
    (stats.Polecat.Vm.deepest = 2);
  (* Without tail calls it would not: this one recurses in an operand position,
     and the depth follows the recursion. *)
  let _, deep =
    Polecat.Driver.run_stats
      "fun sum (n) = if n = 0 then 0 else n + sum (n - 1)\nval a = sum (1000)\n"
  in
  check "a call in an operand position does push frames"
    (deep.Polecat.Vm.deepest = 1002)

(* ------------------------------------------------------------------ main *)

let () =
  let programs = files_in "programs" ".pol" @ files_in "../examples" ".pol" in
  print_endline "golden programs, on the machine and on the evaluator";
  List.iter golden programs;
  print_endline "the front end";
  front_end ();
  print_endline "the operand stack";
  value_stack ();
  print_endline "the frame stack";
  frame_stack ();
  print_endline "hand-written machine code";
  handwritten ();
  print_endline "A-normal form";
  anf ();
  print_endline "tail calls";
  tail_calls ();
  Printf.printf "\n%d checks, %d failed\n" !checks !failures;
  if !failures > 0 then exit 1
