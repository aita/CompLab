(* A-normal form with join points, to LLVM IR.

   Mostly a change of shape, and a shorter one than it would be to any other
   target:

     a code block   ->  a function with an entry block
     a `let`        ->  an instruction appended to the block being filled
     a `join`       ->  a new block, whose parameters become phi nodes
     a `jump`       ->  a `br`, and one incoming pair appended to each phi
     a `switch`     ->  a `switch`, and one new block per arm
     a `tailcall`   ->  a `musttail call` and the `ret` that must follow it

   Two of those lines are the reason this back end is short.

   *A join point is already a basic block with phi nodes.*  Nothing here places
   phi functions, computes a dominance frontier or renames a variable, because
   the front end wrote the joins down and their parameters are the phis.  The
   phis are created empty when the join is reached and filled in as the jumps to
   it are met, which is why the continuation is lowered before the body: the
   jumps are in the continuation.

   *A tail call is `musttail`.*  A SkunkML program has no loop: a join point can
   only jump outwards, so a function's control-flow graph is acyclic and every
   loop in the language is a tail call.  A back end that merely hoped for a tail
   call would turn `fun loop 0 = () | loop n = loop (n - 1)` into a stack
   overflow, so it is not a hope: `musttail` fails to compile rather than
   compiling to a call, and the signature that makes it legal -- every code
   block takes a closure and an argument and returns a value -- is the same fact
   that lets a call go through a word read out of a closure.

   What is *not* here is the rest of a back end.  There is no instruction
   selection, no register allocation, no dominator tree, no scheduling and no
   peephole pass: `-O2` and LLVM's own selector do all of it, and what is left
   is the part that only a SkunkML compiler could know -- that an integer is
   2n + 1, that a closure's first word is its code, and that a `case` over a
   datatype compares the tag in a descriptor. *)

module F = Flat
module Lay = Layout

type ctx = {
  t : Lay.t;
  (* Flat's binders are unique inside a function, so one table is enough and
     nothing is ever shadowed. *)
  names : (string, Ir.value) Hashtbl.t;
  (* For a name a comparison bound: the `i1` the comparison actually produced,
     beside the `true` or `false` block it had to be turned into.  A `case` on
     that name takes the bit and leaves the block to be deleted.  See
     [switch]. *)
  bits : (string, Ir.value) Hashtbl.t;
  joins : (string, Ir.block * Ir.phi list) Hashtbl.t;
  globals : (string, unit) Hashtbl.t;
}

let ir c = c.t.Lay.ir
let here c = Ir.here (ir c)
let block_named c name = Ir.append_block (ir c) name

(* ---- atoms ---------------------------------------------------------------- *)

let atom c : F.atom -> Ir.value = function
  (* A local binding first: a top-level `val x = ...` binds `x` locally inside
     its own body before it becomes the global of that name, and the local is
     what the body means. *)
  | F.AVar x -> (
      match Hashtbl.find_opt c.names x with
      | Some v -> v
      | None ->
          if Prelude.unstubbed x then
            (* Not a mistake in the program: a hole in this back end.  It goes
               out as the one kind of error everything else goes out as, so that
               it reads like the rest and exits like the rest. *)
            Loc.fail ~where:"unsupported" Loc.unknown
              "%s needs a representation for real, which the back end does not \
               have yet (see doc/12-abi.md)"
              x
          else if Hashtbl.mem c.globals x then Ir.load (ir c) (Lay.global c.t x None)
          else failwith ("lower: unbound " ^ x))
  | F.AInt n -> Ir.int ((2 * n) + 1)
  (* A real does not fit in a word and there is no block for one yet.  Deciding
     what it should be is this back end's next piece of work (doc/12-abi.md), so
     until then say so instead of guessing. *)
  | F.AReal _ ->
      Loc.fail ~where:"unsupported" Loc.unknown
        "a real literal needs a representation the back end does not have yet \
         (see doc/12-abi.md)"
  | F.AStr s -> Lay.str c.t s
  | F.AUnit -> Lay.unit_value c.t

(* ---- calls ---------------------------------------------------------------- *)

(* A call reads the code address out of the closure and passes the closure back
   in, so that the callee can reach its captures.  Every code block has the one
   signature, so nothing has to be cast. *)
let call_closure c ?(musttail = false) f a =
  let target = Ir.inttoptr (ir c) (Lay.field c.t f 0) in
  Ir.call_ptr (ir c) ~musttail target [ f; a ]

