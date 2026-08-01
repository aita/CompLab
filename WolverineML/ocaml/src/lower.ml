(* Lowering: the typed syntax tree becomes a control flow graph.

   Two things are worth knowing about this pass.

   It never builds a phi.  A variable written in two branches is written to the
   same register twice, and [ssa.ml] is what turns those two writes into one phi.
   Lowering only has to make sure a definition reaches every use, which
   structured control flow does for free.

   It decides where a variable lives.  A variable the checker did not mark as
   escaping becomes a register; one that escaped becomes a frame slot, reached
   through [Load_slot]/[Store_slot] in its own function and through a chain of
   static links from a nested one. *)

open Ir

type options = { checks : bool }

(* What the whole module shares: string literals and the function list. *)
type shared = {
  opts : options;
  modul : modul;
  (* text -> symbol.  A hash table, because a literal is looked up once per
     occurrence and there is no order to keep: the order the module prints them
     in is [modul.strings], which is appended to as they are first seen. *)
  symbols : (string, string) Hashtbl.t;
  mutable strings : string_lit list; (* reversed while it is built *)
  mutable funcs : func list; (* likewise *)
}

type lowerer = {
  up : shared;
  fn : func;
  mutable cur : block;
  mutable breaks : string list;
  mutable counter : int;
  mutable has_children : bool;
}

let literal up text =
  match Hashtbl.find_opt up.symbols text with
  | Some symbol -> symbol
  | None ->
      let symbol = Printf.sprintf ".Lstr%d" (Hashtbl.length up.symbols) in
      Hashtbl.replace up.symbols text symbol;
      up.strings <- { lit_symbol = symbol; text } :: up.strings;
      symbol

let new_lowerer up label name depth =
  let fn = new_func label name depth in
  let cur = add_block fn "entry" in
  if depth > 0 then fn.link_slot <- new_slot fn;
  up.funcs <- fn :: up.funcs;
  { up; fn; cur; breaks = []; counter = 0; has_children = false }

(* -- block plumbing -------------------------------------------------------- *)

let fresh l hint =
  l.counter <- l.counter + 1;
  add_block l.fn (Printf.sprintf "%s%d" hint l.counter)

let put l instr = emit l.cur instr

let terminate l term =
  put l term;
  l.cur <- fresh l "dead"

let jump l b = terminate l (Jmp { target = b.label })

let branch l cond yes no =
  terminate l (Cbr { cond; then_ = yes.label; else_ = no.label; code = "" })

let reg l = new_reg l.fn

let constant l value =
  let r = reg l in
  put l (Const { dst = r; value });
  r

let binop l op lhs rhs =
  let r = reg l in
  put l (Bin { dst = r; op; lhs; rhs });
  r

let compare_ l op lhs rhs =
  let r = reg l in
  put l (Cmp { dst = r; op; lhs; rhs });
  r

let call_runtime l name args =
  let r = reg l in
  put l (Call { dst = Some r; callee = name; args });
  r

(* -- run-time checks ------------------------------------------------------- *)

let check_not_nil l base =
  if l.up.opts.checks then begin
    let bad = fresh l "nil" in
    let ok = fresh l "ok" in
    branch l (compare_ l "=" base (constant l 0L)) bad ok;
    l.cur <- bad;
    put l (Call { dst = None; callee = "wol_nil_error"; args = [] });
    jump l ok;
    l.cur <- ok
  end

let check_bounds l base idx =
  if l.up.opts.checks then begin
    let length = reg l in
    put l (Load { dst = length; base; offset = 0 });
    let bad = fresh l "oob" in
    let ok = fresh l "ok" in
    branch l (compare_ l "u<" idx length) ok bad;
    l.cur <- bad;
    put l (Call { dst = None; callee = "wol_bounds_error"; args = [ idx; length ] });
    jump l ok;
    l.cur <- ok
  end

let check_nonzero l rhs =
  if l.up.opts.checks then begin
    let bad = fresh l "divzero" in
    let ok = fresh l "ok" in
    branch l (compare_ l "=" rhs (constant l 0L)) bad ok;
    l.cur <- bad;
    put l (Call { dst = None; callee = "wol_div_error"; args = [] });
    jump l ok;
    l.cur <- ok
  end

(* -- reaching variables and frames ----------------------------------------- *)

