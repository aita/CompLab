-- | Optimisation on SSA.
--
-- Five small passes run to a fixed point.  Each is cheap because SSA makes it
-- cheap: a register has one definition, so constant folding and copy propagation
-- are a lookup rather than a dataflow problem, and a phi whose arguments all
-- agree is a copy that was never needed.
--
-- >     fold constants   ->  arithmetic on known values
-- >     propagate copies ->  a move, and phis that turned into one
-- >     simplify phis    ->  a phi with one distinct argument is that argument
-- >     fold branches    ->  a branch on a known value, and the blocks it strands
-- >     dead code        ->  anything computed and not used
--
-- A pass is a function from a function to a function, and nothing reports
-- whether it did anything: the fixed point is over the value, so asking is
-- `==`.
module Wolv.Opt (optimise, optimiseFunc) where

import Data.Bits (xor, (.&.), (.|.))
import Data.Int (Int64)
import Data.List (foldl', mapAccumL)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Wolv.I64
import Wolv.Ir

type Pass = Func -> Func

passes :: [Pass]
passes = [foldConstants, propagateCopies, simplifyPhis, foldBranches, deadCode]

optimise :: Module -> Module
optimise m = m {modFuncs = map optimiseFunc (modFuncs m)}

-- | Every pass runs every round: they are cheap, and one enables another.
optimiseFunc :: Func -> Func
optimiseFunc = converge (\f -> foldl' (flip ($)) f passes)

-- -- rewriting -----------------------------------------------------------------

-- | Replace registers everywhere they are read, phi arguments included.  A chain
-- of copies is followed to its end, and the @seen@ guard is what stops a phi
-- that was simplified into itself from spinning.
rewrite :: Map.Map Reg Reg -> Func -> Func
rewrite mapping f
  | Map.null mapping = f
  | otherwise = mapBlocks one f
  where
    resolve = follow Set.empty
    follow seen r = case Map.lookup r mapping of
      Just r' | not (Set.member r seen) -> follow (Set.insert r seen) r'
      _ -> r
    one b =
      b
        { blPhis = [p {phiArgs = [(pred', resolve r) | (pred', r) <- phiArgs p]} | p <- blPhis b],
          blInstrs = map (mapUses resolve) (blInstrs b)
        }

constants :: Func -> Map.Map Reg Int64
constants f = Map.fromList [(d, v) | b <- walk f, Const d v <- blInstrs b]

-- -- the passes ----------------------------------------------------------------

-- | The table of known values grows as the walk goes, because a constant folded
-- in one block is a constant the next block may fold against — so this is one
-- fold over the whole function and not one per block.
foldConstants :: Pass
foldConstants f0 = fst (foldl' block (f0, constants f0) (fnOrder f0))
  where
    block (f, known) label =
      let (known', out) = mapAccumL one known (blInstrs (blockOf f label))
       in (setBlock (blockOf f label) {blInstrs = out} f, known')
    one known i = case foldOne known i of
      Nothing -> (known, i)
      Just folded@(Const d v) -> (Map.insert d v known, folded)
      Just folded -> (known, folded)

foldOne :: Map.Map Reg Int64 -> Instr -> Maybe Instr
foldOne known i = case i of
  Bin d op lhs rhs -> case (Map.lookup lhs known, Map.lookup rhs known) of
    (Just a, Just b) -> Const d <$> arith op a b
    (a, b)
      -- The identities are worth having on their own: `x shl 0` and `x * 1` come
      -- out of lowering an index, and folding them is what lets the selector see
      -- one `add` where there were three instructions.
      | b == Just 0 && op `elem` [Add, Sub, Or, Xor, Shl, Shr] -> Just (Move d lhs)
      | b == Just 1 && op `elem` [Mul, Div] -> Just (Move d lhs)
      | a == Just 0 && op == Add -> Just (Move d rhs)
      | otherwise -> Nothing
  Cmp d op lhs rhs -> case (Map.lookup lhs known, Map.lookup rhs known) of
    (Just a, Just b) -> Just (Const d (if order op a b then 1 else 0))
    _ -> Nothing
  _ -> Nothing

-- | The arithmetic of the machine, which is 'Int64' and needs no help.  Nothing
-- is what a division by zero and a shift by a negative answer; every operator
-- has a case, and the compiler is what says so.
arith :: Op -> Int64 -> Int64 -> Maybe Int64
arith op a b = case op of
  Add -> Just (a + b)
  Sub -> Just (a - b)
  Mul -> Just (a * b)
  Div -> if b == 0 then Nothing else Just (quotient a b)
  And -> Just (a .&. b)
  Or -> Just (a .|. b)
  Xor -> Just (a `xor` b)
  Shl -> shl a b
  Shr -> shr a b

order :: Rel -> Int64 -> Int64 -> Bool
order op a b = case op of
  Equal -> a == b
  NotEqual -> a /= b
  Less -> a < b
  LessEq -> a <= b
  Greater -> a > b
  GreaterEq -> a >= b
  Below -> unsigned a < unsigned b
  AboveEq -> unsigned a >= unsigned b

propagateCopies :: Pass
propagateCopies f
  | Map.null mapping = f
  | otherwise = mapBlocks noMoves (rewrite mapping f)
  where
    mapping = Map.fromList [(d, s) | b <- walk f, Move d s <- blInstrs b]
    noMoves b = b {blInstrs = [i | i <- blInstrs b, not (isMove i)]}
    isMove (Move _ _) = True
    isMove _ = False

simplifyPhis :: Pass
simplifyPhis f
  | Map.null mapping = f
  | otherwise = rewrite mapping (mapBlocks keep f)
  where
    resolved = [(p, others p) | b <- walk f, p <- blPhis b]
    others p = Set.toList (Set.fromList [r | (_, r) <- phiArgs p, r /= phiDst p])
    mapping = Map.fromList [(phiDst p, r) | (p, [r]) <- resolved]
    keep b = b {blPhis = [p | p <- blPhis b, not (Map.member (phiDst p) mapping)]}

foldBranches :: Pass
foldBranches f
  | null folded = f
  | otherwise = dropUnreachable (foldl' one f folded)
  where
    known = constants f
    folded = mapMaybe taken (walk f)
    taken b = case terminator b of
      CBr cond t e _ -> case Map.lookup cond known of
        Just v -> Just (blLabel b, if v /= 0 then t else e)
        Nothing -> if t == e then Just (blLabel b, t) else Nothing
      _ -> Nothing
    one g (label, target) =
      let b = blockOf g label
       in setBlock (withTerminator (Jmp target) b) g

-- | Removing one dead value can make another dead, so this one has a fixed point
-- of its own rather than waiting for the next round.
deadCode :: Pass
deadCode = converge once
  where
    once f = mapBlocks (keep (readAnywhere f)) f
    readAnywhere f =
      Set.fromList
        ( [r | b <- walk f, p <- blPhis b, (_, r) <- phiArgs p]
            ++ [r | b <- walk f, i <- blInstrs b, r <- uses i]
        )
    keep used b =
      b
        { blPhis = [p | p <- blPhis b, Set.member (phiDst p) used],
          blInstrs = [i | i <- blInstrs b, alive used i]
        }
    alive used i = maybe True (\d -> Set.member d used || hasEffect i) (defs i)
