(* The machine: control, environment, continuation, and -- only because of the
   session system -- a store.

   A state is a block being run, an environment of the names in scope, and a
   list of frames.  There is exactly one kind of frame, [KLet], because in
   A-normal form the only thing that can be waiting for a value is the `let`
   that binds it.  A tail call passes the frame list along untouched, so a loop
   written as a tail-recursive function runs in constant space.

   The store holds channel endpoints.  Communication is buffered one message
   deep: a send blocks only if the peer has not caught up.  Session typing does
   not depend on the choice, and one slot is enough to make a process suspend
   in the middle of a protocol, which is the part worth watching. *)

module Env = Map.Make (String)

type value =
  | VInt of int
  | VBool of bool
  | VUnit
  | VClos of string * Core.block * env
  | VPair of value * value
  (* Labels are scoped: the list may hold a label twice, and the leftmost
     occurrence is the one a projection finds.  Restriction removes it and
     uncovers the one underneath. *)
  | VRecord of (string * value) list
  | VVariant of string * value
  | VChan of int

and env = value ref Env.t

type frame = KLet of string * Core.block * env

(* A message in flight, and the two things a session can carry. *)
type msg = MVal of value | MLabel of string

type endpoint = { mutable slot : msg option; mutable closed : bool }

type proc = {
  pid : int;
  mutable ctrl : Core.block;
  mutable renv : env;
  mutable ks : frame list;
  mutable result : value option;
}

type world = {
  globals : (string, value ref) Hashtbl.t;
  endpoints : (int, endpoint) Hashtbl.t;
  mutable next_endpoint : int;
  mutable procs : proc list; (* main is the head *)
  mutable next_pid : int;
  trace : bool;
}

let create ?(trace = false) () =
  {
    globals = Hashtbl.create 32;
    endpoints = Hashtbl.create 8;
    next_endpoint = 0;
    procs = [];
    next_pid = 0;
    trace;
  }

let rec show = function
  | VInt n -> string_of_int n
  | VBool b -> if b then "true" else "false"
  | VUnit -> "()"
  | VClos _ -> "<fun>"
  | VPair (a, b) -> Printf.sprintf "(%s, %s)" (show a) (show b)
  | VRecord fs ->
      Printf.sprintf "{ %s }"
        (String.concat ", "
           (List.map (fun (l, v) -> Printf.sprintf "%s = %s" l (show v)) fs))
  | VVariant (l, VUnit) -> "`" ^ l
  | VVariant (l, v) -> Printf.sprintf "`%s %s" l (show v)
  | VChan n -> Printf.sprintf "<channel %d>" n

let fault fmt = Loc.fail ~where:"runtime error" Loc.unknown fmt

(* Endpoints are allocated in pairs, so the dual of an endpoint is one bit
   away.  Nothing else in the machine needs to know how a pair is made. *)
let dual n = n lxor 1

let endpoint w n =
  match Hashtbl.find_opt w.endpoints n with
  | Some e -> e
  | None -> fault "channel %d does not exist" n

let new_channel w =
  let a = w.next_endpoint in
  w.next_endpoint <- a + 2;
  Hashtbl.replace w.endpoints a { slot = None; closed = false };
  Hashtbl.replace w.endpoints (dual a) { slot = None; closed = false };
  (a, dual a)

let lookup w env x =
  match Env.find_opt x env with
  | Some r -> !r
  | None -> (
      match Hashtbl.find_opt w.globals x with
      | Some r -> !r
      | None -> fault "unbound variable %s" x)

let atom w env : Core.atom -> value = function
  | AVar x -> lookup w env x
  | AInt n -> VInt n
  | ABool b -> VBool b
  | AUnit -> VUnit

let bind env x v = Env.add x (ref v) env

let as_int = function VInt n -> n | v -> fault "expected an integer, got %s" (show v)
let as_bool = function VBool b -> b | v -> fault "expected a boolean, got %s" (show v)
let as_chan = function VChan n -> n | v -> fault "expected a channel, got %s" (show v)

let rec equal a b =
  match (a, b) with
  | VInt a, VInt b -> a = b
  | VBool a, VBool b -> a = b
  | VUnit, VUnit -> true
  | VPair (a1, a2), VPair (b1, b2) -> equal a1 a2 && equal b1 b2
  | VVariant (l1, v1), VVariant (l2, v2) -> l1 = l2 && equal v1 v2
  | VRecord f1, VRecord f2 ->
      List.length f1 = List.length f2
      && List.for_all2 (fun (l1, v1) (l2, v2) -> l1 = l2 && equal v1 v2) f1 f2
  | VClos _, VClos _ -> fault "functions cannot be compared"
  | VChan _, VChan _ -> fault "channels cannot be compared"
  | _ -> false

