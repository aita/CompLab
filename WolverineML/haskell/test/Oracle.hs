-- | Random programs whose answer is known before they are compiled.
--
-- The other tests say what the compiler should do; these say what the program
-- should print, which is the only thing a user cares about.  A program is built
-- at random, worked out here with the language's arithmetic, and then compiled —
-- so any disagreement is a bug in the compiler and not in a comparison between
-- two of its own configurations.
--
-- The randomness is a linear congruential generator written out below, because
-- this tree depends on nothing GHC does not ship.  It only has to be the same
-- stream twice, which it is.
module Oracle (arithmetic, imperative) where

import Data.Bits (shiftR, (.&.))
import Data.Int (Int64)
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Wolv.I64 (quotient, remainder)

size :: Int
size = 16

vars :: [String]
vars = ["v0", "v1", "v2", "v3"]

constants :: [Int64]
constants = [0, 1, 2, 3, 7, 8, 15, 16, 100, 4095, 4096, 65536, -1, -8, 1099511627776]

arguments :: [(Int64, Int64, Int64)]
arguments = [(0, 0, 0), (1, 2, 3), (-1, 7, -13), (maxBound, minBound, 2)]

orders :: [String]
orders = ["=", "<>", "<", "<=", ">", ">="]

-- -- the source of chance -----------------------------------------------------

-- | Knuth's constants, and the top bits are the ones worth having.
newtype Chance = Chance Integer

seeded :: Int -> Chance
seeded seed = Chance (fromIntegral seed * 2654435761 + 1)

step :: Chance -> (Integer, Chance)
step (Chance state) =
  let next = (state * 6364136223846793005 + 1442695040888963407) `mod` (2 ^ (64 :: Int))
   in ((next `shiftR` 17) .&. 0x7FFFFFFF, Chance next)

-- | A number in [0, 1), which is what every choice below is made with.
roll :: Chance -> (Double, Chance)
roll g = let (n, g') = step g in (fromIntegral n / 2147483648.0, g')

pick :: [a] -> Chance -> (a, Chance)
pick xs g = let (n, g') = step g in (xs !! fromIntegral (n `mod` fromIntegral (length xs)), g')

between :: Int -> Int -> Chance -> (Int, Chance)
between lo hi g =
  let (n, g') = step g in (lo + fromIntegral (n `mod` fromIntegral (hi - lo + 1)), g')

