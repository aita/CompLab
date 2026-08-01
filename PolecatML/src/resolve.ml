(* Lexical addressing, and closure conversion — the same pass, because they are
   the same question asked twice.

   A name in the core tree is either an argument or binding of the function being
   compiled, in which case it is a *slot*; or it comes from further out, in which
   case the function cannot reach it at run time and it has to be *captured*.
   Deciding which is deciding what a closure holds.

   After this pass there are no names.  There is an array of functions, each with
   a body that reads slot numbers and capture numbers, and every place a closure
   is built says where each captured value is to be fetched from.

   Three things fall out of it.

   A function whose free variables are all themselves capture-free functions
   captures nothing.  Such a function is a *global*: a call to it needs no closure
   value at all, which is what [CallStatic] is for, and using it as a value needs
   no allocation, because the closure with no captures can sit in the constant
   pool.

   A local recursive group needs its members to refer to each other, and a
   closure's captures are copies, so there is nothing to back-patch.  Instead
   every member of a group captures *the same vector* — the free variables of the
   group as a whole — and a reference from inside the group to any member,
   including itself, rebuilds that member from the vector the running member is
   already holding.  No cell, no back-patch, no new instruction.

   The one case that needs care is an inner closure that captures a group member.
   Its capture has to come from a local or a capture, and "rebuild it" is neither,
   so the member is materialised into a slot at the top of the function — but
   only in the functions where that actually happens. *)

module IntMap = Map.Make (Int)

type expr =
  | Int of int64
  | Bool of bool
  | Unit
  | Local of int
  | Capture of int
  | Global of Machine.function_id (* a capture-free function, as a value *)
  | Tuple of expr list
  | Proj of int * expr
  | Prim of Core.prim * expr list
  | If of expr * expr * expr
  | Let of int option * expr * expr
  | Untuple of expr * int option list * expr
  | Closure of Machine.function_id * Machine.capture_source array
  | App of expr * expr list
  | AppGlobal of Machine.function_id * expr list

type func = {
  name : string option;
  arity : int;
  local_count : int;
  capture_count : int;
  body : expr;
}

type program = { entry : Machine.function_id; functions : func array }

(* What a name means in the function being resolved. *)
type binding =
  | Slot of int
  | Captured of int
  | Known of Machine.function_id (* captures nothing: no closure needed *)
  | Member of member (* a member of the group this function belongs to *)

and member = {
  m_id : Machine.function_id;
  m_sources : Machine.capture_source array; (* how to rebuild it from here *)
  mutable m_slot : int option; (* filled in if an inner closure needs it *)
}

(* Everything mutable is per function: slots are handed out by a bump counter and
   never reused, and [pre] collects the materialisations that have to run before
   the body does. *)
type fstate = { mutable next_slot : int; mutable pre : (int * expr) list }

type builder = {
  mutable next_id : Machine.function_id;
  funcs : (Machine.function_id, func) Hashtbl.t;
}

let new_id b =
  let id = b.next_id in
  b.next_id <- id + 1;
  id

let alloc_slot st =
  let slot = st.next_slot in
  st.next_slot <- slot + 1;
  slot

let lookup env (n : Core.name) =
  match IntMap.find_opt n.Core.id env with
  | Some b -> b
  | None -> failwith ("resolve: unbound " ^ Core.show_name n)

(* Only the globals survive into a nested function's environment for free; every
   other name it uses has to be captured. *)
let globals_only env = IntMap.filter (fun _ b -> match b with Known _ -> true | _ -> false) env

(* Where the current frame can fetch [name] from, if it has to capture it.  A
   group member is rebuilt into a slot first, once per function. *)
let capture_source st env name =
  match lookup env name with
  | Slot i -> Some (Machine.FromLocal i)
  | Captured i -> Some (Machine.FromCapture i)
  | Known _ -> None (* nothing to capture: the child resolves it as a global *)
  | Member m ->
      let slot =
        match m.m_slot with
        | Some slot -> slot
        | None ->
            let slot = alloc_slot st in
            m.m_slot <- Some slot;
            st.pre <- (slot, Closure (m.m_id, m.m_sources)) :: st.pre;
            slot
      in
      Some (Machine.FromLocal slot)

(* The captures of a function whose free variables are [free], and the
   environment its body will be resolved in. *)
let capture_plan st env free =
  let sources = ref [] in
  let inner = ref (globals_only env) in
  let count = ref 0 in
  List.iter
    (fun (name : Core.name) ->
      match capture_source st env name with
      | None -> ()
      | Some source ->
          inner := IntMap.add name.Core.id (Captured !count) !inner;
          sources := source :: !sources;
          incr count)
    free;
  (Array.of_list (List.rev !sources), !inner)

let with_params env params =
  List.fold_left
    (fun (env, i) (p : Core.name) -> (IntMap.add p.Core.id (Slot i) env, i + 1))
    (env, 0) params
  |> fst

(* Wrap a resolved body in the materialisations its function needed. *)
let with_pre st body =
  List.fold_left (fun body (slot, e) -> Let (Some slot, e, body)) body st.pre

