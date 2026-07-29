(* The whole pipeline in one call: React Flow JSON in, wasm out. *)

type output = {
  wasm : string;  (* the module, as raw bytes in a string *)
  wat : string;
  ir : string;
  (* One entry per breakpoint the module can report, in index order. *)
  watches : (string * string) list;
  (* What the Run panel asks for before a run: export, label, default. *)
  inputs : (string * string * float) list;
}

type result = (output, Graph.error list) Result.t

let of_json (json : Yojson.Safe.t) : result =
  try
    let g = Graph.of_json json in
    let built = Lower.module_of_graph g in
    let m = built.m in
    Ok
      {
        wasm = Emit.module_of m;
        wat = Wat.of_module m;
        ir = Ir.to_string m;
        watches = built.watches;
        inputs = built.inputs;
      }
  with Graph.Errors errs -> Error errs

let of_string (s : string) : result =
  match Yojson.Safe.from_string s with
  | json -> of_json json
  | exception Yojson.Json_error msg ->
      Error [ Graph.error (Printf.sprintf "the graph is not valid JSON: %s" msg) ]
