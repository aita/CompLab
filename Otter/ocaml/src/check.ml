(* Resolves the names a program mentions and gives every expression a type.

   The checker runs in phases, so that declarations may appear in any order:
   every struct gets a type before any field is resolved, and every function
   signature is registered before any body is checked. That is what makes mutual
   recursion and self-referential structs work without forward declarations. *)

open Diagnostics
open Ast

(* -------------------------------------------------------------------------- *)
(* Reaching the end of a body                                                   *)
(* -------------------------------------------------------------------------- *)

let is_always_true condition =
  match condition.e_kind with E_bool value -> value | _ -> false

(* Does a `break` in here belong to the loop we are asking about? Nested loops
   swallow their own breaks, so the walk stops at them. *)
let rec breaks_out_of statement =
  match statement.s_kind with
  | S_break -> true
  | S_block body -> breaks_out_of_block body
  | S_if branch -> breaks_out_of_conditional branch
  | _ -> false

and breaks_out_of_block body = List.exists breaks_out_of body.blk_statements

and breaks_out_of_conditional branch =
  breaks_out_of_block branch.if_then
  ||
  match branch.if_else with
  | None -> false
  | Some (Else_block body) -> breaks_out_of_block body
  | Some (Else_if inner) -> breaks_out_of_conditional inner

(* Does this statement leave the function on every path through it? *)
let rec always_returns statement =
  match statement.s_kind with
  | S_return _ -> true
  | S_block body -> always_returns_block body
  | S_if branch -> always_returns_conditional branch
  (* A loop that never ends on its own leaves only by returning. *)
  | S_while (condition, body) ->
      is_always_true condition && not (breaks_out_of_block body)
  | S_for loop ->
      let endless =
        match loop.fo_condition with
        | None -> true
        | Some condition -> is_always_true condition
      in
      endless && not (breaks_out_of_block loop.fo_body)
  | _ -> false

and always_returns_block body = List.exists always_returns body.blk_statements

and always_returns_conditional branch =
  match branch.if_else with
  | None -> false
  | Some (Else_block body) ->
      always_returns_block branch.if_then && always_returns_block body
  | Some (Else_if inner) ->
      always_returns_block branch.if_then && always_returns_conditional inner

(* A value block runs statements and then yields an expression, so there is
   nowhere for a jump out of it to go. Loops and functions written inside one
   are their own affair. *)
let rec reject_jumps statement ~inside_loop =
  match statement.s_kind with
  | S_return _ ->
      compile_error statement.s_span
        "this block stands for a value, so it cannot return from the function \
         around it"
  | S_break | S_continue ->
      if not inside_loop then
        compile_error statement.s_span
          "this block stands for a value, so there is no loop here to leave"
  | S_block body -> List.iter (reject_jumps ~inside_loop) body.blk_statements
  | S_if branch -> reject_jumps_in_conditional branch ~inside_loop
  | S_while (_, body) ->
      List.iter (reject_jumps ~inside_loop:true) body.blk_statements
  | S_for loop ->
      List.iter (reject_jumps ~inside_loop:true) loop.fo_body.blk_statements
  | _ -> ()

and reject_jumps_in_conditional branch ~inside_loop =
  List.iter (reject_jumps ~inside_loop) branch.if_then.blk_statements;
  match branch.if_else with
  | None -> ()
  | Some (Else_block body) ->
      List.iter (reject_jumps ~inside_loop) body.blk_statements
  | Some (Else_if inner) -> reject_jumps_in_conditional inner ~inside_loop

(* -------------------------------------------------------------------------- *)
(* The checker                                                                  *)
(* -------------------------------------------------------------------------- *)

type state = {
  program : Program.t;
  mutable home : module_ast option;
  (* Innermost first. *)
  mutable scopes : (string, Types.t) Hashtbl.t list;
  mutable results : Types.t list;
  mutable loop_depth : int;
  mutable errors : (span * string) list;
}

let home state =
  match state.home with Some module_ast -> module_ast | None -> assert false

let push_scope state = state.scopes <- Hashtbl.create 8 :: state.scopes

let pop_scope state =
  match state.scopes with [] -> () | _ :: rest -> state.scopes <- rest

let declare state name typ =
  match state.scopes with
  | [] -> ()
  | scope :: _ -> Hashtbl.replace scope name typ

let declared_here state name =
  match state.scopes with [] -> false | scope :: _ -> Hashtbl.mem scope name

let lookup state name =
  let rec search = function
    | [] -> None
    | scope :: outer -> (
        match Hashtbl.find_opt scope name with
        | Some typ -> Some typ
        | None -> search outer)
  in
  search state.scopes

let is_bound state name =
  match lookup state name with
  | Some _ -> true
  | None ->
      find_global (home state) name <> None
      || find_function (home state) name <> None

