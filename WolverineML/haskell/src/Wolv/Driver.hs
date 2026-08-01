{-# LANGUAGE TupleSections #-}
-- | The pipeline, and the toolchain around it.
--
-- >     source ─lex─▶ tokens ─parse─▶ tree ─check─▶ typed tree ─lower─▶ CFG
-- >            ─ssa─▶ SSA ─opt─▶ SSA ─select─▶ machine IR ─regalloc─▶ coloured
-- >            ─emit─▶ ARMv8
--
-- Assembling and linking is left to a cross @gcc@, and running to
-- @qemu-aarch64@ when the machine underneath is not itself an ARM.
--
-- The pipeline is one function, stopped where the caller wants to look: a dump
-- is the pipeline halted, not a second description of it that has to be kept in
-- step with the first.
module Wolv.Driver
  ( Options (..),
    defaultOptions,
    stages,
    Failure (..),
    showFailure,
    toIr,
    compileModule,
    compileToAsm,
    stage,
    crossCc,
    emulator,
    toolchainReady,
    build,
    Outcome (..),
    run,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (try)
import Control.Monad (foldM, void)
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Foldable (asum)
import Data.Maybe (fromMaybe)
import System.Directory (findExecutable, removeDirectoryRecursive)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process
import Wolv.Allocator (allocateModule)
import Wolv.AstShow (showProgram)
import Wolv.Dag (showDag)
import Wolv.Diag
import Wolv.Emit
import Wolv.Ir
import Wolv.Lexer (dump, lexAll)
import Wolv.Lower (lower)
import qualified Wolv.Lower as Lower
import Wolv.Mach (verifyModule)
import Wolv.Opt (optimise)
import Wolv.OutOfSsa (destructModule)
import Wolv.Parser (parse)
import Wolv.Registers (Machine, limited, whole)
import Wolv.Select (graphs, selectModule)
import Wolv.Ssa (constructModule, splitCriticalEdges)
import Wolv.Typecheck (check)

data Options = Options
  { optChecks :: Bool,
    optOptimise :: Bool,
    optMaxRegs :: Maybe Int,
    optBorrowing :: Borrowing
  }

defaultOptions :: Options
defaultOptions = Options True True Nothing MayBorrow

stages :: [String]
stages = ["tokens", "ast", "ir", "ssa", "opt", "dag", "mach", "flat", "ra", "asm"]

-- | Everything that can go wrong before a program runs: the user's mistake, the
-- compiler's own check, or the toolchain's absence.
data Failure = Rejected WolvError | Broken String | Toolchain String

showFailure :: FilePath -> Failure -> String
showFailure path failure = case failure of
  Rejected e -> path ++ ":" ++ showSpan (errAt e) ++ ": " ++ errMessage e
  Broken message -> "wolv: " ++ message
  Toolchain message -> "wolv: " ++ message

machineOf :: Options -> Machine
machineOf opts = maybe whole limited (optMaxRegs opts)

toIr :: String -> Options -> Either Failure Module
toIr source opts = do
  prog <- either (Left . Rejected) Right (parse source >>= check)
  pure (lower prog (Lower.Options (optChecks opts)))

-- | What the pipeline is carrying: the module, and what the allocator decided
-- about each of its functions — empty until it has run that far.
type Carried = (Module, Map.Map String Allocation)

-- | The pipeline, named after the stage each step leaves behind.  A dump is this
-- list cut short, which is why there is one of these and not two: the order the
-- passes run in is written down once.
steps :: Options -> [(String, Carried -> Either Failure Carried)]
steps opts =
  [ ("ir", pure),
    ("ssa", onModule (pure . constructModule)),
    ("opt", onModule (pure . if optOptimise opts then optimise else id)),
    -- The DAGs are a view of this, taken without changing it.
    ("dag", onModule (pure . eachFunc splitCriticalEdges)),
    ("mach", onModule selected),
    ("flat", onModule (pure . destructModule)),
    ("ra", \(m, _) -> broken (allocateModule (machineOf opts) m))
  ]
  where
    onModule step (m, allocs) = (,allocs) <$> step m
    eachFunc g m = m {modFuncs = map g (modFuncs m)}
    selected m = let m' = selectModule m in broken (verifyModule m') >> pure m'
    broken = either (Left . Broken) Right

compileModule :: String -> Options -> String -> Either Failure Carried
compileModule source opts upto = do
  m <- toIr source opts
  -- Everything before the stage asked for, and the one that makes it.  A stage
  -- this list does not name — `asm` — wants the whole of it.
  let (before, rest) = break ((== upto) . fst) (steps opts)
  foldM (flip snd) (m, Map.empty) (before ++ take 1 rest)

compileToAsm :: String -> Options -> Either Failure String
compileToAsm source opts = do
  (m, allocs) <- compileModule source opts "asm"
  pure (emitModule (optBorrowing opts) m allocs)

-- | Run the pipeline as far as @name@, and show what it has by then.
stage :: String -> String -> Options -> Either Failure String
stage source name opts
  | name == "tokens" = either (Left . Rejected) (Right . dump) (lexAll source)
  | name == "ast" = either (Left . Rejected) (Right . showProgram) (parse source >>= check)
  | otherwise = do
      (m, allocs) <- compileModule source opts name
      pure $ case name of
        "dag" -> showDags m
        "asm" -> emitModule (optBorrowing opts) m allocs
        _ -> showModule m allocs

showDags :: Module -> String
showDags m =
  intercalate
    "\n\n"
    [ "fun " ++ fnLabel f ++ "\n"
        ++ intercalate "\n" [label ++ ":\n" ++ showDag g | (label, g) <- graphs f]
      | f <- modFuncs m
    ]
    ++ "\n"

-- -- the toolchain -----------------------------------------------------------

onArm :: IO Bool
onArm = do
  arch <- readProcessMaybe "uname" ["-m"] ""
  pure (fromMaybe "" (fmap (takeWhile (/= '\n')) arch) `elem` ["aarch64", "arm64"])

readProcessMaybe :: String -> [String] -> String -> IO (Maybe String)
readProcessMaybe program args input = do
  attempt <- try (readProcess program args input) :: IO (Either IOError String)
  pure (either (const Nothing) Just attempt)

crossCc :: IO (Either Failure String)
crossCc = do
  override <- lookupEnv "WOLV_CC"
  arm <- onArm
  found <-
    firstOf (["aarch64-linux-gnu-gcc", "aarch64-linux-gnu-cc", "aarch64-none-linux-gnu-gcc"]
               ++ ["cc" | arm] ++ ["gcc" | arm])
  pure $
    maybe
      (Left (Toolchain "no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC"))
      Right
      (override <|> found)

emulator :: IO (Either Failure [String])
emulator = do
  arm <- onArm
  if arm
    then pure (Right [])
    else do
      found <- firstOf ["qemu-aarch64", "qemu-aarch64-static"]
      pure $
        maybe
          (Left (Toolchain "no qemu-aarch64 found, and this machine is not an ARM"))
          (Right . (: []))
          found

-- | The first of these that is on the path.
firstOf :: [String] -> IO (Maybe FilePath)
firstOf names = asum <$> mapM findExecutable names

-- | Whether an end-to-end test can run at all, so that one can say it is
-- skipping.
toolchainReady :: IO Bool
toolchainReady = do
  cc <- crossCc
  qemu <- emulator
  pure (all isRight [void cc, void qemu])
  where
    isRight = either (const False) (const True)

runtimePath :: IO FilePath
runtimePath = do
  here <- findRuntime ["runtime/runtime.c", "../runtime/runtime.c"]
  pure (fromMaybe "runtime/runtime.c" here)
  where
    findRuntime [] = pure Nothing
    findRuntime (p : rest) = do
      ok <- try (readFile p) :: IO (Either IOError String)
      either (const (findRuntime rest)) (const (pure (Just p))) ok

build :: String -> FilePath -> Options -> IO (Either Failure ())
build source out opts = case compileToAsm source opts of
  Left failure -> pure (Left failure)
  Right asm -> do
    cc <- crossCc
    case cc of
      Left failure -> pure (Left failure)
      Right compiler -> do
        runtime <- runtimePath
        tmp <- makeTemporaryDirectory
        let path = tmp </> "program.s"
        writeFile path asm
        (code, _, errors) <-
          readProcessWithExitCode compiler ["-static", "-O2", "-o", out, path, runtime] ""
        removeDirectoryRecursive tmp
        pure $ case code of
          ExitSuccess -> Right ()
          _ -> Left (Toolchain ("the assembler refused it:\n" ++ errors))

-- | The exit code, what it printed, and what it printed on the way out.
data Outcome = Outcome {ouCode :: Int, ouStdout :: String, ouStderr :: String}

run :: String -> Options -> String -> IO (Either Failure Outcome)
run source opts input = do
  tmp <- makeTemporaryDirectory
  let binary = tmp </> "program"
  built <- build source binary opts
  case built of
    Left failure -> do removeDirectoryRecursive tmp; pure (Left failure)
    Right () -> do
      qemu <- emulator
      case qemu of
        Left failure -> do removeDirectoryRecursive tmp; pure (Left failure)
        Right prefix -> do
          let (program, args) = case prefix of
                [] -> (binary, [])
                (p : rest) -> (p, rest ++ [binary])
          (code, out, errors) <- readProcessWithExitCode program args input
          removeDirectoryRecursive tmp
          pure (Right (Outcome (case code of ExitSuccess -> 0; ExitFailure n -> n) out errors))

makeTemporaryDirectory :: IO FilePath
makeTemporaryDirectory = do
  out <- readProcess "mktemp" ["-d", "-t", "wolvXXXXXX"] ""
  pure (takeWhile (/= '\n') out)