(* A register holding the frame pointer of the function at [depth]. *)
let frame_at l depth =
  let r = reg l in
  if depth = l.fn.depth then begin
    put l (Frame_addr { dst = r });
    r
  end
  else begin
    put l (Load_slot { dst = r; slot = l.fn.link_slot });
    let at = ref r and here = ref (l.fn.depth - 1) in
    while !here > depth do
      let next = reg l in
      put l (Load { dst = next; base = !at; offset = slot_offset 0 });
      at := next;
      decr here
    done;
    !at
  end

let read_var l (sym : Types.var_sym) =
  if not sym.escapes then sym.reg
  else if sym.var_depth = l.fn.depth then begin
    let r = reg l in
    put l (Load_slot { dst = r; slot = sym.slot });
    r
  end
  else begin
    let base = frame_at l sym.var_depth in
    let r = reg l in
    put l (Load { dst = r; base; offset = slot_offset sym.slot });
    r
  end

let write_var l (sym : Types.var_sym) value =
  if not sym.escapes then put l (Move { dst = sym.reg; src = value })
  else if sym.var_depth = l.fn.depth then put l (Store_slot { slot = sym.slot; src = value })
  else
    let base = frame_at l sym.var_depth in
    put l (Store { base; offset = slot_offset sym.slot; src = value })

(* [bind] gives a variable its home, and puts the initial value in it. *)
let bind l (sym : Types.var_sym) value =
  if sym.escapes then begin
    sym.slot <- new_slot l.fn;
    put l (Store_slot { slot = sym.slot; src = value })
  end
  else begin
    sym.reg <- reg l;
    put l (Move { dst = sym.reg; src = value })
  end

(* -- expressions ----------------------------------------------------------- *)

(* [exp] answers with the register the value came out in, and with [None] for the
   expressions that have no value: a unit literal, an assignment, a loop, a
   [break].  [value] is the same question asked where a value is required. *)
let rec exp l (e : Ast.exp) =
  match e.node with
  | Ast.Int_lit v -> Some (constant l v)
  | Ast.Bool_lit b -> Some (constant l (if b then 1L else 0L))
  | Ast.Nil_lit -> Some (constant l 0L)
  | Ast.Unit_lit -> None
  | Ast.Str_lit text ->
      let r = reg l in
      put l (Str_const { dst = r; str_symbol = literal l.up text });
      Some r
  | Ast.Var v -> Some (read_var l (Option.get v.var_sym))
  | Ast.Call c -> call l c
  | Ast.Record_lit r -> Some (record l e r)
  | Ast.Index (array, index) ->
      let addr = element_address l array index in
      let r = reg l in
      put l (Load { dst = r; base = addr; offset = word });
      Some r
  | Ast.Field f ->
      let base = value l f.record in
      check_not_nil l base;
      let r = reg l in
      put l (Load { dst = r; base; offset = word * f.offset });
      Some r
  | Ast.Neg operand ->
      let zero = constant l 0L in
      Some (binop l "-" zero (value l operand))
  | Ast.Bin (op, lhs, rhs) -> Some (bin l op lhs rhs)
  | Ast.Logic (op, lhs, rhs) -> Some (logic l op lhs rhs)
  | Ast.Assign (target, v) ->
      assign l target v;
      None
  | Ast.If (cond, then_, else_) -> if_exp l e cond then_ else_
  | Ast.While (cond, body) ->
      while_exp l cond body;
      None
  | Ast.For f ->
      for_exp l f;
      None
  | Ast.Break ->
      terminate l (Jmp { target = List.hd l.breaks });
      None
  | Ast.Seq items -> List.fold_left (fun _ item -> exp l item) None items
  | Ast.Let (ds, body) ->
      decls l ds;
      exp l body

and value l e =
  match exp l e with Some r -> r | None -> failwith "expected a value"

and bin l op lhs rhs =
  let a = value l lhs in
  let b = value l rhs in
  match op with
  | "^" -> call_runtime l "wol_concat" [ a; b ]
  | "/" | "mod" ->
      check_nonzero l b;
      if op = "/" then binop l "/" a b
      else begin
        (* The remainder is spelled out rather than left to the emitter: the
           quotient it needs in between is a value like any other, and the
           allocator can find it a register.  The emitter fuses the last two
           back into one [msub]. *)
        let quotient = binop l "/" a b in
        let product = binop l "*" quotient b in
        binop l "-" a product
      end
  | "+" | "-" | "*" -> binop l op a b
  | _ ->
      if lhs.Ast.ty = Some Types.String_t then
        let order = call_runtime l "wol_string_cmp" [ a; b ] in
        compare_ l op order (constant l 0L)
      else compare_ l op a b

