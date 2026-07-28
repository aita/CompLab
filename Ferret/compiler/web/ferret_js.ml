(* globalThis.ferret.compile(json) -> the same result the CLI would produce,
   with the module as a plain array of bytes for the caller to hand to
   WebAssembly.instantiate. *)

open Js_of_ocaml

let obj = Js.Unsafe.obj
let inject = Js.Unsafe.inject

let byte_array (s : string) =
  Js.array (Array.init (String.length s) (fun i -> Char.code s.[i]))

let error_object (e : Ferret.Graph.error) =
  obj
    [|
      ( "node",
        match e.node with
        | Some id -> inject (Js.string id)
        | None -> inject Js.null );
      ("message", inject (Js.string e.msg));
    |]

let compile (source : Js.js_string Js.t) =
  match Ferret.Compile.of_string (Js.to_string source) with
  | Ok out ->
      obj
        [|
          ("ok", inject Js._true);
          ("wasm", inject (byte_array out.wasm));
          ("wat", inject (Js.string out.wat));
          ("ir", inject (Js.string out.ir));
          ( "params",
            inject
              (Js.array (Array.of_list (List.map Js.string out.params))) );
          ("errors", inject (Js.array [||]));
        |]
  | Error errs ->
      obj
        [|
          ("ok", inject Js._false);
          ( "errors",
            inject
              (Js.array (Array.of_list (List.map error_object errs))) );
        |]

let () =
  let api = obj [| ("compile", inject (Js.wrap_callback compile)) |] in
  (* [Js.export] alone lands on module.exports under node; the editor loads
     the bundle with a plain script tag and wants it on the global. *)
  Js.export "ferret" api;
  Js.Unsafe.set Js.Unsafe.global (Js.string "ferret") api
