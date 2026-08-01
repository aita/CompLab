(* The tests.  One executable, so that `dune test` runs the lot and says how many
   passed; a failure prints what it wanted and what it got, and the run exits
   non-zero. *)

open Wolv
open Ir

let passed = ref 0
let failed = ref 0
let skipped = ref 0

let check name condition =
  if condition then incr passed
  else begin
    incr failed;
    Printf.printf "FAIL %s\n" name
  end

let equal name got want =
  if got = want then incr passed
  else begin
    incr failed;
    Printf.printf "FAIL %s\n  got  %s\n  want %s\n" name got want
  end

let equal_int name got want = equal name (string_of_int got) (string_of_int want)

(* [refuses] insists the source is rejected, with [want] somewhere in the message. *)
let contains haystack needle =
  let n = String.length needle in
  let rec go at =
    at + n <= String.length haystack
    && (String.sub haystack at n = needle || go (at + 1))
  in
  n = 0 || go 0

(* -- the lexer --------------------------------------------------------------- *)

let kinds source = List.map (fun (t : Lexer.token) -> t.kind) (Lexer.lex source)

let refuses_with name source want =
  match Lexer.lex source with
  | exception (Diag.Error _ as e) ->
      if contains (Diag.message e) want then incr passed
      else begin
        incr failed;
        Printf.printf "FAIL %s: %s\n" name (Diag.message e)
      end
  | exception e ->
      incr failed;
      Printf.printf "FAIL %s: %s\n" name (Printexc.to_string e)
  | _ ->
      incr failed;
      Printf.printf "FAIL %s: it was accepted\n" name

let lexer_tests () =
  check "keywords are not identifiers"
    (kinds "let val" = [ Lexer.LET; Lexer.VAL; Lexer.EOF ]
    && kinds "letter" = [ Lexer.IDENT; Lexer.EOF ]);
  check "longest punctuation wins"
    (kinds ":= : <= < <> >="
    = [ Lexer.ASSIGN; Lexer.COLON; Lexer.LE; Lexer.LT; Lexer.NE; Lexer.GE; Lexer.EOF ]);
  check "comments nest" (kinds "(* a (* b *) c *) 1" = [ Lexer.INT; Lexer.EOF ]);
  refuses_with "an unterminated comment is caught" "(* forever" "unterminated comment";
  equal "string escapes"
    (List.hd (Lexer.lex {|"a\nb\t\"\\\065"|})).text
    "a\nb\t\"\\A";
  equal "a string is bytes" (List.hd (Lexer.lex {|"日"|})).text "\xe6\x97\xa5";
  equal "a numeric escape names one byte"
    (List.hd (Lexer.lex {|"\230\151\165"|})).text
    (List.hd (Lexer.lex {|"日"|})).text;
  equal_int "size counts bytes" (String.length (List.hd (Lexer.lex {|"日本語"|})).text) 9;
  equal_int "a character outside the basic plane is four bytes"
    (String.length (List.hd (Lexer.lex "\"\xf0\x9f\x98\x80\"")).text)
    4;
  (* The code point is one character, so a column counts it once. *)
  equal "and one column"
    (Diag.show_span (List.hd (Lexer.lex "(*\xf0\x9f\x98\x80*) x")).at)
    "1:7";
  check "a name may be written in any script"
    (kinds "名前" = [ Lexer.IDENT; Lexer.EOF ]);
  refuses_with "a numeric escape is three digits" {|"\65"|} "three digits";
  refuses_with "a string may not span lines" "\"one\ntwo\"" "may not span lines";
  equal "spans count from one" (Diag.show_span (List.hd (Lexer.lex "val\n  x")).at) "1:1";
  equal "and follow the newline"
    (Diag.show_span (List.nth (Lexer.lex "val\n  x") 1).at)
    "2:3";
  refuses_with "a number may not run into a name" "12ab" "is not a number";
  refuses_with "a stray character is caught" "a ? b" "stray character"

(* -- the parser -------------------------------------------------------------- *)