let expect actual ~wanted span what =
  if not (Types.assignable ~from:actual ~target:wanted) then
    compile_error span "%s is %s, but %s was expected" what
      (Types.describe actual) (Types.describe wanted)

let describe_op = function
  | Add -> "+"
  | Subtract -> "-"
  | Multiply -> "*"
  | Divide -> "/"
  | Remainder -> "%"
  | Less -> "<"
  | Less_equal -> "<="
  | Greater -> ">"
  | Greater_equal -> ">="
  | Equal -> "=="
  | Not_equal -> "!="
  | And -> "&&"
  | Or -> "||"

let is_bare_number expression =
  match expression.e_kind with E_int _ | E_float _ -> true | _ -> false

let builtin_type = function
  | "void" -> Some Types.Void
  | "bool" -> Some Types.Bool
  | "int" -> Some Types.Int
  | "byte" -> Some Types.Byte
  | "char" -> Some Types.Char
  | "string" -> Some Types.String
  | "float32" -> Some Types.Float32
  | "float64" -> Some Types.Float64
  | _ -> None

let imported_module state name span =
  match find_import (home state) name with
  | None -> compile_error span "module `%s` is not imported here" name
  | Some entry -> (
      match entry.im_target with Some target -> target | None -> assert false)

(* An `if` written where a statement can start is read as the statement form, so
   a block that has to stand for a value gives whatever its last statement is. *)
let value_of_block block =
  match block.blk_value with
  | Some value -> value
  | None -> (
      match List.rev block.blk_statements with
      | ({ s_kind = S_if branch; _ } as last) :: earlier
        when branch.if_else <> None ->
          let value = Ast.expr last.s_span (E_if branch) in
          block.blk_statements <- List.rev earlier;
          block.blk_value <- Some value;
          value
      | _ ->
          compile_error block.blk_span
            "this block stands for a value, so it has to end in the expression \
             it gives")

(* -- types ----------------------------------------------------------------- *)

let rec resolve_type state node =
  match node.te_resolved with
  | Some resolved -> resolved
  | None ->
      let resolved = resolve_type_uncached state node in
      node.te_resolved <- Some resolved;
      resolved

and resolve_type_uncached state node =
  match node.te_kind with
  | Te_pointer target -> Types.Pointer (resolve_type state target)
  | Te_function (parameters, result) ->
      Types.Function
        (List.map (resolve_type state) parameters, resolve_type state result)
  | Te_named (path, arguments) -> (
      let no_arguments name =
        if arguments <> [] then
          compile_error node.te_span "`%s` does not take type arguments" name
      in
      match path with
      | [ name ] -> (
          match find_struct (home state) name with
          | Some declaration ->
              no_arguments name;
              Ast.some "a struct type" declaration.sd_type
          | None -> (
              match find_alias (home state) name with
              | Some declaration ->
                  no_arguments name;
                  resolve_alias state declaration
              | None -> (
                  if name = "array" then begin
                    match arguments with
                    | [ argument ] ->
                        let element = resolve_type state argument in
                        if Types.equal element Types.Void then
                          compile_error node.te_span "an array cannot hold void";
                        Types.Array element
                    | _ ->
                        compile_error node.te_span
                          "`array` names the type of its elements, as in \
                           array<int>"
                  end
                  else
                    match builtin_type name with
                    | Some builtin ->
                        no_arguments name;
                        builtin
                    | None ->
                        compile_error node.te_span "there is no type named `%s`"
                          name)))
      | [ module_name; type_name ] -> (
          let target = imported_module state module_name node.te_span in
          match find_struct target type_name with
          | Some declaration ->
              if not declaration.sd_exported then
                compile_error node.te_span "`%s.%s` is not exported" module_name
                  type_name;
              no_arguments type_name;
              Ast.some "a struct type" declaration.sd_type
          | None -> (
              match find_alias target type_name with
              | Some declaration ->
                  if not declaration.ad_exported then
                    compile_error node.te_span "`%s.%s` is not exported"
                      module_name type_name;
                  no_arguments type_name;
                  resolve_alias state declaration
              | None ->
                  compile_error node.te_span "module `%s` has no type `%s`"
                    module_name type_name))
      | _ ->
          compile_error node.te_span
            "a type name is either `Name` or `module.Name`")

(* Aliases are resolved when something asks for one, so that they may be written
   in any order and may name each other. *)
and resolve_alias state declaration =
  match declaration.ad_resolved with
  | Some resolved -> resolved
  | None ->
      if declaration.ad_resolving then
        compile_error declaration.ad_span
          "type `%s` is defined in terms of itself" declaration.ad_name;
      declaration.ad_resolving <- true;
      let saved = state.home in
      state.home <- declaration.ad_owner;
      let resolved = resolve_type state declaration.ad_target in
      state.home <- saved;
      declaration.ad_resolving <- false;
      declaration.ad_resolved <- Some resolved;
      resolved

