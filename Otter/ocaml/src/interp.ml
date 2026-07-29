(* Walks the tree and runs it.

   Evaluation is a plain recursive walk. Control flow is a returned value rather
   than an exception, so a `return` inside a loop costs a comparison. Faults
   that the language checks for — a null dereference, an index out of range, a
   division by zero — are raised, and reported with the position of the
   expression that caused them. *)

open Diagnostics
open Ast
open Value

(* How a statement finished. *)
type flow = Normal | Break | Continue | Return of value

(* Deep enough to catch a runaway recursion before the OCaml stack runs out. *)
let call_depth_limit = 2000

type state = {
  program : Program.t;
  globals : (int, cell) Hashtbl.t;
  (* A named function at the top level captures nothing, so one closure per
     declaration will do for the whole run. *)
  functions : (int, value) Hashtbl.t;
  mutable depth : int;
}

let truth = function Bool value -> value | _ -> invalid_arg "truth"

let whole = function
  | Int value -> value
  | Byte value | Char value -> Int64.of_int value
  | _ -> invalid_arg "whole"

let type_of expression = Ast.some "an expression type" expression.e_type

let check_bounds position size span =
  if position < 0 || position >= size then
    runtime_error span "index %d lies outside a run of %d element(s)" position
      size

(* A whole number narrowed to the type it is being held as. *)
let integer_value value typ =
  match typ with
  | Types.Byte -> Byte (Int64.to_int value land 0xFF)
  | Types.Char -> Char (Int64.to_int value land 0xFFFFFFFF)
  | _ -> Int value

let from_integer value = function
  | Types.Byte -> Byte (Int64.to_int value land 0xFF)
  | Types.Char -> Char (Int64.to_int value land 0xFFFFFFFF)
  | Types.Float32 -> Float32 (narrow (Int64.to_float value))
  | Types.Float64 -> Float64 (Int64.to_float value)
  | _ -> Int value

let from_float value = function
  | Types.Byte -> Byte (Int64.to_int (Int64.of_float value) land 0xFF)
  | Types.Char -> Char (Int64.to_int (Int64.of_float value) land 0xFFFFFFFF)
  | Types.Float32 -> Float32 (narrow value)
  | Types.Float64 -> Float64 value
  | _ -> Int (Int64.of_float value)

let float_value = function
  | Float32 value | Float64 value -> value
  | _ -> invalid_arg "float_value"

(* -------------------------------------------------------------------------- *)
(* Running                                                                      *)
(* -------------------------------------------------------------------------- *)

let rec call state callee arguments span =
  match callee with
  | Function closure -> (
      let definition = closure.definition in
      match definition.fd_body with
      | None -> call_native definition arguments span
      | Some body ->
          state.depth <- state.depth + 1;
          if state.depth > call_depth_limit then begin
            state.depth <- state.depth - 1;
            runtime_error span
              "more than %d nested calls; this looks like a recursion that \
               never ends"
              call_depth_limit
          end;
          let frame = environment closure.captured in
          List.iteri
            (fun index parameter ->
              define frame parameter.p_name (copy_of arguments.(index)))
            definition.fd_parameters;
          let returned =
            match run_block state body frame with
            | Return value -> value
            | _ -> Unit
          in
          state.depth <- state.depth - 1;
          returned)
  | _ -> invalid_arg "call"

and call_native definition arguments span =
  match Builtins.find_native definition.fd_name with
  | Some native -> native arguments span
  | None ->
      runtime_error span "this implementation has no host function named `%s`"
        definition.fd_name

(* -- statements ------------------------------------------------------------ *)

(* The statements of a block, in the scope the block is running in. *)
and run_block state body scope =
  make_nested_functions body.blk_statements scope;
  let rec walk = function
    | [] -> Normal
    | statement :: rest -> (
        match execute state statement scope with
        | Normal -> walk rest
        | leaving -> leaving)
  in
  walk body.blk_statements

(* A block of its own gets a scope of its own, so what it declares is gone
   after it. *)
and run_nested_block state body scope =
  run_block state body (environment (Some scope))

(* Every function declared in a block gets its closure as the block is entered,
   over the scope the block itself is running in, so that a pair of them can
   call each other. *)
and make_nested_functions statements scope =
  List.iter
    (fun statement ->
      match statement.s_kind with
      | S_fun definition ->
          define scope definition.fd_name (closure definition (Some scope))
      | _ -> ())
    statements

