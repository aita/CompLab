(* The operator table.

   Prolog's syntax is not fixed: op/3 adds and removes operators while a
   program is being read, so the table is mutable state that both the reader
   and the writer consult.  This is why the reader is a hand-written
   precedence climber rather than a menhir grammar -- an LR table is built
   once, and this one is not. *)

type kind =
  | XFX
  | XFY
  | YFX (* infix *)
  | FY
  | FX (* prefix *)
  | XF
  | YF (* postfix *)

let kind_of_string = function
  | "xfx" -> Some XFX
  | "xfy" -> Some XFY
  | "yfx" -> Some YFX
  | "fy" -> Some FY
  | "fx" -> Some FX
  | "xf" -> Some XF
  | "yf" -> Some YF
  | _ -> None

let string_of_kind = function
  | XFX -> "xfx"
  | XFY -> "xfy"
  | YFX -> "yfx"
  | FY -> "fy"
  | FX -> "fx"
  | XF -> "xf"
  | YF -> "yf"

let is_prefix = function FY | FX -> true | _ -> false
let is_infix = function XFX | XFY | YFX -> true | _ -> false
let is_postfix = function XF | YF -> true | _ -> false

type entry = { priority : int; kind : kind }

(* An atom can be a prefix operator and an infix one at the same time (`-` is
   the obvious case), so the two live in separate tables. *)
let prefix : (string, entry) Hashtbl.t = Hashtbl.create 64
let infix_postfix : (string, entry) Hashtbl.t = Hashtbl.create 64

let table_for kind = if is_prefix kind then prefix else infix_postfix

let add priority kind name =
  let table = table_for kind in
  if priority = 0 then Hashtbl.remove table name else Hashtbl.replace table name { priority; kind }

let lookup_prefix name = Hashtbl.find_opt prefix name
let lookup_infix_postfix name = Hashtbl.find_opt infix_postfix name
let is_operator name = Hashtbl.mem prefix name || Hashtbl.mem infix_postfix name

(* Every entry for an atom, so that current_op/3 can enumerate them. *)
let entries name =
  List.filter_map (fun t -> Hashtbl.find_opt t name) [ prefix; infix_postfix ]

let fold f init =
  let step name entry acc = f name entry acc in
  Hashtbl.fold step prefix (Hashtbl.fold step infix_postfix init)

(* The ISO table, plus the handful of additions every Prolog has. *)
let () =
  List.iter
    (fun (priority, kind, names) ->
      match kind_of_string kind with
      | Some kind -> List.iter (add priority kind) names
      | None -> assert false)
    [
      (1200, "xfx", [ ":-"; "-->" ]);
      (1200, "fx", [ ":-"; "?-" ]);
      (1150, "fx", [ "dynamic"; "discontiguous"; "initialization"; "multifile"; "module"; "public"; "table" ]);
      (1100, "xfy", [ ";"; "|" ]);
      (1050, "xfy", [ "->"; "*->" ]);
      (1000, "xfy", [ "," ]);
      (990, "xfx", [ ":=" ]);
      (900, "fy", [ "\\+" ]);
      (700, "xfx", [ "="; "\\="; "=="; "\\=="; "@<"; "@>"; "@=<"; "@>="; "=.."; "is"; "=:="; "=\\="; "<"; ">"; "=<"; ">="; "=@="; "\\=@="; "as"; ">:<"; ":<" ]);
      (600, "xfy", [ ":" ]);
      (500, "yfx", [ "+"; "-"; "/\\"; "\\/"; "xor" ]);
      (500, "fx", [ "?" ]);
      (400, "yfx", [ "*"; "/"; "//"; "rem"; "mod"; "div"; "<<"; ">>"; "divmod" ]);
      (200, "xfx", [ "**" ]);
      (200, "xfy", [ "^" ]);
      (200, "fy", [ "-"; "+"; "\\" ]);
      (100, "yfx", [ "." ]);
      (1, "fx", [ "$" ]);
    ]