(* -- phase 1: every struct gets a type, before any field is looked at ------- *)

let declare_structs state =
  List.iter
    (fun module_ast ->
      let seen = Hashtbl.create 16 in
      List.iter
        (fun declaration ->
          if Hashtbl.mem seen declaration.sd_name then
            compile_error declaration.sd_span
              "module `%s` declares struct `%s` twice" module_ast.m_name
              declaration.sd_name;
          Hashtbl.replace seen declaration.sd_name ();
          let structure =
            Types.declare_struct ~module_name:module_ast.m_name
              ~name:declaration.sd_name
          in
          declaration.sd_structure <- Some structure;
          declaration.sd_type <- Some (Types.Struct structure))
        module_ast.m_structs;
      List.iter
        (fun declaration ->
          if Hashtbl.mem seen declaration.ad_name then
            compile_error declaration.ad_span
              "module `%s` already declares a type named `%s`" module_ast.m_name
              declaration.ad_name;
          Hashtbl.replace seen declaration.ad_name ())
        module_ast.m_aliases)
    (Program.order state.program)

(* -- phase 2: field types, which may point back at their own struct --------- *)

let resolve_struct_fields state =
  List.iter
    (fun module_ast ->
      state.home <- Some module_ast;
      List.iter
        (fun declaration ->
          let structure = Ast.some "a struct" declaration.sd_structure in
          let seen = Hashtbl.create 8 in
          let fields =
            List.map
              (fun field ->
                if Hashtbl.mem seen field.sf_name then
                  compile_error field.sf_span
                    "struct `%s` declares field `%s` twice" declaration.sd_name
                    field.sf_name;
                Hashtbl.replace seen field.sf_name ();
                let typ = resolve_type state field.sf_declared in
                if Types.equal typ Types.Void then
                  compile_error field.sf_span "a field cannot be void";
                (field.sf_name, typ))
              declaration.sd_fields
          in
          structure.Types.fields <- fields;
          structure.Types.complete <- true)
        module_ast.m_structs)
    (Program.order state.program);
  state.home <- None

(* A struct that holds itself by value would have no size. Holding itself
   through a pointer is the whole point of a linked structure, so only the
   direct case is rejected. *)
let reject_struct_cycles state =
  let rec contains_itself target current visiting =
    if List.mem current.Types.id visiting then false
    else
      let visiting = current.Types.id :: visiting in
      List.exists
        (fun (_, typ) ->
          match typ with
          | Types.Struct held ->
              held.Types.id = target.Types.id
              || contains_itself target held visiting
          | _ -> false)
        current.Types.fields
  in
  List.iter
    (fun module_ast ->
      List.iter
        (fun declaration ->
          let structure = Ast.some "a struct" declaration.sd_structure in
          if contains_itself structure structure [] then
            compile_error declaration.sd_span
              "struct `%s` contains itself by value, which has no size; hold \
               it through a pointer instead"
              declaration.sd_name)
        module_ast.m_structs)
    (Program.order state.program)

(* -- phase 3: signatures, so that functions may call each other freely ------ *)

let resolve_signature state definition =
  (* A nested function has its signature registered before its block is walked,
     so that its siblings may call it; this is where the second request
     lands. *)
  match definition.fd_type with
  | Some _ -> ()
  | None ->
      let seen = Hashtbl.create 8 in
      let parameters =
        List.map
          (fun parameter ->
            if Hashtbl.mem seen parameter.p_name then
              compile_error parameter.p_span "parameter `%s` is declared twice"
                parameter.p_name;
            Hashtbl.replace seen parameter.p_name ();
            let typ = resolve_type state parameter.p_declared in
            if Types.equal typ Types.Void then
              compile_error parameter.p_span "a parameter cannot be void";
            parameter.p_type <- Some typ;
            typ)
          definition.fd_parameters
      in
      let result = resolve_type state definition.fd_declared_result in
      definition.fd_result <- Some result;
      definition.fd_type <- Some (Types.Function (parameters, result))