let prim name (args : value list) =
  match (name, args) with
  | "+", [ a; b ] -> VInt (as_int a + as_int b)
  | "-", [ a; b ] -> VInt (as_int a - as_int b)
  | "*", [ a; b ] -> VInt (as_int a * as_int b)
  | "/", [ a; b ] ->
      let d = as_int b in
      if d = 0 then fault "division by zero" else VInt (as_int a / d)
  | "%", [ a; b ] ->
      let d = as_int b in
      if d = 0 then fault "division by zero" else VInt (as_int a mod d)
  | "neg", [ a ] -> VInt (-as_int a)
  | "==", [ a; b ] -> VBool (equal a b)
  | "!=", [ a; b ] -> VBool (not (equal a b))
  | "<", [ a; b ] -> VBool (as_int a < as_int b)
  | "<=", [ a; b ] -> VBool (as_int a <= as_int b)
  | ">", [ a; b ] -> VBool (as_int a > as_int b)
  | ">=", [ a; b ] -> VBool (as_int a >= as_int b)
  | "not", [ a ] -> VBool (not (as_bool a))
  | "fst", [ VPair (a, _) ] -> a
  | "snd", [ VPair (_, b) ] -> b
  | ("fst" | "snd"), [ v ] -> fault "expected a pair, got %s" (show v)
  | "print", [ v ] ->
      print_string (show v);
      print_newline ();
      VUnit
  | _ -> fault "no primitive %s of %d arguments" name (List.length args)

let project fields l =
  match List.assoc_opt l fields with
  | Some v -> v
  | None -> fault "record has no field %s" l

let restrict fields l =
  let rec go = function
    | [] -> fault "record has no field %s" l
    | (k, _) :: rest when k = l -> rest
    | f :: rest -> f :: go rest
  in
  go fields

(* One step of one process.  [Went] means the process moved; [Stuck] means it
   is waiting for a message and the instruction should be retried later, which
   is why nothing is consumed before it is known to succeed. *)
type step = Went | Stuck | Done of value