(* ---- primitives ----------------------------------------------------------- *)

(* Which runtime routine a primitive is, when it is one.  Comparison is
   overloaded over int and string and the type checker erased which; the value
   decides, and it decides inside the runtime. *)
let routine = function
  | "^" -> Some "skunk_concat"
  | "@" -> Some "skunk_append"
  | "<" -> Some "skunk_lt"
  | "<=" -> Some "skunk_le"
  | ">" -> Some "skunk_gt"
  | ">=" -> Some "skunk_ge"
  | "=" -> Some "skunk_equal"
  | "<>" -> Some "skunk_noteq"
  | "div" -> Some "skunk_div"
  | "mod" -> Some "skunk_mod"
  | _ -> None

(* Tagged arithmetic.  An integer is 2n + 1, so

     a + b   is  a + b - 1
     a - b   is  a - b + 1
     a * b   is  (a >> 1) * (b - 1) + 1
     ~a      is  2 - a

   and that is the whole of it.  Which instructions those become is LLVM's
   question: the `lea` that does an addition and its fixup at once is a tile in
   its selector, not a decision here. *)
let arith c op args =
  let g = ir c in
  let one = Ir.int 1 in
  match (op, args) with
  | "+", [ x; y ] -> Ir.sub g (Ir.add g x y) one
  | "-", [ x; y ] -> Ir.add g (Ir.sub g x y) one
  | "*", [ x; y ] -> Ir.add g (Ir.mul g (Ir.ashr g x one) (Ir.sub g y one)) one
  | "~", [ x ] -> Ir.sub g (Ir.int 2) x
  | "/", _ ->
      Loc.fail ~where:"unsupported" Loc.unknown
        "real division needs a representation the back end does not have yet \
         (see doc/12-abi.md)"
  | _ -> failwith ("lower: no primitive " ^ op)

(* ---- what LLVM cannot see -------------------------------------------------- *)

(* The runtime is another object file, so LLVM has no idea what is inside
   `skunk_lt` or `skunk_div` and will not inline either.  For most of the
   runtime that is right -- the collector and `show` are loops, and a call is
   what they should be -- but three of them are one instruction in the case that
   actually happens, and the call is then the whole cost.

   So those three get their fast case written out here and keep the call for the
   rest.  Each is a fact only this compiler knows, and the shape is the same in
   all three: a test, the arithmetic, and the runtime on the other branch. *)

let split c ~test ~fast ~slow =
  let g = ir c in
  let fast_b = block_named c "fast" in
  let slow_b = block_named c "slow" in
  let done_b = block_named c "done" in
  Ir.cond_br g test fast_b slow_b;
  Ir.position g fast_b;
  let fv = fast () in
  let from_fast = here c in
  Ir.br g done_b;
  Ir.position g slow_b;
  let sv = slow () in
  let from_slow = here c in
  Ir.br g done_b;
  Ir.position g done_b;
  let p = Ir.phi g done_b ~ty:Ir.i64 ~name:"v" in
  Ir.add_incoming p fv from_fast;
  Ir.add_incoming p sv from_slow;
  Ir.phi_value p

(* An integer is 2n + 1, so the low bit is the test.  Which of `int` and `string`
   a comparison meant was settled by the type checker and then erased, so it is
   the value that says, exactly as it does inside the runtime. *)
let is_int c v = Ir.icmp (ir c) "ne" (Ir.and_ (ir c) v (Ir.int 1)) (Ir.int 0)

(* Two integers compare as their tagged words do -- 2n + 1 is monotone in n -- so
   the fast case needs no untagging at all.  Equality is the same argument once
   over: an integer is equal to a value only if the two words are identical.

   What comes back is the bit as well as the value.  `true` and `false` are
   blocks like any other constructor, so a comparison has to produce one -- and
   then the `case` that reads it immediately afterwards would go back to the
   heap for a descriptor and a tag to learn what this line already knew.  So the
   bit is kept, [switch] uses it when it can, and the `select` that built the
   block is left to be deleted by whoever finds it dead. *)