let declare_signatures state =
  List.iter
    (fun module_ast ->
      state.home <- Some module_ast;
      let seen = Hashtbl.create 16 in
      List.iter
        (fun declaration ->
          if Hashtbl.mem seen declaration.g_name then
            compile_error declaration.g_span "module `%s` declares `%s` twice"
              module_ast.m_name declaration.g_name;
          Hashtbl.replace seen declaration.g_name ();
          let typ = resolve_type state declaration.g_declared in
          if Types.equal typ Types.Void then
            compile_error declaration.g_span "a variable cannot be void";
          declaration.g_type <- Some typ)
        module_ast.m_globals;
      List.iter
        (fun declaration ->
          let definition = declaration.fn_definition in
          if Hashtbl.mem seen definition.fd_name then
            compile_error definition.fd_span "module `%s` declares `%s` twice"
              module_ast.m_name definition.fd_name;
          Hashtbl.replace seen definition.fd_name ();
          resolve_signature state definition;
          (* A function without a body is one the host supplies, so the name has
             to be one the host knows. *)
          if
            (match definition.fd_body with None -> true | Some _ -> false)
            &&
            match Builtins.find_native definition.fd_name with
            | None -> true
            | Some _ -> false
          then
            compile_error definition.fd_span
              "`%s` has no body, so it has to be a function this \
               implementation provides, and there is none by that name"
              definition.fd_name)
        module_ast.m_functions)
    (Program.order state.program);
  state.home <- None

(* -- phase 4: bodies ------------------------------------------------------- *)

let rec check_function state definition =
  match definition.fd_body with
  | None -> ()
  | Some body ->
      let result = Ast.some "a result type" definition.fd_result in
      push_scope state;
      List.iter
        (fun parameter ->
          declare state parameter.p_name
            (Ast.some "a parameter" parameter.p_type))
        definition.fd_parameters;
      state.results <- result :: state.results;
      let saved_depth = state.loop_depth in
      state.loop_depth <- 0;
      check_block state body ~own_scope:false;
      state.loop_depth <- saved_depth;
      state.results <- List.tl state.results;
      pop_scope state;
      if
        (not (Types.equal result Types.Void)) && not (always_returns_block body)
      then
        compile_error definition.fd_span
          "`%s` returns %s, but control can reach the end of its body without \
           a return"
          (if definition.fd_name = "" then "this function"
           else definition.fd_name)
          (Types.describe result)

and check_block state body ~own_scope =
  if own_scope then push_scope state;
  (match body.blk_value with
  | Some value ->
      compile_error value.e_span
        "this block runs statements, so what it ends with needs a `;`"
  | None -> ());
  declare_nested_functions state body.blk_statements;
  List.iter (check_statement state) body.blk_statements;
  if own_scope then pop_scope state

(* Every function declared in a block is in scope throughout it, so a pair of
   them may call each other and either may be used before it is written. *)
and declare_nested_functions state statements =
  List.iter
    (fun statement ->
      match statement.s_kind with
      | S_fun definition ->
          resolve_signature state definition;
          if declared_here state definition.fd_name then
            compile_error definition.fd_span
              "`%s` is already declared in this block" definition.fd_name;
          declare state definition.fd_name
            (Ast.some "a signature" definition.fd_type)
      | _ -> ())
    statements

and check_statement state statement =
  match statement.s_kind with
  | S_var declaration ->
      let typ = resolve_type state declaration.vd_declared in
      if Types.equal typ Types.Void then
        compile_error statement.s_span "a variable cannot be void";
      declaration.vd_type <- Some typ;
      let actual = check state declaration.vd_initializer (Some typ) in
      expect actual ~wanted:typ declaration.vd_initializer.e_span
        "this initial value";
      if declared_here state declaration.vd_name then
        compile_error statement.s_span "`%s` is already declared in this block"
          declaration.vd_name;
      declare state declaration.vd_name typ
  | S_fun definition ->
      (* The signature was registered when the block was entered. *)
      check_function state definition
  | S_return value -> (
      let wanted = List.hd state.results in
      match value with
      | None ->
          if not (Types.equal wanted Types.Void) then
            compile_error statement.s_span
              "this function returns %s, so `return` needs a value"
              (Types.describe wanted)
      | Some value ->
          if Types.equal wanted Types.Void then
            compile_error statement.s_span
              "this function returns void, so `return` takes no value";
          let actual = check state value (Some wanted) in
          expect actual ~wanted value.e_span "this returned value")
  | S_if branch -> check_conditional_statement state branch
  | S_while (condition, body) ->
      require_bool state condition "a while condition";
      state.loop_depth <- state.loop_depth + 1;
      check_block state body ~own_scope:true;
      state.loop_depth <- state.loop_depth - 1
  | S_for loop ->
      (* The loop's own scope holds whatever the initialiser declares, so it is
         gone once the loop is. *)
      push_scope state;
      (match loop.fo_initializer with
      | Some initializer_ -> check_statement state initializer_
      | None -> ());
      (match loop.fo_condition with
      | Some condition -> require_bool state condition "a for condition"
      | None -> ());
      (match loop.fo_step with
      | Some step -> ignore (check state step None)
      | None -> ());
      state.loop_depth <- state.loop_depth + 1;
      check_block state loop.fo_body ~own_scope:true;
      state.loop_depth <- state.loop_depth - 1;
      pop_scope state
  | S_break ->
      if state.loop_depth = 0 then
        compile_error statement.s_span
          "`break` is only meaningful inside a loop"
  | S_continue ->
      if state.loop_depth = 0 then
        compile_error statement.s_span
          "`continue` is only meaningful inside a loop"
  | S_expr value -> ignore (check state value None)
  | S_block body -> check_block state body ~own_scope:true

