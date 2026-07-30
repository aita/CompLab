(* The CESK machine.

   Four components, and the program is a rewriting of the four:

     C  control       the block being run
     E  environment   a name to an address
     S  store         an address to a value
     K  kontinuation  a list of frames

   The middle two are usually collapsed into one in a CEK machine, where the
   environment maps names straight to values.  Splitting them is what the extra
   S is: a variable denotes a *place*, and the store says what is in it.  This
   language needs that, because it has arrays.  An array is a run of addresses,
   `Array.update` writes one, and nothing else in the machine has to change --
   which is the argument for the fourth component in one sentence.

   There is exactly one kind of frame.  In A-normal form the only thing that
   can be waiting for a value is the `let` that binds it, so [KLet] is all
   there is.  A tail call passes the frame list along untouched, so a loop
   written as a tail-recursive function runs in constant space, and a `jump` to
   a join point does not touch it either -- which is what makes a join point
   cost nothing. *)

module F = Flat
module Map = Map.Make (String)

type value =
  | VInt of int
  (* A real is a host double.  Both back ends have to agree on IEEE-754
     binary64 and on how one is printed ([Types.real_str]); nothing else about
     it is the machine's business. *)
  | VReal of float
  | VStr of string
  | VUnit
  (* One product: a tuple is a record whose labels are 1, 2, ... n. *)
  | VRecord of (string * value) list
  | VCon of Types.constr * value option
  (* A closure is a code label and a run of addresses holding its captures. *)
  | VClos of string * int * int
  (* A primitive of the basis.  Every one of them takes a single argument, a
     tuple where it needs more, which is how SML's basis is shaped too. *)
  | VPrim of string
  | VArray of int * int (* base address, length *)
  | VRef of int (* one address *)

type env = { vars : int Map.t; joins : jp Map.t; caps : int }
and jp = { jparams : string list; jbody : F.block; jenv : env }

type frame = KLet of string * F.block * env

type world = {
  mutable cells : value array;
  mutable next : int;
  globals : (string, value) Hashtbl.t;
  codes : (string, F.code) Hashtbl.t;
  mutable trace : bool;
  mutable steps : int;
}

let empty_env = { vars = Map.empty; joins = Map.empty; caps = 0 }

let create ?(trace = false) () =
  {
    cells = Array.make 1024 VUnit;
    next = 0;
    globals = Hashtbl.create 64;
    codes = Hashtbl.create 64;
    trace;
    steps = 0;
  }

let fault fmt = Loc.fail ~where:"runtime error" Loc.unknown fmt

(* The store grows by doubling; addresses are never reused, because nothing
   here collects garbage. *)
let alloc w n =
  if w.next + n > Array.length w.cells then begin
    let bigger = Array.make (max (2 * Array.length w.cells) (w.next + n)) VUnit in
    Array.blit w.cells 0 bigger 0 w.next;
    w.cells <- bigger
  end;
  let base = w.next in
  w.next <- w.next + n;
  base

let get w a = w.cells.(a)
let set w a v = w.cells.(a) <- v

(* How an integer is spelled: SML writes the sign as `~`.  Negating and printing
   the result would be wrong for the one integer that has no positive twin, so
   the sign is replaced rather than removed. *)
let int_str n =
  let s = string_of_int n in
  if s.[0] = '-' then "~" ^ String.sub s 1 (String.length s - 1) else s

(* And how a string is spelled: the four escapes the lexer reads, and every
   other byte through untouched.  OCaml's `%S` also turns a byte outside
   printable ASCII into `\ddd`, which is an escape this language cannot read
   back and which the runtime's `show` does not produce. *)
let str_str s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let rec show w v =
  match v with
  | VInt n -> int_str n
  | VReal r -> Types.real_str r
  | VStr s -> str_str s
  | VUnit -> "()"
  | VRecord [] -> "()"
  | VRecord fs when Types.tuple_shaped fs ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map (fun (_, v) -> show w v) fs))
  | VRecord fs ->
      Printf.sprintf "{ %s }"
        (String.concat ", " (List.map (fun (l, v) -> Printf.sprintf "%s = %s" l (show w v)) fs))
  | VCon (c, _) when c.Types.cres.Types.tid = Types.list_tc.Types.tid -> show_list w v
  | VCon (c, None) -> c.Types.cname
  | VCon (c, Some v) -> Printf.sprintf "%s %s" c.Types.cname (show w v)
  | VClos _ | VPrim _ -> "fn"
  | VRef a -> Printf.sprintf "ref %s" (show w (get w a))
  | VArray (base, len) ->
      Printf.sprintf "[|%s|]"
        (String.concat ", "
           (List.init len (fun i -> show w (get w (base + i)))))

and show_list w v =
  let rec items v =
    match v with
    | VCon (c, None) when c.Types.cname = "nil" -> []
    | VCon (_, Some (VRecord [ (_, hd); (_, tl) ])) -> show w hd :: items tl
    | _ -> [ "?" ]
  in
  Printf.sprintf "[%s]" (String.concat ", " (items v))

let rec equal w a b =
  match (a, b) with
  | VInt a, VInt b -> a = b
  | VStr a, VStr b -> a = b
  | VUnit, VUnit -> true
  | VRecord a, VRecord b ->
      List.length a = List.length b
      && List.for_all2 (fun (l1, v1) (l2, v2) -> l1 = l2 && equal w v1 v2) a b
  | VCon (c1, p1), VCon (c2, p2) ->
      c1.Types.cidx = c2.Types.cidx
      && (match (p1, p2) with
         | None, None -> true
         | Some x, Some y -> equal w x y
         | _ -> false)
  (* A mutable thing is equal to itself and to nothing else. *)
  | VArray (a, _), VArray (b, _) -> a = b
  | VRef a, VRef b -> a = b
  | (VClos _ | VPrim _), _ | _, (VClos _ | VPrim _) ->
      fault "functions cannot be compared"
  (* Unreachable, like the line above: `real` is not an equality type, so the
     type checker stopped this.  Saying it out loud costs one line and is worth
     more than `false` would be. *)
  | VReal _, _ | _, VReal _ -> fault "reals cannot be compared"
  | _ -> false

let as_int = function VInt n -> n | _ -> fault "expected an integer"
let as_real = function VReal r -> r | _ -> fault "expected a real"
let as_str = function VStr s -> s | _ -> fault "expected a string"

(* A pair is a record with the labels 1 and 2. *)
let pair_value a b = VRecord [ ("1", a); ("2", b) ]

let nil_con = List.find (fun c -> c.Types.cname = "nil") Types.list_tc.Types.tcons
let cons_con = List.find (fun c -> c.Types.cname = "::") Types.list_tc.Types.tcons

let rec append w a b =
  match a with
  | VCon (c, None) when c.Types.cidx = nil_con.Types.cidx -> b
  | VCon (_, Some (VRecord [ (_, hd); (_, tl) ])) ->
      VCon (cons_con, Some (pair_value hd (append w tl b)))
  | _ -> fault "expected a list"

(* NaN is *not* unordered here.  SML raises `Unordered` from `Real.compare` and
   answers false to every comparison with a NaN; this language has no
   exceptions, so a NaN sorts below every number instead and `order` is a total
   order on each type.  It is the one place where a real does not behave the way
   IEEE-754 says, and it is written down rather than hidden. *)
let order a b =
  match (a, b) with
  | VInt a, VInt b -> compare a b
  | VReal a, VReal b -> compare a b
  | VStr a, VStr b -> compare a b
  | _ -> fault "these cannot be ordered"

let vbool b =
  VCon
    ( List.find
        (fun c -> c.Types.cname = (if b then "true" else "false"))
        Types.bool_tc.Types.tcons,
      None )

(* The primitives.  Everything the machine can do that is not a call, a switch
   or an allocation is here. *)
let prim w name (args : value list) =
  let two f = match args with [ a; b ] -> f a b | _ -> fault "%s wants two" name in
  let one f = match args with [ a ] -> f a | _ -> fault "%s wants one" name in
  (* An overloaded operator is one primitive, and which arithmetic it does is
     decided by the value.  It cannot be decided any earlier: elaboration emits
     the [Prim] before unification has necessarily settled whether the operands
     are int or real -- `fun double x = x + x` learns that from its caller -- and
     by the time the machine runs, the type that settled it is gone.  Same
     bargain as `order` above. *)
  let num fi fr a b =
    match (a, b) with
    | VInt a, VInt b -> VInt (fi a b)
    | VReal a, VReal b -> VReal (fr a b)
    | _ -> fault "%s wants two numbers of the same type" name
  in
  match name with
  | "+" -> two (num ( + ) ( +. ))
  | "-" -> two (num ( - ) ( -. ))
  | "*" -> two (num ( * ) ( *. ))
  (* `/` is real-only, so there is nothing to dispatch on.  Division by zero is
     an infinity, as IEEE-754 says, and not the error `div` gives: the two
     divisions are spelled differently in SML and they behave differently. *)
  | "/" -> two (fun a b -> VReal (as_real a /. as_real b))
  | "div" ->
      two (fun a b ->
          let d = as_int b in
          if d = 0 then fault "division by zero" else VInt (as_int a / d))
  | "mod" ->
      two (fun a b ->
          let d = as_int b in
          if d = 0 then fault "division by zero" else VInt (as_int a mod d))
  | "~" -> one (fun a -> match a with VReal r -> VReal (-.r) | _ -> VInt (-as_int a))
  | "^" -> two (fun a b -> VStr (as_str a ^ as_str b))
  | "@" -> two (fun a b -> append w a b)
  (* Ordered types are int, string and real; which one is decided by the value,
     because the type that decided it is gone by now. *)
  | "<" -> two (fun a b -> vbool (order a b < 0))
  | "<=" -> two (fun a b -> vbool (order a b <= 0))
  | ">" -> two (fun a b -> vbool (order a b > 0))
  | ">=" -> two (fun a b -> vbool (order a b >= 0))
  | ":=" ->
      two (fun r x ->
          match r with
          | VRef a ->
              set w a x;
              VUnit
          | _ -> fault "expected a ref")
  | "=" -> two (fun a b -> vbool (equal w a b))
  | "<>" -> two (fun a b -> vbool (not (equal w a b)))
  | _ -> fault "no primitive %s" name

(* A basis function, applied to its one argument. *)
let call_prim w name (v : value) =
  let pair () =
    match v with
    | VRecord [ (_, a); (_, b) ] -> (a, b)
    | _ -> fault "%s wants a pair" name
  in
  let triple () =
    match v with
    | VRecord [ (_, a); (_, b); (_, c) ] -> (a, b, c)
    | _ -> fault "%s wants a triple" name
  in
  match name with
  | "print" ->
      print_string (as_str v);
      VUnit
  | "!" -> ( match v with VRef a -> get w a | _ -> fault "expected a ref")
  | "not" -> vbool (match v with VCon (c, None) -> c.Types.cname = "false" | _ -> fault "not")
  | "Int.toString" -> VStr (show w v)
  | "Int.abs" -> VInt (abs (as_int v))
  | "Int.min" ->
      let a, b = pair () in
      VInt (min (as_int a) (as_int b))
  | "Int.max" ->
      let a, b = pair () in
      VInt (max (as_int a) (as_int b))
  | "Int.compare" ->
      let a, b = pair () in
      VInt (compare (as_int a) (as_int b))
  | "Real.toString" -> VStr (Types.real_str (as_real v))
  | "Real.fromInt" -> VReal (float_of_int (as_int v))
  (* `floor` rounds towards minus infinity, and refuses what will not fit in an
     int rather than returning a number nobody meant.  `int_of_float` would
     otherwise be undefined here, and quietly so. *)
  | "Real.floor" ->
      let r = as_real v in
      let f = Float.floor r in
      if Float.is_nan f || Float.abs f >= 4.611686018427388e18 then
        fault "Real.floor: %s does not fit in an int" (Types.real_str r)
      else VInt (int_of_float f)
  | "Real.compare" ->
      let a, b = pair () in
      VInt (compare (as_real a) (as_real b))
  (* The square root of a negative number is a NaN, which prints as `nan`.  SML
     says the same; there is no exception to raise here anyway. *)
  | "Math.sqrt" -> VReal (Float.sqrt (as_real v))
  | "String.size" -> VInt (String.length (as_str v))
  | "String.compare" ->
      let a, b = pair () in
      VInt (compare (as_str a) (as_str b))
  | "String.substring" ->
      let s, i, n = triple () in
      let s = as_str s and i = as_int i and n = as_int n in
      (* `i + n > size` is the obvious test and it is wrong: both are program
         values, so their sum can wrap round and let an out-of-range pair
         through to `String.sub`, which raises where a runtime error was owed.
         Subtracting cannot wrap, because `i` is already known non-negative. *)
      if i < 0 || n < 0 || n > String.length s - i then fault "String.substring: out of range"
      else VStr (String.sub s i n)
  | "Array.array" ->
      let n, init = pair () in
      let n = as_int n in
      if n < 0 then fault "Array.array: negative size";
      let base = alloc w (max n 1) in
      for i = 0 to n - 1 do
        set w (base + i) init
      done;
      VArray (base, n)
  | "Array.fromList" ->
      let rec items = function
        | VCon (c, None) when c.Types.cidx = nil_con.Types.cidx -> []
        | VCon (_, Some (VRecord [ (_, hd); (_, tl) ])) -> hd :: items tl
        | _ -> fault "expected a list"
      in
      let vs = items v in
      let n = List.length vs in
      let base = alloc w (max n 1) in
      List.iteri (fun i x -> set w (base + i) x) vs;
      VArray (base, n)
  | "Array.toList" -> (
      match v with
      | VArray (base, len) ->
          let rec go i =
            if i >= len then VCon (nil_con, None)
            else VCon (cons_con, Some (pair_value (get w (base + i)) (go (i + 1))))
          in
          go 0
      | _ -> fault "expected an array")
  | "Array.length" -> ( match v with VArray (_, n) -> VInt n | _ -> fault "expected an array")
  | "Array.sub" -> (
      let a, i = pair () in
      match a with
      | VArray (base, len) ->
          let i = as_int i in
          if i < 0 || i >= len then
            fault "Array.sub: index %s out of 0..%s" (int_str i) (int_str (len - 1))
          else get w (base + i)
      | _ -> fault "expected an array")
  | "Array.update" -> (
      let a, i, x = triple () in
      match a with
      | VArray (base, len) ->
          let i = as_int i in
          if i < 0 || i >= len then
            fault "Array.update: index %s out of 0..%s" (int_str i) (int_str (len - 1))
          else (
            set w (base + i) x;
            VUnit)
      | _ -> fault "expected an array")
  | _ -> fault "no primitive %s" name

(* One state. *)
type state = { mutable ctrl : F.block; mutable env : env; mutable ks : frame list }

let lookup w env x =
  match Map.find_opt x env.vars with
  | Some a -> get w a
  | None -> (
      match Hashtbl.find_opt w.globals x with
      | Some v -> v
      | None -> fault "unbound variable %s" x)

let atom w env : F.atom -> value = function
  | F.AVar x -> lookup w env x
  | F.AInt n -> VInt n
  | F.AReal r -> VReal r
  | F.AStr s -> VStr s
  | F.AUnit -> VUnit

(* Binding a name allocates a cell.  That is the price of having a store, and
   the reason an array needs nothing new. *)
let bind w env x v =
  let a = alloc w 1 in
  set w a v;
  { env with vars = Map.add x a env.vars }

let code w label =
  match Hashtbl.find_opt w.codes label with
  | Some c -> c
  | None -> fault "no code block %s" label

(* Entering a function: a fresh environment holding just the parameter, and the
   captures of the closure that was called. *)
let enter w (v : value) (arg : value) =
  match v with
  | VClos (label, base, _) ->
      let c = code w label in
      let env = bind w { vars = Map.empty; joins = Map.empty; caps = base } c.F.c_param arg in
      Some (c.F.c_body, env)
  | VPrim _ -> None
  | _ -> fault "expected a function"

let rec run w (st : state) : value =
  w.steps <- w.steps + 1;
  if w.trace then prerr_endline ("  " ^ head_of st.ctrl);
  match st.ctrl with
  | F.Let (x, rhs, rest) -> (
      match rhs with
      | F.Call (f, a) -> (
          let fv = atom w st.env f and av = atom w st.env a in
          match enter w fv av with
          | Some (body, env) ->
              st.ks <- KLet (x, rest, st.env) :: st.ks;
              st.env <- env;
              st.ctrl <- body;
              run w st
          | None ->
              let v = call_prim w (match fv with VPrim n -> n | _ -> assert false) av in
              step_on w st x v rest)
      | _ ->
          let v = eval w st.env rhs in
          step_on w st x v rest)
  | F.Fix (defs, rest) ->
      (* Every closure of the group exists before any of their captures are
         computed, so they can see each other.  The store is what makes that
         possible: the addresses are handed out first and filled in after. *)
      let made =
        List.map
          (fun (name, r) ->
            match r with
            | F.Closure (label, caps) ->
                let base = alloc w (max (List.length caps) 1) in
                (name, VClos (label, base, List.length caps), base, caps)
            | _ -> fault "a fix binding must be a closure")
          defs
      in
      let env =
        List.fold_left (fun env (name, v, _, _) -> bind w env name v) st.env made
      in
      List.iter
        (fun (_, _, base, caps) ->
          List.iteri (fun i a -> set w (base + i) (atom w env a)) caps)
        made;
      st.env <- env;
      st.ctrl <- rest;
      run w st
  | F.Join (j, ps, body, rest) ->
      st.env <-
        {
          st.env with
          joins = Map.add j { jparams = ps; jbody = body; jenv = st.env } st.env.joins;
        };
      st.ctrl <- rest;
      run w st
  | F.Tail t -> (
      match t with
      | F.Ret a -> (
          let v = atom w st.env a in
          match st.ks with
          | [] -> v
          | KLet (x, rest, env) :: ks ->
              st.ks <- ks;
              st.env <- env;
              step_on w st x v rest)
      | F.TCall (f, a) -> (
          let fv = atom w st.env f and av = atom w st.env a in
          match enter w fv av with
          | Some (body, env) ->
              st.env <- env;
              st.ctrl <- body;
              run w st
          | None ->
              let v = call_prim w (match fv with VPrim n -> n | _ -> assert false) av in
              return w st v)
      | F.Jump (j, args) -> (
          match Map.find_opt j st.env.joins with
          | None -> fault "no join point %s" j
          | Some jp ->
              let vs = List.map (atom w st.env) args in
              (* A join point does not capture: it lands in the environment it
                 was written in, with its parameters bound. *)
              let env = List.fold_left2 (bind w) jp.jenv jp.jparams vs in
              st.env <- env;
              st.ctrl <- jp.jbody;
              run w st)
      | F.Fail (loc, msg) -> Loc.fail ~where:"match failure" loc "%s" msg
      | F.Switch (a, branches, dflt) -> (
          let v = atom w st.env a in
          let matches (k : Core.key) =
            match (k, v) with
            | Core.Ktag c, VCon (c', _) -> c.Types.cidx = c'.Types.cidx
            | Core.Ktag c, VRef _ -> c.Types.cres.Types.tid = Types.ref_tc.Types.tid
            | Core.Kint n, VInt m -> n = m
            | Core.Kstr s, VStr t -> s = t
            | _ -> false
          in
          match List.find_opt (fun (k, _) -> matches k) branches with
          | Some (_, body) ->
              st.ctrl <- body;
              run w st
          | None -> (
              match dflt with
              | Some body ->
                  st.ctrl <- body;
                  run w st
              | None -> fault "no branch of this switch matched")))

and step_on w st x v rest =
  st.env <- bind w st.env x v;
  st.ctrl <- rest;
  run w st

and return w st v =
  match st.ks with
  | [] -> v
  | KLet (x, rest, env) :: ks ->
      st.ks <- ks;
      st.env <- env;
      step_on w st x v rest

and eval w env (rhs : F.rhs) : value =
  match rhs with
  | F.Atom a -> atom w env a
  | F.Capture i -> get w (env.caps + i)
  | F.Closure (label, caps) ->
      let base = alloc w (max (List.length caps) 1) in
      List.iteri (fun i a -> set w (base + i) (atom w env a)) caps;
      VClos (label, base, List.length caps)
  | F.Prim (op, ats) -> prim w op (List.map (atom w env) ats)
  | F.Record fs -> VRecord (List.map (fun (l, a) -> (l, atom w env a)) fs)
  (* The one constructor that allocates. *)
  | F.Con (c, Some a) when c.Types.cres.Types.tid = Types.ref_tc.Types.tid ->
      let cell = alloc w 1 in
      set w cell (atom w env a);
      VRef cell
  | F.Con (c, a) -> VCon (c, Option.map (atom w env) a)
  (* The index came from closure.ml, where the type was still around; the
     label is kept for the error and for the dump. *)
  | F.Field (a, l, i) -> (
      match atom w env a with
      | VRecord fs -> (
          match List.nth_opt fs i with
          | Some (l', v) when l' = l -> v
          | _ -> fault "this record has no field %s" l)
      | _ -> fault "expected a record")
  | F.Payload a -> (
      match atom w env a with
      | VRef cell -> get w cell
      | VCon (_, Some v) -> v
      | VCon (c, None) -> fault "%s has no argument" c.Types.cname
      | _ -> fault "expected a constructed value")
  | F.Call _ -> assert false (* a call is a step, not an evaluation *)

and head_of (b : F.block) =
  match b with
  | F.Let (x, r, _) -> Printf.sprintf "let %s = %s" x (F.rhs_str r)
  | F.Fix (defs, _) ->
      Printf.sprintf "fix %s" (String.concat ", " (List.map fst defs))
  | F.Join (j, _, _, _) -> Printf.sprintf "join %s" j
  | F.Tail (F.Ret a) -> Printf.sprintf "ret %s" (F.atom_str a)
  | F.Tail (F.TCall (f, a)) ->
      Printf.sprintf "tailcall %s %s" (F.atom_str f) (F.atom_str a)
  | F.Tail (F.Jump (j, _)) -> Printf.sprintf "jump %s" j
  | F.Tail (F.Switch (a, _, _)) -> Printf.sprintf "switch %s" (F.atom_str a)
  | F.Tail (F.Fail _) -> "fail"

let load w (p : F.program) =
  List.iter (fun (c : F.code) -> Hashtbl.replace w.codes c.F.c_label c) p.F.codes

let define w name v = Hashtbl.replace w.globals name v

let run_block w block =
  run w { ctrl = block; env = empty_env; ks = [] }

(* The machine's half of the basis: the names [basis.ml] declares, bound to the
   primitives above.  A structure is a record, and its fields are sorted,
   because that is what a record is here -- `Sem.struct_ty` decided the layout
   and a field is reached by offset, not by name. *)
let install_basis w =
  List.iter (fun (n, _) -> define w n (VPrim n)) Basis.toplevel_vals;
  List.iter
    (fun (n, sg) ->
      define w n
        (VRecord
           (Types.sort_fields
              (List.map (fun (f, _) -> (f, VPrim (n ^ "." ^ f))) sg.Sem.sg_vals))))
    Basis.structures