let comparison c op pred a b =
  let g = ir c in
  let fast_b = block_named c "fast" in
  let slow_b = block_named c "slow" in
  let done_b = block_named c "done" in
  Ir.cond_br g (is_int c a) fast_b slow_b;
  Ir.position g fast_b;
  let fast_bit = Ir.icmp g pred a b in
  let from_fast = here c in
  Ir.br g done_b;
  Ir.position g slow_b;
  let answer = Lay.call c.t (Option.get (routine op)) [ a; b ] in
  let slow_bit = Ir.icmp g "eq" answer (Lay.true_value c.t) in
  let from_slow = here c in
  Ir.br g done_b;
  Ir.position g done_b;
  let p = Ir.phi g done_b ~ty:Ir.i1 ~name:"bit" in
  Ir.add_incoming p fast_bit from_fast;
  Ir.add_incoming p slow_bit from_slow;
  let bit = Ir.phi_value p in
  (Ir.select g bit (Lay.true_value c.t) (Lay.false_value c.t), bit)

(* Division is the one that pays twice.  Writing `sdiv` here rather than calling
   the runtime saves the call -- and it also hands LLVM a division it can see, so
   `n div 65536` becomes the shift and the sign fixup that a strength-reduction
   pass knows how to write and this compiler does not. *)
let division c op a b =
  let g = ir c in
  let one = Ir.int 1 in
  let y = Ir.ashr g b one in
  split c
    ~test:(Ir.icmp g "ne" y (Ir.int 0))
    ~fast:(fun () ->
      let x = Ir.ashr g a one in
      let q = if op = "div" then Ir.sdiv g x y else Ir.srem g x y in
      Ir.or_ g (Ir.shl g q one) one)
    ~slow:(fun () -> Lay.call c.t (Option.get (routine op)) [ a; b ])

let predicate = function
  | "<" -> Some "slt"
  | "<=" -> Some "sle"
  | ">" -> Some "sgt"
  | ">=" -> Some "sge"
  | "=" -> Some "eq"
  | "<>" -> Some "ne"
  | _ -> None

(* The value, and the bit beside it when there was one. *)
let prim c op args =
  let vs = List.map (atom c) args in
  match (op, vs) with
  (* The store.  A ref is a one-field block, so these two are a load and a store
     and not a call; nothing moves, so there is no barrier to write. *)
  | "!", [ r ] -> (Lay.field c.t r 0, None)
  | ":=", [ r; x ] ->
      Lay.set_field c.t r 0 x;
      (Lay.unit_value c.t, None)
  | ("div" | "mod"), [ a; b ] -> (division c op a b, None)
  | _, [ a; b ] when predicate op <> None ->
      let v, bit = comparison c op (Option.get (predicate op)) a b in
      (v, Some bit)
  | _ -> (
      match routine op with
      | Some sym -> (Lay.call c.t sym vs, None)
      | None -> (arith c op vs, None))

(* ---- right-hand sides ----------------------------------------------------- *)

(* A closure is allocated and then filled in, always -- not only for a recursive
   group.  The captures have to be computed before the allocation is asked for
   anyway, and writing it this way means [Fix], where the closures hold each
   other and there is no order to define them in, is the same code with the two
   halves separated. *)
let alloc_closure c label ncaps =
  let cl = Lay.alloc c.t (Lay.closure_desc c.t ncaps) (ncaps + 1) in
  Lay.set_field c.t cl 0 (Ir.addr (Lay.code c.t label));
  cl

let fill_closure c cl caps = List.iteri (fun i a -> Lay.set_field c.t cl (i + 1) (atom c a)) caps

let rhs c : F.rhs -> Ir.value * Ir.value option = function
  | F.Atom a -> (atom c a, None)
  | F.Capture i -> (Lay.field c.t Lay.closure_param (i + 1), None)
  | F.Closure (label, caps) ->
      let cl = alloc_closure c label (List.length caps) in
      fill_closure c cl caps;
      (cl, None)
  | F.Call (f, a) ->
      let f = atom c f in
      let a = atom c a in
      (call_closure c f a, None)
  | F.Prim (op, ats) -> prim c op ats
  | F.Record fs ->
      let ls = List.map fst fs in
      (* The fields are computed before the allocation is asked for, because the
         allocation may collect and the collector has to be able to see them. *)
      let vs = List.map (fun (_, a) -> atom c a) fs in
      let r = Lay.alloc c.t (Lay.record_desc c.t ls) (List.length vs) in
      List.iteri (fun i v -> Lay.set_field c.t r i v) vs;
      (r, None)
  | F.Con (con, None) -> (Lay.nullary c.t con, None)
  | F.Con (con, Some a) ->
      let v = atom c a in
      let b = Lay.alloc c.t (Lay.con_desc c.t con) 1 in
      Lay.set_field c.t b 0 v;
      (b, None)
  | F.Field (a, _, i) -> (Lay.field c.t (atom c a) i, None)
  | F.Payload a -> (Lay.field c.t (atom c a) 0, None)

