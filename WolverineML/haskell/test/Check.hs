-- | The smallest test harness that says what a failure was.
--
-- There is no HUnit here and no tasty: this tree builds with the packages GHC
-- ships with and nothing else, so the harness is thirty lines and the suite is
-- an 'IO' action that counts.
module Check
  ( Harness,
    newHarness,
    summary,
    test,
    skipped,
    expect,
    equal,
    includes,
    excludes,
  )
where

import Data.IORef
import Data.List (isInfixOf)

data Harness = Harness
  { hName :: IORef String,
    hRun :: IORef Int,
    hFailures :: IORef [String],
    hSkipped :: IORef Int
  }

newHarness :: IO Harness
newHarness = Harness <$> newIORef "" <*> newIORef 0 <*> newIORef [] <*> newIORef 0

-- | Name what comes next, so a failure inside it knows what it belonged to.
test :: Harness -> String -> IO () -> IO ()
test h name body = do
  writeIORef (hName h) name
  modifyIORef' (hRun h) (+ 1)
  body

skipped :: Harness -> String -> IO ()
skipped h why = do
  modifyIORef' (hSkipped h) (+ 1)
  putStrLn ("  (skipped: " ++ why ++ ")")

failure :: Harness -> String -> IO ()
failure h message = do
  name <- readIORef (hName h)
  modifyIORef' (hFailures h) (++ [name ++ ": " ++ message])

expect :: Harness -> String -> Bool -> IO ()
expect h what ok = if ok then pure () else failure h what

equal :: (Eq a, Show a) => Harness -> String -> a -> a -> IO ()
equal h what want got
  | want == got = pure ()
  | otherwise = failure h (what ++ "\n    want: " ++ show want ++ "\n    got:  " ++ show got)

includes :: Harness -> String -> String -> String -> IO ()
includes h what needle haystack =
  expect h (what ++ ": no `" ++ needle ++ "` in it") (needle `isInfixOf` haystack)

excludes :: Harness -> String -> String -> String -> IO ()
excludes h what needle haystack =
  expect h (what ++ ": `" ++ needle ++ "` is in it") (not (needle `isInfixOf` haystack))

-- | What happened, and whether the suite passed.
summary :: Harness -> IO Bool
summary h = do
  run <- readIORef (hRun h)
  failures <- readIORef (hFailures h)
  skips <- readIORef (hSkipped h)
  mapM_ (\f -> putStrLn ("FAIL " ++ f)) failures
  putStrLn
    ( show run ++ " tests, " ++ show (length failures) ++ " failures, "
        ++ show skips
        ++ " skipped"
    )
  pure (null failures)