and execute state statement scope =
  match statement.s_kind with
  | S_var declaration ->
      define scope declaration.vd_name
        (copy_of (evaluate state declaration.vd_initializer scope));
      Normal
  | S_fun _ ->
      (* The closure was made when the block was entered, so that a call written
         above the declaration still finds it. *)
      Normal
  | S_return None -> Return Unit
  | S_return (Some value) -> Return (copy_of (evaluate state value scope))
  | S_if branch -> execute_conditional state branch scope
  | S_while (condition, body) ->
      let result = ref Normal in
      let running = ref true in
      while !running && truth (evaluate state condition scope) do
        match run_nested_block state body scope with
        | Break -> running := false
        | Return value ->
            result := Return value;
            running := false
        | _ -> ()
      done;
      !result
  | S_for loop ->
      let frame = environment (Some scope) in
      (match loop.fo_initializer with
      | Some start -> ignore (execute state start frame)
      | None -> ());
      let result = ref Normal in
      let running = ref true in
      let continues () =
        !running
        &&
        match loop.fo_condition with
        | None -> true
        | Some condition -> truth (evaluate state condition frame)
      in
      while continues () do
        (match run_nested_block state loop.fo_body frame with
        | Break -> running := false
        | Return value ->
            result := Return value;
            running := false
        | _ -> ());
        (* `continue` lands here too, so the step always runs. *)
        if !running then
          match loop.fo_step with
          | Some step -> ignore (evaluate state step frame)
          | None -> ()
      done;
      !result
  | S_break -> Break
  | S_continue -> Continue
  | S_expr value ->
      ignore (evaluate state value scope);
      Normal
  | S_block body -> run_nested_block state body scope

and execute_conditional state branch scope =
  if truth (evaluate state branch.if_condition scope) then
    run_nested_block state branch.if_then scope
  else
    match branch.if_else with
    | None -> Normal
    | Some (Else_block body) -> run_nested_block state body scope
    | Some (Else_if inner) -> execute_conditional state inner scope

(* -- places ---------------------------------------------------------------- *)

(* The slot an expression names, so that it can be written through or have its
   address taken. Anything that is not storage gets a fresh cell, which is what
   `&` on a temporary should do. *)
and place state expression scope =
  match expression.e_kind with
  | E_name { n_resolution = Local; n_name; _ } -> (
      match find_cell scope n_name with
      | Some cell -> Cell_at cell
      | None -> runtime_error expression.e_span "`%s` has no value" n_name)
  | E_name { n_resolution = Global global; _ } ->
      Cell_at (Hashtbl.find state.globals global.g_id)
  | E_field { fa_resolution = Module_global global; _ } ->
      Cell_at (Hashtbl.find state.globals global.g_id)
  | E_field ({ fa_resolution = Struct_field index; _ } as access) ->
      Field_at (structure_of state access scope, index)
  | E_index (subject, index) when is_array subject ->
      let array = array_of (evaluate state subject scope) in
      let position = Int64.to_int (whole (evaluate state index scope)) in
      check_bounds position (Array.length array.items) expression.e_span;
      Element_at (array, position)
  | E_unary (Dereference, operand) -> (
      match evaluate state operand scope with
      | Pointer Null -> runtime_error expression.e_span "this pointer is null"
      | Pointer slot -> slot
      | _ -> invalid_arg "place")
  | _ -> Cell_at (cell (evaluate state expression scope))

(* The struct a field access reads from, whether it was reached directly or
   through a pointer. *)
and structure_of state access scope =
  if access.fa_through_pointer then
    match evaluate state access.fa_subject scope with
    | Pointer Null ->
        runtime_error access.fa_subject.e_span "this pointer is null"
    | Pointer slot -> struct_of (load slot)
    | _ -> invalid_arg "structure_of"
  else if is_storage access.fa_subject then
    struct_of (load (place state access.fa_subject scope))
  else struct_of (evaluate state access.fa_subject scope)

and struct_of = function
  | Struct object_ -> object_
  | _ -> invalid_arg "struct_of"

and array_of = function Array object_ -> object_ | _ -> invalid_arg "array_of"

and is_array expression =
  match type_of expression with Types.Array _ -> true | _ -> false

and is_storage expression =
  match expression.e_kind with
  | E_name { n_resolution = Local | Global _; _ } -> true
  | E_field { fa_resolution = Struct_field _ | Module_global _; _ } -> true
  (* A string is not storage: its bytes cannot be written to. *)
  | E_index (subject, _) -> is_array subject
  | E_unary (Dereference, _) -> true
  | _ -> false

(* -- expressions ----------------------------------------------------------- *)