-- | @+@ twice as likely as @/@, because a division that turns out to be by zero
-- throws the whole expression away and generating them is not free.
weighted :: [(a, Int)] -> Chance -> (a, Chance)
weighted choices g =
  let total = sum (map snd choices)
      (n, g') = step g
      target = fromIntegral (n `mod` fromIntegral total)
   in (walk 0 choices target, g')
  where
    walk _ [] _ = error "no choice"
    walk seen ((choice, weight) : rest) target
      | target < seen + weight = choice
      | otherwise = walk (seen + weight) rest target

-- -- the shape of a program ---------------------------------------------------

data Tree
  = TVar String
  | TInt Int64
  | TIf String Tree Tree Tree Tree
  | TBin String Tree Tree
  | TGet Tree
  | TSet String Tree
  | TPut Tree Tree
  | TSeq [Tree]
  | TWhen String Tree Tree Tree Tree
  | TFor String Int Int Tree

literal :: Int64 -> String
literal v = if v < 0 then "~" ++ show (negate (toInteger v)) else show v

-- -- the arithmetic half ------------------------------------------------------

expression :: Int -> Chance -> (Tree, Chance)
expression depth g0
  | depth == 0 || leaf < 0.25 =
      let (which, g2) = roll g1
       in if which < 0.5
            then let (name, g3) = pick ["a", "b", "c"] g2 in (TVar name, g3)
            else let (value, g3) = pick constants g2 in (TInt value, g3)
  | branch < 0.1 =
      let (op, g3) = pick orders g2
          (x, g4) = expression (depth - 1) g3
          (y, g5) = expression (depth - 1) g4
          (t, g6) = expression (depth - 1) g5
          (e, g7) = expression (depth - 1) g6
       in (TIf op x y t e, g7)
  | otherwise =
      let (op, g3) = weighted [("+", 4), ("-", 3), ("*", 3), ("/", 1), ("mod", 1)] g2
          (x, g4) = expression (depth - 1) g3
          (y, g5) = expression (depth - 1) g4
       in (TBin op x y, g5)
  where
    (leaf, g1) = roll g0
    (branch, g2) = roll g1

-- | 'Nothing' when the expression turns out to divide by zero; the caller throws
-- that expression away and rolls another.
evaluate :: Tree -> Map.Map String Int64 -> Maybe Int64
evaluate node env = case node of
  TVar name -> Map.lookup name env
  TInt value -> Just value
  TIf op x y t e -> do
    a <- evaluate x env
    b <- evaluate y env
    evaluate (if compares op a b then t else e) env
  TBin op x y -> do
    a <- evaluate x env
    b <- evaluate y env
    case op of
      "+" -> Just (a + b)
      "-" -> Just (a - b)
      "*" -> Just (a * b)
      _ | b == 0 -> Nothing
      "/" -> Just (quotient a b)
      _ -> Just (remainder a b)
  _ -> Nothing

compares :: String -> Int64 -> Int64 -> Bool
compares op a b = case op of
  "=" -> a == b
  "<>" -> a /= b
  "<" -> a < b
  "<=" -> a <= b
  ">" -> a > b
  _ -> a >= b

showTree :: Tree -> String
showTree node = case node of
  TVar name -> name
  TInt value -> literal value
  TIf op x y t e ->
    "(if " ++ showTree x ++ " " ++ op ++ " " ++ showTree y ++ " then " ++ showTree t
      ++ " else "
      ++ showTree e
      ++ ")"
  TBin op x y -> "(" ++ showTree x ++ " " ++ op ++ " " ++ showTree y ++ ")"
  _ -> error "not an expression"

-- | @count@ functions of three arguments, and what they print.
arithmetic :: Int -> Int -> (String, String)
arithmetic seed count = go (seeded seed) count [] [] []
  where
    go _ 0 definitions calls expected =
      ( intercalate "\n" (reverse definitions ++ reverse calls) ++ "\n",
        intercalate "\n" (reverse expected) ++ "\n"
      )
    go g left definitions calls expected =
      let (depth, g1) = between 1 5 g
          (tree, g2) = expression depth g1
          made = count - left
          values = mapM (\(a, b, c) -> evaluate tree (env a b c)) arguments
       in case values of
            Nothing -> go g2 left definitions calls expected
            Just answers ->
              go
                g2
                (left - 1)
                ( ("fun f" ++ show made ++ " (a : int, b : int, c : int) : int = " ++ showTree tree)
                    : definitions
                )
                (reverse (map (call made) arguments) ++ calls)
                (reverse (map show answers) ++ expected)
    env a b c = Map.fromList [("a", a), ("b", b), ("c", c)]
    call made (a, b, c) =
      "val () = (printInt (f" ++ show made ++ " (" ++ intercalate ", " (map literal [a, b, c])
        ++ ")); print (\"\\n\"))"

-- -- the imperative half ------------------------------------------------------

statement :: Int -> [String] -> Int -> Chance -> (Tree, Int, Chance)
statement depth scope fresh g0
  | depth > 0 && r < 0.2 =
      let (op, g2) = pick orders g1
          (x, g3) = place scope g2
          (y, g4) = place scope g3
          (t, fresh', g5) = statement (depth - 1) scope fresh g4
          (e, fresh'', g6) = statement (depth - 1) scope fresh' g5
       in (TWhen op x y t e, fresh'', g6)
  | depth > 0 && r < 0.45 =
      let name = "i" ++ show (fresh + 1)
          (lo, g2) = between 0 2 g1
          (hi, g3) = between 2 5 g2
          (body, fresh', g4) = statement (depth - 1) (scope ++ [name]) (fresh + 1) g3
       in (TFor name lo hi body, fresh', g4)
  | depth > 0 && r < 0.55 =
      let (one, fresh', g2) = statement (depth - 1) scope fresh g1
          (two, fresh'', g3) = statement (depth - 1) scope fresh' g2
       in (TSeq [one, two], fresh'', g3)
  | r < 0.8 =
      let (name, g2) = pick vars g1
          (value, g3) = place scope g2
       in (TSet name value, fresh, g3)
  | otherwise =
      let (where', g2) = place scope g1
          (value, g3) = place scope g2
       in (TPut where' value, fresh, g3)
  where
    (r, g1) = roll g0

-- | An expression over the variables in scope and the array.
place :: [String] -> Chance -> (Tree, Chance)
place scope g0
  | r < 0.35 = let (name, g2) = pick scope g1 in (TVar name, g2)
  | r < 0.5 = let (value, g2) = pick constants g1 in (TInt value, g2)
  | r < 0.65 = let (inner, g2) = place scope g1 in (TGet inner, g2)
  | otherwise =
      let (op, g2) = pick ["+", "-", "*"] g1
          (x, g3) = place scope g2
          (y, g4) = place scope g3
       in (TBin op x y, g4)
  where
    (r, g1) = roll g0

-- | @index@ in the generated program: the remainder, made positive.
cell :: Int64 -> Int
cell value = fromIntegral ((value - quotient value (fromIntegral size) * fromIntegral size + fromIntegral size) `mod` fromIntegral size)

type World = (Map.Map String Int64, Map.Map Int Int64)

runPlace :: Tree -> World -> Int64
runPlace node world@(env, array) = case node of
  TVar name -> fromMaybe 0 (Map.lookup name env)
  TInt value -> value
  TGet inner -> fromMaybe 0 (Map.lookup (cell (runPlace inner world)) array)
  TBin op x y ->
    let a = runPlace x world
        b = runPlace y world
     in case op of "+" -> a + b; "-" -> a - b; _ -> a * b
  _ -> error "not a place"

runStatement :: Tree -> World -> World
runStatement node world@(env, array) = case node of
  TSet name value -> (Map.insert name (runPlace value world) env, array)
  TPut where' value -> (env, Map.insert (cell (runPlace where' world)) (runPlace value world) array)
  TSeq items -> foldl (flip runStatement) world items
  TWhen op x y t e ->
    let a = runPlace x world
        b = runPlace y world
     in runStatement (if compares op a b then t else e) world
  TFor name lo hi body ->
    foldl (\w i -> runStatement body (Map.insert name (fromIntegral i) (fst w), snd w)) world [lo .. hi]
  _ -> error "not a statement"

showPlace :: Tree -> String
showPlace node = case node of
  TGet inner -> "xs[index (" ++ showPlace inner ++ ")]"
  TBin op x y -> "(" ++ showPlace x ++ " " ++ op ++ " " ++ showPlace y ++ ")"
  _ -> showTree node

showStatement :: Tree -> String -> String
showStatement node indent = case node of
  TSet name value -> indent ++ name ++ " := " ++ showPlace value
  TPut where' value -> indent ++ "xs[index (" ++ showPlace where' ++ ")] := " ++ showPlace value
  TSeq items ->
    indent ++ "(\n"
      ++ intercalate ";\n" [showStatement i (indent ++ "  ") | i <- items]
      ++ "\n"
      ++ indent
      ++ ")"
  TWhen op x y t e ->
    indent ++ "if " ++ showPlace x ++ " " ++ op ++ " " ++ showPlace y ++ " then\n"
      ++ showStatement t (indent ++ "  ")
      ++ "\n"
      ++ indent
      ++ "else\n"
      ++ showStatement e (indent ++ "  ")
  TFor name lo hi body ->
    indent ++ "for " ++ name ++ " = " ++ show lo ++ " to " ++ show hi ++ " do\n"
      ++ showStatement body (indent ++ "  ")
  _ -> error "not a statement"

preamble :: String
preamble =
  intercalate
    "\n"
    [ "val xs = array (16, 0)",
      "fun index (n : int) : int =",
      "  let val r = n - n / 16 * 16 in",
      "    if r < 0 then r + 16 else r",
      "  end",
      ""
    ]

-- | A program of assignments, loops and branches over an array.
imperative :: Int -> Int -> (String, String)
imperative seed count = (intercalate "\n" lines' ++ "\n", intercalate "\n" expected ++ "\n")
  where
    body = build (seeded seed) count
    build _ 0 = []
    build g left =
      let (one, _, g') = statement 3 vars 0 g
       in one : build g' (left - 1)
    start = (Map.fromList [(name, 0) | name <- vars], Map.fromList [(i, 0) | i <- [0 .. size - 1]])
    (env, array) = foldl (flip runStatement) start body
    expected =
      [show (fromMaybe 0 (Map.lookup name env)) | name <- vars]
        ++ [show (fromMaybe 0 (Map.lookup i array)) | i <- [0 .. size - 1]]
    lines' =
      [preamble]
        ++ ["var " ++ name ++ " = 0" | name <- vars]
        ++ ["val () = ("]
        ++ [intercalate ";\n" [showStatement i "  " | i <- body]]
        ++ [")"]
        ++ ["val () = (printInt (" ++ name ++ "); print (\"\\n\"))" | name <- vars]
        ++ ["val () = for k = 0 to 15 do (printInt (xs[k]); print (\"\\n\"))"]
