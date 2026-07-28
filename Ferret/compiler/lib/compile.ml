(* The whole pipeline in one call: React Flow JSON in, wasm out. *)

type output = {
  wasm : string;  (* the module, as raw bytes in a string *)
  wat : string;
  ir : string;
  params : string list;
  (* One entry per breakpoint the module can report, in index order. *)
  watches : (string * string) list;
}

type result = (output, Graph.error list) Result.t

let of_json (json : Yojson.Safe.t) : result =
  try
    let g = Graph.of_json json in
    let f, watches = Lower.func_of_graph g in
    Ok
      {
        wasm = Emit.module_of_func f;
        wat = Wat.of_func f;
        ir = Ir.to_string f;
        params = f.params;
        watches;
      }
  with Graph.Errors errs -> Error errs

let of_string (s : string) : result =
  match Yojson.Safe.from_string s with
  | json -> of_json json
  | exception Yojson.Json_error msg ->
      Error [ Graph.error (Printf.sprintf "the graph is not valid JSON: %s" msg) ]