and check_conditional_statement state branch =
  require_bool state branch.if_condition "an if condition";
  check_block state branch.if_then ~own_scope:true;
  match branch.if_else with
  | None -> ()
  | Some (Else_block body) -> check_block state body ~own_scope:true
  | Some (Else_if inner) -> check_conditional_statement state inner

and require_bool state condition what =
  let actual = check state condition (Some Types.Bool) in
  if not (Types.equal actual Types.Bool) then
    compile_error condition.e_span "%s is a bool, but this is %s" what
      (Types.describe actual)

(* -- expressions ----------------------------------------------------------- *)

and check state expression expected =
  let typ = check_uncached state expression expected in
  expression.e_type <- Some typ;
  typ

and check_uncached state expression expected =
  match expression.e_kind with
  | E_int value ->
      let typ =
        match expected with
        | Some typ when Types.is_integer typ -> typ
        | _ -> Types.Int
      in
      let low, high = Types.range_of typ in
      if Int64.compare value low < 0 || Int64.compare value high > 0 then
        compile_error expression.e_span "%Ld does not fit in %s" value
          (Types.describe typ);
      typ
  | E_float _ -> (
      match expected with
      | Some typ when Types.is_floating typ -> typ
      | _ -> Types.Float64)
  | E_string _ -> Types.String
  | E_char _ -> Types.Char
  | E_bool _ -> Types.Bool
  | E_null -> (
      match expected with
      | Some (Types.Pointer _ as typ) -> typ
      | _ -> Types.Null_pointer)
  | E_name name -> check_name state expression name
  | E_array literal -> check_array state expression literal expected
  | E_struct literal -> check_struct_literal state expression literal
  | E_fun definition ->
      resolve_signature state definition;
      check_function state definition;
      Ast.some "a signature" definition.fd_type
  | E_call (callee, arguments) -> check_call state expression callee arguments
  | E_index (subject, index) -> check_index state subject index
  | E_field access -> check_field_access state expression access
  | E_unary (op, operand) -> check_unary state expression op operand expected
  | E_cast (operand, target) -> check_cast state expression operand target
  | E_binary operation -> check_binary state expression operation expected
  | E_assign (target, value) -> check_assign state target value
  | E_if branch -> check_conditional state branch expected

and check_name state expression name =
  match lookup state name.n_name with
  | Some typ ->
      name.n_resolution <- Local;
      typ
  | None -> (
      match find_global (home state) name.n_name with
      | Some global ->
          name.n_resolution <- Global global;
          Ast.some "a global" global.g_type
      | None -> (
          match find_function (home state) name.n_name with
          | Some declaration ->
              name.n_resolution <- Named_function declaration;
              Ast.some "a signature" declaration.fn_definition.fd_type
          | None -> (
              match find_import (home state) name.n_name with
              | Some entry ->
                  name.n_resolution <-
                    Module (Ast.some "an import" entry.im_target);
                  compile_error expression.e_span
                    "`%s` is a module, so it needs a member, as in `%s.x`"
                    name.n_name name.n_name
              | None ->
                  compile_error expression.e_span
                    "there is nothing named `%s` here" name.n_name)))

and check_array state expression literal expected =
  let element =
    match expected with Some (Types.Array element) -> Some element | _ -> None
  in
  match literal.ar_count with
  | Some count ->
      let actual = check state (List.hd literal.ar_elements) element in
      let counted = check state count (Some Types.Int) in
      if not (Types.equal counted Types.Int) then
        compile_error count.e_span "an array length is an int, but this is %s"
          (Types.describe counted);
      Types.Array
        (match element with Some element -> element | None -> actual)
  | None -> (
      match literal.ar_elements with
      | [] -> (
          match element with
          | Some element -> Types.Array element
          | None ->
              compile_error expression.e_span
                "an empty array literal has no element type to go on; give the \
                 variable a type, as in `var a: array<int> = [];`")
      | first :: rest ->
          let actual = check state first element in
          let wanted =
            match element with Some element -> element | None -> actual
          in
          expect actual ~wanted first.e_span "this element";
          List.iter
            (fun value ->
              let actual = check state value (Some wanted) in
              expect actual ~wanted value.e_span "this element")
            rest;
          Types.Array wanted)

