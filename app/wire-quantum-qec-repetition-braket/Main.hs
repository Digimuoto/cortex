{- |
Module      : Main
Description : Native distance-3 repetition-code QEC sweep over Amazon Braket.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Run the four exported repetition-code cases of @qec-repetition-realize.wire@ in
turn through the in-process native-Wire → Braket path (compile a selected export,
lower its @\@quantum.realize@ frontier, submit or dry-run), then render the
deterministic experiment report and gate on a per-circuit matching-shot threshold.
A single @get-device@ preflight runs before any task is created, so an offline
device fails once rather than after spawning tasks.
-}
module Main (main) where

import Data.Aeson (object, (.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory)
import System.IO (stderr)
import Text.Read (readMaybe)

import Cortex.Pulse.Lowering.Circuit (lrIdempotencyKey)
import Cortex.Quantum.Braket
  ( BraketAws
  , BraketSettings (..)
  , CircuitResult (..)
  , ExecMode (..)
  , ReconstructedCase (..)
  , SettingsFlags (..)
  , executeCircuit
  , preflightDevice
  , realBraketAws
  , reconstructCaseOutcome
  , resolveAwsBin
  , resolveBraketSettings
  , resolveExecMode
  , settingsBindingPack
  )
import Cortex.Quantum.Compile (compileExport, loadQuantumCompileEnv)
import Cortex.Quantum.Cost (costEstimateAmount)
import Cortex.Quantum.Diagram (renderCircuitDiagram)
import Cortex.Quantum.OpenQASM (emitOpenQASM3)
import Cortex.Quantum.Plan
  ( lowerCompiledRealize
  , quantumPlanMeasurements
  , realizeLowered
  , realizePlan
  , renderRealizeError
  )
import Cortex.Quantum.Provenance
  ( RedactionMode (..)
  , RunProvenance (..)
  , awsCliVersion
  , fileSha256
  , freshReportUuid
  , gitCommitSha
  )
import Cortex.Quantum.Qec
  ( CaseRow (..)
  , QecCase (..)
  , ReportInputs (..)
  , completedRow
  , dryRunRow
  , failedRow
  , qecCases
  , renderReport
  , reportDeviceInvariant
  , reportExitCode
  , rowsValue
  )
import Cortex.Quantum.ReportPath (qecRepetitionReportPath)
import Cortex.Wire.Contract (WireCompileEnv)
import Cortex.Wire.Executor (WireExecutorId (..))

main :: IO ()
main = do
  args <- getArgs
  outcome <- runSweep args
  case outcome of
    Left err -> do
      TIO.hPutStrLn stderr ("wire-quantum-qec-repetition-braket: " <> err)
      exitWith (ExitFailure 1)
    Right code -> exitWith (if code == 0 then ExitSuccess else ExitFailure code)

realizeExecutor :: WireExecutorId
realizeExecutor = WireExecutorId "quantum.realize"

{- | What produces the report rows: a live dry-run/hardware sweep, or a
reconstruction of an existing run from its task ARNs.
-}
data RunKind = LiveRun !ExecMode | ReconstructRun
  deriving stock (Eq, Show)

runSweep :: [String] -> IO (Either Text Int)
runSweep args =
  case parseArgs args of
    Left err -> pure (Left err)
    Right raw
      | raReconstruct raw -> runWith raw ReconstructRun
      | otherwise -> case resolveExecMode (raDryRun raw) (raConfirm raw) of
          Left err -> pure (Left err)
          Right mode -> runWith raw (LiveRun mode)

runWith :: RawArgs -> RunKind -> IO (Either Text Int)
runWith raw kind = do
  settingsE <- resolveBraketSettings (settingsFlags raw)
  case settingsE of
    Left err -> pure (Left err)
    Right settings -> do
      fileStampTime <- getCurrentTime
      let fileStamp = formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" fileStampTime
          outputFileE =
            traverse (qecRepetitionReportPath fileStamp (bsDeviceArn settings)) (raOutputDir raw)
      case outputFileE of
        Left err -> pure (Left err)
        Right outputFile -> do
          envE <- loadQuantumCompileEnv
          case envE of
            Left err -> pure (Left err)
            Right env -> do
              awsBin <- resolveAwsBin
              let aws = realBraketAws awsBin (bsProfile settings) (bsRegion settings)
              rows <- produceRows env aws settings kind raw
              runProvenance <- gatherRunProvenance kind awsBin settings raw
              now <- getCurrentTime
              let isoStamp = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
                  inputs =
                    ReportInputs
                      { riSource = T.pack (raSource raw)
                      , riBackend = bsDeviceArn settings
                      , riShots = bsShots settings
                      , riThreshold = raThreshold raw
                      , riCompletedAt = isoStamp
                      , riOutputPath = T.pack <$> outputFile
                      , riDryRun = kind == LiveRun DryRun
                      , riRows = rows
                      , riRunProvenance = runProvenance
                      , riRedaction = redactionMode raw
                      }
              case reportDeviceInvariant inputs of
                Left err -> pure (Left err)
                Right () -> emitReport raw outputFile rows inputs

emitReport :: RawArgs -> Maybe FilePath -> [CaseRow] -> ReportInputs -> IO (Either Text Int)
emitReport raw outputFile rows inputs = do
  let report = renderReport inputs
  case outputFile of
    Nothing -> pure ()
    Just path -> do
      createDirectoryIfMissing True (takeDirectory path)
      TIO.writeFile path report
      TIO.hPutStrLn stderr ("qec: wrote " <> T.pack path)
  if raJson raw
    then do
      BSL.putStr (encodePretty (object ["report" .= report, "rows" .= rowsValue rows]))
      BSL.putStr "\n"
    else TIO.putStr report
  pure (Right (reportExitCode rows))

-- | Gather run-level provenance (skipped for a dry run, which queues no task).
gatherRunProvenance :: RunKind -> FilePath -> BraketSettings -> RawArgs -> IO (Maybe RunProvenance)
gatherRunProvenance (LiveRun DryRun) _ _ _ = pure Nothing
gatherRunProvenance _ awsBin settings raw = do
  commit <- gitCommitSha
  wireSha <- fileSha256 (raSource raw)
  sdk <- awsCliVersion awsBin
  reportUuid <- freshReportUuid
  pure $
    Just
      RunProvenance
        { rpCortexCommit = commit
        , rpWireSourcePath = T.pack (raSource raw)
        , rpWireSourceSha256 = wireSha
        , rpRegion = bsRegion settings
        , rpSdkVersion = sdk
        , rpReportUuid = reportUuid
        }

redactionMode :: RawArgs -> RedactionMode
redactionMode raw = if raRedact raw then Redacted else Unredacted

produceRows :: WireCompileEnv -> BraketAws -> BraketSettings -> RunKind -> RawArgs -> IO [CaseRow]
produceRows env aws settings kind raw =
  case kind of
    LiveRun mode -> runLiveCases env aws settings mode raw
    ReconstructRun -> mapM (reconstructOneCase env aws settings raw) qecCases

runLiveCases :: WireCompileEnv -> BraketAws -> BraketSettings -> ExecMode -> RawArgs -> IO [CaseRow]
runLiveCases env aws settings mode raw = do
  preflightE <- case mode of
    Hardware -> preflightDevice aws (bsDeviceArn settings)
    DryRun -> pure (Right ())
  case preflightE of
    Left err -> pure [failedRow preflightCase err]
    Right () -> mapM (runCase env aws settings mode (raSource raw) (raThreshold raw)) qecCases

preflightCase :: QecCase
preflightCase = QecCase "preflight" "device preflight" "(preflight)" "" "" "" ""

runCase
  :: WireCompileEnv
  -> BraketAws
  -> BraketSettings
  -> ExecMode
  -> FilePath
  -> Int
  -> QecCase
  -> IO CaseRow
runCase env aws settings mode source threshold qec = do
  case mode of
    Hardware -> TIO.hPutStrLn stderr ("qec: running " <> qcReturn qec <> " on " <> bsDeviceArn settings)
    DryRun -> pure ()
  compiledE <- compileExport env (Just (qcReturn qec)) source
  case compiledE of
    Left err -> pure (failedRow qec err)
    Right circuit -> case lowerCompiledRealize (settingsBindingPack settings) realizeExecutor circuit of
      Left lowerErr -> pure (failedRow qec (renderRealizeError lowerErr))
      Right lowering -> do
        let plan = realizePlan lowering
            diagram = renderCircuitDiagram plan
            qasm = either (const Nothing) Just (emitOpenQASM3 (bsDeviceArn settings) plan)
            withCircuit row = row {rowDiagram = Just diagram, rowOpenQasm = qasm}
        outcomeE <- executeCircuit aws settings mode (T.pack source) lowering
        pure . withCircuit $ case outcomeE of
          Left err -> failedRow qec err
          Right result -> case (mode, crResult result) of
            (DryRun, _) -> dryRunRow qec (costEstimateAmount (crCost result))
            (Hardware, Just decoded) ->
              completedRow
                qec
                threshold
                (bsShots settings)
                decoded
                (costEstimateAmount (crCost result))
                (crProvenance result)
            (Hardware, Nothing) -> failedRow qec "hardware run returned no decoded result"

-- | Reconstruct one case's report row from its existing task ARN (no resubmit).
reconstructOneCase
  :: WireCompileEnv -> BraketAws -> BraketSettings -> RawArgs -> QecCase -> IO CaseRow
reconstructOneCase env aws settings raw qec =
  case lookup (qcKey qec) (raTaskArns raw) of
    Nothing ->
      pure (failedRow qec ("no --task ARN supplied for case " <> qcKey qec))
    Just taskArn -> do
      TIO.hPutStrLn stderr ("qec: reconstructing " <> qcReturn qec <> " from " <> taskArn)
      compiledE <- compileExport env (Just (qcReturn qec)) (raSource raw)
      case compiledE of
        Left err -> pure (failedRow qec err)
        Right circuit -> case lowerCompiledRealize (settingsBindingPack settings) realizeExecutor circuit of
          Left lowerErr -> pure (failedRow qec (renderRealizeError lowerErr))
          Right lowering -> do
            let plan = realizePlan lowering
                diagram = renderCircuitDiagram plan
                qasm = either (const Nothing) Just (emitOpenQASM3 (bsDeviceArn settings) plan)
                measurements = quantumPlanMeasurements plan
                idempotencyKey = lrIdempotencyKey (realizeLowered lowering)
                withCircuit row = row {rowDiagram = Just diagram, rowOpenQasm = qasm}
            outcomeE <- reconstructCaseOutcome aws settings measurements idempotencyKey taskArn
            pure . withCircuit $ case outcomeE of
              Left err -> failedRow qec err
              Right rc ->
                completedRow
                  qec
                  (raThreshold raw)
                  (bsShots settings)
                  (rcResult rc)
                  (costEstimateAmount (rcCost rc))
                  (Just (rcProvenance rc))

-- Argument parsing.

data RawArgs = RawArgs
  { raSource :: !FilePath
  , raShots :: !(Maybe Int)
  , raThreshold :: !Int
  , raOutputDir :: !(Maybe FilePath)
  , raJson :: !Bool
  , raDryRun :: !Bool
  , raConfirm :: !Bool
  , raBackend :: !(Maybe Text)
  , raDeviceArn :: !(Maybe Text)
  , raBucket :: !(Maybe Text)
  , raPrefix :: !(Maybe Text)
  , raRegion :: !(Maybe Text)
  , raProfile :: !(Maybe Text)
  , raPollInterval :: !(Maybe Int)
  , raTimeout :: !(Maybe Int)
  , raReconstruct :: !Bool
  , raTaskArns :: ![(Text, Text)]
  , raRedact :: !Bool
  }

defaultRawArgs :: RawArgs
defaultRawArgs =
  RawArgs
    { raSource = "examples/wire/qec-repetition-realize.wire"
    , raShots = Nothing
    , raThreshold = 90
    , raOutputDir = Nothing
    , raJson = False
    , raDryRun = False
    , raConfirm = False
    , raBackend = Nothing
    , raDeviceArn = Nothing
    , raBucket = Nothing
    , raPrefix = Nothing
    , raRegion = Nothing
    , raProfile = Nothing
    , raPollInterval = Nothing
    , raTimeout = Nothing
    , raReconstruct = False
    , raTaskArns = []
    , raRedact = True
    }

parseArgs :: [String] -> Either Text RawArgs
parseArgs = go defaultRawArgs
  where
    go acc [] = Right acc
    go acc ("--source" : v : rest) = go acc {raSource = v} rest
    go acc ("--shots" : v : rest) = withInt v "--shots" (\n -> acc {raShots = Just n}) rest
    go acc ("--threshold" : v : rest) = withInt v "--threshold" (\n -> acc {raThreshold = n}) rest
    go acc ("--output" : v : rest) = go acc {raOutputDir = Just v} rest
    go acc ("--json" : rest) = go acc {raJson = True} rest
    go acc ("--dry-run" : rest) = go acc {raDryRun = True} rest
    go acc ("--confirm-hardware" : rest) = go acc {raConfirm = True} rest
    go acc ("--backend" : v : rest) = go acc {raBackend = Just (T.pack v)} rest
    go acc ("--device-arn" : v : rest) = go acc {raDeviceArn = Just (T.pack v)} rest
    go acc ("--s3-bucket" : v : rest) = go acc {raBucket = Just (T.pack v)} rest
    go acc ("--s3-prefix" : v : rest) = go acc {raPrefix = Just (T.pack v)} rest
    go acc ("--region" : v : rest) = go acc {raRegion = Just (T.pack v)} rest
    go acc ("--profile" : v : rest) = go acc {raProfile = Just (T.pack v)} rest
    go acc ("--poll-interval" : v : rest) = withInt v "--poll-interval" (\n -> acc {raPollInterval = Just n}) rest
    go acc ("--timeout" : v : rest) = withInt v "--timeout" (\n -> acc {raTimeout = Just n}) rest
    go acc ("--reconstruct" : rest) = go acc {raReconstruct = True} rest
    go acc ("--task" : v : rest) = case parseTaskArg v of
      Left err -> Left err
      Right entry -> go acc {raTaskArns = raTaskArns acc <> [entry]} rest
    go acc ("--redact" : rest) = go acc {raRedact = True} rest
    go acc ("--no-redact" : rest) = go acc {raRedact = False} rest
    go _ (flag : _) = Left ("unknown or incomplete flag: " <> T.pack flag)
    withInt v flag update rest = case readMaybe v of
      Just n | n > 0 -> go (update n) rest
      _ -> Left (T.pack flag <> " expects a positive integer")

parseTaskArg :: String -> Either Text (Text, Text)
parseTaskArg raw =
  case break (== '=') raw of
    (caseKey, '=' : arn)
      | not (null caseKey) && not (null arn) -> Right (T.pack caseKey, T.pack arn)
    _ -> Left ("--task expects <case>=<task-arn>, got " <> T.pack raw)

settingsFlags :: RawArgs -> SettingsFlags
settingsFlags raw =
  SettingsFlags
    { sfShots = raShots raw
    , sfPollInterval = raPollInterval raw
    , sfTimeout = raTimeout raw
    , sfBackend = raBackend raw
    , sfDeviceArn = raDeviceArn raw
    , sfBucket = raBucket raw
    , sfPrefix = raPrefix raw
    , sfRegion = raRegion raw
    , sfProfile = raProfile raw
    }
