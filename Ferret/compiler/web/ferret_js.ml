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
          ( "watches",
            inject
              (Js.array
                 (Array.of_list
                    (List.map
                       (fun (node, label) ->
                         obj
                           [|
                             ("node", inject (Js.string node));
                             ("label", inject (Js.string label));
                           |])
                       out.watches))) );
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

(* The node catalogue, and what one node of a kind looks like once its own
   settings are taken into account -- the title on the card, the sign in its
   icon, and the ports to draw.  Both are JSON text: the editor parses one
   shape rather than reaching into an OCaml value through js_of_ocaml. *)
let specs () = Js.string (Yojson.Safe.to_string (Ferret.Spec.to_json ()))

let describe (kind : Js.js_string Js.t) (data : Js.js_string Js.t) =
  let parsed =
    match Yojson.Safe.from_string (Js.to_string data) with
    | json -> json
    | exception _ -> `Null
  in
  Js.string
    (Yojson.Safe.to_string
       (Ferret.Spec.describe_json ~kind:(Js.to_string kind) ~data:parsed))

let () =
  let api =
    obj
      [|
        ("compile", inject (Js.wrap_callback compile));
        ("specs", inject (Js.wrap_callback specs));
        ("describe", inject (Js.wrap_callback describe));
      |]
  in
  (* [Js.export] alone lands on module.exports under node; the editor loads
     the bundle with a plain script tag and wants it on the global. *)
  Js.export "ferret" api;
  Js.Unsafe.set Js.Unsafe.global (Js.string "ferret") api