and check_struct_literal state expression literal =
  let declaration =
    match literal.sl_path with
    | [ name ] -> (
        match find_struct (home state) name with
        | Some declaration -> declaration
        | None ->
            compile_error expression.e_span "there is no struct named `%s`" name
        )
    | [ module_name; type_name ] -> (
        let target = imported_module state module_name expression.e_span in
        match find_struct target type_name with
        | None ->
            compile_error expression.e_span "module `%s` has no struct `%s`"
              module_name type_name
        | Some declaration ->
            if not declaration.sd_exported then
              compile_error expression.e_span "`%s.%s` is not exported"
                module_name type_name;
            declaration)
    | _ ->
        compile_error expression.e_span
          "a struct name is either `Name` or `module.Name`"
  in
  let structure = Ast.some "a struct" declaration.sd_structure in
  literal.sl_structure <- Some structure;
  let given = Array.make (List.length structure.Types.fields) false in
  List.iter
    (fun initializer_ ->
      let index = Types.index_of structure initializer_.fi_name in
      if index < 0 then
        compile_error initializer_.fi_span "struct `%s` has no field `%s`"
          structure.Types.name initializer_.fi_name;
      if given.(index) then
        compile_error initializer_.fi_span "field `%s` is given twice"
          initializer_.fi_name;
      given.(index) <- true;
      initializer_.fi_index <- index;
      let _, wanted = Types.field_at structure index in
      let actual = check state initializer_.fi_value (Some wanted) in
      expect actual ~wanted initializer_.fi_value.e_span
        (Printf.sprintf "field `%s`" initializer_.fi_name))
    literal.sl_fields;
  Array.iteri
    (fun index filled ->
      if not filled then
        compile_error expression.e_span "field `%s` of struct `%s` is missing"
          (fst (Types.field_at structure index))
          structure.Types.name)
    given;
  Ast.some "a struct type" declaration.sd_type

and check_call state expression callee arguments =
  let callee_type = check state callee None in
  match callee_type with
  | Types.Function (parameters, result) ->
      if List.length arguments <> List.length parameters then
        compile_error expression.e_span
          "this function takes %d argument(s), but was given %d"
          (List.length parameters) (List.length arguments);
      List.iteri
        (fun index argument ->
          let wanted = List.nth parameters index in
          let actual = check state argument (Some wanted) in
          expect actual ~wanted argument.e_span
            (Printf.sprintf "argument %d" (index + 1)))
        arguments;
      result
  | _ ->
      compile_error callee.e_span
        "this is %s, which is not something you can call"
        (Types.describe callee_type)

and check_index state subject index =
  let subject_type = check state subject None in
  let index_type = check state index (Some Types.Int) in
  if not (Types.equal index_type Types.Int) then
    compile_error index.e_span "an index is an int, but this is %s"
      (Types.describe index_type);
  match subject_type with
  | Types.Array element -> element
  | Types.String -> Types.Byte
  | _ ->
      compile_error subject.e_span "%s cannot be indexed"
        (Types.describe subject_type)

and check_field_access state expression access =
  (* `a.b` where `a` names an imported module is a member reference, not a
     field, so that possibility is settled before the subject is typed. *)
  let module_member =
    match access.fa_subject.e_kind with
    | E_name name when not (is_bound state name.n_name) -> (
        match find_import (home state) name.n_name with
        | Some entry ->
            let target = Ast.some "an import" entry.im_target in
            name.n_resolution <- Module target;
            access.fa_subject.e_type <- Some Types.Void;
            Some (check_module_member expression access target name.n_name)
        | None -> None)
    | _ -> None
  in
  match module_member with
  | Some typ -> typ
  | None -> (
      let subject = check state access.fa_subject None in
      (* Reaching a field through a pointer to a struct saves writing out the
         dereference everywhere a linked structure is walked. *)
      let holder =
        match subject with
        | Types.Pointer (Types.Struct _ as held) ->
            access.fa_through_pointer <- true;
            held
        | _ -> subject
      in
      match holder with
      | Types.Struct structure ->
          let index = Types.index_of structure access.fa_name in
          if index < 0 then
            compile_error expression.e_span "struct `%s` has no field `%s`"
              structure.Types.name access.fa_name;
          access.fa_resolution <- Struct_field index;
          snd (Types.field_at structure index)
      | _ -> (
          match subject with
          | Types.Array _ | Types.String ->
              if access.fa_name <> "length" then
                compile_error expression.e_span
                  "%s has no member `%s`; it has `length`"
                  (Types.describe subject) access.fa_name;
              access.fa_resolution <- Length;
              Types.Int
          | _ ->
              compile_error expression.e_span "%s has no member `%s`"
                (Types.describe subject) access.fa_name))

