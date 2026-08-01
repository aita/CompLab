-- | Instruction selection: cover the DAG with ARM instructions.
--
-- Every node that has to become a register of its own is tiled, largest tile
-- first, pulling its foldable operands into the tile as it goes.  The tiles are
-- the things ARM can do in one instruction that the IR needs several nodes to
-- say:
--
-- >     a + b * c            madd
-- >     a - b * c            msub
-- >     a + (b << k)         add with a shifted operand
-- >     a + 4095             add with an immediate
-- >     a * 8                lsl
-- >     [a + 24]             a load with the addition as its displacement
-- >     a < b, then branch   cmp, and a branch on the flags
--
-- What comes out is still the same CFG, and still in SSA — a tile defines one
-- new register — so liveness, the allocator and the verifier carry on as before.
-- What has gone is the guesswork the emitter used to do with its peepholes: an
-- instruction is now chosen where the whole expression is visible, rather than
-- by looking at the line before.
module Wolv.Select (selectModule, select, graphs, immediate) where

import Data.List (foldl')
import Control.Monad.State
import Data.Bits (popCount, testBit)
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as Set
import Wolv.Dag
import Wolv.Ir
import Wolv.Liveness
import Wolv.Mach (condition)

-- | What @add@, @sub@ and @cmp@ take as an immediate operand.
immediate :: Int64
immediate = 4095

logical :: String -> String
logical op = case op of "and" -> "and"; "or" -> "orr"; "xor" -> "eor"; _ -> error "not logical"

shifts :: String -> String
shifts op = case op of "shl" -> "lsl"; "shr" -> "asr"; _ -> error "not a shift"

selectModule :: Module -> Module
selectModule m = m {modFuncs = map select (modFuncs m)}

select :: Func -> Func
select f = foldl' one f (fnOrder f)
  where
    live = analyse f
    one g label =
      let b = blockOf g label
          graph = build b (liveOut live label)
       in setBlock b {blInstrs = run graph} g

-- | The DAGs a selection would work on, for @wolv emit -s dag@.
graphs :: Func -> [(Label, Dag)]
graphs f = [(blLabel b, build b (liveOut live (blLabel b))) | b <- walk f]
  where
    live = analyse f

-- | @sOut@ is what has been emitted, in reverse; @sDone@ the nodes that have
-- been; @sAbsorbed@ the ones the plan says a tile will swallow; and @sFused@ the
-- condition code a comparison left for the branch below it.
data S = S
  { sGraph :: Dag,
    sOut :: [Instr],
    sDone :: Set.Set Int,
    sAbsorbed :: Set.Set Int,
    sFused :: Maybe String
  }

type Sel a = State S a

run :: Dag -> [Instr]
run graph = reverse (sOut (execState body (S graph [] Set.empty (plan graph) Nothing)))
  where
    body = mapM_ one (nodes graph)
    one n = do
      absorbed <- gets sAbsorbed
      let i = ndIndex n
      unless
        ( Set.member i absorbed -- part of the tile that reads it
            || isJust (rematerialisable graph (Just i)) -- computed where a register wants it
        )
        $ do
          fused <- fuseComparison n
          unless fused $ do
            modify (\t -> t {sDone = Set.insert i (sDone t)})
            void (tile n)

-- | Decide which nodes a tile is going to swallow, before emitting any.
--
-- Nothing may be deferred on the chance that its reader takes it.  A node left
-- out of the order and then not absorbed would be computed at its reader
-- instead, and a chain of those — @a + b + c + ...@, where every term has one
-- reader — would move the whole sum to its last line and keep every term alive
-- until then.
plan :: Dag -> Set.Set Int
plan graph =
  Set.fromList
    [ ndIndex n
      | n <- nodes graph,
        alone n,
        Just reader <- [ndReader n],
        swallows graph (fromMaybe (error "no reader") (nodeAt graph (Just reader))) n
    ]

-- | Whether the instruction chosen for @reader@ has room for @node@.
swallows :: Dag -> Node -> Node -> Bool
swallows graph reader n = case ndInstr reader of
  Bin _ op _ _
    | op `elem` ["+", "-"] ->
        ndOperands reader !! 1 == Just (ndIndex n)
          && (isJust (asShift graph (Just (ndIndex n))) || isBin n "*")
  Load _ _ offset -> head (ndOperands reader) == Just (ndIndex n) && isJust (displaces graph n offset)
  Store _ offset _ -> head (ndOperands reader) == Just (ndIndex n) && isJust (displaces graph n offset)
  _ -> False

isBin :: Node -> String -> Bool
isBin n op = case ndInstr n of Bin _ o _ _ -> o == op; _ -> False

-- | @[pointer + 24]@, when what is added to the pointer is a constant.
displaces :: Dag -> Node -> Int -> Maybe Int
displaces graph n offset
  | not (isBin n "+") = Nothing
  | otherwise = do
      value <- constant graph (ndOperands n !! 1)
      let total = offset + fromIntegral value
      if (total >= 0 && total <= 32760 && total `mod` word == 0) || (total >= -256 && total <= 255)
        then Just total
        else Nothing

-- | A @x << k@ that can be folded, however it was written: @* 8@ says it too.
-- This decides nothing and emits nothing, so the plan and the tiles can both ask
-- it and get the same answer.
asShift :: Dag -> Maybe Int -> Maybe (Node, Int64)
asShift graph index = do
  n <- nodeAt graph index
  guard (alone n)
  raw <- constant graph (ndOperands n !! 1)
  amount <- case ndInstr n of
    Bin _ "*" _ _ -> if raw > 0 && popCount raw == 1 then Just (log2 raw) else Nothing
    Bin _ "shl" _ _ -> Just raw
    _ -> Nothing
  if amount >= 0 && amount < 64 then Just (n, amount) else Nothing

log2 :: Int64 -> Int64
log2 v = head [fromIntegral i | i <- [0 .. 63 :: Int], testBit v i]

-- -- emitting -------------------------------------------------------------------

machine :: String -> Maybe Reg -> [Reg] -> Int64 -> String -> Bool -> Sel ()
machine form dst srcs imm symbol effect =
  modify (\s -> s {sOut = Machine form dst srcs imm symbol effect : sOut s})

-- | The register holding an operand, computing it here if it was deferred.
--
-- Only two kinds of node were left out of the order: a constant, which is tiled
-- the first time somebody needs it in a register and read from there afterwards,
-- and a node the plan said would be absorbed, which ends up here only if the
-- tile that was to absorb it changed its mind.
at :: Maybe Int -> Reg -> Sel Reg
at index reg = do
  s <- get
  case nodeAt (sGraph s) index of
    Nothing -> pure reg
    Just n
      | Set.member (ndIndex n) (sDone s) -> pure reg
      | Set.member (ndIndex n) (sAbsorbed s)
          || isJust (rematerialisable (sGraph s) (Just (ndIndex n))) -> do
          modify (\t -> t {sDone = Set.insert (ndIndex n) (sDone t)})
          tile n
      | otherwise -> pure reg

-- | Compute a deferred operand for a reader that has no tile to take it.
force :: Maybe Int -> Sel ()
force index = do
  graph <- gets sGraph
  case nodeAt graph index of
    Nothing -> pure ()
    Just n -> void (at index (fromMaybe 0 (defs (ndInstr n))))

-- -- one node ---------------------------------------------------------------

tile :: Node -> Sel Reg
tile n = case ndInstr n of
  Const d v -> do machine "const" (Just d) [] v "" False; pure d
  StrConst d symbol -> do machine "adr" (Just d) [] 0 symbol False; pure d
  Bin d op lhs rhs -> do arithmetic n d op lhs rhs; pure d
  Cmp d op lhs rhs -> do
    compare' n op lhs rhs
    machine "cset" (Just d) [] 0 (condition op) False
    pure d
  Load d base offset -> do
    (pointer, off) <- address (head (ndOperands n)) base offset
    machine "ldr" (Just d) [pointer] (fromIntegral off) "" False
    pure d
  Store base offset src -> do
    value <- at (ndOperands n !! 1) src
    (pointer, off) <- address (head (ndOperands n)) base offset
    machine "str" Nothing [pointer, value] (fromIntegral off) "" True
    pure src
  i -> do
    -- Moves, calls, slot accesses and the terminator are machine instructions
    -- already, and a phi is not in this list at all.  None of them folds
    -- anything, so every operand that was left to be folded has to be computed
    -- here instead.
    mapM_ force (ndOperands n)
    fused <- gets sFused
    let written = case (i, fused) of
          (CBr cond t e _, Just code) -> CBr cond t e code
          _ -> i
    modify (\s -> s {sOut = written : sOut s})
    pure (fromMaybe 0 (defs i))

-- -- the tiles -------------------------------------------------------------

arithmetic :: Node -> Reg -> String -> Reg -> Reg -> Sel ()
arithmetic n d op lhs rhs = case op of
  _ | op `elem` ["+", "-"] -> additive n d op lhs rhs
  "*" -> multiply n d lhs rhs
  "/" -> both n lhs rhs >>= \srcs -> machine "sdiv" (Just d) srcs 0 "" False
  _ | op `elem` ["shl", "shr"] -> shift n d op lhs rhs
  _ | op `elem` ["and", "or", "xor"] -> logic n d op lhs rhs
  _ -> error ("no instruction for `" ++ op ++ "`")

-- | Both operands in registers, which is what the plain forms want.
both :: Node -> Reg -> Reg -> Sel [Reg]
both n lhs rhs = do
  left <- at (head (ndOperands n)) lhs
  right <- at (ndOperands n !! 1) rhs
  pure [left, right]

-- | @add@ and @sub@, in whichever of their four forms fits.
additive :: Node -> Reg -> String -> Reg -> Reg -> Sel ()
additive n d op lhs rhs = do
  -- A shifted operand comes first: `a + b * 8` is one instruction that way and
  -- two as a multiply-add, because the 8 would need a register.
  shifted <- shiftInto n d op lhs
  unless shifted $ do
    product' <- multiplyInto n d op lhs
    unless product' $ do
      graph <- gets sGraph
      let left = head (ndOperands n)
          right = ndOperands n !! 1
      case constant graph right of
        Just v | v >= 0 && v <= immediate -> do
          a <- at left lhs
          machine (if op == "+" then "addi" else "subi") (Just d) [a] v "" False
        _ -> case (op, constant graph left) of
          -- Only addition may take its constant from the other side.
          ("+", Just v) | v >= 0 && v <= immediate -> do
            a <- at right rhs
            machine "addi" (Just d) [a] v "" False
          _ -> do
            srcs <- both n lhs rhs
            machine (if op == "+" then "add" else "sub") (Just d) srcs 0 "" False

multiply :: Node -> Reg -> Reg -> Reg -> Sel ()
multiply n d lhs rhs = do
  graph <- gets sGraph
  case constant graph (ndOperands n !! 1) of
    Just v | v > 0 && popCount v == 1 -> do
      a <- at (head (ndOperands n)) lhs
      machine "lsli" (Just d) [a] (log2 v) "" False
    _ -> do
      srcs <- both n lhs rhs
      machine "mul" (Just d) srcs 0 "" False

shift :: Node -> Reg -> String -> Reg -> Reg -> Sel ()
shift n d op lhs rhs = do
  graph <- gets sGraph
  case constant graph (ndOperands n !! 1) of
    Just v | v >= 0 && v < 64 -> do
      a <- at (head (ndOperands n)) lhs
      machine (shifts op ++ "i") (Just d) [a] v "" False
    _ -> do
      srcs <- both n lhs rhs
      machine (shifts op) (Just d) srcs 0 "" False

logic :: Node -> Reg -> String -> Reg -> Reg -> Sel ()
logic n d op lhs rhs = do
  graph <- gets sGraph
  -- Which is how `not` arrives.
  if op == "xor" && constant graph (ndOperands n !! 1) == Just 1
    then do
      a <- at (head (ndOperands n)) lhs
      machine "eori" (Just d) [a] 1 "" False
    else do
      srcs <- both n lhs rhs
      machine (logical op) (Just d) srcs 0 "" False

-- | @a + b * c@ and @a - b * c@ are one instruction each.
multiplyInto :: Node -> Reg -> String -> Reg -> Sel Bool
multiplyInto n d op lhs = do
  graph <- gets sGraph
  case nodeAt graph (ndOperands n !! 1) of
    Just p | alone p, isBin p "*", Bin _ _ pl pr <- ndInstr p -> do
      x <- at (head (ndOperands p)) pl
      y <- at (ndOperands p !! 1) pr
      z <- at (head (ndOperands n)) lhs
      machine (if op == "+" then "madd" else "msub") (Just d) [x, y, z] 0 "" False
      pure True
    _ -> pure False

-- | The second operand of an @add@ may be shifted on the way in.
shiftInto :: Node -> Reg -> String -> Reg -> Sel Bool
shiftInto n d op lhs = do
  graph <- gets sGraph
  case asShift graph (ndOperands n !! 1) of
    Just (shifted, amount) | Bin _ _ sl _ <- ndInstr shifted -> do
      a <- at (head (ndOperands n)) lhs
      b <- at (head (ndOperands shifted)) sl
      machine (if op == "+" then "adds" else "subs") (Just d) [a, b] amount "" False
      pure True
    _ -> pure False

-- | A pointer and a displacement, taking in an addition if there is one.
address :: Maybe Int -> Reg -> Int -> Sel (Reg, Int)
address index base offset = do
  graph <- gets sGraph
  case nodeAt graph index of
    Just n
      | alone n,
        Just displaced <- displaces graph n offset,
        Bin _ _ lhs _ <- ndInstr n -> do
          pointer <- at (head (ndOperands n)) lhs
          pure (pointer, displaced)
    _ -> do
      pointer <- at index base
      pure (pointer, offset)

-- -- comparisons and the branch that reads them ------------------------------

compare' :: Node -> String -> Reg -> Reg -> Sel ()
compare' n _ lhs rhs = do
  graph <- gets sGraph
  let left = head (ndOperands n)
      right = ndOperands n !! 1
  case constant graph right of
    Just v | v >= 0 && v <= immediate -> do
      a <- at left lhs
      machine "cmpi" Nothing [a] v "" False
    _ -> do
      a <- at left lhs
      b <- at right rhs
      machine "cmp" Nothing [a, b] 0 "" False

-- | A comparison the branch below it is the only reader of sets the flags.
fuseComparison :: Node -> Sel Bool
fuseComparison n = do
  graph <- gets sGraph
  let all' = nodes graph
      final = ndInstr (last all')
  case ndInstr n of
    Cmp d op lhs rhs
      | ndIndex n + 1 == length all' - 1,
        CBr cond _ _ _ <- final,
        cond == d,
        ndUsers n == 1,
        not (ndEscapes n) -> do
          compare' n op lhs rhs
          modify (\s -> s {sFused = Just (condition op)})
          pure True
    _ -> pure False