and evaluate state expression scope =
  match expression.e_kind with
  | E_int value -> integer_value value (type_of expression)
  | E_float value ->
      if Types.equal (type_of expression) Types.Float32 then
        Float32 (narrow value)
      else Float64 value
  | E_string contents -> copied_text contents
  | E_char code -> Char code
  | E_bool value -> Bool value
  | E_null -> Pointer Null
  | E_name name -> evaluate_name state expression name scope
  | E_array literal -> evaluate_array state expression literal scope
  | E_struct literal -> evaluate_struct_literal state literal scope
  | E_fun definition -> closure definition (Some scope)
  | E_call (callee, arguments) ->
      let called = evaluate state callee scope in
      let values =
        Array.of_list
          (List.map (fun argument -> evaluate state argument scope) arguments)
      in
      call state called values expression.e_span
  | E_index (subject, index) ->
      evaluate_index state expression subject index scope
  | E_field access -> evaluate_field state expression access scope
  | E_unary (op, operand) -> evaluate_unary state expression op operand scope
  | E_cast (operand, _) -> evaluate_cast state expression operand scope
  | E_binary operation -> evaluate_binary state expression operation scope
  | E_assign (target, value) ->
      let slot = place state target scope in
      let result = copy_of (evaluate state value scope) in
      store slot result;
      result
  | E_if branch -> evaluate_conditional state branch scope