(* ---- blocks and terminators ----------------------------------------------- *)

let tag_of = function Core.Ktag con -> con.Types.cidx | _ -> assert false

let key_const = function
  | Core.Kint n -> Ir.int ((2 * n) + 1)
  | Core.Ktag con -> Ir.int con.Types.cidx
  | Core.Kstr _ -> assert false (* strings are not a switch; see [switch] *)

let rec block c : F.block -> unit = function
  | F.Let (x, r, rest) ->
      let v, bit = rhs c r in
      Hashtbl.replace c.names x v;
      (match bit with Some b -> Hashtbl.replace c.bits x b | None -> ());
      block c rest
  | F.Fix (defs, rest) ->
      (* Every closure of the group exists before any capture is written, which
         is the only way to write a cycle of definitions down. *)
      let made =
        List.map
          (fun (name, r) ->
            match r with
            | F.Closure (label, caps) ->
                let cl = alloc_closure c label (List.length caps) in
                Hashtbl.replace c.names name cl;
                (cl, caps)
            | _ -> failwith "lower: a fix binding must be a closure")
          defs
      in
      List.iter (fun (cl, caps) -> fill_closure c cl caps) made;
      block c rest
  | F.Join (j, ps, body, rest) ->
      let g = ir c in
      let entered = here c in
      let jb = block_named c ("join." ^ j) in
      let phis = List.map (fun p -> Ir.phi g jb ~ty:Ir.i64 ~name:p) ps in
      List.iter2 (fun p phi -> Hashtbl.replace c.names p (Ir.phi_value phi)) ps phis;
      Hashtbl.replace c.joins j (jb, phis);
      (* The jumps are in the continuation, so it is lowered first: by the time
         the body is reached, the phis know where their values come from. *)
      Ir.position g entered;
      block c rest;
      Ir.position g jb;
      block c body
  | F.Tail t -> tail c t

and tail c : F.tail -> unit = function
  | F.Ret a -> Ir.ret (ir c) (atom c a)
  | F.TCall (f, a) ->
      let f = atom c f in
      let a = atom c a in
      Ir.ret (ir c) (call_closure c ~musttail:true f a)
  | F.Jump (j, args) ->
      let jb, phis = Hashtbl.find c.joins j in
      let vs = List.map (atom c) args in
      (* After the arguments, because one of them may be a load and the phi has
         to name the block the branch actually leaves from. *)
      let from = here c in
      List.iter2 (fun phi v -> Ir.add_incoming phi v from) phis vs;
      Ir.br (ir c) jb
  | F.Fail (loc, _) ->
      (* The message is the runtime's; what the compiler supplies is where in the
         source it happened. *)
      Lay.call_void c.t "skunk_match_fail" [ Lay.str c.t (Loc.to_string loc) ];
      Ir.unreachable (ir c)
  | F.Switch (a, arms, dflt) -> switch c a (atom c a) arms dflt

(* A `case` over a datatype compares tags, and the tag is in the descriptor: one
   word back from the value, and word five of what is there.  A `case` over
   integers compares the values themselves, tags and all, because the tagged
   representation is one-to-one.  Both are one LLVM `switch`, which is what makes
   a jump table possible without asking for one.

   Strings are the exception.  Equality of strings is a walk over bytes, so there
   is nothing to switch on and the arms become a chain of calls and branches. *)