(* [andalso] and [orelse] are branches, so the result needs a register. *)
and logic l op lhs rhs =
  let result = reg l in
  let rhs_block = fresh l "logic" in
  let join = fresh l "logicjoin" in
  let a = value l lhs in
  put l (Move { dst = result; src = a });
  if op = "andalso" then branch l a rhs_block join else branch l a join rhs_block;
  l.cur <- rhs_block;
  put l (Move { dst = result; src = value l rhs });
  jump l join;
  l.cur <- join;
  result

and call l (c : Ast.call) =
  let sym = Option.get c.fun_sym in
  match sym.builtin with
  | Some "not" ->
      (* Sequential lets, because OCaml evaluates arguments right to left and the
         register numbers are the order the instructions came out in. *)
      let operand = value l (List.hd c.args) in
      let one = constant l 1L in
      Some (binop l "xor" operand one)
  | Some "array" ->
      let n = value l (List.nth c.args 0) in
      let init = value l (List.nth c.args 1) in
      Some (call_runtime l "wol_array" [ n; init ])
  | Some "length" ->
      let arr = value l (List.hd c.args) in
      check_not_nil l arr;
      let r = reg l in
      put l (Load { dst = r; base = arr; offset = 0 });
      Some r
  | _ ->
      (* The arguments are lowered first, and only then the static link, which is
         the order the register numbers come out in. *)
      let args = Util.map_in_order (fun a -> value l a) c.args in
      let args =
        if sym.builtin = None then frame_at l (sym.fun_depth - 1) :: args else args
      in
      if sym.result = Types.Unit_t then begin
        put l (Call { dst = None; callee = sym.label; args });
        None
      end
      else Some (call_runtime l sym.label args)

and record l (e : Ast.exp) (r : Ast.record_lit) =
  let rec_ = match Option.get e.ty with Types.Record_t r -> r | _ -> assert false in
  let fields = max (List.length rec_.fields) 1 in
  let size = constant l (Int64.of_int (word * fields)) in
  let base = call_runtime l "wol_alloc" [ size ] in
  List.iteri
    (fun at (init : Ast.field_init) ->
      put l (Store { base; offset = word * at; src = value l init.value }))
    r.inits;
  base

(* The address of [a.(i)], without the length word the elements follow.

   The selector turns this into one [add] with a shifted operand, and the word is
   the load's displacement, so the two instructions that come out are the two the
   machine has. *)
and element_address l array index =
  let base = value l array in
  let idx = value l index in
  check_not_nil l base;
  check_bounds l base idx;
  binop l "+" base (binop l "shl" idx (constant l 3L))

and assign l (target : Ast.exp) v =
  match target.node with
  | Ast.Var var -> write_var l (Option.get var.var_sym) (value l v)
  | Ast.Index (array, index) ->
      let addr = element_address l array index in
      put l (Store { base = addr; offset = word; src = value l v })
  | Ast.Field f ->
      let base = value l f.record in
      check_not_nil l base;
      put l (Store { base; offset = word * f.offset; src = value l v })
  | _ -> failwith "assignment to something that is not a place"

(* An [if] with a value copies each branch's answer into the one register the
   whole expression came out in.  Either half may be absent: a unit [if] has no
   register to copy into, and a branch that ends in a [break] leaves no value. *)
and copy_into l result taken =
  match (result, taken) with
  | Some dst, Some src -> put l (Move { dst; src })
  | _ -> ()

and if_exp l (e : Ast.exp) cond then_ else_ =
  let result = if Option.get e.ty = Types.Unit_t then None else Some (reg l) in
  let yes = fresh l "then" in
  let no = fresh l "else" in
  let join = fresh l "join" in
  branch l (value l cond) yes no;

  l.cur <- yes;
  copy_into l result (exp l then_);
  jump l join;

  l.cur <- no;
  (match else_ with Some els -> copy_into l result (exp l els) | None -> ());
  jump l join;

  l.cur <- join;
  result