let rec shape (e : Ast.exp) =
  match e.node with
  | Ast.Int_lit v -> Int64.to_string v
  | Ast.Str_lit v -> "\"" ^ v ^ "\""
  | Ast.Bool_lit b -> if b then "true" else "false"
  | Ast.Nil_lit -> "nil"
  | Ast.Unit_lit -> "()"
  | Ast.Var v -> v.name
  | Ast.Neg operand -> "(~ " ^ shape operand ^ ")"
  | Ast.Bin (op, l, r) | Ast.Logic (op, l, r) ->
      "(" ^ op ^ " " ^ shape l ^ " " ^ shape r ^ ")"
  | Ast.Assign (t, v) -> "(:= " ^ shape t ^ " " ^ shape v ^ ")"
  | Ast.If (c, t, e') ->
      "(if " ^ shape c ^ " " ^ shape t
      ^ (match e' with Some x -> " " ^ shape x | None -> "")
      ^ ")"
  | Ast.While (c, b) -> "(while " ^ shape c ^ " " ^ shape b ^ ")"
  | Ast.For f ->
      "(for " ^ f.binder ^ " " ^ shape f.lo ^ " " ^ shape f.hi ^ " " ^ shape f.body ^ ")"
  | Ast.Break -> "break"
  | Ast.Seq items -> "(seq " ^ String.concat " " (List.map shape items) ^ ")"
  | Ast.Call c -> "(" ^ c.callee ^ " " ^ String.concat " " (List.map shape c.args) ^ ")"
  | Ast.Index (a, i) -> "(index " ^ shape a ^ " " ^ shape i ^ ")"
  | Ast.Field f -> "(field " ^ shape f.record ^ " " ^ f.select ^ ")"
  | Ast.Record_lit r ->
      "(record " ^ r.tyname ^ " "
      ^ String.concat " "
          (List.map (fun (f : Ast.field_init) -> f.init_name ^ "=" ^ shape f.value) r.inits)
      ^ ")"
  | Ast.Let (ds, body) -> Printf.sprintf "(let %d %s)" (List.length ds) (shape body)

let parses source want = equal ("parse " ^ source) (shape (Parser.parse_exp source)) want

let refuses_parse name source want =
  match Parser.parse_exp source with
  | exception (Diag.Error _ as e) ->
      if contains (Diag.message e) want then incr passed
      else begin
        incr failed;
        Printf.printf "FAIL %s: %s\n" name (Diag.message e)
      end
  | _ ->
      incr failed;
      Printf.printf "FAIL %s: it was accepted\n" name

let parser_tests () =
  parses "1 + 2 * 3" "(+ 1 (* 2 3))";
  parses "1 * 2 + 3" "(+ (* 1 2) 3)";
  parses "1 - 2 - 3" "(- (- 1 2) 3)";
  parses "1 + 2 = 3" "(= (+ 1 2) 3)";
  parses "a < b andalso c > d" "(andalso (< a b) (> c d))";
  parses "a orelse b andalso c" "(orelse a (andalso b c))";
  parses "x := y + 1" "(:= x (+ y 1))";
  parses "a := b := c" "(:= a (:= b c))";
  parses "if c then x := 1 else x := 2" "(if c (:= x 1) (:= x 2))";
  parses "if c then a else b + 1" "(if c a (+ b 1))";
  parses "a[i].f[j]" "(index (field (index a i) f) j)";
  parses "f(1, 2).g" "(field (f 1 2) g)";
  parses "()" "()";
  parses "(a; b; c)" "(seq a b c)";
  parses "(a; b;)" "(seq a b)";
  parses "(a)" "a";
  parses "~x + 1" "(+ (~ x) 1)";
  parses "~x * y" "(* (~ x) y)";
  parses "~9223372036854775808" "(~ -9223372036854775808)";
  parses "point { x = 1, y = 2 }" "(record point x=1 y=2)";
  parses "point (1, 2)" "(point 1 2)";
  parses "let val x = 1 var y = 2 in x + y end" "(let 2 (+ x y))";
  parses "let val x = 1 in end" "(let 1 ())";
  parses "(if c then a else b).f" "(field (if c a b) f)";
  refuses_parse "negation is a tilde" "-x" "negation is written";
  refuses_parse "a literal that does not fit" "18446744073709551616" "does not fit";
  refuses_parse "only a place can be assigned" "1 + 2 := 3" "not assignable";
  refuses_parse "errors name what was found" "if a do b" "expected `then`";
  refuses_parse "postfix only follows an atom" "nil.f" "unexpected";
  let prog = Parser.parse "type t = int\nval x = 1\nfun f (a : int) : int = a\n" in
  check "a program is declarations"
    (match prog with
    | [ Ast.Type_decl _; Ast.Val_decl _; Ast.Fun_decl _ ] -> true
    | _ -> false);
  check "mutual recursion is one declaration"
    (match Parser.parse "fun f () : int = g ()\nand g () : int = 1\n" with
    | [ Ast.Fun_decl [ a; b ] ] -> a.fun_label = "f" && b.fun_label = "g"
    | _ -> false)

(* -- the checker ------------------------------------------------------------- *)

let accepts source =
  let prog = Parser.parse source in
  Typecheck.check prog;
  prog

let allows name source =
  match accepts source with
  | _ -> incr passed
  | exception e ->
      incr failed;
      Printf.printf "FAIL %s: %s\n" name (Diag.show e)

let rejects name source want =
  match accepts source with
  | exception (Diag.Error _ as e) ->
      if contains (Diag.message e) want then incr passed
      else begin
        incr failed;
        Printf.printf "FAIL %s: %s\n" name (Diag.message e)
      end
  | _ ->
      incr failed;
      Printf.printf "FAIL %s: it was accepted\n" name

let typecheck_tests () =
  allows "arithmetic is on ints" "val x = 1 + 2";
  rejects "an int and a string" {|val x = 1 + "a"|} "expected `int`, found `string`";
  rejects "a bool and an int" "val x = true + 1" "expected `int`, found `bool`";
  allows "concatenation is on strings" {|val s = "a" ^ "b"|};
  rejects "concatenating an int" {|val s = "a" ^ 1|} "expected `string`, found `int`";
  allows "comparison gives bool" "val b = 1 < 2 andalso 3 >= 4";
  rejects "comparing across types" {|val b = "a" < 1|} "expected `string`, found `int`";
  rejects "ordering a bool" "val b = true < false" "compares int or string";
  allows "equality on ints" "val b = 1 = 2";
  rejects "equality across types" "val b = 1 = true" "compares `int` with `bool`";
  allows "a condition is bool" "val x = if true then 1 else 2";
  rejects "a condition that is not" "val x = if 1 then 1 else 2" "expected `bool`, found `int`";
  rejects "branches that differ" {|val x = if true then 1 else "a"|} "the branches differ";
  rejects "an if with no else" "val () = if true then 1" "in an `if` with no `else`";
  allows "a var can be assigned" "var x = 1 val () = x := 2";
  rejects "a val cannot" "val x = 1 val () = x := 2" "is a `val`";
  allows "a call that fits" "fun f (a : int) : int = a\nval x = f (1)";
  rejects "too many arguments" "fun f (a : int) : int = a\nval x = f (1, 2)" "takes 1 argument";
  allows "a procedure" "fun f () = print (\"x\")\nval () = f ()";
  rejects "a procedure that returns" "fun f () = 1" "expected `unit`, found `int`";
  rejects "a function as a value" "fun f () : int = 1\nval x = f" "functions are not values";
  allows "records" "type p = { x : int }\nval a = p { x = 1 }\nval b = a.x";
  rejects "records are nominal"
    "type p = { x : int } and q = { x : int }\n\
     fun f (r : p) : int = r.x\nval x = f (q { x = 1 })" "expected `p`, found `q`";
  rejects "a field that is not there" "type p = { x : int }\nval a = p { y = 1 }"
    "has no field `y`";
  rejects "a field left out" "type p = { x : int, y : int }\nval a = p { x = 1 }"
    "field `y` is missing";
  allows "nil is any record" "type p = { x : int }\nval a : p = nil\nval b = a = nil";
  rejects "nil with no annotation" "val a = nil" "needs a type annotation";
  allows "arrays" "val a = array (3, 0)\nval x = a[0] + 1";
  allows "a named array type" "type ints = int array\nval a : ints = array (3, 0)";
  rejects "an array index that is not an int" "val a = array (3, 0)\nval x = a[true]"
    "as an array index";
  rejects "length of a non-array" "val x = length (1)" "`length` wants an array";
  allows "break in a while" "val () = while true do break";
  allows "break in a for" "val () = for i = 0 to 3 do break";
  rejects "break outside a loop" "val () = break" "outside any loop";
  rejects "break across a function"
    "val () = while true do let fun f () = break in f () end" "outside any loop";
  allows "recursive types"
    "type list = { head : int, tail : list }\n\
     fun sum (l : list) : int = if l = nil then 0 else l.head + sum (l.tail)\n";
  allows "mutually recursive types" "type a = b array and b = { next : a }";
  rejects "an unbound name" "val x = y" "`y` is not bound";
  rejects "an unbound type" "val x : t = 1" "`t` is not a type";
  (* Escape analysis. *)
  let prog =
    accepts
      "fun outer () : int =\n\
      \  let var kept = 1\n\
      \      val plain = 2\n\
      \      fun inner () : int = kept\n\
      \  in inner () + plain end\n"
  in
  (match prog with
  | [ Ast.Fun_decl [ outer ] ] -> (
      match outer.fun_body.node with
      | Ast.Let ([ Ast.Val_decl kept; Ast.Val_decl plain; _ ], _) ->
          check "a nested read makes a variable escape" (Option.get kept.decl_sym).escapes;
          check "and one nobody reads does not"
            (not (Option.get plain.decl_sym).escapes)
      | _ -> check "escape analysis shape" false)
  | _ -> check "escape analysis shape" false);
  let prog =
    accepts "fun outer (n : int) : int =\n  let fun inner () : int = n in inner () end\n"
  in
  match prog with
  | [ Ast.Fun_decl [ outer ] ] ->
      check "a parameter escapes too"
        (Option.get (List.hd outer.fun_params).param_sym).escapes
  | _ -> check "parameter escape shape" false

(* -- the middle -------------------------------------------------------------- *)

let loop_source =
  "\n\
   fun count (n : int) : int =\n\
  \  let var i = 0\n\
  \      var total = 0\n\
  \  in\n\
  \    while i < n do (total := total + i; i := i + 1);\n\
  \    total\n\
  \  end\n\
   val () = printInt (count (10))\n"

let lowered source checks =
  let prog = accepts source in
  Lower.lower prog { Lower.checks }

let in_ssa source checks =
  let m = lowered source checks in
  Ssa.construct_module m;
  m

let selected source checks =
  let m = in_ssa source checks in
  Opt.optimise m;
  List.iter Ssa.split_critical_edges m.funcs;
  Select.select_module m;
  m

let ssa_tests () =
  let f = List.nth (lowered loop_source false).funcs 1 in
  let written = Hashtbl.create 32 in
  List.iter
    (fun b ->
      List.iter
        (fun instr ->
          Option.iter
            (fun d ->
              Hashtbl.replace written d
                (1 + Option.value (Hashtbl.find_opt written d) ~default:0))
            (defs instr))
        (instrs b))
    (walk f);
  check "lowering writes a variable more than once"
    (Hashtbl.fold (fun _ n acc -> acc || n > 1) written false);
  check "and builds no phi" (List.for_all (fun b -> b.phis = []) (walk f));

  let f = List.nth (in_ssa loop_source false).funcs 1 in
  Ssa.verify f;
  incr passed;
  check "a loop needs phis" (List.exists (fun b -> b.phis <> []) (walk f));

  let source = Driver.read_file "../examples/tour.wol" in
  List.iter Ssa.verify (in_ssa source true).funcs;
  incr passed;

  let f =
    List.nth
      (in_ssa "fun f (c : bool) : int = if c then 1 else 2\nval () = printInt (f (true))" false)
        .funcs 1
  in
  let dom = Ssa.dominance f in
  check "the entry dominates everything"
    (Hashtbl.fold (fun label _ acc -> acc && Ssa.dominates dom f.entry label) f.blocks true);
  let joins = List.filter (fun b -> List.length b.preds > 1) (walk f) in
  check "a diamond has a join" (joins <> []);
  check "whose immediate dominator is the entry"
    (List.for_all (fun b -> StrMap.find b.label dom.idom = f.entry) joins);

  List.iter
    (fun f ->
      List.iter
        (fun b ->
          List.iter
            (fun phi ->
              check "a phi names exactly its predecessors"
                (StrSet.equal (StrSet.of_list (phi_preds phi)) (StrSet.of_list b.preds)))
            b.phis)
        (walk f))
    (in_ssa loop_source false).funcs;

  let m = in_ssa loop_source false in
  Opt.optimise m;
  List.iter Ssa.verify m.funcs;
  incr passed;

  let m = in_ssa "val () = printInt (2 * 3 + 4)" false in
  Opt.optimise m;
  let values =
    List.concat_map
      (fun b -> List.filter_map (function Const c -> Some c.value | _ -> None) (instrs b))
      (walk (List.hd m.funcs))
  in
  check "constants fold" (values = [ 10L ]);

  let m =
    in_ssa
      "fun f (n : int) : int = let val unused = n * n in n + 1 end\n\
       val () = printInt (f (2))" false
  in
  Opt.optimise m;
  check "dead code goes"
    (not
       (List.exists
          (fun b -> List.exists (function Bin b -> b.op = "*" | _ -> false) (instrs b))
          (walk (List.nth m.funcs 1))));

  let m = in_ssa {|val () = if true then print ("a") else print ("b")|} false in
  Opt.optimise m;
  let calls =
    List.concat_map
      (fun b -> List.filter_map (function Call c -> Some c.callee | _ -> None) (instrs b))
      (walk (List.hd m.funcs))
  in
  check "unreachable blocks go" (calls = [ "wol_print" ]);

  let m = in_ssa loop_source true in
  Opt.optimise m;
  List.iter
    (fun f ->
      Ssa.split_critical_edges f;
      Ssa.verify f;
      List.iter
        (fun b ->
          if List.length (succs b) > 1 then
            List.iter
              (fun succ ->
                check "splitting leaves phis only after a jump" ((block f succ).phis = []))
              (succs b))
        (walk f))
    m.funcs

(* -- selection ---------------------------------------------------------------- *)

let one_function body =
  Printf.sprintf "fun f (a : int, b : int, c : int) : int = %s\nval () = printInt (f (1, 2, 3))"
    body

let forms source name =
  List.concat_map
    (fun f ->
      if f.fname <> name then []
      else
        List.concat_map
          (fun b -> List.filter_map (function Machine m -> Some m.form | _ -> None) (instrs b))
          (walk f))
    (selected source false).funcs

let chosen body = forms (one_function body) "f"
let counts list want = List.length (List.filter (fun x -> x = want) list)

let select_tests () =
  let got = chosen "a + b * c" in
  check "multiply-add is one instruction" (List.mem "madd" got && not (List.mem "mul" got));
  let got = chosen "a - b * c" in
  check "multiply-subtract is one instruction" (List.mem "msub" got && not (List.mem "mul" got));
  let got = chosen "a + b * 8" in
  check "a shifted operand beats a multiply-add"
    (counts got "adds" = 1 && (not (List.mem "madd" got)) && not (List.mem "lsli" got));
  check "a small constant is an immediate" (chosen "a + 5" = [ "addi" ]);
  check "and two of them" (chosen "(a + 5) - 7" = [ "addi"; "subi" ]);
  check "a large constant is not" (List.mem "const" (chosen "a + 100000"));
  let got = chosen "a * 8" in
  check "a multiply by a power of two is a shift"
    (List.mem "lsli" got && not (List.mem "mul" got));
  let source = "fun f (a : int) : int = if a < 3 then 1 else 2\nval () = printInt (f (1))" in
  let codes =
    List.concat_map
      (fun f ->
        List.filter_map
          (fun b -> match terminator b with Cbr c -> Some c.code | _ -> None)
          (walk f))
      (selected source false).funcs
  in
  check "a comparison read only by its branch sets the flags" (List.mem "lt" codes);
  check "and does not become a value" (not (List.mem "cset" (forms source "f")));
  check "a comparison read by something else is a value"
    (List.mem "cset" (forms {|fun f (a : int) : bool = a < 3
val () = print ("x")|} "f"));
  let got = chosen "(a + 1) * (b + 1)" in
  check "a constant read twice is still an immediate"
    (counts got "addi" = 2 && not (List.mem "const" got));
  check "a node read twice is computed once"
    (counts (chosen "let val t = a * b in t + t end") "mul" = 1);
  let source =
    "fun sum (a : int, b : int, c : int, d : int, e : int, f : int) : int =\n\
    \  a + b + c + d + e + f\n\
     val () = printInt (sum (1, 2, 3, 4, 5, 6))\n"
  in
  List.iter
    (fun f ->
      if f.fname = "sum" then
        check "a chain of additions is not deferred to its last line"
          (Liveness.pressure f (Liveness.analyse f) <= 8))
    (selected source false).funcs;
  List.iter Ssa.verify (selected (one_function "a + b * c + 8") true).funcs;
  incr passed;
  (* The graph counts its readers. *)
  List.iter
    (fun f ->
      if f.fname = "f" then
        let live = Liveness.analyse f in
        List.iter
          (fun b ->
            let g = Dag.build b (Liveness.live_out live b.label) in
            Array.iter
              (fun (n : Dag.node) ->
                let expected =
                  Array.fold_left
                    (fun acc (other : Dag.node) ->
                      acc + List.length (List.filter (fun o -> o = n.index) other.operands))
                    0 g.nodes
                in
                equal_int "the graph counts its readers" n.users expected)
              g.nodes)
          (walk f))
    (selected (one_function "a + b") false).funcs

(* -- the allocator ------------------------------------------------------------ *)

let busy_source =
  "\n\
   type point = { x : int, y : int }\n\n\
   fun busy (n : int) : int =\n\
  \  let\n\
  \    var a = n + 1\n\
  \    var b = n + 2\n\
  \    var c = n + 3\n\
  \    var d = n + 4\n\
  \    var total = 0\n\
  \  in\n\
  \    while a < n * 10 do (\n\
  \      total := total + a * b + c * d;\n\
  \      a := a + 1;\n\
  \      b := b + 2;\n\
  \      c := c + 3;\n\
  \      d := d + 4\n\
  \    );\n\
  \    total\n\
  \  end\n\n\
   fun caller (n : int) : int = busy (n) + busy (n + 1) + busy (n + 2)\n\n\
   val p = point { x = 1, y = 2 }\n\
   val () = printInt (caller (3) + p.x)\n"

let prepared source =
  let m = selected source true in
  Outofssa.destruct_module m;
  m

(* Every function with the colouring the allocator gave it. *)
let allocated machine source =
  let m = prepared source in
  let allocs = Allocator.allocate_module m machine in
  List.map (fun f -> (f, StrMap.find f.flabel allocs)) m.funcs

let moves_left (f, alloc) =
  List.fold_left
    (fun n b ->
      n
      + List.length
          (List.filter
             (function
               | Move m -> IntMap.find m.dst alloc.colours <> IntMap.find m.src alloc.colours
               | _ -> false)
             (instrs b)))
    0 (walk f)

let allocator_tests () =
  List.iter
    (fun (f, alloc) ->
      List.iter
        (fun b ->
          List.iter
            (fun instr ->
              List.iter
                (fun r -> check "every value gets a colour" (IntMap.mem r alloc.colours))
                (uses instr);
              Option.iter
                (fun d -> check "every definition too" (IntMap.mem d alloc.colours))
                (defs instr))
            (instrs b))
        (walk f))
    (allocated Registers.all busy_source);

  List.iter (fun (f, alloc) -> Allocator.verify alloc f) (allocated Registers.all busy_source);
  incr passed;

  (* Without the optimiser the copies survive to the allocator, and coalescing
     gives both ends of one copy the same register.  That is right, and it is
     what a verifier reading whole live sets would reject. *)
  let unoptimised =
    let m = in_ssa busy_source true in
    List.iter Ssa.split_critical_edges m.funcs;
    Select.select_module m;
    Outofssa.destruct_module m;
    let allocs = Allocator.allocate_module m Registers.all in
    List.map (fun f -> (f, StrMap.find f.flabel allocs)) m.funcs
  in
  List.iter (fun (f, alloc) -> Allocator.verify alloc f) unoptimised;
  incr passed;

  (* Both ends of a copy hold the same value, so one register for the two is
     right and the verifier has to say so. *)
  let copied = new_func "f" "f" 0 in
  let entry = add_block copied "entry" in
  let a = new_reg copied in
  let b = new_reg copied in
  emit entry (Const { dst = a; value = 1L });
  emit entry (Move { dst = b; src = a });
  emit entry (Call { dst = None; callee = "wol_print_int"; args = [ a ] });
  emit entry (Ret { value = Some b });
  let one_register =
    { unallocated with colours = IntMap.add a 9 (IntMap.add b 9 IntMap.empty) }
  in
  check "a coalesced copy is not a clash"
    (match Allocator.verify one_register copied with () -> true | exception _ -> false);

  (* And one colour for everything is a clash, so the case above did not simply
     stop the verifier saying anything. *)
  check "one colour for everything is rejected"
    (List.exists
       (fun (f, alloc) ->
         let flat = { alloc with colours = IntMap.map (fun _ -> 0) alloc.colours } in
         match Allocator.verify flat f with () -> false | exception _ -> true)
       (allocated Registers.all busy_source));

  List.iter
    (fun (f, alloc) ->
      IntSet.iter
        (fun r ->
          check "a value live across a call is callee-saved"
            (Registers.is_callee_saved (IntMap.find r alloc.colours)))
        (Liveness.across_calls f (Liveness.analyse f)))
    (allocated Registers.all busy_source);

  List.iter
    (fun (_, alloc) ->
      let used =
        IntMap.fold
          (fun _ colour acc ->
            if Registers.is_callee_saved colour then IntSet.add colour acc else acc)
          alloc.colours IntSet.empty
      in
      check "only the callee-saved it used are saved" (IntSet.elements used = alloc.saved))
    (allocated Registers.all busy_source);

  List.iter
    (fun size ->
      let machine = Registers.limited size in
      List.iter
        (fun (f, alloc) ->
          Allocator.verify alloc f;
          IntMap.iter
            (fun _ colour ->
              check "a smaller machine still works"
                (List.mem colour (Registers.anywhere machine)))
            alloc.colours)
        (allocated machine busy_source))
    [ 5; 6; 8; 12; 16; 26 ];
  incr passed;

  let small = allocated (Registers.limited 6) busy_source in
  check "a small machine spills"
    (List.exists (fun (_, alloc) -> not (IntMap.is_empty alloc.spilled)) small);
  List.iter
    (fun (f, alloc) ->
      IntMap.iter (fun _ slot -> check "into a slot it has" (slot < f.nslots)) alloc.spilled)
    small;

  let machine = Registers.limited 5 in
  List.iter
    (fun (f, _) ->
      check "pressure falls to what the machine has"
        (Liveness.pressure f (Liveness.analyse f) <= Registers.count machine))
    (allocated machine busy_source);

  let source =
    "fun ten (a : int, b : int, c : int, d : int, e : int,\n\
    \         f : int, g : int, h : int, i : int, j : int) : int = a + j\n\
     val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))\n"
  in
  (match Allocator.allocate_module (prepared source) (Registers.limited 8) with
  | exception Spill.Out_of_registers msg ->
      check "an impossible demand is reported" (contains msg "more registers")
  | _ -> check "an impossible demand is reported" false);

  List.iter
    (fun f -> List.iter (fun b -> check "leaving SSA removes every phi" (b.phis = [])) (walk f))
    (prepared busy_source).funcs;

  let m = prepared busy_source in
  let before =
    List.fold_left
      (fun n f ->
        List.fold_left
          (fun n b ->
            n + List.length (List.filter (function Move _ -> true | _ -> false) (instrs b)))
          n (walk f))
      0 m.funcs
  in
  check "leaving SSA makes copies" (before > 0);
  let allocs = Allocator.allocate_module m Registers.all in
  let left =
    List.fold_left (fun n f -> n + moves_left (f, StrMap.find f.flabel allocs)) 0 m.funcs
  in
  check
    (Printf.sprintf "and coalescing eats them (%d of %d survived)" left before)
    (left <= before / 10)

(* -- parallel copies ----------------------------------------------------------- *)

let perform steps registers =
  let state = Hashtbl.copy registers in
  List.iter
    (fun step ->
      match step with
      | Copies.Mov (dst, src) -> Hashtbl.replace state dst (Hashtbl.find state src)
      | Copies.Swap (a, b) ->
          let x = Hashtbl.find state a and y = Hashtbl.find state b in
          Hashtbl.replace state a y;
          Hashtbl.replace state b x)
    steps;
  state

let run_copy name moves borrowed =
  let registers = Hashtbl.create 32 in
  for r = 0 to 31 do
    Hashtbl.replace registers r (Printf.sprintf "v%d" r)
  done;
  let steps = Copies.sequentialize moves borrowed in
  let after = perform steps registers in
  List.iter
    (fun (dst, src) ->
      check
        (Printf.sprintf "%s: x%d should hold v%d" name dst src)
        (Hashtbl.find after dst = Hashtbl.find registers src))
    moves;
  steps

let is_swap = function Copies.Swap _ -> true | _ -> false

let copies_tests () =
  let steps = run_copy "no cycle" [ (1, 2); (3, 4); (5, 5) ] 9 in
  check "a copy with no cycle is just moves"
    ((not (List.exists is_swap steps)) && List.length steps = 2);
  ignore (run_copy "a chain" [ (1, 2); (2, 3); (3, 4) ] 9);
  let steps = run_copy "a cycle with a register to borrow" [ (1, 2); (2, 1) ] 9 in
  check "a cycle borrows a register when there is one"
    ((not (List.exists is_swap steps))
    && List.exists (function Copies.Mov (d, _) -> d = 9 | _ -> false) steps);
  let steps = run_copy "a cycle with nothing to borrow" [ (1, 2); (2, 1) ] (-1) in
  check "a cycle swaps when there is nothing to borrow"
    (List.length steps = 1 && List.for_all is_swap steps);
  let steps = run_copy "a longer cycle" [ (1, 2); (2, 3); (3, 1) ] (-1) in
  check "a longer cycle swaps its way round"
    (List.length steps = 2 && List.for_all is_swap steps);
  ignore (run_copy "two cycles, swapping" [ (1, 2); (2, 1); (3, 4); (4, 3) ] (-1));
  ignore (run_copy "two cycles, borrowing" [ (1, 2); (2, 1); (3, 4); (4, 3) ] 9)

(* -- the emitter --------------------------------------------------------------- *)

let asm source = Driver.compile_to_asm source { Driver.default with checks = false }

let occurrences haystack needle =
  let n = String.length needle in
  let count = ref 0 in
  for at = 0 to String.length haystack - n do
    if String.sub haystack at n = needle then incr count
  done;
  !count

let emit_tests () =
  let text = asm "fun f (a : int, b : int) : int = a mod b\nval () = printInt (f (7, 2))" in
  check "the remainder is a divide and an msub"
    (occurrences text "sdiv" = 1 && occurrences text "msub" = 1 && not (contains text "mul"));
  check "ordinary code keeps no register back"
    (not (contains (asm (Driver.read_file "../examples/tour.wol")) "x17"));
  check "x16 is allocatable"
    (contains (asm (Driver.read_file "programs/pressure.wol")) "x16");
  let text = asm "val a = array (4, 0)\nval () = printInt (a[2] + a[3])" in
  let loads =
    List.length
      (List.filter
         (fun line -> String.length line > 5 && String.sub line 0 5 = "\tldr ")
         (String.split_on_char '\n' text))
  in
  equal_int "an array element takes two instructions" loads 2

(* -- end to end ---------------------------------------------------------------- *)

let toolchain_ready () =
  match
    ignore (Driver.cross_cc ());
    ignore (Driver.emulator ())
  with
  | () -> true
  | exception Driver.Toolchain _ -> false

let configurations =
  [ ("default", Driver.default);
    ("no-opt", { Driver.default with optimise = false });
    ("no-checks", { Driver.default with checks = false });
    ("spilling", { Driver.default with max_regs = 12 });
    ("spilling-no-opt", { Driver.default with max_regs = 12; optimise = false }) ]

let wol_files dir =
  Array.to_list (Sys.readdir dir)
  |> List.filter (fun name -> Filename.check_suffix name ".wol")
  |> List.sort compare
  |> List.map (fun name -> Filename.concat dir name)

let run_program source opts =
  let done_ = Driver.run source opts in
  if done_.exit_code <> 0 then failwith ("exit " ^ string_of_int done_.exit_code ^ ": " ^ done_.stderr);
  done_.stdout

let program_tests () =
  List.iter
    (fun program ->
      let source = Driver.read_file program in
      let expected = Driver.read_file (Filename.remove_extension program ^ ".out") in
      List.iter
        (fun (name, opts) ->
          equal
            (Printf.sprintf "%s [%s]" (Filename.basename program) name)
            (run_program source opts) expected)
        configurations)
    (wol_files "programs");
  List.iter
    (fun example ->
      let source = Driver.read_file example in
      let baseline = run_program source Driver.default in
      check (Filename.basename example ^ " prints something") (baseline <> "");
      List.iter
        (fun (name, opts) ->
          equal
            (Printf.sprintf "%s [%s] agrees with the default" (Filename.basename example) name)
            (run_program source opts) baseline)
        (List.tl configurations))
    (wol_files "../examples");

  List.iter
    (fun (source, message) ->
      let done_ = Driver.run source Driver.default in
      check ("the check catches " ^ message)
        (done_.exit_code = 1 && contains done_.stderr message))
    [ ("val a = array (3, 0)\nval () = printInt (a[5])", "outside an array");
      ("type t = { x : int }\nval n : t = nil\nval () = printInt (n.x)", "field of nil");
      ("var z = 0\nval () = printInt (7 / z)", "division by zero") ];

  equal "a check can be turned off"
    (run_program "val a = array (3, 0)\nval () = printInt (a[1])\n"
       { Driver.default with checks = false })
    "0";

  let source =
    "\nvar line = \"\"\nvar c = getChar ()\n\
     val () = while c <> \"\" andalso c <> \"\\n\" do (line := line ^ c; c := getChar ())\n\
     val () = print (\"read: \" ^ line ^ \" (\" ^ intToString (size (line)) ^ \")\\n\")\n"
  in
  let done_ = Driver.run ~stdin_text:(Some "hello\n") source Driver.default in
  equal "standard input" done_.stdout "read: hello (5)\n";

  let done_ = Driver.run "val () = (print (\"bye\\n\"); exit (3))" Driver.default in
  check "exit code" (done_.exit_code = 3 && done_.stdout = "bye\n")

let oracle_tests () =
  let check_against name source expected opts =
    let done_ = Driver.run source opts in
    if done_.exit_code <> 0 then begin
      incr failed;
      Printf.printf "FAIL %s: exit %d\n%s\n" name done_.exit_code done_.stderr
    end
    else equal name done_.stdout expected
  in
  let oracle_configurations =
    [ ("default", Driver.default);
      ("no-opt", { Driver.default with optimise = false });
      ("no-checks", { Driver.default with checks = false });
      ("spilling", { Driver.default with max_regs = 10 }) ]
  in
  List.iter
    (fun seed ->
      let source, expected = Oracle.arithmetic seed 25 in
      List.iter
        (fun (name, opts) ->
          check_against (Printf.sprintf "oracle arithmetic seed %d [%s]" seed name) source
            expected opts)
        oracle_configurations;
      let source, expected = Oracle.imperative seed 8 in
      List.iter
        (fun (name, opts) ->
          check_against (Printf.sprintf "oracle arrays seed %d [%s]" seed name) source expected
            opts)
        oracle_configurations)
    [ 1; 2 ];

  (* Force the swap: the borrowed register is what usually hides that path. *)
  let source =
    "fun swap (a : int, b : int) : int =\n\
    \  if a > b then swap (b, a) else b * 10 + a\n\
     val () = (printInt (swap (1, 2)); print (\" \"); printInt (swap (7, 3)))\n"
  in
  equal "a cycle of copies, borrowing" (Driver.run source Driver.default).stdout "21 73";
  check "a cycle of copies writes eors when it may not borrow"
    (contains (Driver.compile_to_asm ~no_borrow:true source Driver.default) "eor x");
  equal "and still gets the answer right"
    (Driver.run ~no_borrow:true source Driver.default).stdout "21 73"

(* -- all of it ----------------------------------------------------------------- *)

let () =
  lexer_tests ();
  parser_tests ();
  typecheck_tests ();
  ssa_tests ();
  select_tests ();
  allocator_tests ();
  copies_tests ();
  emit_tests ();
  if toolchain_ready () then begin
    program_tests ();
    oracle_tests ()
  end
  else begin
    skipped := 1;
    print_endline "SKIP the end-to-end tests: no cross gcc or qemu-aarch64"
  end;
  Printf.printf "%d passed, %d failed%s\n" !passed !failed
    (if !skipped > 0 then ", end-to-end skipped" else "");
  if !failed > 0 then exit 1