and check_module_member expression access target module_name =
  match find_function target access.fa_name with
  | Some declaration ->
      if not declaration.fn_exported then
        compile_error expression.e_span "`%s.%s` is not exported" module_name
          access.fa_name;
      access.fa_resolution <- Module_function declaration;
      Ast.some "a signature" declaration.fn_definition.fd_type
  | None -> (
      match find_global target access.fa_name with
      | Some global ->
          if not global.g_exported then
            compile_error expression.e_span "`%s.%s` is not exported"
              module_name access.fa_name;
          access.fa_resolution <- Module_global global;
          Ast.some "a global" global.g_type
      | None ->
          if find_struct target access.fa_name <> None then
            compile_error expression.e_span
              "`%s.%s` is a type, not a value; to build one write `new %s.%s { \
               ... }`"
              module_name access.fa_name module_name access.fa_name;
          compile_error expression.e_span "module `%s` has no member `%s`"
            module_name access.fa_name)

and check_unary state expression op operand expected =
  match op with
  | Plus | Minus ->
      let actual = check state operand expected in
      if not (Types.is_numeric actual) then
        compile_error expression.e_span "`%s` wants a number, but this is %s"
          (if op = Plus then "+" else "-")
          (Types.describe actual);
      actual
  | Not ->
      let actual = check state operand (Some Types.Bool) in
      if not (Types.equal actual Types.Bool) then
        compile_error expression.e_span "`!` wants a bool, but this is %s"
          (Types.describe actual);
      actual
  | Complement ->
      let actual = check state operand expected in
      if not (Types.is_integer actual) then
        compile_error expression.e_span
          "`~` wants a whole number, but this is %s" (Types.describe actual);
      actual
  | Dereference -> (
      let actual = check state operand None in
      match actual with
      | Types.Pointer element -> element
      | _ ->
          compile_error expression.e_span "`*` wants a pointer, but this is %s"
            (Types.describe actual))
  | Address_of ->
      let inner =
        match expected with
        | Some (Types.Pointer element) -> Some element
        | _ -> None
      in
      let actual = check state operand inner in
      if Types.equal actual Types.Void then
        compile_error expression.e_span "there is no address of a void value";
      Types.Pointer actual

and check_cast state expression operand target =
  let wanted = resolve_type state target in
  let actual = check state operand None in
  if Types.is_numeric actual && Types.is_numeric wanted then wanted
  else
    match (actual, wanted) with
    | Types.Pointer _, Types.Pointer _ | Types.Null_pointer, Types.Pointer _ ->
        wanted
    | _ ->
        if Types.equal actual wanted then wanted
        else
          compile_error expression.e_span "there is no conversion from %s to %s"
            (Types.describe actual) (Types.describe wanted)

and check_binary state expression operation expected =
  match operation.bin_op with
  | And | Or ->
      require_bool state operation.bin_left "an operand of `&&` or `||`";
      require_bool state operation.bin_right "an operand of `&&` or `||`";
      operation.bin_operand <- Some Types.Bool;
      Types.Bool
  | op -> (
      (* A bare number takes its type from the other side, so that `1 + x` reads
         the same as `x + 1`. *)
      let left, right =
        if
          is_bare_number operation.bin_left
          && not (is_bare_number operation.bin_right)
        then begin
          let right = check state operation.bin_right expected in
          let left = check state operation.bin_left (Some right) in
          (left, right)
        end
        else begin
          let left = check state operation.bin_left expected in
          let right = check state operation.bin_right (Some left) in
          (left, right)
        end
      in
      if
        (not (Types.assignable ~from:left ~target:right))
        && not (Types.assignable ~from:right ~target:left)
      then
        compile_error expression.e_span
          "these operands are %s and %s; there are no implicit conversions, so \
           write one with `as`"
          (Types.describe left) (Types.describe right);
      let operand =
        if Types.equal left Types.Null_pointer then right else left
      in
      operation.bin_operand <- Some operand;
      match op with
      | Add when Types.equal operand Types.String -> operand
      | Add | Subtract | Multiply | Divide ->
          if not (Types.is_numeric operand) then
            compile_error expression.e_span
              "`%s` wants numbers, but these are %s" (describe_op op)
              (Types.describe operand);
          operand
      | Remainder ->
          if not (Types.is_integer operand) then
            compile_error expression.e_span
              "`%%` wants whole numbers, but these are %s"
              (Types.describe operand);
          operand
      | Less | Less_equal | Greater | Greater_equal ->
          if
            (not (Types.is_numeric operand))
            && not (Types.equal operand Types.String)
          then
            compile_error expression.e_span
              "`%s` compares numbers or strings, but these are %s"
              (describe_op op) (Types.describe operand);
          Types.Bool
      | Equal | Not_equal ->
          (match operand with
          | Types.Function _ ->
              compile_error expression.e_span "functions cannot be compared"
          | _ -> ());
          Types.Bool
      | And | Or -> Types.Bool)

