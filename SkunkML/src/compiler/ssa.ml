(* Static single assignment form, in value shape.

   A *value* is an operation together with the values it uses.  It is not a
   name that something was assigned to: there are no names here at all, only
   values and references to them.  `v5 = prim ^ v1, v4` says that v5 is the
   concatenation of v1 and v4, and v1 and v4 are the very values those
   operations produced, not names looked up in a scope.  Constants are values
   too, so an operand is always just another value.

   Single assignment then costs nothing to maintain -- a value is produced in
   one place because a value *is* that place -- and three things become easy,
   all of which the later passes want:

     * def-use.  Replacing a value everywhere is one walk, and the number of
       uses is a field.
     * common subexpression elimination.  Two values with the same op and the
       same argument values are the same value.
     * instruction selection.  The DP tiler needs to know where a value has
       more than one use, because that is where the DAG has to be cut into
       trees.

   The rest is the textbook shape.  A function is basic blocks; a block is
   phi-functions, then values in order, then one terminator.  A phi's arguments
   line up positionally with the block's predecessors.  Memory is *not* in SSA:
   the values in a block are an ordered list, so the order of effects is the
   order they are written in.

   What is not textbook is how the phi-functions got here.  The usual
   construction starts from a graph with mutable variables and works out where
   phis belong, with dominance frontiers (Cytron et al.).  We never need it:
   the input is A-normal form with join points, and a join point with
   parameters *is* a block with phi-functions.  `dom.ml` still builds the
   dominator tree -- verification and register allocation both want it -- but
   the famous algorithm on top of it has nothing to do here.

   Nothing is lowered yet.  A record is still a record and a closure is still a
   closure; how those are laid out in memory is the next pass, and keeping it
   separate is what lets this one be nothing but a change of shape. *)

type const = CInt of int | CStr of string | CUnit

