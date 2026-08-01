-- | The command line.
--
-- The arguments are picked apart by hand rather than by @getOpt@, which stops
-- reading flags at the first thing that is not one: @wolv emit -s ssa prog.wol@
-- puts a flag after two of them, and every other tree in this repository accepts
-- that.
module Main (main) where

import Data.List (intercalate, isPrefixOf, isSuffixOf)
import System.Environment (getArgs)
import System.Exit
import System.IO
import Wolv.Driver

commands :: [String]
commands = ["build", "run", "emit", "check"]

usage :: String
usage =
  intercalate
    "\n"
    [ "usage: wolv <command> <file> [options]",
      "",
      "  build   compile and link an executable",
      "  run     build it and run it",
      "  emit    write one stage of the pipeline to standard output",
      "  check   types only",
      "",
      "  -o, --out PATH     where `build` should write the executable",
      "  -s, --stage NAME   which stage `emit` should show:",
      "                     " ++ intercalate ", " stages,
      "      --no-checks    leave out the nil, bounds and divide-by-zero checks",
      "      --no-opt       do not optimise the SSA",
      "      --max-regs N   pretend the machine has N registers, to make it spill"
    ]

-- | What the flags said, and what was left over.
data Arguments = Arguments
  { argOptions :: Options,
    argStage :: String,
    argOut :: Maybe String,
    argRest :: [String]
  }

parseArguments :: [String] -> Either String Arguments
parseArguments = go (Arguments defaultOptions "asm" Nothing [])
  where
    go acc [] = Right acc {argRest = reverse (argRest acc)}
    go acc (arg : rest)
      | arg `elem` ["-o", "--out"] = withValue (\v r -> go acc {argOut = Just v} r)
      | arg `elem` ["-s", "--stage"] =
          withValue $ \v r ->
            if v `elem` stages
              then go acc {argStage = v} r
              else Left ("no such stage as `" ++ v ++ "`")
      | arg == "--no-checks" = go acc {argOptions = (argOptions acc) {optChecks = False}} rest
      | arg == "--no-opt" = go acc {argOptions = (argOptions acc) {optOptimise = False}} rest
      | arg == "--max-regs" =
          withValue $ \v r -> case reads v of
            [(n, "")] | n > 0 -> go acc {argOptions = (argOptions acc) {optMaxRegs = Just n}} r
            _ -> Left "`--max-regs` wants a number"
      | length arg > 1 && "-" `isPrefixOf` arg = Left ("no such option as `" ++ arg ++ "`")
      | otherwise = go acc {argRest = arg : argRest acc} rest
      where
        withValue k = case rest of
          [] -> Left ("`" ++ arg ++ "` wants a value after it")
          (v : r) -> k v r

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  argv <- getArgs
  if any (`elem` ["-h", "--help"]) argv
    then putStrLn usage >> exitSuccess
    else case parseArguments argv of
      Left message -> complain message
      Right args -> case argRest args of
        [command, file]
          | command `elem` commands -> dispatch command file args
          | otherwise ->
              complain ("no such command as `" ++ command ++ "`: " ++ intercalate ", " commands)
        _ -> complain "wants a command and a file"

complain :: String -> IO a
complain message = do
  hPutStrLn stderr ("wolv: " ++ message)
  exitWith (ExitFailure 1)

dispatch :: String -> FilePath -> Arguments -> IO ()
dispatch command file args = do
  handle <- openFile file ReadMode
  hSetEncoding handle utf8
  source <- hGetContents handle
  let opts = argOptions args
  case command of
    "check" -> report (fmap (const "") (toIr source opts))
    "emit" -> report (stage source (argStage args) opts)
    "build" -> do
      done <- build source (maybe (dropSuffix file) id (argOut args)) opts
      report (fmap (const "") done)
    _ -> do
      tty <- hIsTerminalDevice stdin
      input <- if tty then pure "" else hSetEncoding stdin utf8 >> hGetContents stdin
      done <- run source opts input
      case done of
        Left failure -> fail' failure
        Right outcome -> do
          putStr (ouStdout outcome)
          hPutStr stderr (ouStderr outcome)
          exitWith (if ouCode outcome == 0 then ExitSuccess else ExitFailure (ouCode outcome))
  where
    report (Left failure) = fail' failure
    report (Right value) = putStr value
    fail' failure = do
      hPutStrLn stderr (showFailure file failure)
      exitWith (ExitFailure 1)

-- | A @.wol@ file becomes an executable of the same name without the suffix.
dropSuffix :: FilePath -> FilePath
dropSuffix file
  | ".wol" `isSuffixOf` file = take (length file - 4) file
  | otherwise = file ++ ".out"
