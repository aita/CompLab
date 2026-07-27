(* The table of datatype declarations.

   Every value of a datatype is a heap block whose first word is the
   constructor tag and whose remaining words are the arguments:

       Node (l, v, r)   ->   [ 1 | l | v | r ]
       Leaf             ->   [ 0 ]

   Constant constructors therefore have a representation too, but it never
   changes, so instead of allocating we emit one read-only block per constant
   constructor and refer to its address.  Keeping every constructor boxed costs
   a word and an indirection compared with OCaml's tagged immediates, and buys
   a back end that never has to ask whether a machine word is a pointer. *)

type constr = {
  cname : string;
  tag : int;
  arg_types : Types.t list;
  owner : string; (* the datatype this constructor belongs to *)
}

type decl = { tyname : string; constrs : constr list }

exception Error of string

let decls : (string, decl) Hashtbl.t = Hashtbl.create 16
let constrs : (string, constr) Hashtbl.t = Hashtbl.create 64
let order : string list ref = ref [] (* declaration order, for emission *)

let reset () =
  Hashtbl.reset decls;
  Hashtbl.reset constrs;
  order := []

let declare tyname constr_specs =
  if Hashtbl.mem decls tyname then
    raise (Error (Printf.sprintf "the type `%s` is declared twice" tyname));
  let constrs_of_decl =
    List.mapi
      (fun tag (cname, arg_types) ->
        if Hashtbl.mem constrs cname then
          raise
            (Error (Printf.sprintf "the constructor `%s` is declared twice" cname));
        { cname; tag; arg_types; owner = tyname })
      constr_specs
  in
  List.iter (fun c -> Hashtbl.replace constrs c.cname c) constrs_of_decl;
  Hashtbl.replace decls tyname { tyname; constrs = constrs_of_decl };
  order := tyname :: !order

let find_constr name = Hashtbl.find_opt constrs name

let constr_exn name =
  match find_constr name with
  | Some c -> c
  | None -> raise (Error (Printf.sprintf "unknown constructor `%s`" name))

let constrs_of tyname =
  match Hashtbl.find_opt decls tyname with
  | Some d -> d.constrs
  | None -> raise (Error (Printf.sprintf "unknown type `%s`" tyname))

let arity c = List.length c.arg_types
let is_constant c = c.arg_types = []
let all_decls () = List.rev_map (fun n -> Hashtbl.find decls n) !order

(* The empty list, which is built in rather than declared, but is represented
   exactly like any other constant constructor: a read-only block holding the
   tag 0.  `x :: xs` is the block [ 1 | x | xs ]. *)
let nil_label = "sable_list_nil"

(* The read-only block standing for a constant constructor. *)
let const_label c =
  (* Internal names carry their module path and a number, neither of which
     belongs in a symbol. *)
  let clean = String.map (fun ch -> if ch = '.' then '_' else ch) in
  Printf.sprintf "sable_const_%s_%s" (clean c.owner) (clean c.cname)

(* Every named type a written type mentions has to exist. *)
let rec check_type where t =
  match t with
  | Types.Named n when not (Hashtbl.mem decls n) ->
    raise (Error (Printf.sprintf "unknown type `%s` %s" n where))
  | Types.Fun (ts, r) ->
    List.iter (check_type where) ts;
    check_type where r
  | Types.Tuple ts -> List.iter (check_type where) ts
  | Types.Array t | Types.List t -> check_type where t
  | _ -> ()

(* A declaration may mention types declared later (or itself), so the check
   that every name resolves happens once all declarations are in. *)
let check_wellformed () =
  Hashtbl.iter
    (fun _ d ->
      List.iter
        (fun c ->
          List.iter
            (check_type (Printf.sprintf "in the declaration of `%s`" d.tyname))
            c.arg_types)
        d.constrs)
    decls