type op =
  | Const of const
  | Global of string (* a top-level binding, or a name from the basis *)
  | Param (* the function's argument *)
  | Capture of int (* the i'th value the running closure captured *)
  (* Allocating a closure and filling it in are two operations, because a
     recursive group defines closures that hold each other and SSA cannot
     express a cycle of definitions.  The machine already worked this way. *)
  | MkClos of string * int (* code label, how many captures *)
  | SetCap of int (* args: the closure and the value.  A statement. *)
  | Call (* args: the function and its argument *)
  | Prim of string
  | Record of string list (* the labels; args are the field values *)
  | Con of Types.constr (* args: the payload, if it has one *)
  | Field of string * int (* the label, and its offset.  args: the record *)
  | Payload (* args: the constructed value *)
  | Phi (* args: one per predecessor, positionally *)

type value = {
  mutable vid : int;
  mutable op : op;
  mutable args : value list;
  (* Which block this value lives in.  Every use has to be dominated by it,
     which is what `dom.ml` checks. *)
  mutable home : block;
  (* How many places refer to this value.  Recomputed rather than maintained,
     so that a pass cannot forget to. *)
  mutable uses : int;
  (* The Flat binder this came from, if any.  Printed as a comment: the value
     is identified by its number, and the name is only there to read by. *)
  origin : string;
}

and term =
  | Ret of value
  | TailCall of value * value
  | Jump of block
  | Switch of value * (Core.key * block) list * block option
  | Fail of Loc.t * string

and block = {
  mutable bid : int;
  mutable phis : value list;
  mutable values : value list; (* in order *)
  mutable term : term;
  mutable preds : block list;
}

type func = {
  fn : string;
  entry : block;
  mutable blocks : block list; (* in creation order; the entry is first *)
}

type prog = {
  funcs : func list;
  (* The top-level bindings in the order they run.  Each has a function of no
     arguments whose result is stored in the global of that name. *)
  items : item list;
}

and item = {
  iname : string;
  ibody : func option;
  ilabel : string Lazy.t option;
  ishow : bool;
}

(* A value that must not be removed even when nothing uses it. *)
let effectful v =
  match v.op with
  | SetCap _ | Call -> true
  | Prim (":=" | "div" | "mod") -> true
  | _ -> false

let is_phi v = match v.op with Phi -> true | _ -> false

let succs (b : block) =
  match b.term with
  | Jump t -> [ t ]
  | Switch (_, arms, dflt) ->
      List.map snd arms @ (match dflt with None -> [] | Some d -> [ d ])
  | Ret _ | TailCall _ | Fail _ -> []

(* Reverse postorder: every block comes after all of its dominators.  It is the
   order dominance is computed in, and the order a dump is easiest to read
   in. *)
let reverse_postorder (f : func) =
  let seen = Hashtbl.create 16 and out = ref [] in
  let rec walk b =
    if not (Hashtbl.mem seen b.bid) then begin
      Hashtbl.replace seen b.bid ();
      List.iter walk (succs b);
      out := b :: !out
    end
  in
  walk f.entry;
  !out

(* Values are identified by number, not by position, so nothing depends on the
   numbering -- but a dump is much easier to read when it counts upwards.  Done
   once, at the end of building. *)
let renumber (f : func) =
  let rpo = reverse_postorder f in
  let unreachable = List.filter (fun b -> not (List.memq b rpo)) f.blocks in
  f.blocks <- rpo @ unreachable;
  List.iteri (fun i b -> b.bid <- i) f.blocks;
  let n = ref 0 in
  List.iter
    (fun b ->
      List.iter
        (fun v ->
          v.vid <- !n;
          incr n)
        (b.phis @ b.values))
    f.blocks

(* Uses are recounted from scratch: cheaper to be right than to be
   incremental. *)
let recount (f : func) =
  let all = List.concat_map (fun b -> b.phis @ b.values) f.blocks in
  List.iter (fun v -> v.uses <- 0) all;
  let bump v = v.uses <- v.uses + 1 in
  List.iter
    (fun b ->
      List.iter (fun v -> List.iter bump v.args) (b.phis @ b.values);
      match b.term with
      | Ret v -> bump v
      | TailCall (a, b) ->
          bump a;
          bump b
      | Switch (v, _, _) -> bump v
      | Jump _ | Fail _ -> ())
    f.blocks

(* Printing, for `--dump-ssa`. *)

let const_str = function
  | CInt n -> if n < 0 then Printf.sprintf "~%d" (-n) else string_of_int n
  | CStr s -> Printf.sprintf "%S" s
  | CUnit -> "()"

let vref v = Printf.sprintf "v%d" v.vid
let args_str v = String.concat ", " (List.map vref v.args)

let op_str v =
  match v.op with
  | Const c -> Printf.sprintf "const %s" (const_str c)
  | Global g -> Printf.sprintf "global %s" g
  | Param -> "param"
  | Capture i -> Printf.sprintf "capture %d" i
  | MkClos (l, n) -> Printf.sprintf "mkclos %s, %d" l n
  | SetCap i -> Printf.sprintf "setcap %d, %s" i (args_str v)
  | Call -> Printf.sprintf "call %s" (args_str v)
  | Prim p -> Printf.sprintf "prim %s %s" p (args_str v)
  | Record ls ->
      Printf.sprintf "record { %s }"
        (String.concat ", " (List.map2 (fun l a -> l ^ " = " ^ vref a) ls v.args))
  | Con c ->
      Printf.sprintf "con %s/%d%s" c.Types.cname c.Types.cidx
        (match v.args with [] -> "" | _ -> ", " ^ args_str v)
  | Field (l, i) -> Printf.sprintf "field %s, %s(%d)" (args_str v) l i
  | Payload -> Printf.sprintf "payload %s" (args_str v)
  | Phi -> "phi"

let term_str = function
  | Ret v -> Printf.sprintf "ret %s" (vref v)
  | TailCall (f, a) -> Printf.sprintf "tailcall %s, %s" (vref f) (vref a)
  | Jump b -> Printf.sprintf "jump b%d" b.bid
  | Fail (loc, m) -> Printf.sprintf "fail %S at %s" m (Loc.to_string loc)
  | Switch (v, arms, dflt) ->
      Printf.sprintf "switch %s [%s%s]" (vref v)
        (String.concat ", "
           (List.map (fun (k, b) -> Printf.sprintf "%s -> b%d" (Core.key_str k) b.bid) arms))
        (match dflt with None -> "" | Some b -> Printf.sprintf ", _ -> b%d" b.bid)

let add = Buffer.add_string

let line out text origin =
  if origin = "" then add out (Printf.sprintf "    %s\n" text)
  else add out (Printf.sprintf "    %-38s ; %s\n" text origin)

let print_block out (b : block) =
  add out (Printf.sprintf "  b%d:" b.bid);
  (match b.preds with
  | [] -> add out "\n"
  | ps ->
      add out
        (Printf.sprintf "%*s; preds %s\n"
           (max 1 (34 - String.length (Printf.sprintf "  b%d:" b.bid)))
           "" (String.concat " " (List.map (fun p -> Printf.sprintf "b%d" p.bid) ps))));
  List.iter
    (fun v ->
      line out
        (Printf.sprintf "%s = phi [%s]" (vref v)
           (String.concat ", "
              (List.map2
                 (fun p a -> Printf.sprintf "b%d: %s" p.bid (vref a))
                 b.preds v.args)))
        v.origin)
    b.phis;
  List.iter
    (fun v ->
      match v.op with
      | SetCap _ -> line out (op_str v) v.origin
      | _ -> line out (Printf.sprintf "%s = %s" (vref v) (op_str v)) v.origin)
    b.values;
  add out (Printf.sprintf "    %s\n" (term_str b.term))

let print_func out (f : func) =
  add out (Printf.sprintf "func %s:\n" f.fn);
  List.iter (print_block out) f.blocks;
  add out "\n"

let prog_to_string (p : prog) =
  let out = Buffer.create 1024 in
  List.iter (print_func out) p.funcs;
  List.iter
    (fun i ->
      match i.ibody with
      | None -> ()
      | Some f ->
          add out
            (Printf.sprintf "-- %s\n"
               (match i.ilabel with Some l -> Lazy.force l | None -> i.iname));
          print_func out f)
    p.items;
  Buffer.contents out
