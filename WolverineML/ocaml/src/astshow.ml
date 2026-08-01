(* An indented dump of the typed syntax tree, for [wolv emit -s ast]. *)

let put out depth text = out := (String.concat "" (List.init depth (fun _ -> "  ")) ^ text) :: !out

let show_type (e : Ast.exp) =
  match e.ty with None -> "" | Some ty -> " : " ^ Types.show ty

(* A string literal, written the way the Python tree writes it, so that a dump
   taken from either is the same dump.  Every character of one is a byte, and a
   byte that stands for nothing printable is shown as [\xNN]. *)
let quoted text =
  let quote = if String.contains text '\'' && not (String.contains text '"') then '"' else '\'' in
  let out = Buffer.create (String.length text + 2) in
  Buffer.add_char out quote;
  String.iter
    (fun ch ->
      let code = Char.code ch in
      if ch = quote || ch = '\\' then begin
        Buffer.add_char out '\\';
        Buffer.add_char out ch
      end
      else if ch = '\n' then Buffer.add_string out "\\n"
      else if ch = '\r' then Buffer.add_string out "\\r"
      else if ch = '\t' then Buffer.add_string out "\\t"
      else if Uucp.Gc.general_category (Uchar.of_int code) = `Cc
              || (match Uucp.Gc.general_category (Uchar.of_int code) with
                 | `Cf | `Cs | `Co | `Cn | `Zl | `Zp -> true
                 | `Zs -> ch <> ' '
                 | _ -> false)
      then Buffer.add_string out (Printf.sprintf "\\x%02x" code)
      else Buffer.add_utf_8_uchar out (Uchar.of_int code))
    text;
  Buffer.add_char out quote;
  Buffer.contents out

let escapes = function
  | Some (sym : Types.var_sym) when sym.escapes -> " (escapes)"
  | _ -> ""

let rec decl out depth (d : Ast.decl) =
  match d with
  | Ast.Type_decl binds ->
      List.iter (fun (b : Ast.type_bind) -> put out depth ("type " ^ b.bind_name)) binds
  | Ast.Val_decl v ->
      let keyword = if v.is_var then "var" else "val" in
      let name = match v.bound_name with Some n -> n | None -> "()" in
      put out depth (keyword ^ " " ^ name ^ escapes v.decl_sym);
      exp out (depth + 1) v.init
  | Ast.Fun_decl binds ->
      List.iter
        (fun (b : Ast.fun_bind) ->
          let params =
            String.concat ", "
              (List.map (fun (p : Ast.param) -> p.param_name ^ escapes p.param_sym) b.fun_params)
          in
          let result =
            match b.sym with Some s -> Types.show s.result | None -> "?"
          in
          put out depth (Printf.sprintf "fun %s(%s) : %s" b.fun_label params result);
          exp out (depth + 1) b.fun_body)
        binds

and exp out depth (e : Ast.exp) =
  match e.node with
  | Ast.Int_lit v -> put out depth (Printf.sprintf "int %Ld" v)
  | Ast.Str_lit v -> put out depth ("string " ^ quoted v)
  | Ast.Bool_lit b -> put out depth ("bool " ^ if b then "true" else "false")
  | Ast.Nil_lit -> put out depth "nil"
  | Ast.Unit_lit -> put out depth "()"
  | Ast.Var v -> put out depth ("var " ^ v.name ^ show_type e)
  | Ast.Call c ->
      put out depth ("call " ^ c.callee ^ show_type e);
      List.iter (exp out (depth + 1)) c.args
  | Ast.Record_lit r ->
      put out depth ("record " ^ r.tyname ^ show_type e);
      List.iter
        (fun (f : Ast.field_init) ->
          put out (depth + 1) (f.init_name ^ " =");
          exp out (depth + 2) f.value)
        r.inits
  | Ast.Index (array, index) ->
      put out depth ("index" ^ show_type e);
      exp out (depth + 1) array;
      exp out (depth + 1) index
  | Ast.Field f ->
      put out depth ("field ." ^ f.select ^ show_type e);
      exp out (depth + 1) f.record
  | Ast.Neg operand ->
      put out depth "neg";
      exp out (depth + 1) operand
  | Ast.Bin (op, lhs, rhs) | Ast.Logic (op, lhs, rhs) ->
      put out depth (op ^ show_type e);
      exp out (depth + 1) lhs;
      exp out (depth + 1) rhs
  | Ast.Assign (target, value) ->
      put out depth ":=";
      exp out (depth + 1) target;
      exp out (depth + 1) value
  | Ast.If (cond, then_, else_) ->
      put out depth ("if" ^ show_type e);
      exp out (depth + 1) cond;
      exp out (depth + 1) then_;
      (match else_ with Some els -> exp out (depth + 1) els | None -> ())
  | Ast.While (cond, body) ->
      put out depth "while";
      exp out (depth + 1) cond;
      exp out (depth + 1) body
  | Ast.For f ->
      put out depth ("for " ^ f.binder ^ escapes f.loop_sym);
      exp out (depth + 1) f.lo;
      exp out (depth + 1) f.hi;
      exp out (depth + 1) f.body
  | Ast.Break -> put out depth "break"
  | Ast.Seq items ->
      put out depth ("seq" ^ show_type e);
      List.iter (exp out (depth + 1)) items
  | Ast.Let (ds, body) ->
      put out depth ("let" ^ show_type e);
      List.iter (decl out (depth + 1)) ds;
      put out depth "in";
      exp out (depth + 1) body

let show_program (prog : Ast.program) =
  let out = ref [] in
  List.iter (decl out 0) prog;
  String.concat "\n" (List.rev !out) ^ "\n"
