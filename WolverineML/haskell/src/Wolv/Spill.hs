-- | Spilling.
--
-- A spilled value gets a frame slot, a store after every definition of it and a
-- reload in front of every use.  The reloads are new registers, live from the
-- load to the instruction under it and nowhere else, which is what makes the
-- pressure come down.  Nothing here assumes SSA: a value written twice gets two
-- stores, and a phi argument is reloaded at the end of the predecessor it comes
-- from, so the same rewrite serves the graph before and after it left SSA.
module Wolv.Spill (loopDepth, costs, spill) where

import Data.List (foldl')
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Wolv.Ir
import Wolv.Ssa (dominance, dominates)

-- | How deeply each block is nested in loops, for weighing what a use costs.
--
-- A back edge is an edge into a block that dominates its source; everything that
-- can reach the source without leaving the dominated region is in that loop.
loopDepth :: Func -> Map.Map Label Int
loopDepth f = foldl' one (Map.fromList [(label, 0) | label <- fnOrder f]) backEdges
  where
    dom = dominance f
    backEdges = [(blLabel b, s) | b <- walk f, s <- succs b, dominates dom s (blLabel b)]
    one depth (from, header) = foldr (Map.adjust (+ 1)) depth (Set.toList (body header from))
    body header from = climb (Set.singleton header) [from]
    climb seen [] = seen
    climb seen (label : rest)
      | Set.member label seen = climb seen rest
      | otherwise = climb (Set.insert label seen) (blPreds (blockOf f label) ++ rest)

-- | What spilling a value would cost: its reads and writes, weighed by loops.
costs :: Func -> Map.Map Reg Double
costs f = Map.fromListWith (+) (concatMap inBlock (walk f))
  where
    depth = loopDepth f
    scale label = 10 ^^ min (fromMaybe 0 (Map.lookup label depth)) 4
    inBlock b =
      [(r, scale pred') | p <- blPhis b, (pred', r) <- phiArgs p]
        ++ [(phiDst p, scale (blLabel b)) | p <- blPhis b]
        ++ [(r, scale (blLabel b)) | i <- blInstrs b, r <- uses i]
        ++ [(d, scale (blLabel b)) | i <- blInstrs b, Just d <- [defs i]]

-- | Give @victim@ a frame slot, and answer with the function it made, the slot,
-- and the reloads that replaced it.
spill :: Reg -> Func -> (Func, Int, Set.Set Reg)
spill victim f0 = (withPhis, slot, reloads)
  where
    slot = fnSlots f0
    f1 = f0 {fnSlots = fnSlots f0 + 1}
    isParam = victim `elem` fnParams f1

    -- Every reload is a register the function did not have, so the counter is
    -- threaded through both walks below and the names come out in order.
    (f2, used) = foldl' inBlock (f1, []) (fnOrder f1)
    inBlock (f, made) label =
      let b = blockOf f label
          before =
            [StoreSlot slot victim | any ((== victim) . phiDst) (blPhis b)]
              ++ [StoreSlot slot victim | isParam && label == fnEntry f]
          (next, made', out) = foldl' one (fnRegs f, made, []) (before ++ blInstrs b)
       in (setBlock b {blInstrs = reverse out} f {fnRegs = next}, made')
    one (next, made, out) i
      -- The store this pass just put in reads the victim on purpose.
      | isSpillStore i || victim `notElem` uses i =
          (next, made, after i (i : out))
      | otherwise =
          ( next + 1,
            Reg next : made,
            after i
              (mapUses (\r -> if r == victim then Reg next else r) i : LoadSlot (Reg next) slot : out)
          )
    after i out = [StoreSlot slot victim | defs i == Just victim] ++ out
    isSpillStore i = case i of StoreSlot n _ -> n == slot; _ -> False

    (withPhis, alsoUsed) = foldl' fromPhis (f2, used) (fnOrder f2)
    fromPhis (f, made) label =
      let b = blockOf f label
          (f', made', phis) = foldl' (onePhi label) (f, made, []) (blPhis b)
       in (setBlock (blockOf f' label) {blPhis = reverse phis} f', made')
    onePhi _ (f, made, out) p =
      let (f', made', args) = foldl' reload (f, made, []) (phiArgs p)
       in (f', made', p {phiArgs = reverse args} : out)
    reload (f, made, args) (pred', arg)
      | arg /= victim = (f, made, (pred', arg) : args)
      | otherwise =
          let fresh = Reg (fnRegs f)
              source = blockOf f pred'
              f' =
                setBlock
                  (beforeTerminator [LoadSlot fresh slot] source)
                  f {fnRegs = fnRegs f + 1}
           in (f', fresh : made, (pred', fresh) : args)

    reloads = Set.fromList alsoUsed
