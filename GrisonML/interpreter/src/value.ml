(* Runtime values, and the shape of a module at run time.

   A module is a fragment: the three maps of names it defines.  Evaluating a
   "mod ... end" produces one, sealing it with a signature drops the names the
   signature does not mention, and "import" merges one back into scope.  A
   functor keeps its parameters, its body and the environment it was written
   in, and applying it evaluates that body again -- which is what makes each
   application produce its own types as well as its own values. *)

module SMap = Map.Make (String)

exception Runtime of string

let fail fmt = Printf.ksprintf (fun m -> raise (Runtime m)) fmt

type value =
  | VInt of int
  | VReal of float
  | VChar of char
  | VStr of string
  | VBool of bool
  | VUnit
  | VTuple of value list
  | VRec of (string * value) list
  | VCon of string * value option
  | VClos of Ast.rule list * env
  | VPrim of string * (value -> value)
  | VUndef (* a recursive binding, before its right-hand side has run *)

and frag = {
  f_vals : value ref SMap.t;
  f_cons : int SMap.t;   (* arity: 0 or 1 *)
  f_mods : mval SMap.t;
}

and mval =
  | MStruct of frag
  | MFunctor of functor_v

and functor_v = {
  fu_params : (string * Ast.sigexp) list;
  fu_ascr : Ast.sigexp option;
  fu_body : Ast.decl list;
  fu_env : env;
}

and env = {
  vals : value ref SMap.t;
  cons : int SMap.t;
  mods : mval SMap.t;
  sigs : Ast.spec list SMap.t;
}

let empty_frag = { f_vals = SMap.empty; f_cons = SMap.empty; f_mods = SMap.empty }

let empty_env =
  { vals = SMap.empty; cons = SMap.empty; mods = SMap.empty; sigs = SMap.empty }

let union a b = SMap.union (fun _ _ y -> Some y) a b

let merge_frag env f =
  { env with
    vals = union env.vals f.f_vals;
    cons = union env.cons f.f_cons;
    mods = union env.mods f.f_mods }

let merge_frags a b =
  { f_vals = union a.f_vals b.f_vals;
    f_cons = union a.f_cons b.f_cons;
    f_mods = union a.f_mods b.f_mods }

(* The printed form of a value.  Constructors print applied, records print
   their fields in the order they were built, and a list prints as a list
   rather than as the :: chain it is. *)
let rec show v =
  match v with
  | VInt n -> string_of_int n
  | VReal r ->
    let s = Printf.sprintf "%.12g" r in
    if String.contains s '.' || String.contains s 'e' || String.contains s 'n' then s
    else s ^ ".0"
  | VChar c -> "'" ^ Char.escaped c ^ "'"
  | VStr s -> "\"" ^ String.escaped s ^ "\""
  | VBool b -> if b then "true" else "false"
  | VUnit -> "()"
  | VTuple vs -> "(" ^ String.concat ", " (List.map show vs) ^ ")"
  | VRec fs -> "{" ^ String.concat ", " (List.map (fun (f, v) -> f ^ " = " ^ show v) fs) ^ "}"
  | VCon ("[]", None) -> "[]"
  | VCon ("::", Some (VTuple [ _; _ ])) ->
    let rec items v =
      match v with
      | VCon ("[]", None) -> []
      | VCon ("::", Some (VTuple [ h; t ])) -> show h :: items t
      | v -> [ ".. " ^ show v ]
    in
    "[" ^ String.concat ", " (items v) ^ "]"
  | VCon (c, None) -> c
  | VCon (c, Some (VTuple _ as a)) -> c ^ " " ^ show a
  | VCon (c, Some a) -> c ^ " " ^ paren a
  | VClos _ | VPrim _ -> "fn"
  | VUndef -> "<undefined>"

and paren v =
  match v with
  | VCon (_, Some _) -> "(" ^ show v ^ ")"
  | _ -> show v

(* Structural equality.  Functions have none; the type checker cannot say so,
   because the grammar has no equality types, so it is said here. *)
let rec equal a b =
  match (a, b) with
  | VInt x, VInt y -> x = y
  | VReal x, VReal y -> x = y
  | VChar x, VChar y -> x = y
  | VStr x, VStr y -> String.equal x y
  | VBool x, VBool y -> x = y
  | VUnit, VUnit -> true
  | VTuple xs, VTuple ys -> List.length xs = List.length ys && List.for_all2 equal xs ys
  | VRec xs, VRec ys ->
    List.length xs = List.length ys
    && List.for_all (fun (f, x) -> match List.assoc_opt f ys with
                                   | Some y -> equal x y
                                   | None -> false) xs
  | VCon (c, x), VCon (d, y) ->
    String.equal c d
    && (match (x, y) with
        | None, None -> true
        | Some x, Some y -> equal x y
        | _ -> false)
  | (VClos _ | VPrim _), _ | _, (VClos _ | VPrim _) -> fail "a function has no equality"
  | _ -> false

(* The order behind < <= > >= : the same shape as equality, and defined on the
   types the Ord constraint admits. *)
let rec compare_v a b =
  match (a, b) with
  | VInt x, VInt y -> compare x y
  | VReal x, VReal y -> compare x y
  | VChar x, VChar y -> compare x y
  | VStr x, VStr y -> String.compare x y
  | VBool x, VBool y -> compare x y
  | VUnit, VUnit -> 0
  | VTuple xs, VTuple ys -> compare_list xs ys
  | _ -> fail "these values cannot be ordered"

and compare_list xs ys =
  match (xs, ys) with
  | [], [] -> 0
  | [], _ -> -1
  | _, [] -> 1
  | x :: xs, y :: ys ->
    let c = compare_v x y in
    if c <> 0 then c else compare_list xs ys