and switch c scrutinee v arms dflt =
  let g = ir c in
  let arm_blocks = List.map (fun (k, body) -> (k, body, block_named c "arm")) arms in
  let dflt_block = block_named c (match dflt with Some _ -> "default" | None -> "nomatch") in
  (match arms with
  | (Core.Kstr _, _) :: _ ->
      let rec chain = function
        | [] -> Ir.br g dflt_block
        | (k, _, blk) :: rest ->
            let s = match k with Core.Kstr s -> s | _ -> assert false in
            let r = Lay.call c.t "skunk_equal" [ v; Lay.str c.t s ] in
            let cond = Ir.icmp g "eq" r (Lay.true_value c.t) in
            let next = if rest = [] then dflt_block else block_named c "next" in
            Ir.cond_br g cond blk next;
            if rest <> [] then begin
              Ir.position g next;
              chain rest
            end
      in
      chain arm_blocks
  | _ ->
      (* A `case` over booleans whose value came from a comparison is the one
         place the tag is already in hand: `true` and `false` are blocks, but the
         bit that chose between them is still there, and switching on it leaves
         the block with nobody to read it. *)
      let bit =
        match (scrutinee, arms) with
        | F.AVar x, (Core.Ktag con, _) :: _
          when con.Types.cres.Types.tid = Types.bool_tc.Types.tid ->
            Hashtbl.find_opt c.bits x
        | _ -> None
      in
      let ty, on, key =
        match (bit, arms) with
        | Some b, _ -> (Ir.i1, b, fun k -> Ir.int (tag_of k))
        | None, (Core.Ktag _, _) :: _ ->
            (* The tag is in the descriptor: one word back from the value, and
               word five of what is there. *)
            (Ir.i64, Lay.field c.t (Lay.field c.t v (-1)) 5, key_const)
        | None, _ -> (Ir.i64, v, key_const)
      in
      Ir.switch g ~ty ~on ~default:dflt_block
        (List.map (fun (k, _, blk) -> (key k, blk)) arm_blocks));
  List.iter
    (fun (_, body, blk) ->
      Ir.position g blk;
      block c body)
    arm_blocks;
  Ir.position g dflt_block;
  match dflt with
  | Some body -> block c body
  | None -> tail c (F.Fail (Loc.unknown, "no pattern matched"))

(* ---- functions ------------------------------------------------------------ *)

let body t globals ~name ~linkage param b =
  ignore (Ir.func t.Lay.ir ~name ~linkage ~ret:Ir.i64 ~params:Lay.code_params);
  let c =
    { t; names = Hashtbl.create 64; bits = Hashtbl.create 16; joins = Hashtbl.create 16; globals }
  in
  Ir.position t.Lay.ir (Ir.append_block t.Lay.ir "entry");
  (match param with
  | None -> ()
  | Some p -> Hashtbl.replace c.names p Lay.argument_param);
  block c b;
  Ir.render t.Lay.ir

(* ---- the program ---------------------------------------------------------- *)

(* What `skunk_program` has to do for one top-level binding: run its body, keep
   the result in the global it names, and report it the way the interpreter
   reports it. *)
type item = {
  iglobal : string option;
  icode : string option;
  ilabel : string option;
  ishow : bool;
}

(* One compilation unit: every code block, and one function per top-level
   binding that has a body.  A binding's body is a function of no arguments --
   closure conversion did not have to name it, because nothing calls it -- so it
   is given the position it had. *)
let unit_ t globals ~prefix (p : F.program) =
  List.iter
    (fun (cd : F.code) ->
      body t globals ~name:(Lay.code t cd.F.c_label) ~linkage:Ir.internal (Some cd.F.c_param)
        cd.F.c_body)
    p.F.codes;
  List.mapi
    (fun i (it : F.item) ->
      let code =
        Option.map
          (fun b ->
            let name = Printf.sprintf "@%s_item_%d" prefix i in
            body t globals ~name ~linkage:Ir.internal None b;
            name)
          it.F.ibody
      in
      {
        iglobal = (if it.F.iname = "" then None else Some (Lay.global t it.F.iname None));
        icode = code;
        ilabel = Option.map Lazy.force it.F.ilabel;
        ishow = it.F.ishow;
      })
    p.F.items

(* The entry point the runtime calls once the heap exists. *)
let entry t items =
  ignore
    (Ir.func t.Lay.ir ~name:"@skunk_program" ~linkage:Ir.exported ~ret:Ir.void ~params:[]);
  Ir.position t.Lay.ir (Ir.append_block t.Lay.ir "entry");
  let zero = Ir.int 1 in
  List.iter
    (fun it ->
      let result = Option.map (fun code -> Ir.call t.Lay.ir code [ zero; zero ]) it.icode in
      (match (it.iglobal, result) with
      | Some g, Some r -> Ir.store t.Lay.ir r g
      | _ -> ());
      match (it.ilabel, result) with
      | None, _ -> ()
      | Some l, Some r when it.ishow -> Lay.call_void t "skunk_report" [ Lay.str t l; r ]
      | Some l, _ -> Lay.call_void t "skunk_report_label" [ Lay.str t l ])
    items;
  Ir.ret_void t.Lay.ir;
  Ir.render t.Lay.ir