and while_exp l cond body =
  let test = fresh l "test" in
  let body_block = fresh l "body" in
  let done_ = fresh l "done" in
  jump l test;
  l.cur <- test;
  branch l (value l cond) body_block done_;
  l.cur <- body_block;
  l.breaks <- done_.label :: l.breaks;
  ignore (exp l body);
  l.breaks <- List.tl l.breaks;
  jump l test;
  l.cur <- done_

(* [for i = lo to hi] counts up, and stops before overflowing at [hi]. *)
and for_exp l (f : Ast.for_exp) =
  let sym = Option.get f.loop_sym in
  let lo = value l f.lo in
  let hi_value = value l f.hi in
  let hi = reg l in
  put l (Move { dst = hi; src = hi_value });
  bind l sym lo;
  let body = fresh l "forbody" in
  let step = fresh l "forstep" in
  let done_ = fresh l "fordone" in
  branch l (compare_ l "<=" lo hi) body done_;

  l.cur <- body;
  l.breaks <- done_.label :: l.breaks;
  ignore (exp l f.body);
  l.breaks <- List.tl l.breaks;
  let i = read_var l sym in
  branch l (compare_ l "<" i hi) step done_;

  l.cur <- step;
  let i = read_var l sym in
  let one = constant l 1L in
  write_var l sym (binop l "+" i one);
  jump l body;

  l.cur <- done_

(* -- declarations ---------------------------------------------------------- *)

and decls l list = List.iter (decl l) list

and decl l = function
  | Ast.Type_decl _ -> ()
  | Ast.Val_decl d -> (
      let v = exp l d.init in
      match (d.decl_sym, v) with
      | Some sym, Some r when sym.var_ty <> Types.Unit_t -> bind l sym r
      | _ -> ())
  | Ast.Fun_decl binds ->
      l.has_children <- true;
      List.iter (fun b -> function_ l.up b) binds

(* -- whole functions ------------------------------------------------------- *)

(* A function nobody nests inside, and that never looks outward, keeps no static
   link: the slot goes, and every later slot moves down one. *)
and drop_unused_static_link l =
  let slot = l.fn.link_slot in
  let reads =
    List.exists
      (fun b ->
        List.exists (function Load_slot ls -> ls.slot = slot | _ -> false) (instrs b))
      (walk l.fn)
  in
  if slot >= 0 && (not l.has_children) && not reads then begin
    List.iter
      (fun b ->
        let below at = if at > slot then at - 1 else at in
        let kept =
          List.filter_map
            (function
              | Store_slot s when s.slot = slot -> None
              | Store_slot s -> Some (Store_slot { s with slot = below s.slot })
              | Load_slot l -> Some (Load_slot { l with slot = below l.slot })
              | i -> Some i)
            (instrs b)
        in
        set_instrs b kept)
      (walk l.fn);
    l.fn.nslots <- l.fn.nslots - 1;
    l.fn.link_slot <- -1
  end

and finish l =
  drop_unreachable l.fn;
  drop_unused_static_link l

and function_ up (b : Ast.fun_bind) =
  let sym = Option.get b.sym in
  let l = new_lowerer up sym.label sym.fun_name sym.fun_depth in
  if l.fn.depth > 0 then begin
    let link = reg l in
    Dynarray.add_last l.fn.params link;
    put l (Store_slot { slot = l.fn.link_slot; src = link })
  end;
  let first = Dynarray.length l.fn.params in
  List.iteri
    (fun offset (psym : Types.var_sym) ->
      let index = first + offset in
      if index >= argument_registers then begin
        psym.escapes <- true;
        psym.slot <- -(index - argument_registers + 1)
      end
      else begin
        let r = reg l in
        Dynarray.add_last l.fn.params r;
        if psym.escapes then begin
          psym.slot <- new_slot l.fn;
          put l (Store_slot { slot = psym.slot; src = r })
        end
        else psym.reg <- r
      end)
    sym.params;
  let v = exp l b.fun_body in
  let v = if sym.result = Types.Unit_t then None else v in
  terminate l (Ret { value = v });
  finish l

let lower (prog : Ast.program) opts =
  let up =
    { opts; modul = { funcs = []; strings = [] }; symbols = Hashtbl.create 16;
      strings = []; funcs = [] }
  in
  let main = new_lowerer up "wol_main" "main" 0 in
  decls main prog;
  terminate main (Ret { value = None });
  finish main;
  up.modul.funcs <- List.rev up.funcs;
  up.modul.strings <- List.rev up.strings;
  up.modul
