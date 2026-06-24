{- |
Module      : Main
Description : Native Wire -> Amazon Braket OpenQASM single-circuit runner.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Compile one selected export of a native @use quantum.*@ Wire source, lower its
@\@quantum.realize@ frontier in-process (admission, host-binding resolution, and
the idempotency digest), emit OpenQASM 3, and either dry-run or submit it to Amazon
Braket. The AWS CLI binary is taken from @CORTEX_AWS_BIN@ (default @aws@); the host
authority is the Braket binding pack constructed here, never imported from Wire.
-}
module Main (main) where

import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy qualified as BSL
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr)
import Text.Read (readMaybe)

import Cortex.Quantum.Braket
  ( BraketSettings (..)
  , CircuitResult (..)
  , ExecMode (..)
  , SettingsFlags (..)
  , executeCircuit
  , preflightDevice
  , realBraketAws
  , resolveAwsBin
  , resolveBraketSettings
  , resolveExecMode
  , settingsBindingPack
  )
import Cortex.Quantum.Compile (compileExport, loadQuantumCompileEnv)
import Cortex.Quantum.Cost (costEstimateText)
import Cortex.Quantum.Plan (lowerCompiledRealize, renderRealizeError)
import Cortex.Wire.Executor (WireExecutorId (..))

main :: IO ()
main = do
  args <- getArgs
  outcome <- runMain args
  case outcome of
    Left err -> do
      TIO.hPutStrLn stderr ("wire-quantum-braket: " <> err)
      exitWith (ExitFailure 1)
    Right () -> pure ()

realizeExecutor :: WireExecutorId
realizeExecutor = WireExecutorId "quantum.realize"

runMain :: [String] -> IO (Either Text ())
runMain args =
  case parseArgs args of
    Left err -> pure (Left err)
    Right raw -> case raInput raw of
      Nothing -> pure (Left usage)
      Just input -> do
        resolved <- resolveSettings raw
        case resolved of
          Left err -> pure (Left err)
          Right (mode, settings) -> do
            envE <- loadQuantumCompileEnv
            case envE of
              Left err -> pure (Left err)
              Right env -> do
                compiledE <- compileExport env (raReturn raw) input
                case compiledE of
                  Left err -> pure (Left err)
                  Right circuit ->
                    case lowerCompiledRealize (settingsBindingPack settings) realizeExecutor circuit of
                      Left lowerErr -> pure (Left (renderRealizeError lowerErr))
                      Right lowering -> do
                        awsBin <- resolveAwsBin
                        let aws = realBraketAws awsBin (bsProfile settings) (bsRegion settings)
                        preflightE <- case mode of
                          Hardware -> preflightDevice aws (bsDeviceArn settings)
                          DryRun -> pure (Right ())
                        case preflightE of
                          Left err -> pure (Left err)
                          Right () -> do
                            outcomeE <- executeCircuit aws settings mode (T.pack input) lowering
                            case outcomeE of
                              Left err -> pure (Left err)
                              Right result -> do
                                emitOutput (raJson raw) mode settings result
                                pure (Right ())

usage :: Text
usage =
  "usage: wire-quantum-braket FILE [--return NAME] [--shots N] [--json] "
    <> "[--dry-run | --confirm-hardware] [--backend B] [--device-arn ARN] "
    <> "[--s3-bucket B] [--s3-prefix P] [--region R] [--profile P] "
    <> "[--poll-interval S] [--timeout S]"

emitOutput :: Bool -> ExecMode -> BraketSettings -> CircuitResult -> IO ()
emitOutput jsonOut mode settings result
  | jsonOut = do
      BSL.putStr (encodePretty (crJson result))
      BSL.putStr "\n"
  | otherwise =
      TIO.putStr . T.unlines $
        [ "execution: " <> (if mode == DryRun then "dry-run" else "hardware")
        , "device: " <> bsDeviceArn settings
        , "shots: " <> T.pack (show (bsShots settings))
        ]
          <> foldMap (\t -> ["estimated cost: $" <> t <> " USD"]) (costEstimateText (crCost result))

-- Argument parsing.

data RawArgs = RawArgs
  { raInput :: !(Maybe FilePath)
  , raReturn :: !(Maybe Text)
  , raShots :: !(Maybe Int)
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
  }

defaultRawArgs :: RawArgs
defaultRawArgs =
  RawArgs
    Nothing
    Nothing
    Nothing
    False
    False
    False
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing

parseArgs :: [String] -> Either Text RawArgs
parseArgs = go defaultRawArgs
  where
    go acc [] = Right acc
    go acc ("--return" : v : rest) = go acc {raReturn = Just (T.pack v)} rest
    go acc ("--shots" : v : rest) = withInt v "--shots" (\n -> acc {raShots = Just n}) rest
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
    go _ (flag : _) | "--" `isPrefixOf` flag = Left ("unknown or incomplete flag: " <> T.pack flag)
    go acc (positional : rest) = case raInput acc of
      Nothing -> go acc {raInput = Just positional} rest
      Just _ -> Left ("unexpected extra argument: " <> T.pack positional)
    withInt v flag update rest = case readMaybe v of
      Just n | n > 0 -> go (update n) rest
      _ -> Left (T.pack flag <> " expects a positive integer")

-- Settings resolution.

resolveSettings :: RawArgs -> IO (Either Text (ExecMode, BraketSettings))
resolveSettings raw = do
  settingsE <- resolveBraketSettings (settingsFlags raw)
  pure $ do
    settings <- settingsE
    mode <- resolveExecMode (raDryRun raw) (raConfirm raw)
    Right (mode, settings)

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