let step w (p : proc) : step =
  let value_of = atom w p.renv in
  (* Hand a value to whatever was waiting for it. *)
  let return v =
    match p.ks with
    | [] ->
        p.result <- Some v;
        Done v
    | KLet (x, rest, env) :: ks ->
        p.ks <- ks;
        p.renv <- bind env x v;
        p.ctrl <- rest;
        Went
  in
  let continue_with x v rest =
    p.renv <- bind p.renv x v;
    p.ctrl <- rest;
    Went
  in
  match p.ctrl with
  | Core.Let (x, rhs, rest) -> (
      match rhs with
      | Core.Atom a -> continue_with x (value_of a) rest
      | Core.Lam (param, body) -> continue_with x (VClos (param, body, p.renv)) rest
      | Core.Prim (op, ats) -> continue_with x (prim op (List.map value_of ats)) rest
      | Core.MkPair (a, b) -> continue_with x (VPair (value_of a, value_of b)) rest
      | Core.MkRecord (fs, tail) ->
          let base =
            match tail with
            | None -> []
            | Some a -> (
                match value_of a with
                | VRecord fields -> fields
                | v -> fault "expected a record to extend, got %s" (show v))
          in
          let added = List.map (fun (l, a) -> (l, value_of a)) fs in
          continue_with x (VRecord (added @ base)) rest
      | Core.Proj (a, l) -> (
          match value_of a with
          | VRecord fs -> continue_with x (project fs l) rest
          | v -> fault "expected a record, got %s" (show v))
      | Core.Restrict (a, l) -> (
          match value_of a with
          | VRecord fs -> continue_with x (VRecord (restrict fs l)) rest
          | v -> fault "expected a record, got %s" (show v))
      | Core.Inject (l, a) -> continue_with x (VVariant (l, value_of a)) rest
      | Core.Call (f, a) -> (
          match value_of f with
          | VClos (param, body, cenv) ->
              p.ks <- KLet (x, rest, p.renv) :: p.ks;
              p.renv <- bind cenv param (value_of a);
              p.ctrl <- body;
              Went
          | v -> fault "expected a function, got %s" (show v))
      | Core.Fork f ->
          let mine, theirs = new_channel w in
          (match value_of f with
          | VClos (param, body, cenv) ->
              w.next_pid <- w.next_pid + 1;
              let child =
                {
                  pid = w.next_pid;
                  ctrl = body;
                  renv = bind cenv param (VChan theirs);
                  ks = [];
                  result = None;
                }
              in
              w.procs <- w.procs @ [ child ]
          | v -> fault "fork expected a function, got %s" (show v));
          continue_with x (VChan mine) rest
      | Core.Send (v, c) ->
          let n = as_chan (value_of c) in
          let peer = endpoint w (dual n) in
          if peer.slot <> None then Stuck
          else if peer.closed then fault "sent on a closed channel"
          else (
            peer.slot <- Some (MVal (value_of v));
            continue_with x (VChan n) rest)
      | Core.Select (l, c) ->
          let n = as_chan (value_of c) in
          let peer = endpoint w (dual n) in
          if peer.slot <> None then Stuck
          else (
            peer.slot <- Some (MLabel l);
            continue_with x (VChan n) rest)
      | Core.Recv c -> (
          let n = as_chan (value_of c) in
          let me = endpoint w n in
          match me.slot with
          | Some (MVal v) ->
              me.slot <- None;
              continue_with x (VPair (v, VChan n)) rest
          | Some (MLabel l) -> fault "expected a value, got the label `%s" l
          | None -> Stuck)
      | Core.Close c ->
          let n = as_chan (value_of c) in
          (endpoint w n).closed <- true;
          continue_with x VUnit rest)
  | Core.LetRec (f, param, body, rest) ->
      (* The cell goes into the environment the closure captures, and is then
         filled with the closure: that knot is all `let rec` needs. *)
      let cell = ref VUnit in
      let env = Env.add f cell p.renv in
      cell := VClos (param, body, env);
      p.renv <- env;
      p.ctrl <- rest;
      Went
  | Core.Tail (Core.Ret a) -> return (value_of a)
  | Core.Tail (Core.TCall (f, a)) -> (
      match value_of f with
      | VClos (param, body, cenv) ->
          p.renv <- bind cenv param (value_of a);
          p.ctrl <- body;
          Went
      | v -> fault "expected a function, got %s" (show v))
  | Core.Tail (Core.If (c, t, e)) ->
      p.ctrl <- (if as_bool (value_of c) then t else e);
      Went
  | Core.Tail (Core.Case (a, arms, dflt)) -> (
      match value_of a with
      | VVariant (l, payload) as v -> (
          match List.find_opt (fun arm -> arm.Core.alabel = l) arms with
          | Some arm -> continue_with arm.Core.abinder payload arm.Core.abody
          | None -> (
              match dflt with
              | Some (x, body) -> continue_with x v body
              | None -> fault "no case for `%s" l))
      | v -> fault "expected a variant, got %s" (show v))
  | Core.Tail (Core.Branch (c, arms)) -> (
      let n = as_chan (value_of c) in
      let me = endpoint w n in
      match me.slot with
      | Some (MLabel l) -> (
          match List.find_opt (fun (k, _, _) -> k = l) arms with
          | Some (_, x, body) ->
              me.slot <- None;
              continue_with x (VChan n) body
          | None -> fault "the peer chose `%s, which this branch does not offer" l)
      | Some (MVal v) -> fault "expected a label, got the value %s" (show v)
      | None -> Stuck)

(* Round-robin: run a process until it blocks or finishes, then move on.  With
   one-deep buffering that is enough to interleave two processes taking turns
   over a channel, and it keeps the order of output deterministic.
   [w.procs] is read once per round, so a process forked during a round gets
   its first turn in the next one. *)
let rec run_all w =
  let progressed = ref false in
  List.iter
    (fun p ->
      if p.result = None then
        let rec drive () =
          if w.trace then
            prerr_endline (Printf.sprintf "[%d] %s" p.pid (Core.head_to_string p.ctrl));
          match step w p with
          | Went ->
              progressed := true;
              drive ()
          | Done _ -> progressed := true
          | Stuck -> ()
        in
        drive ())
    w.procs;
  let main = List.hd w.procs in
  let all_done = List.for_all (fun p -> p.result <> None) w.procs in
  match main.result with
  (* The main process has its answer, but a child forked at the last moment may
     not have run at all yet, so keep going until either everyone is finished or
     nothing is moving.  A child left blocked once main is done is not reported:
     the program produced its value. *)
  | Some v when all_done || not !progressed -> v
  | Some _ -> run_all w
  | None ->
      if !progressed then run_all w
      else
        fault
          "every process is blocked waiting for a message: the session \
           deadlocked"

let run w block =
  w.next_pid <- 0;
  let main = { pid = 0; ctrl = block; renv = Env.empty; ks = []; result = None } in
  w.procs <- [ main ];
  run_all w

let define w name v = Hashtbl.replace w.globals name (ref v)
