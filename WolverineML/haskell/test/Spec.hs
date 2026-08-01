{-# LANGUAGE DataKinds #-}
-- | Everything the compiler promises, in one run.
module Main (main) where

import Control.Monad (forM_, unless, when)
import Data.List (isInfixOf, isPrefixOf, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Set as Set
import System.Exit
import System.IO
import Check
import Oracle
import Wolv.Allocator (allocateModule)
import qualified Wolv.Allocator as Allocator
import Wolv.Ast
import qualified Wolv.Dag as Dag
import Wolv.Dag (ndIndex, ndOperands, ndUsers, nodes)
import Wolv.Diag
import Wolv.Driver
import Wolv.Emit (Borrowing (..))
import Wolv.Ir
import Wolv.Lexer (Tok (..), lexAll, tokAt, tokKind, tokText)
import Wolv.Liveness (acrossCalls, analyse, liveOut, pressure)
import Wolv.Lower (lower)
import qualified Wolv.Lower as Lower
import Wolv.Opt (optimise)
import Wolv.OutOfSsa (destructModule)
import Wolv.Parser (parse, parseExp)
import Wolv.Registers (Machine, anywhere, calleeSaved, count, limited, whole)
import Wolv.Select (selectModule)
import qualified Wolv.Ssa as Ssa
import Wolv.Typecheck (Checked (..), check)
import Wolv.Types (vsId)

main :: IO ()
main = do
  hSetEncoding stdout utf8
  h <- newHarness
  lexerTests h
  parserTests h
  typecheckTests h
  middleTests h
  allocatorTests h
  ready <- toolchainReady
  if ready then programTests h >> randomTests h else skipped h "no ARM toolchain"
  ok <- summary h
  unless ok (exitWith (ExitFailure 1))

-- -- the lexer -----------------------------------------------------------------

kinds :: String -> [Tok]
kinds source = either (const []) (map tokKind) (lexAll source)

lexerTests :: Harness -> IO ()
lexerTests h = do
  test h "keywords are not identifiers" $ do
    equal h "let val" [LET, VAL, EOF] (kinds "let val")
    equal h "letter" [IDENT, EOF] (kinds "letter")

  test h "the longest punctuation wins" $
    equal h "punctuation" [ASSIGN, COLON, LE, LT_, NE, GE, EOF] (kinds ":= : <= < <> >=")

  test h "comments nest" $
    equal h "nested" [INT, EOF] (kinds "(* a (* b *) c *) 1")

  test h "an unterminated comment is an error" $
    refuses h LexKind "unterminated comment" (lexAll "(* forever")

  test h "string escapes" $
    equal h "escapes" "a\nb\t\"\\A" (text "\"a\\nb\\t\\\"\\\\\\065\"")

  -- Source text contributes its UTF-8; `\ddd` names one byte of it.
  test h "a string is bytes" $ do
    equal h "the same bytes" (text "\"\26085\"") (text "\"\\230\\151\\165\"")
    equal h "three characters, nine bytes" 9 (length (text "\"\26085\26412\35486\""))

  test h "a numeric escape is three digits" $
    refuses h LexKind "three digits" (lexAll "\"\\65\"")

  test h "a string may not span lines" $
    refuses h LexKind "may not span lines" (lexAll "\"one\ntwo\"")

  test h "spans count from one" $ case lexAll "val\n  x" of
    Right (a : b : _) -> do
      equal h "first" (1, 1) (spanLine (tokAt a), spanCol (tokAt a))
      equal h "second" (2, 3) (spanLine (tokAt b), spanCol (tokAt b))
    _ -> expect h "two tokens" False

  test h "a number may not run into a name" $
    refuses h LexKind "is not a number" (lexAll "12ab")

  test h "a stray character is an error" $
    refuses h LexKind "stray character" (lexAll "a ? b")
  where
    text source = case lexAll source of
      Right (t : _) -> tokText t
      _ -> ""

refuses :: Harness -> Kind -> String -> Either WolvError a -> IO ()
refuses h kind message answer = case answer of
  Left e | errKind e == kind && message `isInfixOf` errMessage e -> pure ()
  Left e -> expect h ("wanted `" ++ message ++ "`, got `" ++ errMessage e ++ "`") False
  Right _ -> expect h ("wanted `" ++ message ++ "`, but it was accepted") False

-- -- the parser ----------------------------------------------------------------

-- | A parenthesised sketch of the tree, so precedence is easy to assert.
shape :: Exp 'Parsed -> String
shape e = case eNode e of
  EInt value -> show value
  EStr value -> "\"" ++ value ++ "\""
  EBool value -> if value then "true" else "false"
  ENil -> "nil"
  EUnit -> "()"
  EPlace p -> place p
  ENeg operand -> "(~ " ++ shape operand ++ ")"
  EBin op lhs rhs -> "(" ++ op ++ " " ++ shape lhs ++ " " ++ shape rhs ++ ")"
  ELogic op lhs rhs -> "(" ++ op ++ " " ++ shape lhs ++ " " ++ shape rhs ++ ")"
  EAssign target value -> "(:= " ++ place target ++ " " ++ shape value ++ ")"
  EIf cond then' els ->
    "(if " ++ shape cond ++ " " ++ shape then' ++ maybe "" ((" " ++) . shape) els ++ ")"
  EWhile cond body -> "(while " ++ shape cond ++ " " ++ shape body ++ ")"
  EFor name lo hi body _ ->
    "(for " ++ name ++ " " ++ shape lo ++ " " ++ shape hi ++ " " ++ shape body ++ ")"
  EBreak -> "break"
  ESeq items -> "(seq " ++ unwords (map shape items) ++ ")"
  ECall name args _ -> "(" ++ name ++ " " ++ unwords (map shape args) ++ ")"
  ERecord tyname fields ->
    "(record " ++ tyname ++ " " ++ unwords [fiName f ++ "=" ++ shape (fiValue f) | f <- fields] ++ ")"
  ELet decls body -> "(let " ++ show (length decls) ++ " " ++ shape body ++ ")"

place :: Place 'Parsed -> String
place p = case plNode p of
  PVar name _ -> name
  PIndex array index -> "(index " ++ shape array ++ " " ++ shape index ++ ")"
  PField record name _ -> "(field " ++ shape record ++ " " ++ name ++ ")"

parserTests :: Harness -> IO ()
parserTests h = do
  test h "arithmetic precedence" $ do
    sketch "(+ 1 (* 2 3))" "1 + 2 * 3"
    sketch "(+ (* 1 2) 3)" "1 * 2 + 3"
    sketch "(- (- 1 2) 3)" "1 - 2 - 3"
    sketch "(= (+ 1 2) 3)" "1 + 2 = 3"

  test h "logic binds looser than comparison" $ do
    sketch "(andalso (< a b) (> c d))" "a < b andalso c > d"
    sketch "(orelse a (andalso b c))" "a orelse b andalso c"

  test h "assignment is right-associative and loosest" $
    sketch "(:= x (+ y 1))" "x := y + 1"

  test h "a branch swallows what follows it" $ do
    sketch "(if c (:= x 1) (:= x 2))" "if c then x := 1 else x := 2"
    sketch "(if c a (+ b 1))" "if c then a else b + 1"

  test h "postfix chains" $ do
    sketch "(index (field (index a i) f) j)" "a[i].f[j]"
    sketch "(field (f 1 2) g)" "f(1, 2).g"

  test h "sequences and unit" $ do
    sketch "()" "()"
    sketch "(seq a b c)" "(a; b; c)"
    sketch "a" "(a)"

  test h "negation is a tilde" $ do
    sketch "(+ (~ x) 1)" "~x + 1"
    refuses h ParseKind "negation is written" (parseExp "-x")

  test h "a record literal is not a call" $ do
    sketch "(record point x=1 y=2)" "point { x = 1, y = 2 }"
    sketch "(point 1 2)" "point (1, 2)"

  test h "let with declarations" $
    sketch "(let 2 (+ x y))" "let val x = 1 var y = 2 in x + y end"

  test h "a program is declarations" $ case parse "type t = int\nval x = 1\nfun f (a : int) : int = a\n" of
    Right [DType _ _, DVal {}, DFun _ _] -> pure ()
    _ -> expect h "three declarations" False

  test h "mutual recursion is one declaration" $
    case parse "fun f () : int = g ()\nand g () : int = 1\n" of
      Right (DFun _ binds : _) -> equal h "names" ["f", "g"] (map fbName binds)
      _ -> expect h "one declaration" False

  test h "only a place can be assigned" $
    refuses h ParseKind "not assignable" (parseExp "1 + 2 := 3")

  test h "errors name what was expected" $
    refuses h ParseKind "expected `then`" (parseExp "if a do b")
  where
    sketch want source = case parseExp source of
      Right e -> equal h source want (shape e)
      Left e -> expect h (source ++ ": " ++ errMessage e) False

-- -- the checker ---------------------------------------------------------------

typecheckTests :: Harness -> IO ()
typecheckTests h = do
  test h "arithmetic is on ints" $ do
    accepts "val x = 1 + 2"
    rejects "expected `int`, found `string`" "val x = 1 + \"a\""
    rejects "expected `int`, found `bool`" "val x = true + 1"

  test h "concatenation is on strings" $ do
    accepts "val s = \"a\" ^ \"b\""
    rejects "expected `string`, found `int`" "val s = \"a\" ^ 1"

  test h "comparison gives bool" $ do
    accepts "val b = 1 < 2 andalso 3 >= 4"
    rejects "expected `string`, found `int`" "val b = \"a\" < 1"
    rejects "compares int or string" "val b = true < false"

  test h "equality needs one type" $ do
    accepts "val b = 1 = 2"
    accepts "val b = \"a\" <> \"b\""
    rejects "compares `int` with `bool`" "val b = 1 = true"

  test h "conditions are bool" $ do
    accepts "val x = if true then 1 else 2"
    rejects "expected `bool`, found `int`" "val x = if 1 then 1 else 2"
    rejects "the branches differ" "val x = if true then 1 else \"a\""
    rejects "in an `if` with no `else`" "val () = if true then 1"

  test h "a val cannot be assigned" $ do
    accepts "var x = 1 val () = x := 2"
    rejects "is a `val`" "val x = 1 val () = x := 2"

  test h "functions check their arguments" $ do
    accepts "fun f (a : int) : int = a\nval x = f (1)"
    rejects "takes 1 argument" "fun f (a : int) : int = a\nval x = f (1, 2)"
    rejects "expected `int`" "fun f (a : int) : int = a\nval x = f (\"s\")"

  test h "a fun without a result is a procedure" $ do
    accepts "fun f () = print (\"x\")\nval () = f ()"
    rejects "expected `unit`, found `int`" "fun f () = 1"

  test h "functions are not values" $
    rejects "functions are not values" "fun f () : int = 1\nval x = f"

  test h "records are nominal" $ do
    accepts "type p = { x : int }\nval a = p { x = 1 }\nval b = a.x"
    rejects
      "expected `p`, found `q`"
      "type p = { x : int } and q = { x : int }\nfun f (r : p) : int = r.x\nval x = f (q { x = 1 })"
    rejects "has no field `y`" "type p = { x : int }\nval a = p { y = 1 }"
    rejects "field `y` is missing" "type p = { x : int, y : int }\nval a = p { x = 1 }"

  test h "nil belongs to every record type" $ do
    accepts "type p = { x : int }\nval a : p = nil\nval b = a = nil"
    rejects "needs a type annotation" "val a = nil"
    rejects "compares" "type p = { x : int }\nval a : p = nil\nval b = a = 1"

  test h "arrays know their element" $ do
    accepts "val a = array (3, 0)\nval x = a[0] + 1"
    accepts "type ints = int array\nval a : ints = array (3, 0)"
    rejects "expected `string`" "val a = array (3, 0)\nval x = a[0] ^ \"s\""
    rejects "as an array index" "val a = array (3, 0)\nval x = a[true]"
    rejects "`length` wants an array" "val x = length (1)"

  test h "break is inside a loop" $ do
    accepts "val () = while true do break"
    accepts "val () = for i = 0 to 3 do break"
    rejects "outside any loop" "val () = break"
    rejects "outside any loop" "val () = while true do let fun f () = break in f () end"

  test h "escape analysis marks what a nested function reads" $ do
    let source =
          "fun outer () : int =\n\
          \  let var kept = 1\n\
          \      val plain = 2\n\
          \      fun inner () : int = kept\n\
          \  in inner () + plain end\n"
    case parse source >>= check of
      Right (Checked (DFun _ (b : _) : _) escapes) -> case eNode (fbBody b) of
        ELet (kept : plain : _) _ -> do
          expect h "kept escapes" (escaped escapes kept)
          expect h "plain does not" (not (escaped escapes plain))
        _ -> expect h "a let with two declarations" False
      _ -> expect h "one function" False

  test h "a parameter escapes too" $ do
    let source =
          "fun outer (n : int) : int =\n\
          \  let fun inner () : int = n in inner () end\n"
    case parse source >>= check of
      Right (Checked (DFun _ (b : _) : _) escapes) -> case fbParams b of
        (p : _) -> expect h "n escapes" (Set.member (vsId (pSym p)) escapes)
        _ -> expect h "one parameter" False
      _ -> expect h "one function" False

  test h "recursive types" $ do
    accepts
      "type list = { head : int, tail : list }\n\
      \fun sum (l : list) : int = if l = nil then 0 else l.head + sum (l.tail)\n"
    accepts "type a = b array and b = { next : a }"

  test h "unbound names" $ do
    rejects "`y` is not bound" "val x = y"
    rejects "`t` is not a type" "val x : t = 1"
    rejects "`f` is not bound" "val x = f ()"
  where
    accepts source = case parse source >>= check of
      Right _ -> pure ()
      Left e -> expect h (source ++ ": " ++ errMessage e) False
    rejects message source = refuses h TypeKind message (parse source >>= check)
    escaped escapes d = maybe False ((`Set.member` escapes) . vsId . bSym) (dBound d)

-- -- the middle ----------------------------------------------------------------

loopSource :: String
loopSource =
  "fun count (n : int) : int =\n\
  \  let var i = 0\n\
  \      var total = 0\n\
  \  in\n\
  \    while i < n do (total := total + i; i := i + 1);\n\
  \    total\n\
  \  end\n\
  \val () = printInt (count (10))\n"

built :: Bool -> String -> Module
built checks source = case parse source >>= check of
  Right c -> lower c (Lower.Options checks)
  Left e -> error (errMessage e)

inSsa :: Bool -> String -> Module
inSsa checks = Ssa.constructModule . built checks

selected :: Bool -> String -> Module
selected checks source =
  let m = optimise (inSsa checks source)
   in selectModule m {modFuncs = map Ssa.splitCriticalEdges (modFuncs m)}

funcNamed :: Module -> String -> Func
funcNamed m name = head [f | f <- modFuncs m, fnName f == name]

instructions :: Func -> [Instr]
instructions f = [i | b <- walk f, i <- blInstrs b]

function :: String -> String
function body =
  "fun f (a : int, b : int, c : int) : int = " ++ body ++ "\nval () = printInt (f (1, 2, 3))"

-- | The instruction forms chosen inside one function, the caller's aside, named
-- the way a dump names them.
formsOf :: String -> [String]
formsOf source = mapMaybe chosen (instructions (funcNamed (selected False source) "f"))
  where
    chosen i = case i of
      Machine {mForm = form} -> Just (takeWhile (/= ' ') (showForm form))
      MConst _ _ -> Just "const"
      MAdr _ _ -> Just "adr"
      MLoad {} -> Just "ldr"
      MStore {} -> Just "str"
      _ -> Nothing

middleTests :: Harness -> IO ()
middleTests h = do
  test h "lowering writes a variable more than once" $ do
    let f = modFuncs (built False loopSource) !! 1
        written = Map.fromListWith (+) [(d, 1 :: Int) | i <- instructions f, Just d <- [defs i]]
    expect h "one register written twice" (any (> 1) (Map.elems written))
    expect h "no phis" (all (null . blPhis) (walk f))

  test h "construction gives one definition and phis" $ do
    let f = modFuncs (inSsa False loopSource) !! 1
    verified h "count" (Ssa.verify f)
    expect h "a loop needs phis" (any (not . null . blPhis) (walk f))

  test h "every function of the tour verifies" $ do
    source <- readFile "examples/tour.wol"
    mapM_ (verified h "tour" . Ssa.verify) (modFuncs (inSsa True source))

  test h "the dominators of a diamond" $ do
    let f = modFuncs (inSsa False "fun f (c : bool) : int = if c then 1 else 2\nval () = printInt (f (true))") !! 1
        dom = Ssa.dominance f
        joins = [b | b <- walk f, length (blPreds b) > 1]
    expect h "the entry dominates everything" (all (Ssa.dominates dom (fnEntry f)) (fnOrder f))
    expect h "a diamond has a join" (not (null joins))
    forM_ joins $ \join ->
      equal h "the join's dominator" (Just (fnEntry f)) (Map.lookup (blLabel join) (Ssa.domIdom dom))

  test h "a phi names exactly its predecessors" $
    forM_ (modFuncs (inSsa False loopSource)) $ \f ->
      forM_ (walk f) $ \b ->
        forM_ (blPhis b) $ \p ->
          equal h ("phi in " ++ blLabel b) (sort (blPreds b)) (sort (map fst (phiArgs p)))

  test h "constants fold" $ do
    let m = optimise (inSsa False "val () = printInt (2 * 3 + 4)")
    equal h "one ten" [10] [v | Const _ v <- instructions (head (modFuncs m))]

  test h "dead code goes" $ do
    let m = optimise (inSsa False "fun f (n : int) : int = let val unused = n * n in n + 1 end\nval () = printInt (f (2))")
    expect h "no multiply" (null [() | Bin _ Mul _ _ <- instructions (modFuncs m !! 1)])

  test h "unreachable blocks go" $ do
    let m = optimise (inSsa False "val () = if true then print (\"a\") else print (\"b\")")
    equal h "one call" ["wol_print"] [callee | Call _ callee _ <- instructions (head (modFuncs m))]

  test h "splitting leaves phis only after a jump" $ do
    let m = optimise (inSsa True loopSource)
    forM_ (map Ssa.splitCriticalEdges (modFuncs m)) $ \f -> do
      verified h "split" (Ssa.verify f)
      forM_ (walk f) $ \b ->
        when (length (succs b) > 1) $
          forM_ (succs b) $ \s ->
            expect h "no phi after a branch" (null (blPhis (blockOf f s)))

  test h "multiply-add is one instruction" $ do
    let chosen = formsOf (function "a + b * c")
    includes' "madd" chosen
    excludes' "mul" chosen

  test h "multiply-subtract is one instruction" $ do
    let chosen = formsOf (function "a - b * c")
    includes' "msub" chosen
    excludes' "mul" chosen

  -- `a + b * 8` is one instruction with a shift and two as a multiply-add.
  test h "a shifted operand beats a multiply-add" $ do
    let chosen = formsOf (function "a + b * 8")
    equal h "one adds" 1 (length (filter (== "adds") chosen))
    excludes' "madd" chosen
    excludes' "lsli" chosen

  test h "a small constant is an immediate" $ do
    equal h "a + 5" ["addi"] (formsOf (function "a + 5"))
    equal h "(a + 5) - 7" ["addi", "subi"] (formsOf (function "(a + 5) - 7"))

  test h "a large constant is not" $
    includes' "const" (formsOf (function "a + 100000"))

  test h "a multiply by a power of two is a shift" $ do
    let chosen = formsOf (function "a * 8")
    includes' "lsli" chosen
    excludes' "mul" chosen

  test h "a comparison read only by its branch sets the flags" $ do
    let source = "fun f (a : int) : int = if a < 3 then 1 else 2\nval () = printInt (f (1))"
        codes = [showCond code | f <- modFuncs (selected False source), b <- walk f, CBr _ _ _ (Just code) <- [terminator b]]
    includes' "lt" codes
    excludes' "cset" (formsOf source)

  test h "a comparison read by something else is a value" $
    includes' "cset" (formsOf "fun f (a : int) : bool = a < 3\nval () = print (\"x\")")

  test h "an array element takes two instructions" $ do
    let text = asm "val a = array (4, 0)\nval () = printInt (a[2] + a[3])" (defaultOptions {optChecks = False})
    equal h "two loads" 2 (length (filter ("\tldr " `isPrefixOf`) (lines text)))

  -- It costs nothing to repeat, so two readers may both take it.
  test h "a constant read twice is still an immediate" $ do
    let chosen = formsOf (function "(a + 1) * (b + 1)")
    equal h "two addi" 2 (length (filter (== "addi") chosen))
    excludes' "const" chosen

  -- Folding a whole spine would keep every term live until the end.
  test h "a chain of additions is not deferred to its last line" $ do
    let m =
          selected
            False
            "fun sum (a : int, b : int, c : int, d : int, e : int, f : int) : int =\n\
            \  a + b + c + d + e + f\n\
            \val () = printInt (sum (1, 2, 3, 4, 5, 6))\n"
        f = funcNamed m "sum"
    expect h "pressure stays low" (pressure f (analyse f) <= 8)

  test h "a node read twice is computed once" $
    equal h "one multiply" 1 (length (filter (== "mul") (formsOf (function "let val t = a * b in t + t end"))))

  test h "the graph counts its readers" $ do
    let f = funcNamed (selected False (function "a + b")) "f"
        live = analyse f
    forM_ (walk f) $ \b -> do
      let g = Dag.build b (liveOutOf live (blLabel b))
      forM_ (nodes g) $ \n ->
        equal
          h
          "users"
          (length [() | other <- nodes g, o <- ndOperands other, o == Just (ndIndex n)])
          (ndUsers n)

  test h "selection keeps it in SSA" $
    mapM_ (verified h "selected" . Ssa.verify) (modFuncs (selected True (function "a + b * c + 8")))
  where
    includes' needle xs = expect h ("no `" ++ needle ++ "`: " ++ show xs) (needle `elem` xs)
    excludes' needle xs = expect h ("`" ++ needle ++ "` is there: " ++ show xs) (needle `notElem` xs)
    liveOutOf = liveOut

verified :: Harness -> String -> Either String () -> IO ()
verified h what answer = case answer of
  Right () -> pure ()
  Left message -> expect h (what ++ ": " ++ message) False

asm :: String -> Options -> String
asm source opts = either (error . showFailure "?") id (compileToAsm source opts)

-- -- the allocator --------------------------------------------------------------

busySource :: String
busySource =
  "type point = { x : int, y : int }\n\
  \\n\
  \fun busy (n : int) : int =\n\
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
  \  end\n\
  \\n\
  \fun caller (n : int) : int = busy (n) + busy (n + 1) + busy (n + 2)\n\
  \\n\
  \val p = point { x = 1, y = 2 }\n\
  \val () = printInt (caller (3) + p.x)\n"

-- | The pipeline up to the point where the allocator takes over.
prepared :: String -> Module
prepared source = destructModule (selected True source)

allocated :: Machine -> String -> (Module, Map.Map String Allocation)
allocated machine source =
  either error id (allocateModule machine (prepared source))

allocatorTests :: Harness -> IO ()
allocatorTests h = do
  let (m, allocs) = allocated whole busySource
      allocOf f = fromMaybe unallocated (Map.lookup (fnLabel f) allocs)

  test h "every value gets a colour" $
    forM_ (modFuncs m) $ \f -> do
      let colours = alColours (allocOf f)
      forM_ (instructions f) $ \i -> do
        forM_ (uses i) $ \r -> expect h ("%" ++ show r ++ " uncoloured") (Map.member r colours)
        forM_ (defs i) $ \d -> expect h ("%" ++ show (unReg d) ++ " uncoloured") (Map.member d colours)

  test h "values live together differ" $
    forM_ (modFuncs m) $ \f -> verified h (fnName f) (Allocator.verify f (allocOf f))

  -- One colour for everything is wrong, and has to be said so.
  test h "the verifier rejects a real clash" $
    forM_ (modFuncs m) $ \f -> do
      let alloc = allocOf f
          colours = alColours alloc
      when (Set.size (Set.fromList (Map.elems colours)) > 1) $
        case Allocator.verify f alloc {alColours = Map.map (const 0) colours} of
          Left message -> includes h "the complaint" "at once" message
          Right () -> expect h "one colour for everything was accepted" False

  -- Both ends of a copy are live after it, and hold the same value.
  test h "the verifier accepts a coalesced copy" $ do
    let f0 = addBlock "entry" (newFunc "f" "f" 0)
        entry = blockOf f0 "entry"
        f =
          recomputePreds
            ( setBlock
              entry
                { blInstrs =
                    [ Const (Reg 0) 1,
                      Move (Reg 1) (Reg 0),
                      Call Nothing "wol_print_int" [Reg 0],
                      Ret (Just (Reg 1))
                    ]
                }
              f0
          )
              { fnRegs = 2
              }
    verified h "coalesced" (Allocator.verify f (Allocation (Map.fromList [(Reg 0, 9), (Reg 1, 9)]) [] Map.empty))

  test h "a value live across a call is callee-saved" $
    forM_ (modFuncs m) $ \f -> do
      let colours = alColours (allocOf f)
      forM_ (Set.toList (acrossCalls f (analyse f))) $ \r ->
        expect h ("%" ++ show (unReg r) ++ " is caller-saved") (Map.lookup r colours `elem` map Just calleeSaved)

  test h "only the callee-saved it used are saved" $
    forM_ (modFuncs m) $ \f -> do
      let alloc = allocOf f
      equal
        h
        (fnName f)
        (Set.toAscList (Set.intersection (Set.fromList (Map.elems (alColours alloc))) (Set.fromList calleeSaved)))
        (alSaved alloc)

  test h "a smaller machine still works" $
    forM_ [5, 6, 8, 12, 16, 26] $ \n -> do
      let machine = limited n
          (small, smallAllocs) = allocated machine busySource
      forM_ (modFuncs small) $ \f -> do
        let alloc = fromMaybe unallocated (Map.lookup (fnLabel f) smallAllocs)
        verified h ("limited " ++ show n) (Allocator.verify f alloc)
        forM_ (Map.elems (alColours alloc)) $ \colour ->
          expect h "a colour off the machine" (colour `elem` anywhere machine)

  test h "a small machine spills" $ do
    let (small, smallAllocs) = allocated (limited 6) busySource
    expect h "nothing spilled" (any (not . Map.null . alSpilled) (Map.elems smallAllocs))
    forM_ (modFuncs small) $ \f -> do
      let alloc = fromMaybe unallocated (Map.lookup (fnLabel f) smallAllocs)
      forM_ (Map.elems (alSpilled alloc)) $ \slot ->
        expect h "a slot off the frame" (slot < fnSlots f)

  test h "pressure falls to what the machine has" $ do
    let machine = limited 5
        (small, _) = allocated machine busySource
    forM_ (modFuncs small) $ \f ->
      expect h (fnName f ++ " is still over") (pressure f (analyse f) <= count machine)

  test h "an impossible demand is reported" $ do
    let source =
          "fun ten (a : int, b : int, c : int, d : int, e : int,\n\
          \         f : int, g : int, h : int, i : int, j : int) : int = a + j\n\
          \val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))\n"
    case allocateModule (limited 8) (prepared source) of
      Left message -> includes h "the complaint" "more registers" message
      Right _ -> expect h "an impossible demand was met" False

  test h "leaving SSA removes every phi" $
    forM_ (modFuncs (prepared busySource)) $ \f ->
      expect h (fnName f ++ " still has phis") (all (null . blPhis) (walk f))

  test h "leaving SSA makes copies and coalescing eats them" $ do
    let before = length [() | f <- modFuncs (prepared busySource), Move _ _ <- instructions f]
        left =
          length
            [ ()
              | f <- modFuncs m,
                Move d s <- instructions f,
                Map.lookup d (alColours (allocOf f)) /= Map.lookup s (alColours (allocOf f))
            ]
    expect h "leaving SSA should have made copies" (before > 0)
    expect h (show left ++ " of " ++ show before ++ " copies survived") (left <= before `div` 10)

  test h "the remainder is a divide and an msub" $ do
    let text = asm "fun f (a : int, b : int) : int = a mod b\nval () = printInt (f (7, 2))" defaultOptions
    equal h "one sdiv" 1 (occurrences "sdiv" text)
    equal h "one msub" 1 (occurrences "msub" text)
    excludes h "a plain multiply" "mul" text

  -- x17 is only for an address the emitter cannot reach any other way.
  test h "ordinary code keeps no register back" $ do
    source <- readFile "examples/tour.wol"
    excludes h "the scratch register" "x17" (asm source defaultOptions)

  -- It used to be held back for the emitter; a busy function should take it.
  test h "x16 is allocatable" $ do
    source <- readFile "test/programs/pressure.wol"
    includes h "x16" "x16" (asm source defaultOptions)

occurrences :: String -> String -> Int
occurrences needle haystack =
  length [() | i <- [0 .. length haystack - length needle], needle `isPrefixOf` drop i haystack]

-- -- end to end -----------------------------------------------------------------

configurations :: [(String, Options)]
configurations =
  [ ("default", defaultOptions),
    ("no-opt", defaultOptions {optOptimise = False}),
    ("no-checks", defaultOptions {optChecks = False}),
    ("spilling", defaultOptions {optMaxRegs = Just 12}),
    ("spilling-no-opt", defaultOptions {optMaxRegs = Just 12, optOptimise = False})
  ]

programs :: [String]
programs = ["basics", "control", "edge", "nested", "pressure", "records", "swap"]

examples :: [String]
examples = ["queens", "sort", "tour"]

ran :: Harness -> String -> String -> Options -> String -> IO String
ran h what source opts input = do
  done <- run source opts input
  case done of
    Left failure -> do
      expect h (what ++ ": " ++ showFailure "?" failure) False
      pure ""
    Right outcome -> do
      equal h (what ++ " exit code") 0 (ouCode outcome)
      pure (ouStdout outcome)

programTests :: Harness -> IO ()
programTests h = do
  test h "every option gives the same answer; only the code differs" $
    forM_ programs $ \name -> do
      source <- readFile ("test/programs/" ++ name ++ ".wol")
      want <- readFile ("test/programs/" ++ name ++ ".out")
      forM_ configurations $ \(what, opts) -> do
        got <- ran h (name ++ " [" ++ what ++ "]") source opts ""
        equal h (name ++ " [" ++ what ++ "]") want got

  -- No expected output on file: what matters is that the stages agree.
  test h "the examples agree with themselves" $
    forM_ examples $ \name -> do
      source <- readFile ("examples/" ++ name ++ ".wol")
      baseline <- ran h name source defaultOptions ""
      expect h (name ++ " printed nothing") (not (null baseline))
      forM_ [c | c@(what, _) <- configurations, what /= "default", what /= "no-checks"] $ \(what, opts) -> do
        got <- ran h (name ++ " [" ++ what ++ "]") source opts ""
        equal h (name ++ " [" ++ what ++ "]") baseline got

  test h "the checks catch what they are for" $
    forM_
      [ ("val a = array (3, 0)\nval () = printInt (a[5])", "outside an array"),
        ("type t = { x : int }\nval n : t = nil\nval () = printInt (n.x)", "field of nil"),
        ("var z = 0\nval () = printInt (7 / z)", "division by zero")
      ]
      $ \(source, message) -> do
        done <- run source defaultOptions ""
        case done of
          Right outcome -> do
            equal h message 1 (ouCode outcome)
            includes h message message (ouStderr outcome)
          Left failure -> expect h (showFailure "?" failure) False

  test h "a check can be turned off" $ do
    got <- ran h "no checks" "val a = array (3, 0)\nval () = printInt (a[1])\n" (defaultOptions {optChecks = False}) ""
    equal h "prints zero" "0" got

  test h "standard input" $ do
    let source =
          "var line = \"\"\n\
          \var c = getChar ()\n\
          \val () = while c <> \"\" andalso c <> \"\\n\" do (line := line ^ c; c := getChar ())\n\
          \val () = print (\"read: \" ^ line ^ \" (\" ^ intToString (size (line)) ^ \")\\n\")\n"
    got <- ran h "stdin" source defaultOptions "hello\n"
    equal h "read it back" "read: hello (5)\n" got

  test h "the exit code is the program's" $ do
    done <- run "val () = (print (\"bye\\n\"); exit (3))" defaultOptions ""
    case done of
      Right outcome -> do
        equal h "code" 3 (ouCode outcome)
        equal h "output" "bye\n" (ouStdout outcome)
      Left failure -> expect h (showFailure "?" failure) False

-- -- the oracle -----------------------------------------------------------------

randomTests :: Harness -> IO ()
randomTests h = do
  test h "arithmetic" $
    forM_ [(seed, c) | seed <- [1, 2], c <- take 3 configurations] $ \(seed, (what, opts)) -> do
      let (source, expected) = arithmetic seed 25
      agrees ("arithmetic " ++ show seed ++ " [" ++ what ++ "]") source expected opts

  test h "arrays, loops and branches" $
    forM_ [(seed, c) | seed <- [1, 2], c <- take 3 configurations] $ \(seed, (what, opts)) -> do
      let (source, expected) = imperative seed 8
      agrees ("imperative " ++ show seed ++ " [" ++ what ++ "]") source expected opts

  -- Force the swap: the borrowed register is what usually hides this path.  The
  -- recursive call swaps its two arguments, so the copies into `x0` and `x1` are
  -- a cycle that has to be untangled somehow.
  test h "a cycle of copies can be done without a scratch register" $ do
    let source =
          "fun swap (a : int, b : int) : int =\n\
          \  if a > b then swap (b, a) else b * 10 + a\n\
          \val () = (printInt (swap (1, 2)); print (\" \"); printInt (swap (7, 3)))\n"
        swapping = defaultOptions {optBorrowing = MustSwap}
    borrowed <- ran h "borrowing" source defaultOptions ""
    equal h "borrowing" "21 73" borrowed
    includes h "no swap was written" "eor x" (asm source swapping)
    swapped <- ran h "swapping" source swapping ""
    equal h "swapping" "21 73" swapped
  where
    -- The first line that differs is the useful part of the answer.
    agrees what source expected opts = do
      got <- ran h what source opts ""
      forM_ (zip3 [0 :: Int ..] (lines got) (lines expected)) $ \(i, g, w) ->
        equal h (what ++ ", line " ++ show i) w g
      equal h (what ++ ", lines") (length (lines expected)) (length (lines got))
