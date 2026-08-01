-- | Which colour a value would like, which is the calling convention asking.
--
-- The allocator does not have to satisfy these — a preference is dropped the
-- moment it clashes with something the colouring actually requires — but taking
-- one when it is free is what stops the emitter having to move a value into
-- @x2@ on the way into a call, or out of @x0@ on the way back from one.
module Wolv.Hints (preferences) where

import Data.List (foldl')
import qualified Data.Map.Strict as Map
import Wolv.Ir
import Wolv.Registers

-- | The register each value is about to be wanted in, where there is one.  A
-- later answer wins, which is what a map built by folding in program order says.
preferences :: Func -> Map.Map Reg Int
preferences f = foldl' one (Map.fromList (zip (fnParams f) argumentRegs)) wanted
  where
    wanted = concatMap fromInstr [i | b <- walk f, i <- blInstrs b]
    fromInstr i = case i of
      Call d _ args -> zip args argumentRegs ++ maybe [] (\r -> [(r, resultRegister)]) d
      Ret (Just value) -> [(value, resultRegister)]
      _ -> []
    one m (r, colour) = Map.insert r colour m