let rec resolve b st env (e : Core.expr) =
  match e with
  | Core.Int n -> Int n
  | Core.Bool v -> Bool v
  | Core.Unit -> Unit
  | Core.Var n -> (
      match lookup env n with
      | Slot i -> Local i
      | Captured i -> Capture i
      | Known id -> Global id
      | Member m -> Closure (m.m_id, m.m_sources))
  | Core.Tuple es -> Tuple (List.map (resolve b st env) es)
  | Core.Proj (i, e) -> Proj (i, resolve b st env e)
  | Core.Prim (p, es) -> Prim (p, List.map (resolve b st env) es)
  | Core.If (c, t, f) ->
      If (resolve b st env c, resolve b st env t, resolve b st env f)
  | Core.Let (None, rhs, body) ->
      Let (None, resolve b st env rhs, resolve b st env body)
  | Core.Let (Some n, rhs, body) ->
      let rhs = resolve b st env rhs in
      let slot = alloc_slot st in
      Let (Some slot, rhs, resolve b st (IntMap.add n.Core.id (Slot slot) env) body)
  | Core.Untuple (rhs, binders, body) ->
      let rhs = resolve b st env rhs in
      let env, slots =
        List.fold_left
          (fun (env, slots) binder ->
            match binder with
            | None -> (env, None :: slots)
            | Some (n : Core.name) ->
                let slot = alloc_slot st in
                (IntMap.add n.Core.id (Slot slot) env, Some slot :: slots))
          (env, []) binders
      in
      Untuple (rhs, List.rev slots, resolve b st env body)
  | Core.Fn l -> closure_of b st env l
  | Core.Letrec (group, body) -> letrec b st env group body
  | Core.App (f, args) -> (
      let args = List.map (resolve b st env) args in
      match resolve b st env f with
      | Global id -> AppGlobal (id, args)
      | callee -> App (callee, args))

(* A function on its own: capture its free variables, compile the body, and
   answer with the value that stands for it here. *)
and closure_of b st env (l : Core.lambda) =
  let free = Core.free_vars_lambda l in
  let sources, inner = capture_plan st env free in
  let id = compile_lambda b inner l (Array.length sources) in
  if Array.length sources = 0 then Global id else Closure (id, sources)

and compile_lambda b outer_env (l : Core.lambda) capture_count =
  let id = new_id b in
  emit_lambda b id outer_env l capture_count;
  id

(* [outer_env] already holds the globals and the captures; the parameters take
   slots 0 .. arity-1. *)
and emit_lambda b id outer_env (l : Core.lambda) capture_count =
  let arity = List.length l.Core.params in
  let st = { next_slot = arity; pre = [] } in
  let env = with_params outer_env l.Core.params in
  let body = resolve b st env l.Core.body in
  Hashtbl.replace b.funcs id
    {
      name = l.Core.lname;
      arity;
      local_count = st.next_slot;
      capture_count;
      body = with_pre st body;
    }

and letrec b st env group body =
  let free = Core.free_vars_group group in
  let sources, base = capture_plan st env free in
  let ids = List.map (fun _ -> new_id b) group in
  let capture_count = Array.length sources in
  if capture_count = 0 then (
    (* Nothing to capture, so every member is a global: the members refer to
       each other by name, and so does everything after the group. *)
    let bind env =
      List.fold_left2
        (fun env ((n : Core.name), _) id -> IntMap.add n.Core.id (Known id) env)
        env group ids
    in
    let inner = bind base in
    List.iter2 (fun (_, l) id -> emit_lambda b id inner l 0) group ids;
    resolve b st (bind env) body)
  else
    (* Every member captures the same vector, so from inside any of them the
       vector is at captures 0 .. k-1 and any member can be rebuilt from it. *)
    let rebuild = Array.init capture_count (fun i -> Machine.FromCapture i) in
    List.iter2
      (fun (_, l) id ->
        (* One [member] record per member function: [m_slot] is that function's
           slot, and no two functions share it. *)
        let inner =
          List.fold_left2
            (fun env ((n : Core.name), _) mid ->
              IntMap.add n.Core.id
                (Member { m_id = mid; m_sources = rebuild; m_slot = None })
                env)
            base group ids
        in
        emit_lambda b id inner l capture_count)
      group ids;
    (* Outside the group each member is built once, into a slot of its own. *)
    let env, slots =
      List.fold_left2
        (fun (env, slots) ((n : Core.name), _) id ->
          let slot = alloc_slot st in
          (IntMap.add n.Core.id (Slot slot) env, (slot, id) :: slots))
        (env, []) group ids
    in
    List.fold_left
      (fun body (slot, id) -> Let (Some slot, Closure (id, sources), body))
      (resolve b st env body)
      slots

let program (core : Core.expr) =
  let b = { next_id = 0; funcs = Hashtbl.create 16 } in
  let entry = new_id b in
  emit_lambda b entry IntMap.empty
    { Core.lname = Some "<entry>"; params = []; body = core }
    0;
  let functions = Array.init b.next_id (fun i -> Hashtbl.find b.funcs i) in
  { entry; functions }