and check_conditional state branch expected =
  require_bool state branch.if_condition "an if condition";
  let consequent = check_value_block state branch.if_then expected in
  let wanted =
    match expected with Some typ -> Some typ | None -> Some consequent
  in
  let alternative =
    match branch.if_else with
    | None ->
        compile_error branch.if_span
          "an if used for its value needs both arms, since it has to give one \
           either way"
    | Some (Else_block body) -> check_value_block state body wanted
    (* `else if` gives its value the same way, so it is checked as one. *)
    | Some (Else_if inner) -> check_conditional state inner wanted
  in
  if
    (not (Types.assignable ~from:consequent ~target:alternative))
    && not (Types.assignable ~from:alternative ~target:consequent)
  then
    compile_error branch.if_span
      "one arm of this if gives %s and the other gives %s, so it has no single \
       type"
      (Types.describe consequent)
      (Types.describe alternative);
  if Types.equal consequent Types.Void then
    compile_error branch.if_span
      "an if used for its value has to give one, but these arms give void";
  if Types.equal consequent Types.Null_pointer then alternative else consequent

and check_value_block state body expected =
  push_scope state;
  let value = value_of_block body in
  declare_nested_functions state body.blk_statements;
  List.iter
    (fun statement ->
      reject_jumps statement ~inside_loop:false;
      check_statement state statement)
    body.blk_statements;
  let typ = check state value expected in
  pop_scope state;
  typ

and check_assign state target value =
  let wanted = check state target None in
  require_assignable target;
  let actual = check state value (Some wanted) in
  expect actual ~wanted value.e_span "this value";
  wanted

(* The forms that name storage rather than a result. *)
and require_assignable target =
  match target.e_kind with
  | E_name name -> (
      match name.n_resolution with
      | Local | Global _ -> ()
      | _ -> compile_error target.e_span "`%s` is not a variable" name.n_name)
  | E_field access -> (
      match access.fa_resolution with
      | Struct_field _ | Module_global _ -> ()
      | _ -> compile_error target.e_span "`%s` is not a variable" access.fa_name
      )
  | E_index (subject, _) ->
      if
        match subject.e_type with
        | Some typ -> Types.equal typ Types.String
        | None -> false
      then compile_error target.e_span "strings cannot be changed in place"
  | E_unary (Dereference, _) -> ()
  | _ ->
      compile_error target.e_span
        "this is not something that can be assigned to"

(* -------------------------------------------------------------------------- *)
(* Running the phases                                                           *)
(* -------------------------------------------------------------------------- *)

let guard state span body =
  try body () with
  | Compile_error (span, message) ->
      state.errors <- (span, message) :: state.errors;
      state.scopes <- [];
      state.results <- [];
      state.loop_depth <- 0
  | Failure message ->
      state.errors <- (span, message) :: state.errors;
      state.scopes <- [];
      state.results <- [];
      state.loop_depth <- 0

let check_bodies state =
  List.iter
    (fun module_ast ->
      state.home <- Some module_ast;
      List.iter
        (fun declaration ->
          guard state declaration.g_span (fun () ->
              let wanted = Ast.some "a global" declaration.g_type in
              let actual =
                check state declaration.g_initializer (Some wanted)
              in
              expect actual ~wanted declaration.g_initializer.e_span
                "this initial value"))
        module_ast.m_globals;
      List.iter
        (fun declaration ->
          guard state declaration.fn_definition.fd_span (fun () ->
              check_function state declaration.fn_definition))
        module_ast.m_functions)
    (Program.order state.program);
  state.home <- None

let check_entry_point state =
  let entry = Program.entry state.program in
  match find_function entry "main" with
  | None ->
      state.errors <-
        ( entry.m_span,
          Printf.sprintf
            "module `%s` is the entry point, so it needs a `fun main() -> int`"
            entry.m_name )
        :: state.errors
  | Some declaration ->
      let definition = declaration.fn_definition in
      if definition.fd_parameters <> [] then
        state.errors <-
          (definition.fd_span, "`main` takes no arguments") :: state.errors;
      let result = Ast.some "a result type" definition.fd_result in
      if
        (not (Types.equal result Types.Int))
        && not (Types.equal result Types.Void)
      then
        state.errors <-
          (definition.fd_span, "`main` returns int or void") :: state.errors

(* Checks every module of a loaded program. The returned list is empty when the
   program is well formed. *)
let check_program program =
  let state =
    {
      program;
      home = None;
      scopes = [];
      results = [];
      loop_depth = 0;
      errors = [];
    }
  in
  match
    try
      declare_structs state;
      resolve_struct_fields state;
      reject_struct_cycles state;
      declare_signatures state;
      None
    with Compile_error (span, message) -> Some (span, message)
  with
  (* Nothing later can be trusted once the shape of the program is wrong, so
     this is where the checker gives up. *)
  | Some error -> [ error ]
  | None ->
      check_bodies state;
      check_entry_point state;
      List.rev state.errors
