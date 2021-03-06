{-# LANGUAGE CPP #-}
module Report (
  runModules

#ifdef TEST
, Report
, Summary(..)
, ReportState (..)
, report
, report_
, reportFailure
, runProperty
, DocTestResult (..)
#endif
) where

import           Prelude hiding (putStr, putStrLn, error)
import           Data.Monoid
import           Control.Monad
import           Text.Printf (printf)
import           System.IO (hPutStrLn, hPutStr, stderr, hIsTerminalDevice)
import           Data.Char

import           Control.Monad.Trans.State
import           Control.Monad.IO.Class

import           Interpreter (Interpreter)
import qualified Interpreter
import           Parse
import           Location
import           Type
import           Property

-- | Summary of a test run.
data Summary = Summary {
  sExamples :: Int
, sTried    :: Int
, sErrors   :: Int
, sFailures :: Int
}

-- | Format a summary.
instance Show Summary where
  show (Summary examples tried errors failures) =
    printf "Examples: %d  Tried: %d  Errors: %d  Failures: %d" examples tried errors failures

-- | Sum up summaries.
instance Monoid Summary where
  mempty = Summary 0 0 0 0
  (Summary x1 x2 x3 x4) `mappend` (Summary y1 y2 y3 y4) = Summary (x1 + y1) (x2 + y2) (x3 + y3) (x4 + y4)

-- |
-- Run all examples from given modules, return true if there were
-- errors/failures.
runModules :: Int -> Interpreter -> [Module DocTest] -> IO Bool
runModules exampleCount repl modules = do
  isInteractive <- hIsTerminalDevice stderr
  ReportState _ _ s <- (`execStateT` ReportState 0 isInteractive mempty {sExamples = exampleCount}) $ do
    forM_ modules $ runModule repl

    -- report final summary
    gets (show . reportStateSummary) >>= report

  return (sErrors s /= 0 || sFailures s /= 0)

-- | A monad for generating test reports.
type Report = StateT ReportState IO

data ReportState = ReportState {
  reportStateCount        :: Int     -- ^ characters on the current line
, reportStateInteractive  :: Bool    -- ^ should intermediate results be printed?
, reportStateSummary      :: Summary -- ^ test summary
}

-- | Add output to the report.
report :: String -> Report ()
report msg = do
  overwrite msg

  -- add a newline, this makes the output permanent
  liftIO $ hPutStrLn stderr ""
  modify (\st -> st {reportStateCount = 0})

-- | Add intermediate output to the report.
--
-- This will be overwritten by subsequent calls to `report`/`report_`.
-- Intermediate out may not contain any newlines.
report_ :: String -> Report ()
report_ msg = do
  f <- gets reportStateInteractive
  when f $ do
    overwrite msg
    modify (\st -> st {reportStateCount = length msg})

-- | Add output to the report, overwrite any intermediate out.
overwrite :: String -> Report ()
overwrite msg = do
  n <- gets reportStateCount
  let str | 0 < n     = "\r" ++ msg ++ replicate (n - length msg) ' '
          | otherwise = msg
  liftIO (hPutStr stderr str)

-- | Run all examples from given module.
runModule :: Interpreter -> Module DocTest -> Report ()
runModule repl (Module name examples) = do
  forM_ examples $ \e -> do

    -- report intermediate summary
    gets (show . reportStateSummary) >>= report_

    r <- liftIO $ runDocTest repl name e
    case r of
      Success ->
        success
      Error (Located loc expression) err -> do
        report (printf "### Error in %s: expression `%s'" (show loc) expression)
        report err
        error
      InteractionFailure (Located loc (Interaction expression expected)) actual -> do
        report (printf "### Failure in %s: expression `%s'" (show loc) expression)
        reportFailure expected actual
        failure
      PropertyFailure (Located loc expression) msg -> do
        report (printf "### Failure in %s: expression `%s'" (show loc) expression)
        report msg
        failure
  where
    success = updateSummary (Summary 0 1 0 0)
    failure = updateSummary (Summary 0 1 0 1)
    error   = updateSummary (Summary 0 1 1 0)

    updateSummary summary = do
      ReportState n f s <- get
      put (ReportState n f $ s `mappend` summary)

reportFailure :: [String] -> [String] -> Report ()
reportFailure expected actual = do
  outputLines "expected: " expected
  outputLines " but got: " actual
  where

    -- print quotes if any line ends with trailing whitespace
    printQuotes = any isSpace (map last . filter (not . null) $ expected ++ actual)

    -- use show to escape special characters in output lines if any output line
    -- contains any unsafe character
    escapeOutput = any (not . isSafe) (concat $ expected ++ actual)

    isSafe :: Char -> Bool
    isSafe c = c == ' ' || (isPrint c && (not . isSpace) c)

    outputLines message l_ = case l of
      x:xs -> do
        report (message ++ x)
        let padding = replicate (length message) ' '
        forM_ xs $ \y -> report (padding ++ y)
      []   ->
        report message
      where
        l | printQuotes || escapeOutput = map show l_
          | otherwise                   = l_

runDocTest :: Interpreter -> String -> DocTest -> IO DocTestResult
runDocTest repl module_ docTest = do
  _ <- Interpreter.eval repl   ":reload"
  _ <- Interpreter.eval repl $ ":m *" ++ module_
  case docTest of
    Example xs -> runExample repl xs
    Property p -> runProperty repl p

-- |
-- Execute all expressions from given example in given
-- 'Interpreter' and verify the output.
--
-- The interpreter state is zeroed with @:reload@ before executing the
-- expressions.  This means that you can reuse the same
-- 'Interpreter' for several calls to `runExample`.
runExample :: Interpreter -> [Located Interaction] -> IO DocTestResult
runExample repl = go
  where
    go (i@(Located loc (Interaction expression expected)) : xs) = do
      r <- fmap lines `fmap` Interpreter.safeEval repl expression
      case r of
        Left err -> do
          return (Error (Located loc expression) err)
        Right actual -> do
          if expected /= actual
            then
              return (InteractionFailure i actual)
            else
              go xs
    go [] = return Success
