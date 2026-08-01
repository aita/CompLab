-- | Liveness on SSA.
--
-- The only subtlety is the phi.  A phi does not read its arguments where it
-- stands; it reads them on the edges, so an argument is live at the end of the
-- predecessor it is paired with and not anywhere inside the block that holds the
-- phi.  Getting that wrong is what makes phi-related values interfere when they
-- should not.
module Wolv.Liveness (Live (..), analyse, liveIn, liveOut, acrossCalls, pressure) where

import Data.List (foldl')
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Wolv.Ir

data Live = Live
  { lvIn :: Map.Map Label (Set.Set Reg),
    lvOut :: Map.Map Label (Set.Set Reg)
  }
  deriving (Eq)

liveIn :: Live -> Label -> Set.Set Reg
liveIn live label = fromMaybe Set.empty (Map.lookup label (lvIn live))

liveOut :: Live -> Label -> Set.Set Reg
liveOut live label = fromMaybe Set.empty (Map.lookup label (lvOut live))

analyse :: Func -> Live
analyse f = converge round' (Live empty empty)
  where
    empty = Map.fromList [(label, Set.empty) | label <- fnOrder f]

    -- What a block reads before writing, and what it writes at all.
    upward = Map.fromList [(blLabel b, fst (facts b)) | b <- walk f]
    killed = Map.fromList [(blLabel b, snd (facts b)) | b <- walk f]
    facts b = foldl' one (Set.empty, Set.fromList (map phiDst (blPhis b))) (blInstrs b)
    one (use, kill) i =
      ( foldr (\r acc -> if Set.member r kill then acc else Set.insert r acc) use (uses i),
        maybe kill (`Set.insert` kill) (defs i)
      )

    order = reverse (rpo f)
    round' live = foldl' step live order
    step live label =
      let b = blockOf f label
          out = Set.unions (map (leaving live label) (succs b))
          entering =
            Set.union
              (fromMaybe Set.empty (Map.lookup label upward))
              (Set.difference out (fromMaybe Set.empty (Map.lookup label killed)))
       in Live (Map.insert label entering (lvIn live)) (Map.insert label out (lvOut live))
    leaving live from succ' =
      Set.union
        (liveIn live succ')
        (Set.fromList [r | p <- blPhis (blockOf f succ'), Just r <- [lookup from (phiArgs p)]])

-- | Values that are live across a call, and so cannot sit in a scratch register.
acrossCalls :: Func -> Live -> Set.Set Reg
acrossCalls f live = Set.unions (map inBlock (walk f))
  where
    inBlock b = snd (foldl' one (liveOut live (blLabel b), Set.empty) (reverse (blInstrs b)))
    one (after, out) i =
      let without = maybe after (`Set.delete` after) (defs i)
          out' = case i of Call {} -> Set.union out without; _ -> out
       in (Set.union without (Set.fromList (uses i)), out')

-- | The most values live at any one point — the registers the function wants.
pressure :: Func -> Live -> Int
pressure f live = maximum (0 : concatMap inBlock (walk f))
  where
    inBlock b =
      let entry = Set.union (liveIn live (blLabel b)) (Set.fromList (map phiDst (blPhis b)))
       in Set.size entry : walkBack (liveOut live (blLabel b)) (reverse (blInstrs b))
    walkBack after [] = [Set.size after]
    walkBack after (i : rest) =
      let without = maybe after (`Set.delete` after) (defs i)
          next = Set.union without (Set.fromList (uses i))
       in Set.size after : walkBack next rest
