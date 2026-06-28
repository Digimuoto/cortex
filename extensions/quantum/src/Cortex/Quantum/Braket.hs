{- |
Module      : Cortex.Quantum.Braket
Description : Amazon Braket transport and realized-circuit execution.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The host-side Amazon Braket driver: it resolves device/region/credential settings,
lowers a realized circuit to OpenQASM, and submits it through the AWS CLI. The AWS
surface is captured by the 'BraketAws' record so the orchestration (preflight,
create, poll, fetch, decode) is exercised against a fixture in tests without any
network or credentials; 'realBraketAws' is the production implementation that
shells out to @aws@.

This is host/runtime material (ADR 0054): it carries the AWS authority a Wire
package never does. The realize lowering it consumes already passed admission and
host-binding resolution through 'Cortex.Quantum.Plan.lowerCompiledRealize'.
-}
module Cortex.Quantum.Braket
  ( -- * Settings
    BraketSettings (..)
  , SettingsFlags (..)
  , resolveDeviceArn
  , resolveBraketSettings
  , resolveExecMode
  , resolveAwsBin

    -- * The AWS transport seam
  , BraketAws (..)
  , CreateTaskRequest (..)
  , realBraketAws
  , buildActionPayload
  , braketCreateTaskClientToken
  , settingsBindingPack

    -- * Orchestration
  , ExecMode (..)
  , CircuitResult (..)
  , preflightDevice
  , executeCircuit
  , reconstructCaseOutcome
  , ReconstructedCase (..)
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (Value (..), eitherDecodeStrict, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock (UTCTime, addUTCTime, diffUTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (hSetBinaryMode, stderr)
import System.Process
  ( CreateProcess (..)
  , StdStream (..)
  , proc
  , readCreateProcessWithExitCode
  , waitForProcess
  , withCreateProcess
  )
import Text.Read (readMaybe)

import Cortex.Capability.BindingPack (HostBindingPack)
import Cortex.Capability.BindingPack.Braket (BraketConfig (..), braketBindingPack)
import Cortex.Pulse.Lowering.Circuit (LoweredExternalCall (..))
import Cortex.Quantum.Cost
  ( CostEstimate
  , CostOverrides (..)
  , TaskMeta (..)
  , costEstimateToJSON
  , estimateTaskCost
  , estimatedCostDouble
  )
import Cortex.Quantum.Diagram (renderCircuitDiagram)
import Cortex.Quantum.OpenQASM (emitOpenQASM3)
import Cortex.Quantum.Plan
  ( Measurement
  , QuantumPlan (..)
  , RealizeLowering (..)
  )
import Cortex.Quantum.Provenance
  ( CaseProvenance
  , ClientTokenSource (..)
  , ProvenanceSources (..)
  , caseProvenanceJSON
  , cpRequestedShots
  , extractCaseProvenance
  , sha256OfBytes
  , taskUuidFromArn
  )
import Cortex.Quantum.Result
  ( QuantumResult (..)
  , completeCounts
  , completeCountsValue
  , countsValue
  , decodeBraketResult
  , labeledCountsValue
  , measurementsValue
  , outputCountsValue
  )

-- | Resolved Braket execution settings (the Main builds this from flags + env).
data BraketSettings = BraketSettings
  { bsDeviceArn :: !Text
  , bsRegion :: !Text
  , bsBucket :: !(Maybe Text)
  , bsPrefix :: !Text
  , bsProfile :: !(Maybe Text)
  , bsShots :: !Int
  , bsPollInterval :: !Int
  , bsTimeout :: !Int
  , bsOverrides :: !CostOverrides
  }
  deriving stock (Show)

{- | Resolve a Braket device ARN. An explicit @--device-arn@ (or its env default)
wins; otherwise a logical @--backend@ name maps to a managed-simulator ARN (or
passes a raw ARN through); otherwise the SV1 default. Unknown logical backend
names are errors, not silent SV1 fallbacks.
-}
resolveDeviceArn :: Maybe Text -> Maybe Text -> Maybe Text -> Either Text Text
resolveDeviceArn deviceFlag backend envArn =
  case deviceFlag <|> envArn of
    Just arn -> Right arn
    Nothing -> maybe (Right defaultSv1Arn) backendArn backend
  where
    backendArn raw = case T.toLower (T.strip raw) of
      "sv1" -> Right (simulatorArn "sv1")
      "tn1" -> Right (simulatorArn "tn1")
      "dm1" -> Right (simulatorArn "dm1")
      _
        | "arn:" `T.isPrefixOf` raw -> Right raw
        | otherwise ->
            Left
              ( "unknown Braket backend "
                  <> T.pack (show raw)
                  <> "; expected sv1, tn1, dm1, or an explicit ARN"
              )

defaultSv1Arn :: Text
defaultSv1Arn = simulatorArn "sv1"

simulatorArn :: Text -> Text
simulatorArn name = "arn:aws:braket:::device/quantum-simulator/amazon/" <> name

{- | Construct the host Braket binding pack from resolved settings. The binding
pack carries the AWS authority a Wire package never does (ADR 0054).
-}
settingsBindingPack :: BraketSettings -> HostBindingPack
settingsBindingPack settings =
  braketBindingPack
    BraketConfig
      { braketRegion = bsRegion settings
      , braketDeviceArn = bsDeviceArn settings
      , braketS3Bucket = fromMaybe "" (bsBucket settings)
      , braketProfile = bsProfile settings
      }

-- | A create-quantum-task request payload.
data CreateTaskRequest = CreateTaskRequest
  { ctrDeviceArn :: !Text
  , ctrShots :: !Int
  , ctrS3Bucket :: !Text
  , ctrS3Prefix :: !Text
  , ctrAction :: !Text
  , ctrClientToken :: !Text
  }
  deriving stock (Eq, Show)

{- | The Amazon Braket transport surface. Fakeable in tests; 'realBraketAws' is
the production implementation.
-}
data BraketAws = BraketAws
  { awsGetDevice :: Text -> IO (Either Text Value)
  , awsCreateTask :: CreateTaskRequest -> IO (Either Text Text)
  , awsGetTask :: Text -> IO (Either Text Value)
  , awsFetchResult :: Text -> IO (Either Text BS.ByteString)
  {- ^ Fetch a result object's exact bytes (so the @sha256@ matches AWS's
  artifact), not a re-encoded value.
  -}
  }

-- | The production AWS transport: shells out to the @aws@ CLI.
realBraketAws :: FilePath -> Maybe Text -> Text -> BraketAws
realBraketAws awsBin profile region =
  BraketAws
    { awsGetDevice = \arn ->
        runAws awsBin profile region ["braket", "get-device", "--device-arn", arn, "--output", "json"]
          >>= pure . (>>= parseJsonObject)
    , awsCreateTask = \req -> do
        result <-
          runAws
            awsBin
            profile
            region
            [ "braket"
            , "create-quantum-task"
            , "--device-arn"
            , ctrDeviceArn req
            , "--shots"
            , tshow (ctrShots req)
            , "--output-s3-bucket"
            , ctrS3Bucket req
            , "--output-s3-key-prefix"
            , ctrS3Prefix req
            , "--action"
            , ctrAction req
            , "--client-token"
            , ctrClientToken req
            , "--query"
            , "quantumTaskArn"
            , "--output"
            , "text"
            ]
        pure $ case result of
          Left err -> Left err
          Right out ->
            let arn = T.strip out
             in if "arn:aws:braket:" `T.isPrefixOf` arn
                  then Right arn
                  else Left "Braket task creation did not return a task ARN"
    , awsGetTask = \arn ->
        runAws
          awsBin
          profile
          region
          ["braket", "get-quantum-task", "--quantum-task-arn", arn, "--output", "json"]
          >>= pure . (>>= parseJsonObject)
    , awsFetchResult = \uri ->
        runAwsBytes awsBin profile region ["s3", "cp", uri, "-"]
    }

-- The full AWS CLI argument vector: positional args, then @--profile@ (when
-- non-empty), then @--region@.
awsArgs :: Maybe Text -> Text -> [Text] -> [String]
awsArgs profile region args =
  let profileArgs = maybe [] (\p -> if T.null p then [] else ["--profile", p]) profile
      regionArgs = if T.null region then [] else ["--region", region]
   in map T.unpack (args <> profileArgs <> regionArgs)

-- Run the AWS CLI, capturing stdout as decoded text (for JSON/text responses).
runAws :: FilePath -> Maybe Text -> Text -> [Text] -> IO (Either Text Text)
runAws awsBin profile region args = do
  (code, out, err) <- readCreateProcessWithExitCode (proc awsBin (awsArgs profile region args)) ""
  pure $ case code of
    ExitSuccess -> Right (T.pack out)
    ExitFailure c ->
      let detail = case T.strip (T.pack err) of
            e | T.null e -> T.strip (T.pack out)
            e -> e
       in Left ("aws " <> T.unwords (take 4 args) <> " ... failed (" <> tshow c <> "): " <> detail)

{- | Run the AWS CLI capturing stdout as exact raw bytes (no locale decode), so a
fetched @results.json@ hashes to the same @sha256@ as @aws s3 cp <uri> - | sha256sum@.
Child stderr is inherited rather than piped, so there is no read-order deadlock.
-}
runAwsBytes :: FilePath -> Maybe Text -> Text -> [Text] -> IO (Either Text BS.ByteString)
runAwsBytes awsBin profile region args =
  withCreateProcess (proc awsBin (awsArgs profile region args)) {std_out = CreatePipe} run
  where
    run _ (Just out) _ ph = do
      hSetBinaryMode out True
      bytes <- BS.hGetContents out
      code <- waitForProcess ph
      pure $ case code of
        ExitSuccess -> Right bytes
        ExitFailure c -> Left ("aws " <> T.unwords (take 4 args) <> " ... failed (" <> tshow c <> ")")
    run _ Nothing _ _ = pure (Left "aws command did not provide a stdout stream")

parseJsonObject :: Text -> Either Text Value
parseJsonObject raw =
  case eitherDecodeStrict (TE.encodeUtf8 (T.strip raw)) of
    Right value@(Object _) -> Right value
    Right _ -> Left "aws command did not return a JSON object"
    Left err -> Left ("aws command returned non-JSON output: " <> T.pack err)

-- | Parse the exact fetched result bytes into a JSON value.
parseResultBytes :: BS.ByteString -> Either Text Value
parseResultBytes raw =
  case eitherDecodeStrict raw of
    Right value -> Right value
    Left err -> Left ("could not parse Braket result JSON: " <> T.pack err)

-- | The Braket OpenQASM action payload for @--action@.
buildActionPayload :: Text -> Text
buildActionPayload qasm =
  TE.decodeUtf8 . BSL.toStrict . encode $
    object
      [ "braketSchemaHeader"
          .= object ["name" .= ("braket.ir.openqasm.program" :: Text), "version" .= ("1" :: Text)]
      , "source" .= qasm
      ]

{- | AWS Braket's @client-token@ identifies one concrete create request, not just
the abstract external-call payload. Hash the payload digest together with every parameter that
can change the create request so a rerun with different shots/device/S3/action
gets a distinct token, while a retry of the exact same request reuses it.
-}
braketCreateTaskClientToken :: Text -> Text -> Text -> Int -> Text -> Text -> Text -> Text
braketCreateTaskClientToken planIdempotencyKey region deviceArn shots bucket prefix action =
  digestText
    ( T.intercalate
        "\n"
        [ "braket-create-quantum-task-v1"
        , "plan=" <> planIdempotencyKey
        , "region=" <> region
        , "device=" <> deviceArn
        , "shots=" <> tshow shots
        , "bucket=" <> bucket
        , "prefix=" <> prefix
        , "action=" <> action
        ]
    )

-- | What to do with a realized circuit.
data ExecMode = DryRun | Hardware
  deriving stock (Eq, Show)

{- | The execution result: the runner JSON object, the decoded result (hardware
only), and the cost estimate.
-}
data CircuitResult = CircuitResult
  { crJson :: !Value
  , crResult :: !(Maybe QuantumResult)
  , crCost :: !CostEstimate
  , crProvenance :: !(Maybe CaseProvenance)
  }

-- | Preflight a device with @get-device@, failing unless it is @ONLINE@.
preflightDevice :: BraketAws -> Text -> IO (Either Text ())
preflightDevice aws deviceArn = do
  deviceE <- awsGetDevice aws deviceArn
  pure $ case deviceE of
    Left err -> Left err
    Right device ->
      case objText "deviceStatus" device of
        Just "ONLINE" -> Right ()
        status ->
          let name = maybe deviceArn id (objText "deviceName" device)
           in Left ("Braket device " <> name <> " is not available. Status = " <> maybe "UNKNOWN" id status)

{- | Execute a realized circuit: dry-run lowers and prices it without submitting;
hardware submits, polls, fetches, and decodes a correlated 'QuantumResult'.
-}
executeCircuit
  :: BraketAws -> BraketSettings -> ExecMode -> Text -> RealizeLowering -> IO (Either Text CircuitResult)
executeCircuit aws settings mode source lowering =
  case emitOpenQASM3 deviceArn plan of
    Left err -> pure (Left err)
    Right qasm -> case mode of
      DryRun -> pure (Right (dryRunResult qasm))
      Hardware -> runHardware qasm
  where
    plan = realizePlan lowering
    measurements = quantumPlanMeasurements plan
    deviceArn = bsDeviceArn settings
    shots = bsShots settings
    overrides = bsOverrides settings
    idempotencyKey = lrIdempotencyKey (realizeLowered lowering)
    backendLabel = T.takeWhileEnd (/= '/') deviceArn

    dryRunResult qasm =
      let cost = estimateTaskCost overrides deviceArn shots Nothing
       in CircuitResult
            { crJson =
                object
                  [ "execution" .= ("dry_run" :: Text)
                  , "source" .= source
                  , "backend" .= backendLabel
                  , "backend_family" .= ("amazon_braket" :: Text)
                  , "device_arn" .= deviceArn
                  , "shots" .= shots
                  , "openqasm3" .= qasm
                  , "circuit_diagram" .= renderCircuitDiagram plan
                  , "idempotency_key" .= idempotencyKey
                  , "measurements" .= measurementsValue measurements
                  , "estimated_cost_usd" .= estimatedCostDouble cost
                  , "cost_estimate" .= costEstimateToJSON cost
                  ]
            , crResult = Nothing
            , crCost = cost
            , crProvenance = Nothing
            }

    runHardware qasm =
      case bsBucket settings of
        Nothing -> pure (Left "Amazon Braket execution needs CORTEX_BRAKET_BUCKET or --s3-bucket")
        Just bucket -> do
          runPrefix <- runS3Prefix (bsPrefix settings)
          let action = buildActionPayload qasm
              clientToken =
                braketCreateTaskClientToken
                  idempotencyKey
                  (bsRegion settings)
                  deviceArn
                  shots
                  bucket
                  runPrefix
                  action
          let request =
                CreateTaskRequest
                  { ctrDeviceArn = deviceArn
                  , ctrShots = shots
                  , ctrS3Bucket = bucket
                  , ctrS3Prefix = runPrefix
                  , ctrAction = action
                  , ctrClientToken = clientToken
                  }
          createE <- awsCreateTask aws request
          case createE of
            Left err -> pure (Left err)
            Right taskArn -> do
              progress ("submitted Braket task " <> taskArn <> "; waiting for completion")
              deadline <- addUTCTime (fromIntegral (max 0 (bsTimeout settings))) <$> getCurrentTime
              taskE <- pollTask aws taskArn (bsPollInterval settings) deadline
              case taskE of
                Left err -> pure (Left err)
                Right task -> fetchAndDecode bucket runPrefix taskArn clientToken task qasm

    fetchAndDecode bucket runPrefix taskArn clientToken task qasm =
      case taskResultUri task of
        Left err -> pure (Left err)
        Right uri -> do
          resultE <- awsFetchResult aws uri
          pure $ do
            raw <- resultE
            value <- parseResultBytes raw
            counts <- decodeBraketResult measurements value
            prov <-
              extractCaseProvenance
                ProvenanceSources
                  { psTaskValue = task
                  , psResultValue = value
                  , psResultRawSha256 = sha256OfBytes raw
                  , psExpectedDeviceArn = deviceArn
                  , psClientToken = Just clientToken
                  , psClientTokenSource = TokenExact
                  }
            let result = QuantumResult shots measurements counts
                completeResult = QuantumResult shots measurements (completeCounts result)
                cost = estimateTaskCost overrides deviceArn shots (Just (taskMeta task))
            Right
              CircuitResult
                { crJson =
                    object
                      [ "execution" .= ("hardware" :: Text)
                      , "source" .= source
                      , "backend" .= backendLabel
                      , "backend_family" .= ("amazon_braket" :: Text)
                      , "device_arn" .= deviceArn
                      , "task_arn" .= taskArn
                      , "status" .= publicStatus (taskStatus task)
                      , "shots" .= shots
                      , "idempotency_key" .= idempotencyKey
                      , "counts" .= countsValue counts
                      , "complete_counts" .= completeCountsValue result
                      , "labeled_counts" .= labeledCountsValue result
                      , "complete_labeled_counts" .= labeledCountsValue completeResult
                      , "output_counts" .= outputCountsValue result
                      , "complete_output_counts" .= outputCountsValue completeResult
                      , "measurements" .= measurementsValue measurements
                      , "region" .= bsRegion settings
                      , "s3_bucket" .= bucket
                      , "s3_prefix" .= runPrefix
                      , "result_s3_uri" .= uri
                      , "openqasm3" .= qasm
                      , "circuit_diagram" .= renderCircuitDiagram plan
                      , "estimated_cost_usd" .= estimatedCostDouble cost
                      , "cost_estimate" .= costEstimateToJSON cost
                      , "provenance" .= caseProvenanceJSON prov
                      ]
                , crResult = Just result
                , crCost = cost
                , crProvenance = Just prov
                }

{- | One case reconstructed from an existing task ARN: the decoded result, the
captured provenance, and the completion-time cost estimate.
-}
data ReconstructedCase = ReconstructedCase
  { rcResult :: !QuantumResult
  , rcProvenance :: !CaseProvenance
  , rcCost :: !CostEstimate
  }

{- | Reconstruct one case from an existing quantum-task ARN: fetch its metadata
and result from AWS and capture provenance without resubmitting (so an already
paid run is regenerated, not rerun). The plan idempotency key lets the client
token be recomputed from the recovered create parameters; the device invariant
still holds the task's @deviceId@ to the runner's resolved device.
-}
reconstructCaseOutcome
  :: BraketAws
  -> BraketSettings
  -> [Measurement]
  -> Text
  -- ^ plan idempotency key
  -> Text
  -- ^ the existing quantum-task ARN
  -> IO (Either Text ReconstructedCase)
reconstructCaseOutcome aws settings measurements idempotencyKey taskArn = do
  taskE <- awsGetTask aws taskArn
  case taskE of
    Left err -> pure (Left err)
    Right task -> case taskResultUri task of
      Left err -> pure (Left err)
      Right uri -> do
        resultE <- awsFetchResult aws uri
        pure $ do
          raw <- resultE
          value <- parseResultBytes raw
          counts <- decodeBraketResult measurements value
          let (clientToken, tokenSource) =
                recoverClientToken settings idempotencyKey task value taskArn
          prov <-
            extractCaseProvenance
              ProvenanceSources
                { psTaskValue = task
                , psResultValue = value
                , psResultRawSha256 = sha256OfBytes raw
                , psExpectedDeviceArn = bsDeviceArn settings
                , psClientToken = clientToken
                , psClientTokenSource = tokenSource
                }
          let shots = case cpRequestedShots prov of
                0 -> bsShots settings
                n -> n
              result = QuantumResult shots measurements counts
              cost = estimateTaskCost (bsOverrides settings) (bsDeviceArn settings) shots (Just (taskMeta task))
          Right (ReconstructedCase result prov cost)

{- | Recompute the create-task client token from parameters recovered from the
task metadata and result. The S3 key prefix is the @outputS3Directory@ with its
trailing @/<taskUUID>@ removed (Braket's default key layout).
-}
recoverClientToken
  :: BraketSettings -> Text -> Value -> Value -> Text -> (Maybe Text, ClientTokenSource)
recoverClientToken settings idempotencyKey task result taskArn =
  case (objText "outputS3Bucket" task, objText "outputS3Directory" task, source, shots) of
    (Just bucket, Just directory, Just src, Just shotCount)
      | not (T.null bucket) && not (T.null src) ->
          ( Just
              ( braketCreateTaskClientToken
                  idempotencyKey
                  (bsRegion settings)
                  (bsDeviceArn settings)
                  shotCount
                  bucket
                  (recoverPrefix directory (taskUuidFromArn taskArn))
                  (buildActionPayload src)
              )
          , TokenRecomputed
          )
    _ -> (Nothing, TokenUnavailable)
  where
    source = objPath ["additionalMetadata", "action", "source"] result >>= asTextValue
    shots = objPath ["taskMetadata", "shots"] result >>= asIntValue
    asTextValue (String t) = Just t
    asTextValue _ = Nothing
    asIntValue (Number n) = case properFraction n of
      (i, frac) | frac == 0 -> Just (i :: Int)
      _ -> Nothing
    asIntValue _ = Nothing

recoverPrefix :: Text -> Text -> Text
recoverPrefix directory uuid =
  let trimmed = T.dropWhileEnd (== '/') directory
   in fromMaybe trimmed (T.stripSuffix ("/" <> uuid) trimmed)

-- Poll a task until a terminal status, bounded by an absolute deadline.
pollTask :: BraketAws -> Text -> Int -> UTCTime -> IO (Either Text Value)
pollTask aws taskArn pollInterval deadline = do
  now <- getCurrentTime
  if now >= deadline
    then pure (pollTimeout taskArn)
    else do
      taskE <- awsGetTask aws taskArn
      case taskE of
        Left err -> pure (Left err)
        Right task ->
          let status = taskStatus task
           in if status `elem` terminalStatuses
                then
                  if status == "COMPLETED"
                    then pure (Right task)
                    else
                      pure (Left ("Braket task " <> taskArn <> " ended with status " <> status <> failureDetail task))
                else
                  if status `elem` runningStatuses
                    then do
                      afterPoll <- getCurrentTime
                      let remainingMicros = diffMicros deadline afterPoll
                          sleepMicros = min (secondsMicros pollInterval) remainingMicros
                      if sleepMicros <= 0
                        then pure (pollTimeout taskArn)
                        else do
                          progress
                            ( "Braket task "
                                <> taskArn
                                <> " status="
                                <> status
                                <> "; polling again in "
                                <> formatMicrosAsSeconds sleepMicros
                                <> "s"
                            )
                          threadDelay sleepMicros
                          pollTask aws taskArn pollInterval deadline
                    else pure (Left ("Braket task " <> taskArn <> " returned unexpected status " <> status))

pollTimeout :: Text -> Either Text Value
pollTimeout taskArn = Left ("timed out waiting for Braket task " <> taskArn)

secondsMicros :: Int -> Int
secondsMicros seconds = max 1 seconds * 1000000

diffMicros :: UTCTime -> UTCTime -> Int
diffMicros later earlier =
  max 0 (floor (nominalDiffTimeToSeconds (diffUTCTime later earlier) * 1000000))

formatMicrosAsSeconds :: Int -> Text
formatMicrosAsSeconds micros =
  let (whole, fraction) = micros `quotRem` 1000000
   in if fraction == 0
        then tshow whole
        else tshow whole <> "." <> T.justifyRight 6 '0' (tshow fraction)

terminalStatuses :: [Text]
terminalStatuses = ["COMPLETED", "FAILED", "CANCELLED", "CANCELED"]

runningStatuses :: [Text]
runningStatuses = ["CREATED", "QUEUED", "RUNNING"]

taskStatus :: Value -> Text
taskStatus task = maybe "UNKNOWN" id (objText "status" task)

failureDetail :: Value -> Text
failureDetail task =
  case objText "failureReason" task of
    Just reason | not (T.null (T.strip reason)) -> ": " <> T.take 500 (T.unwords (T.words reason))
    _ -> ""

publicStatus :: Text -> Text
publicStatus = \case
  "COMPLETED" -> "Completed"
  "FAILED" -> "Failed"
  "CANCELLED" -> "Cancelled"
  "CANCELED" -> "Cancelled"
  "CREATED" -> "Created"
  "QUEUED" -> "Queued"
  "RUNNING" -> "Running"
  _ -> "Unknown"

taskResultUri :: Value -> Either Text Text
taskResultUri task = do
  bucket <-
    maybe (Left "Braket task did not include outputS3Bucket") Right (objText "outputS3Bucket" task)
  directory <-
    maybe
      (Left "Braket task did not include outputS3Directory")
      Right
      (objText "outputS3Directory" task)
  Right ("s3://" <> bucket <> "/" <> T.dropWhileEnd (== '/') directory <> "/results.json")

taskMeta :: Value -> TaskMeta
taskMeta task =
  TaskMeta
    { taskSuccessfulShots = objInt "numSuccessfulShots" task
    , taskWallClockSeconds = wallClock
    }
  where
    wallClock = do
      createdAt <- objLookup "createdAt" task >>= taskTimeSeconds
      endedAt <- objLookup "endedAt" task >>= taskTimeSeconds
      let delta = endedAt - createdAt
      if delta > 0 then Just delta else Nothing

taskTimeSeconds :: Value -> Maybe Rational
taskTimeSeconds (Number n) = Just (toRational n)
taskTimeSeconds (String s) =
  fmap (toRational . utcTimeToPOSIXSeconds) (parseIso8601 (T.unpack s))
taskTimeSeconds _ = Nothing

parseIso8601 :: String -> Maybe UTCTime
parseIso8601 s =
  parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" s
    <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%Ez" s

-- | A timestamped run prefix, e.g. @cortex/dev/wire-openqasm-20260623T031500Z@.
runS3Prefix :: Text -> IO Text
runS3Prefix prefix = do
  now <- getCurrentTime
  let stamp = T.pack (formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" now)
      clean = T.dropWhile (== '/') (T.dropWhileEnd (== '/') prefix)
  pure $ if T.null clean then "wire-openqasm-" <> stamp else clean <> "/wire-openqasm-" <> stamp

-- Small JSON accessors over a result object.

objLookup :: Text -> Value -> Maybe Value
objLookup key (Object km) = KeyMap.lookup (Key.fromText key) km
objLookup _ _ = Nothing

objPath :: [Text] -> Value -> Maybe Value
objPath [] value = Just value
objPath (key : rest) value = objLookup key value >>= objPath rest

objText :: Text -> Value -> Maybe Text
objText key value = case objLookup key value of
  Just (String t) -> Just t
  _ -> Nothing

objInt :: Text -> Value -> Maybe Int
objInt key value = case objLookup key value of
  Just (Number n) -> case properFraction n of
    (i, f) | f == 0 -> Just (i :: Int)
    _ -> Nothing
  _ -> Nothing

tshow :: Show a => a -> Text
tshow = T.pack . show

digestText :: Text -> Text
digestText raw =
  T.pack (show (hashlazy (BSL.fromStrict (TE.encodeUtf8 raw)) :: Digest SHA256))

-- | Emit a progress line to stderr so it never corrupts @--json@ stdout.
progress :: Text -> IO ()
progress msg = TIO.hPutStrLn stderr ("braket: " <> msg)

-- Settings/flag resolution shared by the runners.

-- | Command-line flag values, before env defaults are applied.
data SettingsFlags = SettingsFlags
  { sfShots :: !(Maybe Int)
  , sfPollInterval :: !(Maybe Int)
  , sfTimeout :: !(Maybe Int)
  , sfBackend :: !(Maybe Text)
  , sfDeviceArn :: !(Maybe Text)
  , sfBucket :: !(Maybe Text)
  , sfPrefix :: !(Maybe Text)
  , sfRegion :: !(Maybe Text)
  , sfProfile :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | Resolve full Braket settings from flags and the environment.
resolveBraketSettings :: SettingsFlags -> IO (Either Text BraketSettings)
resolveBraketSettings flags = do
  region <- resolveRegion (sfRegion flags)
  envDeviceArn <- lookupEnvText "CORTEX_BRAKET_DEVICE_ARN"
  envBucket <- lookupEnvText "CORTEX_BRAKET_BUCKET"
  envPrefix <- lookupEnvText "CORTEX_BRAKET_PREFIX"
  envProfile <- lookupEnvText "AWS_PROFILE"
  overrides <- resolveOverrides
  pure $ do
    deviceArn <- resolveDeviceArn (sfDeviceArn flags) (sfBackend flags) envDeviceArn
    Right
      BraketSettings
        { bsDeviceArn = deviceArn
        , bsRegion = region
        , bsBucket = sfBucket flags <|> envBucket
        , bsPrefix = fromMaybe "cortex/dev" (sfPrefix flags <|> envPrefix)
        , bsProfile = sfProfile flags <|> envProfile <|> Just "cortex-braket"
        , bsShots = fromMaybe 100 (sfShots flags)
        , bsPollInterval = fromMaybe 5 (sfPollInterval flags)
        , bsTimeout = fromMaybe 900 (sfTimeout flags)
        , bsOverrides = overrides
        }

-- | Resolve the execution mode, refusing a hardware submit without confirmation.
resolveExecMode :: Bool -> Bool -> Either Text ExecMode
resolveExecMode dryRun confirm
  | dryRun = Right DryRun
  | confirm = Right Hardware
  | otherwise =
      Left
        "refusing to submit an Amazon Braket task without --confirm-hardware; use --dry-run to inspect the request locally"

-- | The AWS CLI binary path from @CORTEX_AWS_BIN@ (default @aws@).
resolveAwsBin :: IO FilePath
resolveAwsBin = fromMaybe "aws" <$> lookupEnv "CORTEX_AWS_BIN"

resolveRegion :: Maybe Text -> IO Text
resolveRegion flag = do
  cortexRegion <- lookupEnvText "CORTEX_BRAKET_REGION"
  awsRegion <- lookupEnvText "AWS_REGION"
  awsDefaultRegion <- lookupEnvText "AWS_DEFAULT_REGION"
  pure (fromMaybe "us-east-1" (flag <|> cortexRegion <|> awsRegion <|> awsDefaultRegion))

resolveOverrides :: IO CostOverrides
resolveOverrides =
  CostOverrides
    <$> decimalEnv "CORTEX_BRAKET_TASK_PRICE_USD"
    <*> decimalEnv "CORTEX_BRAKET_SHOT_PRICE_USD"
    <*> decimalEnv "CORTEX_BRAKET_SIMULATOR_MINUTE_PRICE_USD"

decimalEnv :: String -> IO (Maybe Rational)
decimalEnv name = do
  value <- lookupEnv name
  pure $ case value >>= readMaybe of
    Just d | d >= (0 :: Double) -> Just (toRational d)
    _ -> Nothing

lookupEnvText :: String -> IO (Maybe Text)
lookupEnvText name = do
  value <- lookupEnv name
  pure $ case value of
    Just raw | not (null raw) -> Just (T.pack raw)
    _ -> Nothing
