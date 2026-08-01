(* Every module a run needs, loaded and linked to the modules it imports.

   Loading is depth first from the entry file, so [order] lists a module only
   after everything it imports, which is the order the checker and the evaluator
   both want. *)

open Diagnostics

(* The file extension a module of a given name is expected to live in. *)
let source_extension = ".otter"

type t = {
  directory : string;
  modules : (string, Ast.module_ast) Hashtbl.t;
  mutable loaded : Ast.module_ast list; (* newest first *)
  mutable loading : string list;
  mutable entry : Ast.module_ast option;
}

let parent_path path =
  match String.rindex_opt path '/' with
  | None -> ""
  | Some 0 -> "/"
  | Some index -> String.sub path 0 index

let beside directory name =
  if directory = "" then name
  else if
    String.length directory > 0 && directory.[String.length directory - 1] = '/'
  then directory ^ name
  else directory ^ "/" ^ name

let create path =
  {
    directory = parent_path path;
    modules = Hashtbl.create 16;
    loaded = [];
    loading = [];
    entry = None;
  }

let find program name = Hashtbl.find_opt program.modules name

(* Modules with their dependencies before them. *)
let order program = List.rev program.loaded

let entry program =
  match program.entry with
  | Some module_ast -> module_ast
  | None -> assert false

let read_file path span =
  match open_in_bin path with
  | exception Sys_error _ -> compile_error span "cannot read `%s`" path
  | channel ->
      let text = really_input_string channel (in_channel_length channel) in
      close_in channel;
      text

(* A module the implementation provides. Its functions have no body and stand
   for host functions, which is what a body-less function is anywhere else, so
   nothing downstream has to know where the module came from. *)
let build_builtin_module (description : Builtins.builtin_module) =
  let span =
    {
      file = Printf.sprintf "<%s>" description.bm_name;
      start = { line = 0; column = 0 };
    }
  in
  let function_of (entry : Builtins.builtin_function) =
    let parameter index typ =
      {
        Ast.p_name = Printf.sprintf "argument%d" (index + 1);
        p_declared = Ast.written_type span typ;
        p_span = span;
        p_type = None;
      }
    in
    {
      Ast.fn_definition =
        Ast.func_def ~host:(Some entry.bf_host) ~span ~name:entry.bf_name
          ~parameters:(List.mapi parameter entry.bf_parameters)
          ~result:(Ast.written_type span entry.bf_result)
          ~body:None;
      fn_exported = true;
      fn_owner = None;
    }
  in
  let module_ast =
    {
      Ast.m_name = description.bm_name;
      m_file = span.file;
      m_span = span;
      m_imports = [];
      m_structs = [];
      m_aliases = [];
      m_functions = List.map function_of description.bm_functions;
      m_globals = [];
    }
  in
  List.iter
    (fun (entry : Ast.func_decl) -> entry.fn_owner <- Some module_ast)
    module_ast.Ast.m_functions;
  module_ast

let adopt program module_ast =
  match Hashtbl.find_opt program.modules module_ast.Ast.m_name with
  | Some existing ->
      compile_error existing.Ast.m_span "module `%s` is already loaded"
        module_ast.Ast.m_name
  | None ->
      Hashtbl.replace program.modules module_ast.Ast.m_name module_ast;
      module_ast

let rec resolve_imports program module_ast =
  program.loading <- module_ast.Ast.m_name :: program.loading;
  List.iter
    (fun (entry : Ast.import) ->
      if entry.im_name = module_ast.Ast.m_name then
        compile_error entry.im_span "module `%s` imports itself" entry.im_name;
      if List.mem entry.im_name program.loading then
        compile_error entry.im_span
          "modules `%s` and `%s` import one another, and a module has to be \
           complete before another can use it"
          module_ast.Ast.m_name entry.im_name;
      entry.im_target <- Some (require program entry.im_name entry.im_span))
    module_ast.Ast.m_imports;
  program.loading <-
    List.filter (fun name -> name <> module_ast.Ast.m_name) program.loading;
  program.loaded <- module_ast :: program.loaded

and require program name span =
  match find program name with
  | Some loaded -> loaded
  | None ->
      let parsed =
        match Builtins.find_builtin_module name with
        | Some description -> build_builtin_module description
        | None ->
            let path = beside program.directory (name ^ source_extension) in
            if not (Sys.file_exists path) then
              compile_error span "no module `%s`: there is no file `%s`" name
                path;
            let parsed =
              Parse.parse_module ~file:path ~text:(read_file path span)
            in
            if parsed.Ast.m_name <> name then
              compile_error parsed.Ast.m_span
                "`%s` declares module `%s`, but it was imported as `%s`" path
                parsed.Ast.m_name name;
            parsed
      in
      let module_ast = adopt program parsed in
      resolve_imports program module_ast;
      module_ast

(* Reads the entry file and everything it reaches. *)
let load_entry program path =
  let span = { file = path; start = { line = 0; column = 0 } } in
  let text = read_file path span in
  let parsed = Parse.parse_module ~file:path ~text in
  let stem = Filename.remove_extension (Filename.basename path) in
  if parsed.Ast.m_name <> stem then
    compile_error parsed.Ast.m_span
      "this file declares module `%s`, but a module lives in a file named \
       after it, so `%s%s` was expected"
      parsed.Ast.m_name parsed.Ast.m_name source_extension;
  let module_ast = adopt program parsed in
  program.entry <- Some module_ast;
  resolve_imports program module_ast
