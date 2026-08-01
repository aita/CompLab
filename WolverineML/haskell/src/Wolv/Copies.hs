-- | Doing several copies at once, one at a time.
--
-- A phi is a copy that happens on an edge, and all the phis of a block happen
-- together: every argument is read before any destination is written.  Once the
-- allocator has given both ends real registers that is a permutation, and
-- putting a permutation into a sequence of instructions is this module.
--
-- Copies whose destination nobody else has still to read can go first.  When
-- only cycles are left, something has to be got out of the way, and there are
-- two ways to do it: a register the function never used can hold a value for one
-- step, and if there is no such register the two ends of the cycle swap.  A swap
-- is three @eor@s and needs nothing to borrow, which is why no register is
-- reserved for this anywhere in the compiler.
module Wolv.Copies (Step (..), sequentialize) where


data Step = Mov {stDst :: Int, stSrc :: Int} | Swap {stA :: Int, stB :: Int}
  deriving (Eq, Show)

-- | Order @(destination, source)@ pairs so that nothing is lost on the way.
-- @borrowed@ is a register free to clobber, or 'Nothing'.
--
-- The pairs are a parallel copy, so no destination appears twice: they come
-- from the phis of one block, whose destinations are distinct because SSA
-- construction gave each one a register of its own.
sequentialize :: [(Int, Int)] -> Maybe Int -> [Step]
sequentialize moves borrowed = go real
  where
    real = [(d, s) | (d, s) <- moves, d /= s]

    -- `pending` stays in the order it was given: which copy is picked when
    -- several are ready is what the emitted sequence looks like.
    go [] = []
    go pending = case [d | (d, _) <- pending, d `notElem` map snd pending] of
      ready@(_ : _) ->
        [Mov d s | (d, s) <- pending, d `elem` ready]
          ++ go [m | m@(d, _) <- pending, d `notElem` ready]
      [] -> case (pending, borrowed) of
        ((stuck, _) : _, Just free) -> Mov free stuck : go (moved pending stuck free)
        -- Swapping satisfies `stuck` outright and leaves its old value where the
        -- other end was, so everything still to read it reads there instead.
        ((stuck, other) : rest, Nothing) -> Swap stuck other : go (moved rest stuck other)

-- | The value that was in @was@ is in @now@; whoever wanted it looks there.
moved :: [(Int, Int)] -> Int -> Int -> [(Int, Int)]
moved pending was now =
  [ (d, if s == was then now else s)
    | (d, s) <- pending,
      -- The swap already put it where it belongs.
      not (s == was && d == now)
  ]
