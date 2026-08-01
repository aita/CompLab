-- | Sixty-four bit arithmetic.
--
-- Haskell has the machine's word already: 'Int64' wraps on overflow, @quot@ and
-- @rem@ truncate towards zero the way @sdiv@ does, and the bit operations are
-- the bit operations.  Three things still have to be said out loud — the two
-- shifts past 63, which 'shiftL' and 'shiftR' would rather not define, and
-- @minBound `quot` (-1)@, which the machine wraps back to @minBound@ and which
-- GHC raises an overflow for.
module Wolv.I64
  ( Word64Value,
    quotient,
    remainder,
    shl,
    shr,
    unsigned,
  )
where

import Data.Bits
import Data.Int (Int64)
import Data.Word (Word64)

type Word64Value = Int64

-- | The same bits read as unsigned, which is what @u<@ and @u>=@ compare.
unsigned :: Int64 -> Word64
unsigned = fromIntegral

quotient :: Int64 -> Int64 -> Int64
quotient a (-1) = negate a
quotient a b = a `quot` b

remainder :: Int64 -> Int64 -> Int64
remainder a b = a - quotient a b * b

-- | A shift of 64 or more is not the host's business to decide.
shl :: Int64 -> Int64 -> Maybe Int64
shl a b
  | b < 0 = Nothing
  | b >= 64 = Just 0
  | otherwise = Just (shiftL a (fromIntegral b))

shr :: Int64 -> Int64 -> Maybe Int64
shr a b
  | b < 0 = Nothing
  | b >= 64 = Just (if a < 0 then -1 else 0)
  | otherwise = Just (shiftR a (fromIntegral b))
