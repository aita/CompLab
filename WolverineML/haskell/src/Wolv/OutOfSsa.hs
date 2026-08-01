-- | Leaving SSA before allocation.
--
-- A phi is a copy that happens on an edge, so it becomes copies at the end of
-- each predecessor.  Critical edges are already split, so a predecessor of a
-- block with phis has nowhere else to go and the copies can simply be appended.
--
-- The copies of one edge happen at once: every argument is read before any
-- destination is written.  Usually that needs no care, because a phi's
-- destination is defined nowhere else and so is nobody's argument — but a block
-- that is its own predecessor can have two phis that swap, and then the copies
-- go through temporaries, which is Sreedhar's answer and which coalescing is
-- expected to remove again.
module Wolv.OutOfSsa (destruct, destructModule) where

import Data.List (foldl')
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Wolv.Ir

-- | Replace every phi in @f@ with copies in its predecessors.
destruct :: Func -> Func
destruct f0 = recomputePreds (mapBlocks noPhis (foldl' atBlock f0 (fnOrder f0)))
  where
    noPhis b = b {blPhis = []}
    atBlock f label =
      let b = blockOf f label
       in if null (blPhis b) then f else foldl' (fromPred label) f (blPreds b)
    fromPred label f pred'
      | length (succs (blockOf f pred')) /= 1 =
          error (pred' ++ " -> " ++ label ++ " is a critical edge")
      | otherwise = copyInParallel pred' (onEdge pred' (blockOf f label)) f

copyInParallel :: Label -> [(Reg, Reg)] -> Func -> Func
copyInParallel label moves f
  | null real = f
  | otherwise = setBlock (beforeTerminator copies b) f'
  where
    real = [(d, s) | (d, s) <- moves, d /= s]
    written = Set.fromList (map fst real)
    tangled = any ((`Set.member` written) . snd) real
    -- Something read is also written, so the two halves cannot be one list.
    (f', copies)
      | tangled =
          let (g, through) = foldl' reserve (f, Map.empty) (map fst real)
           in ( g,
                [Move (through Map.! d) s | (d, s) <- real]
                  ++ [Move d (through Map.! d) | (d, _) <- real]
              )
      | otherwise = (f, [Move d s | (d, s) <- real])
    reserve (g, m) d = (g {fnRegs = fnRegs g + 1}, Map.insert d (Reg (fnRegs g)) m)
    b = blockOf f' label

destructModule :: Module -> Module
destructModule m = m {modFuncs = map destruct (modFuncs m)}
