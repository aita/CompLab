-- | The seam the allocator is reached through, and the verifier it answers to.
--
-- There is one allocator here — leave SSA, build the interference graph, colour
-- it with Chaitin's algorithm and George and Appel's iterated coalescing.  The
-- Python tree has a second one that colours the SSA itself in dominance order,
-- and keeps both so that the two can be measured against each other; this tree
-- keeps the graph.
module Wolv.Allocator (allocateModule, verify) where

import Control.Monad (foldM, foldM_, when)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.List (find)
import Wolv.Graph (allocate)
import Wolv.Ir
import Wolv.Liveness
import Wolv.Registers (Machine)

-- | Colour every function, and answer with the module the spiller rewrote and
-- what was decided about each of its functions.
allocateModule :: Machine -> Module -> Either String (Module, Map.Map String Allocation)
allocateModule machine m = do
  done <- mapM (allocate machine) (modFuncs m)
  pure
    ( m {modFuncs = map fst done},
      Map.fromList [(fnLabel f, alloc) | (f, alloc) <- done]
    )

-- | No two values that hold different things at once may share a colour.
--
-- The check is made where the interference graph joins values — at each
-- definition, and at the top of a block for the phis and the parameters, which
-- define several at once.  Looking at a whole live set instead would be wrong,
-- not merely slower: both ends of a copy are live after it and hold the same
-- value, so they may share a register, and that is the entire point of
-- coalescing.  A verifier that rejected it would reject every program the
-- coalescer had done its job on.
--
-- Every value that interferes with another is caught this way, because the later
-- of the two definitions that put the values there happens while the other is
-- live.
verify :: Func -> Allocation -> Either String ()
verify f alloc = mapM_ inBlock (walk f)
  where
    colours = alColours alloc
    live = analyse f

    -- Each of the three walks carries the live set along and may stop with a
    -- complaint, which is what `foldM` over `Either` is.
    inBlock b = do
      foldM_ underInstr (liveOut live at) (reverse (blInstrs b))
      entering <- foldM atPhi (liveIn live at) (blPhis b)
      when (at == fnEntry f) (foldM_ atParam entering (fnParams f))
      where
        at = blLabel b

        underInstr alive i = do
          -- Both ends of a copy hold the same value, so the one it reads is not
          -- what the one it writes has to differ from.
          let after = case i of Move _ s -> Set.delete s alive; _ -> alive
          mapM_ coloured (uses i)
          kept <- case defs i of
            Nothing -> pure after
            Just d -> do
              coloured d
              noClash (Set.insert d after) d at
              -- A definition kills what was there, walking backwards.
              pure (Set.delete d after)
          pure (Set.union kept (Set.fromList (uses i)))

        atPhi entering p = do
          coloured (phiDst p)
          let with = Set.insert (phiDst p) entering
          noClash with (phiDst p) at
          pure with

        atParam entering param = do
          let with = Set.insert param entering
          noClash with param at
          pure with

    coloured r
      | Map.member r colours = pure ()
      | otherwise = Left ("%" ++ show (unReg r) ++ " has no colour")

    -- Nothing else live here may hold the colour `written` was just given.
    noClash alive written where' = case Map.lookup written colours of
      Nothing -> pure ()
      Just colour -> case find (holds colour) (Set.toAscList (Set.delete written alive)) of
        Nothing -> pure ()
        Just other ->
          Left
            ( "x" ++ show colour ++ " holds %" ++ show (unReg written) ++ " and %" ++ show (unReg other)
                ++ " at once in "
                ++ where'
            )
      where
        holds colour other = Map.lookup other colours == Just colour