(* Nothing in a value block can jump out of it, so the statements run to the end
   and the block's expression is the answer. *)
and evaluate_conditional state branch scope =
  let taken = truth (evaluate state branch.if_condition scope) in
  if taken then evaluate_value_block state branch.if_then scope
  else
    match branch.if_else with
    | Some (Else_block body) -> evaluate_value_block state body scope
    | Some (Else_if inner) -> evaluate_conditional state inner scope
    | None -> invalid_arg "evaluate_conditional"

and evaluate_value_block state body scope =
  let frame = environment (Some scope) in
  make_nested_functions body.blk_statements frame;
  List.iter
    (fun statement -> ignore (execute state statement frame))
    body.blk_statements;
  evaluate state (Ast.some "a block value" body.blk_value) frame

and evaluate_name state expression name scope =
  match name.n_resolution with
  | Local -> (
      match find_cell scope name.n_name with
      | Some cell -> cell.held
      | None -> runtime_error expression.e_span "`%s` has no value" name.n_name)
  | Global global -> (Hashtbl.find state.globals global.g_id).held
  | Named_function declaration -> function_value state declaration
  | _ -> runtime_error expression.e_span "`%s` has no value" name.n_name

and function_value state declaration =
  let definition = declaration.fn_definition in
  match Hashtbl.find_opt state.functions definition.fd_id with
  | Some value -> value
  | None ->
      let value = closure definition None in
      Hashtbl.replace state.functions definition.fd_id value;
      value

and evaluate_array state expression literal scope =
  let element =
    match type_of expression with
    | Types.Array element -> element
    | _ -> Types.Void
  in
  match literal.ar_count with
  | Some count ->
      let seed = evaluate state (List.hd literal.ar_elements) scope in
      let counted = Int64.to_int (whole (evaluate state count scope)) in
      if counted < 0 then
        runtime_error count.e_span "an array cannot have %d elements" counted;
      array_object element (Array.init counted (fun _ -> copy_of seed))
  | None ->
      array_object element
        (Array.of_list
           (List.map
              (fun value -> copy_of (evaluate state value scope))
              literal.ar_elements))

and evaluate_struct_literal state literal scope =
  let structure = Ast.some "a struct" literal.sl_structure in
  let fields = Array.make (List.length structure.Types.fields) Unit in
  List.iter
    (fun initializer_ ->
      fields.(initializer_.fi_index) <-
        copy_of (evaluate state initializer_.fi_value scope))
    literal.sl_fields;
  struct_object structure fields

and evaluate_index state expression subject index scope =
  let value = evaluate state subject scope in
  let position = Int64.to_int (whole (evaluate state index scope)) in
  match value with
  | Text contents ->
      check_bounds position (String.length contents) expression.e_span;
      Byte (Char.code contents.[position])
  | Array array ->
      check_bounds position (Array.length array.items) expression.e_span;
      array.items.(position)
  | _ -> invalid_arg "evaluate_index"

and evaluate_field state expression access scope =
  match access.fa_resolution with
  | Struct_field index -> (structure_of state access scope).fields.(index)
  | Length -> (
      match evaluate state access.fa_subject scope with
      | Text contents -> Int (Int64.of_int (String.length contents))
      | Array array -> Int (Int64.of_int (Array.length array.items))
      | _ -> invalid_arg "evaluate_field")
  | Module_function declaration -> function_value state declaration
  | Module_global global -> (Hashtbl.find state.globals global.g_id).held
  | Field_unresolved ->
      runtime_error expression.e_span "`%s` has no value" access.fa_name

and evaluate_unary state expression op operand scope =
  match op with
  | Address_of -> Pointer (place state operand scope)
  | Dereference -> (
      match evaluate state operand scope with
      | Pointer Null -> runtime_error expression.e_span "this pointer is null"
      | Pointer slot -> load slot
      | _ -> invalid_arg "evaluate_unary")
  | _ -> (
      let value = evaluate state operand scope in
      match op with
      | Plus -> value
      | Not -> Bool (not (truth value))
      | Minus -> (
          match value with
          | Int number -> Int (Int64.neg number)
          | Byte number -> Byte (-number land 0xFF)
          | Char number -> Char (-number land 0xFFFFFFFF)
          | Float32 number -> Float32 (narrow (-.number))
          | Float64 number -> Float64 (-.number)
          | _ -> invalid_arg "evaluate_unary")
      | Complement -> (
          match value with
          | Byte number -> Byte (lnot number land 0xFF)
          | Char number -> Char (lnot number land 0xFFFFFFFF)
          | _ -> Int (Int64.lognot (whole value)))
      | _ -> invalid_arg "evaluate_unary")

and evaluate_cast state expression operand scope =
  let value = evaluate state operand scope in
  let from = type_of operand in
  let target = type_of expression in
  match target with
  | Types.Pointer _ -> value
  | _ ->
      if Types.equal from target then value
      else if Types.is_floating from then from_float (float_value value) target
      else from_integer (whole value) target

and evaluate_binary state expression operation scope =
  match operation.bin_op with
  | And ->
      Bool
        (truth (evaluate state operation.bin_left scope)
        && truth (evaluate state operation.bin_right scope))
  | Or ->
      Bool
        (truth (evaluate state operation.bin_left scope)
        || truth (evaluate state operation.bin_right scope))
  | op -> (
      let left = evaluate state operation.bin_left scope in
      let right = evaluate state operation.bin_right scope in
      match op with
      | Equal -> Bool (equal_values left right)
      | Not_equal -> Bool (not (equal_values left right))
      | _ -> (
          match Ast.some "an operand type" operation.bin_operand with
          | Types.String -> string_operation op (text_of left) (text_of right)
          | Types.Float32 ->
              floating_operation op (float_value left) (float_value right)
                ~single:true
          | Types.Float64 ->
              floating_operation op (float_value left) (float_value right)
                ~single:false
          | _ ->
              integer_operation op (whole left) (whole right)
                (type_of expression) expression.e_span))

and text_of = function Text contents -> contents | _ -> invalid_arg "text_of"

and string_operation op left right =
  match op with
  | Add -> text (left ^ right)
  | Less -> Bool (String.compare left right < 0)
  | Less_equal -> Bool (String.compare left right <= 0)
  | Greater -> Bool (String.compare left right > 0)
  | _ -> Bool (String.compare left right >= 0)

and floating_operation op left right ~single =
  let number value = if single then Float32 (narrow value) else Float64 value in
  match op with
  | Add -> number (left +. right)
  | Subtract -> number (left -. right)
  | Multiply -> number (left *. right)
  | Divide -> number (left /. right)
  | Less -> Bool (left < right)
  | Less_equal -> Bool (left <= right)
  | Greater -> Bool (left > right)
  | _ -> Bool (left >= right)

and integer_operation op left right typ span =
  match op with
  | Add -> integer_value (Int64.add left right) typ
  | Subtract -> integer_value (Int64.sub left right) typ
  | Multiply -> integer_value (Int64.mul left right) typ
  | Divide ->
      if Int64.equal right 0L then runtime_error span "division by zero";
      integer_value (Int64.div left right) typ
  | Remainder ->
      if Int64.equal right 0L then runtime_error span "remainder by zero";
      integer_value (Int64.rem left right) typ
  | Less -> Bool (Int64.compare left right < 0)
  | Less_equal -> Bool (Int64.compare left right <= 0)
  | Greater -> Bool (Int64.compare left right > 0)
  | _ -> Bool (Int64.compare left right >= 0)

(* Runs a checked program and returns what `main` returned. *)
let run_program program =
  let state =
    {
      program;
      globals = Hashtbl.create 16;
      functions = Hashtbl.create 16;
      depth = 0;
    }
  in
  let scope = environment None in
  List.iter
    (fun module_ast ->
      List.iter
        (fun declaration ->
          let value =
            copy_of (evaluate state declaration.g_initializer scope)
          in
          Hashtbl.replace state.globals declaration.g_id (cell value))
        module_ast.m_globals)
    (Program.order state.program);
  let main =
    match find_function (Program.entry program) "main" with
    | Some declaration -> declaration
    | None -> assert false
  in
  let result =
    call state (function_value state main) [||] main.fn_definition.fd_span
  in
  match Ast.some "a result type" main.fn_definition.fd_result with
  | Types.Int -> Int64.to_int (whole result)
  | _ -> 0
