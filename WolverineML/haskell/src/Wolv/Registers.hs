-- | What the allocator and the emitter both have to agree about: the registers.
--
-- x16 and x17 are the ABI's intra-procedure-call scratch registers, which a
-- linker veneer may clobber at a @bl@.  Nothing of ours is ever live across a
-- call in a caller-saved register, so x16 is allocatable like any other; x17 is
-- the one register kept back, for an address the emitter has to compute after
-- allocation is over.  x18 is the platform register, x29 the frame pointer, x30
-- the link register.
module Wolv.Registers
  ( callerSaved,
    calleeSaved,
    argumentRegs,
    resultRegister,
    spare,
    Machine (..),
    whole,
    anywhere,
    count,
    limited,
  )
where

callerSaved :: [Int]
callerSaved = [9, 10, 11, 12, 13, 14, 15, 16, 0, 1, 2, 3, 4, 5, 6, 7, 8]

calleeSaved :: [Int]
calleeSaved = [19, 20, 21, 22, 23, 24, 25, 26, 27, 28]

argumentRegs :: [Int]
argumentRegs = [0, 1, 2, 3, 4, 5, 6, 7]

-- | Where an argument goes in and where a result comes back, which AAPCS64 makes
-- the same register.
resultRegister :: Int
resultRegister = head argumentRegs

-- | The one register kept back, for an address the emitter has to compute after
-- allocation is over.
spare :: Int
spare = 17

-- | The machine an allocator is colouring for.
data Machine = Machine {mCaller :: [Int], mCallee :: [Int]}

whole :: Machine
whole = Machine callerSaved calleeSaved

anywhere :: Machine -> [Int]
anywhere m = mCaller m ++ mCallee m

count :: Machine -> Int
count m = length (mCaller m) + length (mCallee m)

-- | A smaller machine, so that the spiller can be tested on small programs.
limited :: Int -> Machine
limited maxRegs = Machine caller callee
  where
    callee = take (max 2 (maxRegs `div` 2)) calleeSaved
    caller = take (max 1 (maxRegs - length callee)) callerSaved
